defmodule Eab.ModelSourceTest do
  use ExUnit.Case, async: false
  alias Eab.ModelSource

  @repo "unsloth/Qwen3.8-27B-GGUF"
  @file_path "Qwen3.8-27B-UD-Q6_K_L.gguf"
  @head String.duplicate("3", 40)
  @readme String.duplicate("2", 40)
  @v3_1 String.duplicate("1", 40)
  @v3 String.duplicate("0", 40)
  @sha_v3_1 String.duplicate("e", 64)
  @sha_v3 String.duplicate("d", 64)

  setup do
    on_exit(fn -> Application.delete_env(:eab, :hugging_face_request) end)
    :ok
  end

  test "a Hugging Face file link names its author, repository, revision and every shard" do
    assert {:ok, source} =
             ModelSource.declare(
               "https://huggingface.co/#{@repo}/resolve/main/UD-Q6_K_L/Q-00002-of-00003.gguf?download=true",
               " v3.1 "
             )

    assert source["url"] ==
             "https://huggingface.co/#{@repo}/blob/main/UD-Q6_K_L/Q-00002-of-00003.gguf"

    assert Map.take(source, ~w(host author repository revision path file release_label)) == %{
             "host" => "huggingface.co",
             "author" => "unsloth",
             "repository" => @repo,
             "revision" => "main",
             "path" => "UD-Q6_K_L/Q-00002-of-00003.gguf",
             "file" => "Q-00002-of-00003.gguf",
             "release_label" => "v3.1"
           }

    assert source["shards"] == for(i <- 1..3, do: "UD-Q6_K_L/Q-0000#{i}-of-00003.gguf")
    assert source["declared_by"] == "operator"

    assert {:ok, %{"revision" => "refs/pr/4"}} =
             ModelSource.parse("https://hf.co/#{@repo}/blob/refs%2Fpr%2F4/#{@file_path}")
  end

  test "repository pages, datasets, credentials and long labels are refused; other hosts keep only the file" do
    for url <- [
          "https://huggingface.co/#{@repo}",
          "https://huggingface.co/#{@repo}/tree/main",
          "https://huggingface.co/datasets/a/b/blob/main/x.gguf",
          "https://user:pass@example.com/x.gguf",
          "ftp://example.com/x.gguf",
          ""
        ],
        do: assert({:error, _} = ModelSource.parse(url))

    assert {:error, _} =
             ModelSource.declare("https://example.com/x.gguf", String.duplicate("v", 41))

    assert {:ok, source} =
             ModelSource.parse("https://models.example.com/q/Model-Q4_K_M.gguf?token=secret#x")

    assert source["url"] == "https://models.example.com/q/Model-Q4_K_M.gguf"
    assert source["file"] == "Model-Q4_K_M.gguf"
    assert source["repository"] == nil
  end

  # A repository whose main branch had the file overwritten: v3 was uploaded in @v3, replaced
  # by v3.1 in @v3_1, then a README commit (@readme) and the head (@head) left it alone.
  defp hub(parent) do
    Application.put_env(:eab, :hugging_face_request, fn opts ->
      send(parent, {:hub, opts[:method], URI.parse(opts[:url]).path})
      path = URI.parse(opts[:url]).path

      body =
        cond do
          path == "/api/models/#{@repo}/revision/main" ->
            %{"sha" => @head, "lastModified" => "2026-11-12T08:00:00.000Z"}

          String.starts_with?(path, "/api/models/#{@repo}/paths-info/") ->
            commit = Path.basename(path)

            {sha, last, date} =
              if commit == @v3,
                do: {@sha_v3, @v3, "2026-10-01T00:00:00.000Z"},
                else: {@sha_v3_1, @v3_1, "2026-11-10T00:00:00.000Z"}

            [
              %{
                "type" => "file",
                "path" => @file_path,
                "size" => 135,
                "lfs" => %{"oid" => sha, "size" => 24_170_553_344},
                "lastCommit" => %{"id" => last, "date" => date}
              }
            ]

          path == "/api/models/#{@repo}/commits/main" ->
            Enum.map([@head, @readme, @v3_1, @v3], &%{"id" => &1})
        end

      {:ok, %{status: 200, body: body, headers: %{}}}
    end)
  end

  defp declared do
    {:ok, source} = ModelSource.declare("https://huggingface.co/#{@repo}/blob/main/#{@file_path}")
    source
  end

  defp served(sha), do: [%{"name" => @file_path, "size_bytes" => 24_170_553_344, "sha256" => sha}]

  test "a lookup pins the revision's commit and the file's sha256, size and upload" do
    hub(self())
    source = ModelSource.look_up(declared())
    assert source["lookup"]["commit"] == @head
    assert source["lookup_error"] == nil

    assert [%{"sha256" => @sha_v3_1, "size_bytes" => 24_170_553_344, "last_commit" => @v3_1}] =
             source["lookup"]["files"]

    checked = ModelSource.verify(source, served(@sha_v3_1), network: false)
    assert checked["verification"] == "verified"
    assert checked["commit"] == @v3_1
    assert checked["commit_date"] == "2026-11-10T00:00:00.000Z"

    assert ModelSource.pinned_url(checked) ==
             "https://huggingface.co/#{@repo}/blob/#{@v3_1}/#{@file_path}"
  end

  test "an overwritten file is found in the repository's history by its sha256" do
    hub(self())
    source = ModelSource.look_up(declared())
    flush()

    # Offline, the stored lookup only shows that main no longer holds the served file.
    assert ModelSource.verify(source, served(@sha_v3), network: false)["verification"] ==
             "differs"

    checked = ModelSource.verify(source, served(@sha_v3))
    assert checked["verification"] == "verified"
    assert checked["commit"] == @v3
    assert checked["verification_note"] =~ "main has changed since"

    # The commits between the head and the v3.1 upload hold the same file and are skipped.
    checked_commits =
      for {:hub, :post, path} <- messages(), do: Path.basename(path)

    assert checked_commits == [@v3]
  end

  test "files found nowhere differ; unhashed or non-Hub files are not checked" do
    hub(self())
    source = ModelSource.look_up(declared())

    assert ModelSource.verify(source, served(String.duplicate("f", 64)))["verification"] ==
             "differs"

    assert ModelSource.verify(source, nil)["verification"] == "not_checked"

    assert ModelSource.verify(source, [%{"name" => "x", "sha256" => nil}])["verification"] ==
             "not_checked"

    assert ModelSource.verify(nil, served(@sha_v3)) == nil

    {:ok, other} = ModelSource.declare("https://example.com/#{@file_path}")
    assert ModelSource.verify(other, served(@sha_v3))["verification"] == "not_checked"

    public = ModelSource.public(ModelSource.verify(source, served(@sha_v3_1)))
    assert Enum.sort(Map.keys(public)) == Enum.sort(ModelSource.public_fields())
    refute Map.has_key?(public, "lookup")
  end

  test "an unreachable or private repository is recorded as not looked up" do
    Application.put_env(:eab, :hugging_face_request, fn _ -> {:ok, %{status: 401, body: %{}}} end)
    source = ModelSource.look_up(declared())
    assert source["lookup"] == nil
    assert source["lookup_error"] =~ "HTTP 401"

    Application.put_env(:eab, :hugging_face_request, fn _ -> {:error, :nxdomain} end)
    source = ModelSource.look_up(declared())
    assert source["lookup_error"] =~ "could not be reached"
    assert ModelSource.verify(source, served(@sha_v3))["verification"] == "not_checked"
  end

  defp flush do
    receive do
      {:hub, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp messages(acc \\ []) do
    receive do
      {:hub, _, _} = message -> messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
