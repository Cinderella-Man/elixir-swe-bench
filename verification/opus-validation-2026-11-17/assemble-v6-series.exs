# Assembles Opus 5.5's run series for elixir-agent-benchmark-v6 from attempts that already
# exist, at the user's request of 2026-11-17. It is not the record of two runs made on v6:
#
#   * 18 cases have identical files in v5 and v6. Their outcomes come from the first two runs
#     of Opus's published v5 series (2026-10-27), oldest first.
#   * ash-pr-3031 and livebook-pr-2800 had their tickets rewritten for v6. Their outcomes come
#     from the single-case attempts of 2026-11-17, first attempt with the first run.
#
# Every number is read from files in this repository: the published v5 series, the October
# transcripts in verification/opus-validation-2026-10-26/ and this folder's run folders.
#
# From the repository root:
#   MIX_ENV=test mix run --no-start verification/opus-validation-2026-11-17/assemble-v6-series.exs
alias Eab.{Cache, ContextSize, Inventory, Results}

october = "verification/opus-validation-2026-10-26"
today = "verification/opus-validation-2026-11-17"

# {the v5 run, its ash-pr-3031 attempt, its livebook-pr-2800 attempt}
parts = [
  {"20261027-183407-2bbea0a5", "20261117-204208-f3baa4e1", "20261117-215740-042076e5"},
  {"20261027-204103-33348dcc", "20261117-212559-9eb4605e", "20261117-220429-d6cc14d1"}
]

rewritten = ~w(ash-pr-3031 livebook-pr-2800)
inventory = Inventory.definition()
cases = inventory["cases"]
fixtures = Map.new(cases, &{&1, Results.fixture_hashes(&1)})

v5 =
  Path.wildcard("results-page/releases/v5/*.json")
  |> Enum.map(&Results.read!/1)
  |> Enum.find(&(&1["model"]["name"] == "Opus 5.5"))

# The 18 carried cases must be byte-identical between the two releases.
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

attempt = fn run, id ->
  summary = Results.read!(Path.join([today, "run-#{run}", id, "grade-summary.json"]))

  unless summary["case"] == id and summary["status"] == "completed" and
           summary["stop_reason"] == "agent_completed" and summary["compactions"] == 0,
         do: raise("#{run} #{id}: not a completed attempt")

  %{
    "id" => id,
    "passed" => summary["passed"],
    "patch_passed" => summary["passed"],
    "generated_tokens" => summary["generated_tokens"],
    "model_calls" => summary["model_calls"],
    "cutoff" => nil,
    "timing" => nil,
    "peak_context_tokens" => peak.(today, run, id)
  }
end

runs =
  parts
  |> Enum.with_index(1)
  |> Enum.map(fn {{source, ash, livebook}, number} ->
    carried = Enum.find(v5["runs"], &(&1["run_id"] == source)) || raise("#{source} is not in v5")
    by_id = Map.new(carried["cases"], &{&1["id"], &1})
    attempts = %{"ash-pr-3031" => ash, "livebook-pr-2800" => livebook}

    %{
      "run_id" => "opus-v6-assembled-#{number}",
      # When its last attempts were made.
      "created_at" => %{1 => "2026-11-17T20:42:08.032453Z", 2 => "2026-11-17T21:25:59.693275Z"}[number],
      "seed" => nil,
      # The release and code the two rewritten cases were attempted under.
      "source_release_id" => "7b3bd635b43944a811acce048a3613e4af5dae4970ddeee416b322345daf5743",
      "code_version" => "ababa509b2e979ba0e933478d6f2959d39b559b19f7c9ce96c522c3a29055ed9",
      # The October runs worked on two cases at once and the attempts on one.
      "deployment" => %{"server_build" => nil, "total_slots" => nil, "parallel_attempts" => nil},
      "cases" =>
        Enum.map(cases, fn id ->
          if id in rewritten do
            attempt.(attempts[id], id)
          else
            c = by_id[id]

            %{
              "id" => id,
              "passed" => c["passed"],
              "patch_passed" => c["passed"],
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

# Its own setup, so that a run made on v6 never joins it: such a run starts Opus's real series.
setup =
  Map.put(v5["setup"], "assembled", %{
    "from" => Enum.map(parts, fn {source, ash, livebook} -> [source, ash, livebook] end),
    "rewritten_cases" => rewritten
  })

series =
  Cache.key(Map.merge(setup, %{"benchmark" => inventory["id"], "cases" => cases, "case_fixtures" => fixtures}))

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
      "https://github.com/Cinderella-Man/elixir-swe-bench/tree/main/verification/opus-validation-2026-11-17",
    "note" =>
      "Assembled from existing attempts, not run as one. Each run takes 18 cases from one of Opus 5.5's v5 runs of " <>
        "2026-10-27, whose case files are identical in v6, and ash-pr-3031 and livebook-pr-2800, whose tickets v6 " <>
        "rewrote, from single-case attempts of 2026-11-17. The October runs used Claude Code 2.1.308 and instructions " <>
        "one sentence shorter than v6's; the two rewritten cases used 2.1.321. Opus 5.5 validated these cases."
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
