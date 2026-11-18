# Assembles Sonnet 5.5's run series for elixir-agent-benchmark-v6 from attempts that already
# exist, at the user's request of 2026-11-17. It is not the record of two runs made on v6:
#
#   * 18 cases have identical files in v5 and v6. Their outcomes come from the two runs of
#     Sonnet's published v5 series (2026-10-28), oldest first.
#   * guardian-pr-748 is one of those 18, with its verdict under v6's grading. v5 rejected both
#     patches untested for a README.md edit outside the edit area; v6 discards such edits
#     (ADR 0017). Re-graded on 2026-11-18, both patches pass every check.
#   * ash-pr-3031 and livebook-pr-2800 had their tickets rewritten for v6. Their outcomes come
#     from the single-case attempts of 2026-11-17 and 18, first attempt with the first run.
#
# Every number is read from files in this repository: the published v5 series, the October
# transcripts in verification/sonnet-series-2026-10-28/ and this folder.
#
# From the repository root:
#   MIX_ENV=test mix run --no-start verification/sonnet-series-2026-11-17/assemble-v6-series.exs
alias Eab.{Cache, ContextSize, Inventory, Results}

october = "verification/sonnet-series-2026-10-28"
today = "verification/sonnet-series-2026-11-17"

# {the v5 run, its ash-pr-3031 attempt, its livebook-pr-2800 attempt, when the last was started}
parts = [
  {"20261028-065746-940e9ba4", "20261117-233204-7b2bd497", "20261117-224148-3918a9b8",
   "2026-11-17T23:32:04.209400Z"},
  {"20261028-133546-8d515727", "20261118-003552-5e45f12f", "20261117-230447-55568d0f",
   "2026-11-18T00:35:52.813973Z"}
]

rewritten = ~w(ash-pr-3031 livebook-pr-2800)
regraded = "guardian-pr-748"
inventory = Inventory.definition()
cases = inventory["cases"]
fixtures = Map.new(cases, &{&1, Results.fixture_hashes(&1)})

v5 =
  Path.wildcard("results-page/releases/v5/*.json")
  |> Enum.map(&Results.read!/1)
  |> Enum.find(&(&1["model"]["name"] == "Sonnet 5.5"))

for id <- cases -- rewritten do
  unless v5["case_fixtures"][id] == fixtures[id], do: raise("#{id}: case files differ from v5")
end

for id <- rewritten do
  if v5["case_fixtures"][id] == fixtures[id], do: raise("#{id}: expected a rewritten case")
end

peak = fn folder, run, id ->
  Path.join([folder, "run-#{run}", id, "logs", "claude-transcript.jsonl"])
  |> ContextSize.from_transcript()
  |> Enum.max()
end

# What ended an attempt before the agent finished, as a published case records it.
cutoff = fn
  "agent_completed" -> nil
  "context_limit" -> "context_budget"
  "response_limit" -> "response_budget"
end

attempt = fn run, id ->
  summary = Results.read!(Path.join([today, "run-#{run}", id, "grade-summary.json"]))

  unless summary["case"] == id and summary["status"] == "completed" and
           is_boolean(summary["passed"]),
         do: raise("#{run} #{id}: not a graded attempt")

  %{
    "id" => id,
    "passed" => summary["passed"],
    "patch_passed" => summary["passed"],
    "generated_tokens" => summary["generated_tokens"],
    "model_calls" => summary["model_calls"],
    "cutoff" => cutoff.(summary["stop_reason"]),
    "timing" => nil,
    "peak_context_tokens" => peak.(today, run, id)
  }
end

