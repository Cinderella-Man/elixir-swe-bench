defmodule Eab.Comparison do
  @moduledoc "Side-by-side functional outcomes for explicitly selected, comparable runs."
  alias Eab.{Cache, Runner, Store}

  def load(ids) when is_list(ids) do
    unless length(ids) in 2..30 and ids == Enum.uniq(ids) and Enum.all?(ids, &Store.valid_id?/1),
      do: raise("Choose between 2 and 30 distinct runs")

    build(Enum.map(ids, &(Store.run(&1) || raise("Run not found: #{&1}"))))
  end

  def build(runs) do
    identities = Enum.map(runs, &identity/1) |> Enum.uniq()

    unless length(runs) in 2..30 and length(identities) == 1,
      do:
        raise(
          "Comparison requires the same cases, fixtures and effective settings apart from seed"
        )

    [first | _] = runs

    %{
      "cohort" => Cache.key(hd(identities)),
      "release" => first["release_id"],
      "runs" =>
        Enum.map(runs, fn run ->
          %{
            "id" => run["id"],
            "model" => Eab.ModelIdentity.label(run["model"]),
            "backend" => get_in(run, ["model", "backend"]),
            "harness" => Eab.Harness.label(run),
            "seed" => get_in(run, ["settings", "seed"]),
            "status" => run["status"],
            "score" => Runner.score(run)
          }
        end),
      "cases" =>
        Enum.map(first["cases"], fn id ->
          %{"case" => id, "outcomes" => Enum.map(runs, &outcome(get_in(&1, ["attempts", id])))}
        end)
    }
  end

  # Runs of one series may differ in seed and benchmark code version (ADR 0011), so the
  # frozen cases and their fixture files stand in for the release identity.
  defp identity(run) do
    unless is_binary(run["release_id"]) and is_map(run["settings"]) and is_list(run["cases"]) and
             run["cases"] != [],
           do: raise("Legacy or corrupt runs without a frozen release cannot join a comparison")

    %{
      "cases" => run["cases"],
      "fixtures" => Map.take(get_in(run, ["protocol", "fixtures"]) || %{}, run["cases"]),
      "settings" => Map.delete(run["settings"], "seed")
    }
  end

  defp outcome(%{"status" => "completed", "grade" => %{"passed" => true}}), do: "Passed"
  defp outcome(%{"status" => "completed", "grade" => %{"passed" => false}}), do: "Failed"
  defp outcome(%{"status" => "error"}), do: "Evaluation error"
  defp outcome(_), do: "Incomplete"
end
