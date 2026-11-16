defmodule Eab.ModelSource do
  @moduledoc """
  Where a local model's weight files came from, as the operator declares it (ADR 0018): the
  file's URL, parsed into host, Hugging Face author, repository, revision and path, plus an
  optional release label. A Hugging Face file is looked up on the Hub: the commit its
  revision pointed to and each shard's sha256 and size. Makers overwrite files under the same
  name, so the record keeps the commit and hashes even after the file stops being
  downloadable, and `verify/3` compares them with the hashes measured on the model host.
  """

  @hosts ~w(huggingface.co www.huggingface.co hf.co)
  @shard ~r/\A(.*)-(\d{5})-of-(\d{5})(\.gguf)\z/i
  @label_length 40
  # The most commits the history search checks; each checked commit is one Hub request.
  @history_checks 40
  @history_pages 4

  @doc "Parses a declared URL and label into a source record, or returns an error message."
  def declare(url, label \\ "", by \\ "operator") do
    with {:ok, source} <- parse(url),
         {:ok, label} <- release_label(label) do
      {:ok,
       Map.merge(source, %{
         "release_label" => label,
         "declared_by" => by,
         "declared_at" => DateTime.utc_now() |> DateTime.to_iso8601()
       })}
    end
  end

  def parse(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))

    cond do
      String.trim(url) == "" ->
        {:error, "Enter the URL of the model file you downloaded"}

      uri.scheme not in ["http", "https"] or not is_binary(uri.host) or uri.host == "" ->
        {:error, "Enter an http(s) URL of the model file"}

      uri.userinfo != nil ->
        {:error, "Enter the URL without embedded credentials"}

      String.downcase(uri.host) in @hosts ->
        hugging_face(uri)

      true ->
        file = (uri.path || "") |> String.split("/", trim: true) |> List.last()
        file = file && URI.decode(file)

        if file in [nil, ""],
          do: {:error, "Enter the URL of the model file itself, not a folder or page"},
          else:
            {:ok,
             %{
               # A signed query can carry credentials, so it is not kept.
               "url" => URI.to_string(%{uri | query: nil, fragment: nil}),
               "host" => String.downcase(uri.host),
               "author" => nil,
               "repository" => nil,
               "revision" => nil,
               "path" => file,
               "file" => file,
               "shards" => [file]
             }}
    end
  end

  def parse(_), do: {:error, "Enter the URL of the model file you downloaded"}

  defp hugging_face(uri) do
    segments = (uri.path || "") |> String.split("/", trim: true) |> Enum.map(&URI.decode/1)

    case segments do
      [kind | _] when kind in ~w(datasets spaces) ->
        {:error, "Link a model repository's file, not a dataset or Space"}

      [author, repo, view, revision | path] when view in ~w(blob resolve) and path != [] ->
        path = Enum.join(path, "/")
        file = Path.basename(path)
        repository = author <> "/" <> repo

        {:ok,
         %{
           "url" =>
             "https://huggingface.co/#{repository}/blob/#{URI.encode(revision, &URI.char_unreserved?/1)}/" <>
               Enum.map_join(String.split(path, "/"), "/", &URI.encode/1),
           "host" => "huggingface.co",
           "author" => author,
           "repository" => repository,
           "revision" => revision,
           "path" => path,
           "file" => file,
           "shards" => shards(path)
         }}

      _ ->
        {:error,
         "Link the model file itself, as https://huggingface.co/<author>/<repository>/blob/<revision>/<file>"}
    end
  end

  @doc "Every shard path of a numbered GGUF set (any shard may be linked), or the one path."
  def shards(path) do
    case Regex.run(@shard, path) do
      [_, prefix, _index, count, ext] ->
        total = String.to_integer(count)

        if total in 1..1024,
          do: for(i <- 1..total, do: "#{prefix}-#{pad(i)}-of-#{count}#{ext}"),
          else: [path]

      nil ->
        [path]
    end
  end

  defp pad(i), do: String.pad_leading(to_string(i), 5, "0")

  defp release_label(value) when value in [nil, ""], do: {:ok, nil}

  defp release_label(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:ok, nil}
      String.length(value) > @label_length -> {:error, "Keep the release label short"}
      not String.printable?(value) -> {:error, "The release label must be plain text"}
      true -> {:ok, value}
    end
  end

  defp release_label(_), do: {:error, "The release label must be plain text"}

  def hugging_face?(source), do: is_map(source) and source["host"] == "huggingface.co"

  @doc """
  Looks a Hugging Face source up on the Hub: the commit its revision points to now, and each
  shard's sha256, size and last-changed commit. Other sources are returned unchanged.
  """
  def look_up(source) do
    if hugging_face?(source) do
      case revision(source, source["revision"]) do
        {:ok, commit, date} ->
          case files(source, commit) do
            {:ok, files} ->
              Map.merge(source, %{
                "lookup" => %{
                  "commit" => commit,
                  "commit_date" => date,
                  "files" => files,
                  "looked_up_at" => DateTime.utc_now() |> DateTime.to_iso8601()
                },
                "lookup_error" => nil
              })

            {:error, message} ->
              Map.merge(source, %{"lookup" => nil, "lookup_error" => message})
          end

        {:error, message} ->
          Map.merge(source, %{"lookup" => nil, "lookup_error" => message})
      end
    else
      source
    end
  end

  defp revision(source, revision) do
    case hub(:get, "/api/models/#{source["repository"]}/revision/#{encode(revision)}") do
      {:ok, %{"sha" => commit} = body} when is_binary(commit) ->
        if commit =~ ~r/\A[0-9a-f]{40}\z/,
          do: {:ok, commit, body["lastModified"]},
          else: {:error, "Hugging Face returned an invalid commit"}

      {:ok, _} ->
        {:error, "Hugging Face returned no commit for #{source["repository"]}@#{revision}"}

      {:error, message} ->
        {:error, message}
    end
  end

  # The listed shards at one commit, in shard order; an error when any is missing.
  defp files(source, commit) do
    paths = source["shards"]
    form = Enum.map(paths, &{"paths", &1}) ++ [{"expand", "true"}]

    case hub(:post, "/api/models/#{source["repository"]}/paths-info/#{commit}", form) do
      {:ok, rows} when is_list(rows) ->
        found = Map.new(rows, &{&1["path"], &1})

        if Enum.all?(paths, &Map.has_key?(found, &1)) do
          {:ok,
           Enum.map(paths, fn path ->
             row = found[path]
             last = row["lastCommit"] || %{}

             %{
               "path" => path,
               "size_bytes" => get_in(row, ["lfs", "size"]) || row["size"],
               "sha256" => sha256(get_in(row, ["lfs", "oid"])),
               "last_commit" => last["id"],
               "last_commit_date" => last["date"]
             }
           end)}
        else
          missing = Enum.reject(paths, &Map.has_key?(found, &1))

          {:error,
           "#{source["repository"]} has no #{Enum.join(missing, ", ")} at commit #{String.slice(commit, 0, 12)}"}
        end

      {:ok, _} ->
        {:error, "Hugging Face returned unexpected file information"}

      {:error, message} ->
        {:error, message}
    end
  end

  defp sha256(value) when is_binary(value),
    do: if(value =~ ~r/\A[0-9a-f]{64}\z/, do: value)

  defp sha256(_), do: nil

  @doc """
  Compares the hashes measured on the model host with the source. `verified` names the commit
  that uploaded those exact bytes. When the declared revision has moved on, as when a maker
  overwrote the file, the repository's history is searched for the upload that matches.
  `differs` means the source was read and nothing in it matches; `not_checked` that a side is
  missing. Options: `network: false` uses only the stored lookup.
  """
  def verify(source, measured, opts \\ [])

  def verify(nil, _measured, _opts), do: nil

  def verify(source, measured, opts) do
    cond do
      not hashed?(measured) ->
        not_checked(source, "The served files were not hashed on the model host")

      not hugging_face?(source) ->
        not_checked(source, "Only Hugging Face files can be compared with their source")

      same?(source["lookup"], measured) ->
        verified(source, source["lookup"]["files"], false)

      opts[:network] == false ->
        if source["lookup"],
          do: differs(source),
          else: not_checked(source, source["lookup_error"] || "The source was not looked up")

      true ->
        source = if source["lookup"], do: source, else: look_up(source)

        cond do
          same?(source["lookup"], measured) ->
            verified(source, source["lookup"]["files"], false)

          is_nil(source["lookup"]) ->
            not_checked(source, source["lookup_error"])

          true ->
            case search(source, measured) do
              {:ok, files} ->
                verified(source, files, true)

              {:error, nil} ->
                differs(source)

              {:error, message} ->
                differs(
                  source,
                  "The served files' sha256 differ from #{source["repository"]}@#{source["revision"]}; its history could not be searched: #{message}"
                )
            end
        end
    end
  end

  defp hashed?(files),
    do: is_list(files) and files != [] and Enum.all?(files, &is_binary(&1["sha256"]))

  # Shards pair by position, so a renamed download still compares with its source.
  defp same?(%{"files" => expected}, measured) when is_list(expected),
    do:
      length(expected) == length(measured) and
        Enum.all?(Enum.zip(expected, measured), fn {e, m} ->
          is_binary(e["sha256"]) and e["sha256"] == m["sha256"] and
            (is_nil(e["size_bytes"]) or e["size_bytes"] == m["size_bytes"])
        end)

  defp same?(_, _), do: false

  defp verified(source, files, history) do
    upload = Enum.max_by(files, &(&1["last_commit_date"] || ""), fn -> %{} end)

    Map.merge(source, %{
      "verification" => "verified",
      "verification_note" =>
        if(history,
          do:
            "#{source["revision"]} has changed since; this upload is in the repository's history"
        ),
      "commit" => upload["last_commit"] || get_in(source, ["lookup", "commit"]),
      "commit_date" => upload["last_commit_date"] || get_in(source, ["lookup", "commit_date"])
    })
  end

  defp differs(source, note \\ nil) do
    Map.merge(source, %{
      "verification" => "differs",
      "verification_note" =>
        note ||
          "The served files' sha256 differ from #{source["repository"]}@#{source["revision"]} and from the uploads in its recent history",
      "commit" => get_in(source, ["lookup", "commit"]),
      "commit_date" => get_in(source, ["lookup", "commit_date"])
    })
  end

  defp not_checked(source, note) do
    Map.merge(source, %{
      "verification" => "not_checked",
      "verification_note" => note,
      "commit" => get_in(source, ["lookup", "commit"]),
      "commit_date" => get_in(source, ["lookup", "commit_date"])
    })
  end

  # Walks the revision's commits, newest first. Each checked commit says which commit last
  # changed the files, so the commits in between hold the same upload and are skipped.
  defp search(source, measured) do
    lookup = source["lookup"]

    case commits(source) do
      {:ok, commits} ->
        # The declared revision's own upload was compared already.
        start = skip_to(lookup["files"], lookup["commit"]) || lookup["commit"]

        commits
        |> Enum.reduce_while({start, 0}, fn commit, {skip, checked} ->
          cond do
            skip != nil ->
              {:cont, {if(commit == skip, do: nil, else: skip), checked}}

            checked >= @history_checks ->
              {:halt, {nil, checked}}

            true ->
              case files(source, commit) do
                {:ok, files} ->
                  if same?(%{"files" => files}, measured),
                    do: {:halt, {:found, files}},
                    else: {:cont, {skip_to(files, commit), checked + 1}}

                {:error, _} ->
                  {:cont, {nil, checked + 1}}
              end
          end
        end)
        |> case do
          {:found, files} -> {:ok, files}
          _ -> {:error, nil}
        end

      {:error, message} ->
        {:error, message}
    end
  end

  defp skip_to(files, commit) do
    case Enum.map(files, & &1["last_commit"]) |> Enum.uniq() do
      [last] when is_binary(last) and last != commit -> last
      _ -> nil
    end
  end

  defp commits(source) do
    path = "/api/models/#{source["repository"]}/commits/#{encode(source["revision"])}"

    Enum.reduce_while(1..@history_pages, {path, []}, fn _, {path, acc} ->
      case hub_page(path) do
        {:ok, rows, next} ->
          acc = acc ++ for %{"id" => id} <- rows, is_binary(id), do: id
          if next, do: {:cont, {next, acc}}, else: {:halt, {nil, acc}}

        {:error, message} ->
          {:halt, {:error, message}}
      end
    end)
    |> case do
      {:error, message} -> {:error, message}
      {_, ids} -> {:ok, ids}
    end
  end

  defp encode(revision), do: URI.encode(revision, &URI.char_unreserved?/1)

  defp hub(method, path, form \\ nil) do
    case request(method, base() <> path, form) do
      {:ok, body, _} -> {:ok, body}
      {:error, message} -> {:error, message}
    end
  end

  defp hub_page(path) do
    url = if String.starts_with?(path, "http"), do: path, else: base() <> path

    case request(:get, url, nil) do
      {:ok, body, headers} when is_list(body) -> {:ok, body, next(headers)}
      {:ok, _, _} -> {:error, "Hugging Face returned an unexpected commit list"}
      {:error, message} -> {:error, message}
    end
  end

  # A next page is followed only on the Hub itself.
  defp next(headers) do
    link =
      Enum.find_value(headers || %{}, fn {name, value} ->
        if String.downcase(name) == "link", do: List.wrap(value) |> Enum.join(",")
      end)

    with link when is_binary(link) <- link,
         [_, url] <- Regex.run(~r/<([^>]+)>;\s*rel="next"/, link),
         true <- String.starts_with?(url, base() <> "/") do
      url
    else
      _ -> nil
    end
  end

  defp request(method, url, form) do
    opts = [
      method: method,
      url: url,
      retry: false,
      redirect: true,
      max_redirects: 3,
      receive_timeout: 20_000,
      connect_options: [timeout: 10_000]
    ]

    opts = if form, do: Keyword.put(opts, :form, form), else: opts
    request = Application.get_env(:eab, :hugging_face_request, &Req.request/1)

    case request.(opts) do
      {:ok, %{status: status, body: body} = response} when status in 200..299 ->
        {:ok, body, Map.get(response, :headers, %{})}

      {:ok, %{status: status}} when status in [401, 403, 404] ->
        {:error,
         "Hugging Face has no such public file or revision (HTTP #{status}); check the link"}

      {:ok, %{status: status}} ->
        {:error, "Hugging Face returned HTTP #{status}"}

      {:error, error} ->
        {:error, "Hugging Face could not be reached: #{error_text(error)}"}
    end
  rescue
    error -> {:error, "Hugging Face could not be reached: #{Exception.message(error)}"}
  end

  defp error_text(error) when is_exception(error), do: Exception.message(error)
  defp error_text(error), do: inspect(error)

  defp base, do: Application.get_env(:eab, :hugging_face_url, "https://huggingface.co")

  @public ~w(url host author repository revision path file release_label declared_by commit
    commit_date verification verification_note)

  def public_fields, do: @public

  @doc "The checked source as a published series records it; lookups and hashes stay private."
  def public(nil), do: nil
  def public(source), do: Map.new(@public, &{&1, source[&1]})

  @doc "A pinned link to the file at the commit that uploaded it, or the declared URL."
  def pinned_url(%{"repository" => repo, "path" => path, "commit" => commit} = source)
      when is_binary(repo) and is_binary(commit) do
    if hugging_face?(source),
      do:
        "https://huggingface.co/#{repo}/blob/#{commit}/" <>
          Enum.map_join(String.split(path, "/"), "/", &URI.encode/1),
      else: source["url"]
  end

  def pinned_url(source), do: source && source["url"]

  @doc "Remembers the source last declared for a served file, to offer it on the next connect."
  def remember(artifact, source) when is_binary(artifact) do
    sources = Eab.Store.read("model-sources.json", %{})

    Eab.Store.write(
      "model-sources.json",
      Map.put(sources, artifact, %{
        "url" => source["url"],
        "release_label" => source["release_label"] || ""
      })
    )
  end

  def remember(_, _), do: :ok

  def remembered(artifact) when is_binary(artifact) do
    case Eab.Store.read("model-sources.json", %{})[artifact] do
      %{"url" => url} = row when is_binary(url) ->
        %{"url" => url, "release_label" => row["release_label"] || ""}

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def remembered(_), do: nil

  @doc "One line for the dashboard: where the file came from and how far that is checked."
  def label(nil), do: "Not declared"

  def label(source) do
    where =
      if source["repository"],
        do: "#{source["repository"]} · #{source["file"]} @ #{source["revision"]}",
        else: source["url"]

    commit =
      case get_in(source, ["lookup", "commit"]) do
        commit when is_binary(commit) -> " (commit #{String.slice(commit, 0, 7)})"
        _ -> ""
      end

    release = if source["release_label"], do: " · #{source["release_label"]}", else: ""
    where <> commit <> release
  end
end
