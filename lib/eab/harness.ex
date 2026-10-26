defmodule Eab.Harness do
  @moduledoc "The coding-agent harness behind a run. Runs without a recorded harness used Pi."
  alias Eab.{ClaudeCode, Pi}

  def identity(endpoint) do
    if ClaudeCode.harness?(endpoint),
      do: ClaudeCode.identity(endpoint),
      else: Map.put(Pi.identity(), "name", "pi")
  end

  def name(run), do: get_in(run || %{}, ["harness", "name"]) || "pi"

  def label(run) do
    case run && run["harness"] do
      %{"name" => "claude_code", "claude_code_version" => version} when is_binary(version) ->
        "Claude Code #{version}"

      %{"name" => "claude_code"} ->
        "Claude Code"

      %{"name" => "pi", "version" => version} when is_binary(version) ->
        "Pi #{version}"

      _ ->
        "Pi"
    end
  end

  @doc "The agent named in progress messages."
  def agent(run), do: if(name(run) == "claude_code", do: "Claude Code", else: "Pi")
end
