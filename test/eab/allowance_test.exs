defmodule Eab.AllowanceTest do
  use ExUnit.Case, async: true
  alias Eab.Allowance

  defp inventory(overrides \\ %{}) do
    %{
      "id" => "example-v1",
      "cases" => ~w(small large),
      "allowance" =>
        Map.merge(
          %{
            "validator" => "Fixture validator",
            "multiple" => 2,
            "minimum_tokens" => 16_384,
            "validator_tokens" => %{"small" => [6000, 9000, 7000], "large" => [90_000, 95_001]}
          },
          overrides
        )
    }
  end

  test "a case's allowance is the multiple of the validator's median, and at least the minimum" do
    # Twice the median of 7,000 is under the minimum; the two large samples average 92,500.5.
    assert Allowance.tokens(inventory(), "small") == 16_384
    assert Allowance.tokens(inventory(), "large") == 185_001
    assert Allowance.tokens(inventory(%{"multiple" => 3}), "small") == 21_000

    assert Allowance.table(inventory(), ~w(small large)) == %{
             "validator" => "Fixture validator",
             "multiple" => 2,
             "minimum_tokens" => 16_384,
             "tokens" => %{"small" => 16_384, "large" => 185_001}
           }
  end

  test "a release without the rule has no allowances and keeps its attempts' settings" do
    plain = %{"id" => "example-v1", "cases" => ~w(small large)}
    settings = %{"window_tokens" => 262_144, "max_tokens" => nil}

    assert Allowance.validate!(plain) == :ok
    assert Allowance.tokens(plain, "small") == nil
    assert Allowance.tokens(nil, "small") == nil
    assert Allowance.table(plain, ~w(small large)) == nil
    assert Allowance.settings(settings, plain, "small") == settings
    refute Allowance.applies?(settings)

    summary = %{"passed" => true, "checks" => []}

    assert Allowance.judge(summary, %{"settings" => settings, "stop_reason" => "context_budget"}) ==
             summary
  end

  test "the rule must cover exactly the release's cases with positive samples" do
    assert Allowance.validate!(inventory()) == :ok

    for broken <- [
          %{"validator_tokens" => %{"small" => [6000]}},
          %{"validator_tokens" => %{"small" => [1], "large" => [1], "retired" => [1]}},
          %{"validator_tokens" => %{"small" => [], "large" => [1]}},
          %{"validator_tokens" => %{"small" => [0], "large" => [1]}},
          %{"multiple" => 0.5},
          %{"minimum_tokens" => 0},
          %{"validator" => " "}
        ] do
      assert_raise ArgumentError, ~r/Invalid token allowance/, fn ->
        Allowance.validate!(inventory(broken))
      end
    end
  end

  test "an attempt's generation budget is its case's allowance, for local and hosted runs" do
    local =
      Allowance.settings(%{"window_tokens" => 262_144, "max_tokens" => nil}, inventory(), "small")

    assert local["max_tokens"] == 16_384 and Allowance.applies?(local)

    # A hosted run declares 262,144 for the whole run; the case's allowance replaces it.
    hosted =
      Allowance.settings(
        %{"max_tokens" => 262_144, "budget_policy" => "declared_not_enforced"},
        inventory(),
        "large"
      )

    assert hosted["max_tokens"] == 185_001 and hosted["budget_policy"] == "declared_not_enforced"
  end

  test "a case passes only when the agent finished on its own inside the allowance" do
    settings = Allowance.settings(%{"window_tokens" => 262_144}, inventory(), "small")
    summary = %{"passed" => true, "checks" => [%{"id" => "hidden", "passed" => true}]}

    judge = fn stop, tokens, summary ->
      Allowance.judge(summary, %{
        "settings" => settings,
        "stop_reason" => stop,
        "generated_tokens" => tokens
      })
    end

    inside = judge.("agent_completed", 16_384, summary)
    assert inside["passed"] and inside["patch_passed"]

    assert List.last(inside["checks"])["id"] == "allowance" and
             List.last(inside["checks"])["passed"]

    # Stopped by the gateway at the allowance: the patch passes, the case does not.
    stopped = judge.("token_budget", 16_384, summary)
    refute stopped["passed"]
    assert stopped["patch_passed"]
    assert List.last(stopped["checks"])["reason"] =~ "stopped at its allowance of 16,384"

    # A hosted model or Claude Code can finish over it; that fails as well.
    over = judge.("agent_completed", 20_001, summary)
    refute over["passed"]

    assert List.last(over["checks"])["reason"] =~
             "generated 20,001 tokens against an allowance of 16,384"

    for stop <- ~w(context_budget context_limit response_limit) do
      cut = judge.(stop, 9000, summary)
      refute cut["passed"]
      assert cut["patch_passed"]
    end

    # A failing patch stays failed inside the allowance, and its verdict is kept apart.
    wrong = judge.("agent_completed", 9000, %{summary | "passed" => false})
    refute wrong["passed"] or wrong["patch_passed"]
    assert List.last(wrong["checks"])["passed"]
  end
end
