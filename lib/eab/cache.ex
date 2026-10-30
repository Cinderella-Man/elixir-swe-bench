defmodule Eab.Cache do
  @moduledoc "Content-addressed, atomically published preparation artifacts."
  alias Eab.{Inventory, Store}

  def key(inputs), do: Inventory.hash(:erlang.term_to_binary(inputs, [:deterministic]))

  def fetch(kind, inputs, build, opts \\ []) do
    Eab.Retention.with_use(fn -> do_fetch(kind, inputs, build, opts) end)
  end

  defp do_fetch(kind, inputs, build, opts) do
    id = key(inputs)

    locked({kind, id}, fn ->
      case lookup(kind, id, opts) do
        {:ok, artifact} ->
          {artifact, :reused}

        {:missing, reason} ->
          if Eab.Readiness.offline?(),
            do:
              raise(
                "Offline mode cannot prepare #{kind}: #{reason}. Reconnect the internet and click Prepare all cases."
              )

          File.mkdir_p!(Store.root())
          Eab.Retention.ensure_space!(opts)
          artifact = build.(reason) |> Map.put_new("images", [])
          images = Map.get(artifact, "images", [])
          exists? = Keyword.get(opts, :image_exists?, &Eab.Fixtures.image_exists?/1)

          unless Enum.all?(images, exists?), do: raise("Cannot publish missing cache images")

          record = %{
            "version" => 1,
            "id" => id,
            "inputs" => inputs,
            "artifact" => artifact,
            "checksum" => key(artifact)
          }

          Store.write(path(kind, id), record)
          {artifact, :built}
      end
    end)
  end

  def lookup(kind, id, opts \\ []) do
    exists? = Keyword.get(opts, :image_exists?, &Eab.Fixtures.image_exists?/1)

    case read(path(kind, id)) do
      %{"version" => 1, "id" => ^id, "inputs" => inputs, "artifact" => artifact} = record
      when is_map(artifact) ->
        cond do
          key(inputs) != id or key(artifact) != record["checksum"] ->
            {:missing, "invalid artifact record"}

          not is_list(artifact["images"]) ->
            {:missing, "invalid image inventory"}

          not Enum.all?(artifact["images"], exists?) ->
            {:missing, "a cached image is missing from Docker"}

          true ->
            {:ok, artifact}
        end

      nil ->
        {:missing, "no saved artifact"}

      _ ->
        {:missing, "invalid artifact record"}
    end
  end

  def records(kind) do
    validate_kind!(kind)

    Path.wildcard(Store.path("cache/#{kind}/*.json"))
    |> Enum.flat_map(fn file ->
      case read(Path.relative_to(file, Store.root())) do
        %{"version" => 1, "id" => id, "inputs" => inputs, "artifact" => artifact} = record
        when is_map(artifact) ->
          if key(inputs) == id and key(artifact) == record["checksum"], do: [record], else: []

        _ ->
          []
      end
    end)
  end

  def locked(resource, fun) do
    # A monitored global lock is released if its worker is cancelled. The store
    # root is part of the resource so independent installations/tests don't mix.
    :global.trans({{__MODULE__, Store.root(), resource}, self()}, fun, [node()])
  end

  defp path(kind, id) do
    validate_kind!(kind)
    unless is_binary(id) and Regex.match?(~r/^[a-f0-9]{64}$/, id), do: raise("Invalid cache id")
    "cache/#{kind}/#{id}.json"
  end

  defp validate_kind!(kind) do
    unless is_binary(kind) and Regex.match?(~r/^[a-z][a-z-]*$/, kind),
      do: raise("Invalid cache kind")
  end

  defp read(path) do
    Store.read(path)
  rescue
    Jason.DecodeError -> nil
  end
end
