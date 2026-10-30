defmodule Eab.Retention do
  @moduledoc "Explicit baseline retention, conservative shared references and active-use protection."
  alias Eab.{Cache, Command, Store}
  @managed ~w(agents projects databases)

  def with_use(fun) do
    key = {:cache_users, Store.root()}
    ref = make_ref()
    Cache.locked(:retention, fn -> Registry.register(Eab.Commands, key, ref) end)

    try do
      fun.()
    after
      Registry.unregister_match(Eab.Commands, key, ref)
    end
  end

  def lease(run_id) do
    unless Store.valid_id?(run_id), do: raise("Invalid lease owner")

    if Registry.lookup(Eab.Commands, {:cache_removal, Store.root()}) != [],
      do: raise("Cache removal is active; wait for it to finish")

    Cache.locked(:retention, fn -> Store.write("leases/#{run_id}.json", %{"run" => run_id}) end)
  end

  def release(run_id) do
    unless Store.valid_id?(run_id), do: raise("Invalid lease owner")

    Cache.locked(:retention, fn ->
      File.rm(Store.path("leases/#{run_id}.json"))
      :ok
    end)
  end

  def leased_runs do
    Path.wildcard(Store.path("leases/*.json"))
    |> Enum.map(&Path.basename(&1, ".json"))
    |> Enum.filter(&Store.valid_id?/1)
  end

  def retain(id, runtime, release \\ nil) do
    unless Store.valid_id?(id), do: raise("Invalid retained case")
    if release, do: validate_release!(release)
    images = runtime_images(runtime)
    key = Cache.key(images)
    path = "retained/#{id}/#{key}.json"

    Cache.locked(:retention, fn ->
      previous = Store.read(path) || %{}

      releases =
        ((previous["releases"] || []) ++ if(release, do: [release], else: []))
        |> Enum.uniq()
        |> Enum.sort()

      Store.write(path, %{"case" => id, "images" => images, "releases" => releases})
    end)
  end

  def ensure_space!(opts \\ []) do
    reserve =
      Keyword.get(
        opts,
        :reserve_bytes,
        Application.get_env(:eab, :cache_reserve_bytes, 5 * 1024 * 1024 * 1024)
      )

    unless is_integer(reserve) and reserve >= 0, do: raise("Invalid cache free-space reserve")

    if reserve > 0 do
      free = Keyword.get(opts, :free_bytes, &free_bytes/1)

      paths =
        [Store.root(), Application.get_env(:eab, :docker_storage_path)]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      for path <- paths do
        unless File.dir?(path), do: raise("Storage reserve path is unavailable: #{path}")

        if free.(path) < reserve,
          do:
            raise(
              "Preparation paused: free space is below the configured #{reserve}-byte reserve at #{path}. Retained baselines were not evicted."
            )
      end
    end

    :ok
  end

  def status do
    roots = roots()

    %{
      "cases" => roots |> Enum.map(& &1["case"]) |> Enum.uniq() |> Enum.sort(),
      "releases" => roots |> Enum.flat_map(&(&1["releases"] || [])) |> Enum.uniq() |> Enum.sort(),
      "baselines" => length(roots),
      "images" => roots |> Enum.flat_map(& &1["images"]) |> Enum.uniq() |> length(),
      "leases" => length(leased_runs())
    }
  rescue
    error ->
      %{
        "cases" => [],
        "releases" => [],
        "baselines" => nil,
        "images" => nil,
        "error" => "Cache records need attention: #{Exception.message(error)}"
      }
  end

  def preview(id) do
    release =
      case id do
        "release:" <> release ->
          validate_release!(release)
          release

        _ ->
          unless id == "unused" or Store.valid_id?(id), do: raise("Invalid cache selection")
          nil
      end

    records =
      for kind <- @managed, record <- Cache.records(kind), do: Map.put(record, "kind", kind)

    roots = roots()

    {affected, retained} =
      Enum.split_with(roots, fn root ->
        if release, do: release in (root["releases"] || []), else: root["case"] == id
      end)

    {updated, removed} =
      if release do
        affected
        |> Enum.map(&Map.update(&1, "releases", [], fn ids -> List.delete(ids, release) end))
        |> Enum.split_with(&(&1["releases"] != []))
      else
        {[], affected}
      end

    retained = retained ++ updated
    keep = closure(Enum.flat_map(retained, & &1["images"]), records)

    selected =
      if id == "unused",
        do: MapSet.new(Enum.map(records, &ref/1)),
        else: closure(Enum.flat_map(affected, & &1["images"]), records)

    victims =
      Enum.filter(
        records,
        &(MapSet.member?(selected, ref(&1)) and not MapSet.member?(keep, ref(&1)))
      )

    keep_images =
      records
      |> Enum.filter(&MapSet.member?(keep, ref(&1)))
      |> Enum.flat_map(& &1["artifact"]["images"])

    images =
      victims
      |> Enum.flat_map(& &1["artifact"]["images"])
      |> Enum.uniq()
      |> Enum.reject(&(&1 in keep_images))
      |> Enum.sort()

    plan = %{
      "case" => id,
      "roots" => removed,
      "updated_roots" => updated,
      "affected_cases" => Enum.map(affected, & &1["case"]) |> Enum.uniq() |> Enum.sort(),
      "records" => victims,
      "images" => images,
      "shared_records_preserved" =>
        Enum.count(
          records,
          &(MapSet.member?(selected, ref(&1)) and MapSet.member?(keep, ref(&1)))
        )
    }

    Map.put(plan, "id", Cache.key(plan))
  end

  def remove(id, expected, opts \\ []) do
    if Eab.Readiness.offline?(),
      do: raise("Offline mode keeps prepared state: it cannot be rebuilt without internet")

    key = {:cache_removal, Store.root()}
    Registry.register(Eab.Commands, key, nil)

    try do
      do_remove(id, expected, opts)
    after
      Registry.unregister(Eab.Commands, key)
    end
  end

  defp do_remove(id, expected, opts) do
    Cache.locked(:retention, fn ->
      unless Path.wildcard(Store.path("leases/*.json")) == [] and
               Registry.lookup(Eab.Commands, {:cache_users, Store.root()}) == [],
             do: raise("Cached state is in use; wait for active runs, preparation and cleanup")

      plan = preview(id)

      unless plan["id"] == expected,
        do: raise("Cache references changed; review a new removal preview")

      remove = Keyword.get(opts, :remove_image, &remove_image/1)
      # Delete children before parents; Docker refuses remaining dependencies or
      # unrelated tags. Never use force or a daemon-wide prune.
      records =
        Enum.sort_by(plan["records"], fn record ->
          {if(record["kind"] == "agents", do: 0, else: 1), -(record["artifact"]["depth"] || 0)}
        end)

      images =
        records
        |> Enum.flat_map(& &1["artifact"]["images"])
        |> Enum.uniq()
        |> Enum.filter(&(&1 in plan["images"]))

      results = Map.new(images, &{&1, remove.(&1)})

      for record <- records,
          Enum.all?(record["artifact"]["images"], &(results[&1] == :ok)) do
        File.rm!(Store.path("cache/#{record["kind"]}/#{record["id"]}.json"))
      end

      for root <- plan["roots"], do: File.rm!(Store.path(root["path"]))
      for root <- plan["updated_roots"], do: Store.write(root["path"], Map.delete(root, "path"))

      for case_id <- plan["affected_cases"] do
        runtime = Store.read("runtimes/#{case_id}.json")

        if runtime &&
             (runtime["image"] in plan["images"] or
                not Enum.any?(
                  roots(),
                  &(&1["case"] == case_id and &1["path"] != "runtimes/#{case_id}.json")
                )),
           do: File.rm(Store.path("runtimes/#{case_id}.json"))
      end

      failures =
        for {image, {:error, message}} <- results, do: %{"image" => image, "reason" => message}

      %{
        "removed_images" => Enum.count(results, fn {_, result} -> result == :ok end),
        "retained_images" => failures
      }
    end)
  end

  defp roots do
    retained =
      for file <- Path.wildcard(Store.path("retained/*/*.json")) do
        path = Path.relative_to(file, Store.root())
        Store.read(path) |> Map.put("path", path)
      end

    legacy =
      for file <- Path.wildcard(Store.path("runtimes/*.json")),
          id = Path.basename(file, ".json"),
          not Enum.any?(retained, &(&1["case"] == id)) do
        %{
          "case" => id,
          "images" => runtime_images(Store.read(Path.relative_to(file, Store.root()))),
          "path" => Path.relative_to(file, Store.root())
        }
      end

    retained ++ legacy
  end

  defp validate_release!(release) do
    unless is_binary(release) and Regex.match?(~r/^[a-f0-9]{64}$/, release),
      do: raise("Invalid retained release")
  end

  defp runtime_images(runtime),
    do:
      ([
         runtime["image"],
         runtime["base_image"],
         runtime["node_image"],
         runtime["toolchain_image"],
         get_in(runtime, ["build_seed", "image"])
       ] ++ Map.values(runtime["services"] || %{}))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.sort()

  defp ref(record), do: {record["kind"], record["id"]}

  defp closure(images, records, keep \\ MapSet.new()) do
    next =
      Enum.reduce(records, keep, fn record, selected ->
        if Enum.any?(record["artifact"]["images"], &(&1 in images)) or
             (record["kind"] == "agents" and record["inputs"]["project"] in images),
           do: MapSet.put(selected, ref(record)),
           else: selected
      end)

    chosen = Enum.filter(records, &MapSet.member?(next, ref(&1)))

    seeds =
      for record <- chosen,
          record["kind"] == "databases",
          seed = record["artifact"]["seed"],
          not is_nil(seed),
          do: {"databases", seed}

    next = Enum.reduce(seeds, next, &MapSet.put(&2, &1))

    dependencies =
      Enum.flat_map(chosen, fn record ->
        [record["inputs"]["project"], get_in(record, ["artifact", "build_seed", "image"])] ++
          record["artifact"]["images"]
      end)
      |> Enum.reject(&is_nil/1)

    if next == keep and Enum.all?(dependencies, &(&1 in images)),
      do: next,
      else: closure(Enum.uniq(images ++ dependencies), records, next)
  end

  defp free_bytes(path) do
    Command.run!("df", ["--output=avail", "-B1", path], timeout: 10)
    |> String.split()
    |> List.last()
    |> String.to_integer()
  end

  defp remove_image(image) do
    result = Command.run("docker", ["image", "inspect", image], timeout: 30)

    if result["returncode"] == 0 do
      [info] = Jason.decode!(result["output"])
      tags = info["RepoTags"] || []

      if tags != [] and Enum.all?(tags, &String.starts_with?(&1, "elixir-agent-benchmark:")) do
        result = Command.run("docker", ["image", "rm" | tags], timeout: 120)

        if result["returncode"] == 0,
          do: :ok,
          else: {:error, String.slice(result["output"], 0, 1000)}
      else
        {:error, "Image has external tags or no owned tag; left untouched"}
      end
    else
      if String.contains?(result["output"], "No such image"),
        do: :ok,
        else: {:error, "Docker could not verify the image; left untouched"}
    end
  end
end
