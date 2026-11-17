defmodule Eab.ContextSizeTest do
  use ExUnit.Case, async: true
  alias Eab.{ContextSize, Store}

  test "a call's context is its prompt plus its reply, in every backend's accounting" do
    # A local server or ChatGPT: the whole prompt is one number.
    assert ContextSize.of_call(%{"input_tokens" => 10_031, "output_tokens" => 180}) == 10_211

    # A Claude Code transcript: Anthropic splits the prompt three ways.
    assert ContextSize.of_call(%{
             "input_tokens" => 3,
             "cache_creation_input_tokens" => 1000,
             "cache_read_input_tokens" => 50,
             "output_tokens" => 40
           }) == 1093

    # The gateway's Claude API record keeps the split beside the whole prompt.
    assert ContextSize.of_call(%{
             "input_tokens" => 1053,
             "uncached_input_tokens" => 3,
             "cache_creation_input_tokens" => 1000,
             "cache_read_input_tokens" => 50,
             "output_tokens" => 40
           }) == 1093

    assert ContextSize.of_call(%{"input_tokens" => nil}) == 0
    assert ContextSize.of_call(nil) == 0
    assert ContextSize.peak(nil, %{"input_tokens" => 5, "output_tokens" => 2}) == 7
    assert ContextSize.peak(900, %{"input_tokens" => 5, "output_tokens" => 2}) == 900
  end

  test "an attempt's peak is what it recorded, or what its saved calls show" do
    run = "context-size-#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf!(Store.path("runs/#{run}")) end)

    assert ContextSize.of_attempt(run, "case-a", %{"peak_context_tokens" => 4321}) == 4321
    assert ContextSize.of_attempt(run, "case-a", %{}) == nil
    assert ContextSize.of_attempt(nil, "case-a", %{}) == nil

    # A Pi run made before the peak was recorded still has one usage record per call.
    for {step, input, output} <- [{"0000", 2070, 86}, {"0001", 9000, 1200}, {"0002", 9800, 40}] do
      Store.write("runs/#{run}/case-a/usage-#{step}.json", %{
        "input_tokens" => input,
        "output_tokens" => output
      })
    end

    assert ContextSize.of_attempt(run, "case-a", %{}) == 10_200

    # A Claude Code run has its transcript; streaming repeats a call's record per content block.
    usage = fn output ->
      %{
        "input_tokens" => 3,
        "cache_creation_input_tokens" => 1000,
        "cache_read_input_tokens" => 50,
        "output_tokens" => output
      }
    end

    lines =
      [
        %{"type" => "user", "message" => %{"content" => "task"}},
        %{"type" => "assistant", "message" => %{"id" => "m1", "usage" => usage.(7)}},
        %{"type" => "assistant", "message" => %{"id" => "m1", "usage" => usage.(40)}},
        %{"type" => "assistant", "message" => %{"id" => "m2", "usage" => usage.(20)}},
        %{
          "type" => "assistant",
          "message" => %{"id" => "m3", "model" => "<synthetic>", "usage" => usage.(9_000_000)}
        }
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)

    Store.write_text("runs/#{run}/case-b/claude-transcript.jsonl", lines <> "\nnot json\n")
    assert ContextSize.of_attempt(run, "case-b", %{}) == 1093
  end

  defp record(runs) do
    %{
      "runs" =>
        Enum.map(runs, fn cases ->
          %{
            "cases" =>
              Enum.map(cases, fn {id, passed, cutoff, peak} ->
                %{
                  "id" => id,
                  "passed" => passed,
                  "cutoff" => cutoff,
                  "peak_context_tokens" => peak
                }
              end)
          }
        end)
    }
  end

  test "a case counts at a size only if the agent finished inside it with a passing patch" do
    small = %{"passed" => true, "cutoff" => nil, "peak_context_tokens" => 60_000}
    assert ContextSize.fits?(small, 65_536)
    refute ContextSize.fits?(%{small | "peak_context_tokens" => 65_537}, 65_536)
    refute ContextSize.fits?(%{small | "passed" => false}, 262_144)
    # A patch that passed when the window cut the attempt off did not finish inside it.
    refute ContextSize.fits?(%{small | "cutoff" => "context_budget"}, 262_144)
    refute ContextSize.fits?(%{small | "peak_context_tokens" => nil}, 262_144)
  end

  test "one run gives a score at every context size; a series without peaks has none" do
    series =
      record([
        [
          {"a", true, nil, 40_000},
          {"b", true, nil, 120_000},
          {"c", true, "context_budget", 262_000}
        ],
        [{"a", true, nil, 70_000}, {"b", false, nil, 90_000}, {"c", true, nil, 250_000}]
      ])

    scores = ContextSize.scores(series)
    assert Map.keys(scores) == Enum.map(ContextSize.sizes(), &Integer.to_string/1) |> Enum.sort()

    assert scores["65536"]["case_passes"] == %{"a" => 1, "b" => 0, "c" => 0}
    assert scores["131072"]["case_passes"] == %{"a" => 2, "b" => 1, "c" => 0}
    assert scores["262144"]["case_passes"] == %{"a" => 2, "b" => 1, "c" => 1}
    assert scores["262144"]["score_percent"] == 66.67
    assert is_float(scores["131072"]["interval_percent"])

    refute ContextSize.recorded?(record([[{"a", true, nil, nil}]]))

    assert ContextSize.scores(record([[{"a", true, nil, 40_000}], [{"a", true, nil, nil}]])) ==
             nil
  end
end
