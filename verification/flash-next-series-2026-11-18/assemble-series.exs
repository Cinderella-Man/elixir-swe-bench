# Assembles a run of Qwen3.8 Flash Next UD-IQ2_XS (Unsloth v3.1, on Strata, through Pi) on
# elixir-agent-benchmark-v6 from two runs, at the user's request of 2026-11-18. It is not the
# record of one run:
#
#   * 19 cases come from the full run 20261118-115818-69764904, seed 101.
#   * beacon-pr-687 ended in that run as an evaluation error: the agent removed lib/ before a
#     copy back that failed, the patch snapshot after that tool call was over the 1 MiB limit,
#     and the harness ended the attempt (fixed in 4ba807da). Its outcome comes from the one-case
#     rerun 20261118-184224-6d451a46: the same model, settings, seed, harness and case files,
#     on the controller with that fix.
#
# The public record is what the exporter makes of the full run with the rerun's attempt in
# place of the errored one, plus an `assembled` entry in its setup, so that no real run joins
# it. Both run records come from the controller's data folder; copy them out first:
#
#   for id in 20261118-115818-69764904 20261118-184224-6d451a46; do
#     docker compose cp benchmark:/data/runs/$id/run.json .local/publication/$id.json
#   done
#   MIX_ENV=test mix run --no-start verification/flash-next-series-2026-11-18/assemble-series.exs
alias Eab.{Cache, Results}

source_id = "20261118-115818-69764904"
rerun_id = "20261118-184224-6d451a46"
rerun_case = "beacon-pr-687"
read = fn id -> Results.read!(Path.join(".local/publication", id <> ".json")) end
source = read.(source_id)
rerun = read.(rerun_id)

require! = fn ok, message -> unless ok, do: raise(message) end

require!.(source["id"] == source_id and rerun["id"] == rerun_id, "Not the two runs")

require!.(
  source["attempts"][rerun_case]["status"] == "error" and
    Enum.all?(source["cases"] -- [rerun_case], &(source["attempts"][&1]["status"] == "completed")),
  "The full run should have one error, on #{rerun_case}"
)

require!.(
  rerun["status"] == "completed" and rerun["cases"] == [rerun_case] and
    rerun["selection"]["kind"] == "case_rerun" and rerun["selection"]["source_run"] == source_id,
  "The rerun should be a completed one-case rerun of #{rerun_case} from #{source_id}"
)

# The same experiment, apart from the benchmark code and when the model's source was declared.
for path <- [
      ["settings"],
      ["parallel_attempts"],
      ["harness"],
      ["model", "backend"],
      ["model", "model"],
      ["model", "profile"],
      ["model", "source", "url"]
    ],
    do: require!.(get_in(source, path) == get_in(rerun, path), "#{Enum.join(path, ".")} differs")

require!.(
  Map.drop(source["protocol"], ["implementation"]) ==
    Map.drop(rerun["protocol"], ["implementation"]),
  "The releases differ in more than the benchmark code"
)

attempt = rerun["attempts"][rerun_case]
require!.(is_boolean(attempt["grade"]["passed"]), "The rerun is not graded")

# As a resumed run lists each code version it ran under, the last being the rerun's.
merged =
  source
  |> Map.put("status", "completed")
  |> put_in(["attempts", rerun_case], attempt)
  |> Map.put("code_versions", source["code_versions"] ++ rerun["code_versions"])

note =
  "Assembled from two runs, not run as one. 19 cases come from the full run " <>
    "#{source_id} with seed 101. There #{rerun_case} ended in a harness error, not an " <>
    "outcome: the agent removed lib/ before a copy back that failed, the patch snapshot after " <>
    "that call was over its size limit, and the harness ended the attempt. Its outcome comes " <>
    "from the rerun #{rerun_id}, with the same model, settings, seed and case files, on the " <>
    "controller with that bug fixed."

exported =
  Results.export!(merged,
    note: note,
    evidence_url:
      "https://github.com/Cinderella-Man/elixir-swe-bench/tree/main/verification/flash-next-series-2026-11-18"
  )

series_key = fn setup ->
  Cache.key(
    Map.merge(setup, %{
      "benchmark" => exported["benchmark"],
      "cases" => Enum.map(hd(exported["runs"])["cases"], & &1["id"]),
      "case_fixtures" => exported["case_fixtures"]
    })
  )
end

require!.(
  series_key.(exported["setup"]) == exported["series_id"],
  "The series key does not reproduce the exporter's"
)

# Its own setup, so that a real run never joins it: such a run starts the model's real series.
setup =
  Map.put(exported["setup"], "assembled", %{
    "from" => [[source_id, rerun_id]],
    "rerun_cases" => [rerun_case]
  })

[run] = exported["runs"]

record =
  Results.validate!(%{
    exported
    | "series_id" => series_key.(setup),
      "setup" => setup,
      "runs" => [%{run | "run_id" => "flash-next-v6-assembled-1"}]
  })

path = Path.join("results-page/results", record["series_id"] <> ".json")
require!.(not File.exists?(path), "#{path} exists already")
Results.write!(path, record)

for run <- record["runs"] do
  IO.puts(
    "#{run["run_id"]}: #{Enum.count(run["cases"], & &1["passed"])} of #{length(run["cases"])} passed; " <>
      "failed: #{inspect(for c <- run["cases"], not c["passed"], do: c["id"])}"
  )
end

IO.puts("wrote #{path}")
