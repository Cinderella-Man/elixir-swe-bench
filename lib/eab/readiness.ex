defmodule Eab.Readiness do
  @moduledoc """
  Whether each case can run with no internet. Read-only: it reports what is missing and
  never builds, downloads or writes.
  """
  alias Eab.{AgentImage, Cache, Fixtures, Grader, ImagePresence, Inventory, Provenance, Store}

  def offline?, do: Application.get_env(:eab, :offline, false)

  def check(ids \\ Inventory.all(), opts \\ []) do
    existing = Keyword.get(opts, :existing, &ImagePresence.existing/1)
    parts = Map.new(ids, &{&1, parts(&1)})

    present =
      parts
      |> Map.values()
      |> Enum.flat_map(fn part -> Enum.flat_map(part, &(elem(&1, 1) || [])) end)
      |> existing.()

    cases =
      for id <- ids do
        missing =
          for {name, images} <- parts[id],
              is_nil(images) or not Enum.all?(images, &MapSet.member?(present, &1)),
              do: name

        %{"case" => id, "ready" => missing == [], "missing" => missing}
      end

    %{"total" => length(ids), "ready" => Enum.count(cases, & &1["ready"]), "cases" => cases}
  end

  @doc "In offline mode, refuses work that would stop on a case that is not prepared."
  def enforce!(ids) do
    if offline?() do
      missing = for %{"ready" => false, "case" => id} <- check(ids)["cases"], do: id

      if missing != [],
        do:
          raise(
            "Offline mode: #{length(missing)} of #{length(ids)} cases are not prepared (" <>
              Enum.join(missing, ", ") <>
              "). Reconnect the internet and click Prepare all cases."
          )
    end

    :ok
  end

  # Each part is its name with the images it needs, or nil when its record is missing.
  defp parts(id) do
    baseline =
      case Fixtures.cached_images(id) do
        {:ok, images} -> images
        _ -> nil
      end

    runtime = runtime(id, baseline)

    [
      {"source check", record("provenance", Provenance.inputs(id))},
      {"project and database images", baseline},
      {"Pi image", agent(id, runtime)},
      {"fixture qualification", qualification(id, runtime)}
    ]
  end

  # Attempts start from this record, so it must describe the current fixtures and images.
  defp runtime(id, baseline) do
    runtime = Store.read("runtimes/#{id}.json")

    if runtime && baseline && runtime["image"] in baseline &&
         runtime["fixture_hashes"] == Inventory.fixture_hashes(id),
       do: runtime
  end

  defp agent(_id, nil), do: nil

  defp agent(id, runtime),
    do: record("agents", AgentImage.inputs(Inventory.spec(id), runtime["image"]))

  defp qualification(_id, nil), do: nil

  defp qualification(id, runtime) do
    identity = Grader.qualification_identity(id, runtime)
    receipt = Store.read("qualifications/#{Cache.key(identity)}.json")
    if receipt && receipt["valid"] == true && receipt["identity"] == identity, do: []
  end

  # Images are probed afterwards in one batch, not per record.
  defp record(kind, inputs) do
    case Cache.lookup(kind, Cache.key(inputs), image_exists?: fn _ -> true end) do
      {:ok, artifact} -> artifact["images"]
      _ -> nil
    end
  end
end
