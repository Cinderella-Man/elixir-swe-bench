# Adds each attempt's peak context to DeepSeek-V4.1-Flash-1017's published v6 run, at the
# user's request of 2026-11-18. The run was made on 2026-11-13, before attempts recorded
# their peak context (ADR 0022), by a controller on another machine, which still holds its
# files. The run's calls.json, among its saved logs in verification/runs/, lists every model
# call's prompt and output tokens, read from that run's per-call usage records. Nothing was
# run or graded again. The file is kept in place once
# written: run again, the script finds the peaks already there and writes the same record.
#
# The script refuses to write unless every case has as many calls as the published run
# counts and their reply tokens add up to the generated tokens it published.
#
# From the repository root:
#   MIX_ENV=test mix run --no-start verification/local-series-2026-11-18/add-deepseek-peak-context.exs
alias Eab.{ContextSize, Results}

calls = Results.read!("verification/runs/run-20261113-193538-5205670a/calls.json")
["prompt_tokens", "output_tokens"] = calls["fields"]

path =
  Path.wildcard("results-page/results/*.json")
  |> Enum.find(fn path ->
    Enum.any?(Results.read!(path)["runs"], &(&1["run_id"] == calls["run_id"]))
  end) || raise("#{calls["run_id"]} is not a published run")

record = Results.read!(path)
[run] = record["runs"]

unless Enum.sort(Map.keys(calls["cases"])) == Enum.sort(Enum.map(run["cases"], & &1["id"])),
  do: raise("calls.json does not list the run's cases")

cases =
  Enum.map(run["cases"], fn c ->
    usage = calls["cases"][c["id"]]

    unless length(usage) == c["model_calls"] and
             Enum.sum(for [_, output] <- usage, do: output) == c["generated_tokens"],
           do: raise("#{c["id"]}: the calls do not match the published attempt")

    peak =
      usage
      |> Enum.map(fn [input, output] ->
        ContextSize.of_call(%{"input_tokens" => input, "output_tokens" => output})
      end)
      |> Enum.max()

    Map.put(c, "peak_context_tokens", peak)
  end)

record =
  %{record | "runs" => [%{run | "cases" => cases}]}
  |> Results.upgrade()
  |> Results.validate!()

Results.write!(path, record)

for size <- ContextSize.sizes() do
  solved =
    Enum.count(cases, &(&1["passed"] and is_nil(&1["cutoff"]) and &1["peak_context_tokens"] <= size))

  IO.puts("inside #{size}: #{solved} of #{length(cases)}")
end

IO.puts("as run: #{Enum.count(cases, & &1["passed"])} of #{length(cases)}")
IO.puts("wrote #{path}")
