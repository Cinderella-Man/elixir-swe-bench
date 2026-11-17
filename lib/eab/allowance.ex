defmodule Eab.Allowance do
  @moduledoc """
  Each case's token allowance (ADR 0021): the most tokens an attempt at it may generate,
  reasoning and tool syntax included. A release that declares one derives it from what its
  validator generated on that case, and an attempt passes only if the agent finished on its
  own inside it. A release without one keeps the earlier rules.

  The rule is part of the release's inventory, in `config/benchmark.json`:

      "allowance": {
        "validator": "Opus 5.5 through Claude Code at xhigh",
        "multiple": 2,
        "minimum_tokens": 16384,
        "validator_tokens": {"plausible-pr-5939": [9812, 10220, 12544]}
      }

  It lives beside the cases, not in them: the validator's attempts are made on the frozen
  case files, so a number derived from those attempts cannot be one of the files.
  """

  @doc "Raises unless the inventory's allowance rule, when it has one, covers exactly its cases."
  def validate!(inventory) do
    case inventory["allowance"] do
      nil ->
        :ok

      rule ->
        tokens = rule["validator_tokens"]

        unless is_map(rule) and is_binary(rule["validator"]) and
                 String.trim(rule["validator"]) != "" and
                 is_number(rule["multiple"]) and rule["multiple"] >= 1 and
                 is_integer(rule["minimum_tokens"]) and rule["minimum_tokens"] > 0 and
                 is_map(tokens) and
                 Enum.sort(Map.keys(tokens)) == Enum.sort(inventory["cases"] || []) and
                 Enum.all?(Map.values(tokens), fn samples ->
                   is_list(samples) and samples != [] and
                     Enum.all?(samples, &(is_integer(&1) and &1 > 0))
                 end),
               do:
                 raise(
                   ArgumentError,
                   "Invalid token allowance: it needs a validator, a multiple of at least 1, " <>
                     "a minimum and the validator's generated tokens for exactly the release's cases"
                 )

        :ok
    end
  end

  @doc """
  The case's allowance in generated tokens, or nil when the release declares none: the
  rule's multiple of the validator's median, and at least its minimum.
  """
  def tokens(inventory, id) do
    with %{"validator_tokens" => %{^id => samples}} = rule <- (inventory || %{})["allowance"] do
      max(rule["minimum_tokens"], ceil(rule["multiple"] * median(samples)))
    else
      _ -> nil
    end
  end

  @doc "The rule with each of `cases`' allowances, as a run series records it; nil without one."
  def table(inventory, cases) do
    case (inventory || %{})["allowance"] do
      nil ->
        nil

      rule ->
        rule
        |> Map.take(~w(validator multiple minimum_tokens))
        |> Map.put("tokens", Map.new(cases, &{&1, tokens(inventory, &1)}))
    end
  end

  @doc """
  An attempt's settings under its case's allowance: the allowance is its generation budget,
  which the gateway enforces where it counts tokens itself. Unchanged without an allowance.
  """
  def settings(settings, inventory, id) do
    case tokens(inventory, id) do
      nil -> settings
      tokens -> Map.merge(settings, %{"max_tokens" => tokens, "case_allowance" => true})
    end
  end

  @doc "Whether these are an attempt's settings under a case allowance."
  def applies?(settings), do: is_map(settings) and settings["case_allowance"] == true

  @doc """
  Adds the allowance to a grade summary as one more required check. The grader's own verdict
  on the patch stays in `patch_passed`; `passed` also needs the agent to have finished on its
  own having generated no more than the allowance.
  """
  def judge(summary, record) do
    if applies?(record["settings"]) do
      allowance = record["settings"]["max_tokens"]
      reason = reason(record["stop_reason"], record["generated_tokens"], allowance)

      check = %{
        "id" => "allowance",
        "label" => "Token allowance",
        "passed" => is_nil(reason),
        "completed" => true,
        "test_count" => 0,
        "failure_count" => 0,
        "failures" => [],
        "reason" => reason,
        "excerpt" => nil,
        "allowance_tokens" => allowance,
        "generated_tokens" => record["generated_tokens"]
      }

      summary
      |> Map.put("patch_passed", summary["passed"])
      |> Map.put("passed", summary["passed"] and is_nil(reason))
      |> Map.update("checks", [check], &(&1 ++ [check]))
    else
      summary
    end
  end

  @doc "Why an attempt did not finish inside its allowance, or nil when it did."
  def reason("agent_completed", used, allowance) when is_integer(used) and used <= allowance,
    do: nil

  def reason("agent_completed", used, allowance) when is_integer(used),
    do:
      "The agent finished, but generated #{format(used)} tokens against an allowance of #{format(allowance)}."

  def reason("token_budget", _used, allowance),
    do: "The attempt was stopped at its allowance of #{format(allowance)} generated tokens."

  def reason(stop, _used, _allowance) when stop in ~w(context_budget context_limit),
    do: "The attempt ran out of context before the agent finished."

  def reason(stop, _used, _allowance) when stop in ~w(response_budget response_limit),
    do: "A reply reached its length limit before the agent finished."

  def reason(_stop, _used, _allowance),
    do: "The attempt did not record that the agent finished inside its allowance."

  @doc "A token count with thousands separators."
  def format(n) when is_integer(n),
    do: n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")

  defp median(samples) do
    sorted = Enum.sort(samples)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1,
      do: Enum.at(sorted, middle),
      else: (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
  end
end