runs =
  parts
  |> Enum.with_index(1)
  |> Enum.map(fn {{source, ash, livebook, created}, number} ->
    carried = Enum.find(v5["runs"], &(&1["run_id"] == source)) || raise("#{source} is not in v5")
    by_id = Map.new(carried["cases"], &{&1["id"], &1})
    attempts = %{"ash-pr-3031" => ash, "livebook-pr-2800" => livebook}

    regrade =
      Results.read!(Path.join([today, "guardian-regrade", "run-#{source}", "grade-summary.json"]))

    patch = File.read!(Path.join([october, "run-#{source}", regraded, "model.patch"]))

    unless regrade["source_run"] == source and
             regrade["model_patch_sha256"] == Inventory.hash(patch),
           do: raise("#{source}: the re-grade is of another patch")

    %{
      "run_id" => "sonnet-v6-assembled-#{number}",
      "created_at" => created,
      "seed" => nil,
      # The release and code the two rewritten cases were attempted under.
      "source_release_id" => "d65149ed3b4dac4b810d3c0c0397e4b8fb3c783473d0146d23eaf2c18b21803b",
      "code_version" => "311f42550a8ebb5602a39b9c68f1ccae15f7c7147f877b3cba4a6d50be2713c7",
      # The October runs worked on two cases at once and the attempts on one.
      "deployment" => %{"server_build" => nil, "total_slots" => nil, "parallel_attempts" => nil},
      "cases" =>
        Enum.map(cases, fn id ->
          if id in rewritten do
            attempt.(attempts[id], id)
          else
            c = by_id[id]
            passed = if id == regraded, do: regrade["passed"], else: c["passed"]

            %{
              "id" => id,
              "passed" => passed,
              "patch_passed" => passed,
              "generated_tokens" => c["generated_tokens"],
              "model_calls" => c["model_calls"],
              "cutoff" => c["cutoff"],
              "timing" => nil,
              "peak_context_tokens" => peak.(october, source, id)
            }
          end
        end),
      "timing" => nil,
      "machine" => nil,
      "resources" => nil
    }
  end)

# Its own setup, so that a run made on v6 never joins it: such a run starts Sonnet's real series.
setup =
  Map.put(v5["setup"], "assembled", %{
    "from" => Enum.map(parts, fn {source, ash, livebook, _} -> [source, ash, livebook] end),
    "rewritten_cases" => rewritten,
    "regraded_cases" => [regraded]
  })

series =
  Cache.key(
    Map.merge(setup, %{"benchmark" => inventory["id"], "cases" => cases, "case_fixtures" => fixtures})
  )

record =
  Results.validate!(%{
    "schema_version" => Eab.Results.Schema.current_version(),
    "series_id" => series,
    "benchmark" => inventory["id"],
    "model" => v5["model"],
    "harness" => v5["harness"],
    "settings" => v5["settings"],
    "setup" => setup,
    "case_fixtures" => fixtures,
    "seeds" => nil,
    "required_runs" => 3,
    "runs" => runs,
    "evidence_url" =>
      "https://github.com/Cinderella-Man/elixir-swe-bench/tree/main/verification/sonnet-series-2026-11-17",
    "note" =>
      "Assembled from existing attempts, not run as one. Each run takes 18 cases from one of Sonnet 5.5's v5 runs of " <>
        "2026-10-28, whose case files are identical in v6, and ash-pr-3031 and livebook-pr-2800, whose tickets v6 " <>
        "rewrote, from single-case attempts of 2026-11-17 and 18. guardian-pr-748 carries its verdict under v6's " <>
        "grading: v5 rejected both patches for a README.md edit that v6 discards, and re-graded they pass. The October " <>
        "runs used Claude Code 2.1.308 and instructions one sentence shorter than v6's; the two rewritten cases used 2.1.321."
  })

path = Path.join("results-page/results", series <> ".json")
Results.write!(path, record)

for run <- record["runs"] do
  IO.puts(
    "#{run["run_id"]}: #{Enum.count(run["cases"], & &1["passed"])} of #{length(run["cases"])} passed; " <>
      "failed: #{inspect(for c <- run["cases"], not c["passed"], do: c["id"])}"
  )
end

IO.puts("wrote #{path}")
