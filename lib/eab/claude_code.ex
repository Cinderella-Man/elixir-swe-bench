defmodule Eab.ClaudeCode do
  @moduledoc """
  The Claude Code harness (ADR 0010): subscription Claude models attempt cases as
  locked-down Claude Code subagents driven from a solver folder, while the controller
  keeps the workspace, Pi's exact instructions and the grader.
  """
  alias Eab.{Cache, Inventory}

  @backend "claude_code"
  # Pi's subscription budget sentence is rendered with this value; it is declared to the
  # model but Claude Code cannot enforce it. Usage above it is flagged, never failed.
  @declared_tokens 262_144
  @profiles [
    %{"model" => "claude-opus-5-5", "name" => "Opus 5.5", "effort" => "xhigh"},
    %{"model" => "claude-sonnet-5-5", "name" => "Sonnet 5.5", "effort" => "max"},
    %{"model" => "claude-haiku-5-5", "name" => "Haiku 5.5", "effort" => "max"}
  ]

  def backend, do: @backend
  def declared_tokens, do: @declared_tokens
  def harness?(endpoint), do: is_map(endpoint) and endpoint["backend"] == @backend

  def profiles,
    do: Enum.map(@profiles, &Map.put(&1, "agent", agent_name(&1["model"], &1["effort"])))

  def profile!(model) do
    Enum.find(profiles(), &(&1["model"] == model)) ||
      raise ArgumentError, "Claude Code has no solver agent for #{inspect(model)}"
  end

  defp agent_name("claude-" <> model, effort), do: "eab-#{model}-#{effort}"

  def endpoint(model) do
    profile = profile!(model)

    %{
      "url" => "claude-code://subscription",
      "backend" => @backend,
      "model" => profile["model"],
      "context" => nil,
      "profile" => %{
        "harness" => @backend,
        "billing" => "claude_subscription",
        "agent" => profile["agent"],
        "effort" => profile["effort"],
        "kit_sha256" => kit_hash(),
        "preamble_sha256" => Inventory.hash(preamble()),
        "tools_sha256" => Inventory.hash_file(path("tools.json"))
      },
      "identity" => %{
        "version" => 1,
        "name" => profile["name"],
        "quantization" => nil,
        "artifact" => nil,
        "source" => "reported_name",
        "size_bytes" => nil,
        "parameter_count" => nil
      },
      "identity_note" =>
        "Claude subscription model through Claude Code; the serving snapshot is not reported."
    }
  end

  def settings(endpoint, _input \\ %{}) do
    %{
      "max_tokens" => @declared_tokens,
      "budget_policy" => "declared_not_enforced",
      "context_policy" => "provider_enforced",
      "window_tokens" => nil,
      "response_tokens" => nil,
      "seed" => nil,
      "compaction" => false,
      "reasoning_effort" => endpoint["profile"]["effort"],
      "reasoning_effort_source" => "harness_agent_file",
      "thinking_policy" => "harness_agent_file"
    }
  end

  # The kit and preamble are part of the endpoint profile; an edited copy is a new harness.
  def unchanged!(endpoint) do
    unless endpoint == endpoint(endpoint["model"]),
      do: raise("Claude Code harness files changed during this run")

    :ok
  end

  def identity(endpoint) do
    profile = endpoint["profile"]

    %{
      "name" => @backend,
      "agent" => profile["agent"],
      "kit_sha256" => profile["kit_sha256"],
      "preamble_sha256" => profile["preamble_sha256"],
      "tools_sha256" => profile["tools_sha256"],
      "pi_tools" => Eab.Pi.identity()["version"],
      "claude_code_version" => nil
    }
  end

  def preamble, do: File.read!(path("preamble.md"))

  @doc "The frozen preamble, then Pi's exact instructions, then the ticket."
  def prompt(instructions, ticket), do: preamble() <> "\n\n" <> instructions <> "\n" <> ticket

  def tools, do: Inventory.read_json(path("tools.json"))

  def path(relative), do: Inventory.path("priv/claude_code/" <> relative)

  @doc "The solver kit exactly as the installer writes it for this controller's address."
  def kit(url \\ controller_url()) do
    root = path("kit")

    Path.wildcard(Path.join(root, ".claude/**/*"), match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn file ->
      body = File.read!(file) |> String.replace("__EAB_CONTROLLER_URL__", url)
      {Path.relative_to(file, root), body}
    end)
  end

  def kit_files(url \\ controller_url()),
    do: Map.new(kit(url), fn {file, body} -> {file, Inventory.hash(body)} end)

  def kit_hash(url \\ controller_url()), do: Cache.key(kit_files(url))

  def controller_url do
    port = get_in(Application.get_env(:eab, EabWeb.Endpoint, []), [:http, :port]) || 4000
    "http://127.0.0.1:#{port}"
  end

  @doc "Problems that make an installed solver folder unusable, as reported by its hook."
  def kit_problems(report, url \\ controller_url()) do
    expected = kit_files(url)
    report = if is_map(report), do: report, else: %{}
    files = if is_map(report["files"]), do: report["files"], else: %{}

    changed =
      for file <- Enum.sort(Enum.uniq(Map.keys(expected) ++ Map.keys(files))),
          files[file] != expected[file] do
        cond do
          is_nil(files[file]) -> "missing #{file}"
          is_nil(expected[file]) -> "unexpected #{file}"
          true -> "changed #{file}"
        end
      end

    repository =
      for folder <- List.wrap(report["repository"]), do: "Git repository at #{folder}"

    instructions =
      for file <- List.wrap(report["instructions"]), do: "instruction file #{file}"

    changed ++ repository ++ instructions
  end
end
