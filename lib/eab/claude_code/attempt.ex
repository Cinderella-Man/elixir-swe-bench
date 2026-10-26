defmodule Eab.ClaudeCode.Attempt do
  @moduledoc """
  One Claude Code attempt: waits in the broker for the solver session, executes its
  workspace tool calls in this attempt's container and checks the returned transcript.
  No elapsed time is measured or stored.
  """
  alias Eab.{Activity, ClaudeCode, Command, Inventory, Sandbox, Store}
  alias Eab.ClaudeCode.{Broker, Transcript}
  # Each workspace tool runs Pi's tool once; Pi's watchdog ends a hung bash command at
  # 1200 seconds inside the container. This outer watchdog only reaps a stuck exec.
  @bash_timeout_seconds 1200
  @tool_watchdog_seconds 1320
  @mutating ~w(bash edit write)

  def run(box, endpoint, key, prefix, prompt, emit) do
    workspace().install.(box)
    Store.write_text("#{prefix}/harness-prompt.md", prompt, key)
    agent = endpoint["profile"]["agent"]

    case Broker.register(%{
           run_id: box.run_id,
           case: box.id,
           agent: agent,
           prompt: prompt,
           model: endpoint["model"]
         }) do
      :ok -> :ok
      {:error, message} -> raise message
    end

    Activity.note("Waiting for the Claude Code solver: run /solve-run in the solver session")
    emit.("Waiting for the Claude Code solver (/solve-run, subagent #{agent})")

    try do
      loop(%{
        box: box,
        endpoint: endpoint,
        key: key,
        prefix: prefix,
        prompt: prompt,
        emit: emit,
        tools: 0
      })
    after
      Broker.withdraw()
    end
  end

  defp loop(state) do
    receive do
      :eab_claimed ->
        Activity.note("Claude Code solver started")
        state.emit.("Claude Code solver is working")
        loop(state)

      {:eab_tool, from, ref, name, arguments} ->
        state = %{state | tools: state.tools + 1}
        send(from, {ref, tool(state, name, arguments)})
        loop(state)

      {:eab_finished, agent_id, transcript, error} ->
        finish(state, agent_id, transcript, error)
    end
  end

  def tool(state, name, arguments) do
    Activity.note("Claude Code tool call #{state.tools}: #{name} " <> preview(arguments))

    result =
      if name in ~w(read bash edit write) and is_map(arguments) do
        workspace().execute.(state.box, name, arguments)
      else
        %{
          "content" => [%{"type" => "text", "text" => "Tool #{name} not found"}],
          "isError" => true
        }
      end

    append(state, %{"name" => name, "arguments" => arguments, "result" => result})

    if name in @mutating do
      Store.write_text("#{state.prefix}/model.patch", workspace().patch.(state.box), state.key)
    end

    result
  rescue
    error ->
      %{
        "content" => [
          %{"type" => "text", "text" => "Workspace tool failed: " <> Exception.message(error)}
        ],
        "isError" => true
      }
  end

  # Tests replace the container operations; everything else runs unchanged.
  defp workspace,
    do:
      Application.get_env(:eab, :claude_code_workspace, %{
        install: &install/1,
        execute: &execute/3,
        patch: &Sandbox.patch/1
      })

  defp install(box),
    do:
      Sandbox.copy_file(
        box,
        ClaudeCode.path("workspace-tools.mjs"),
        "/opt/eab-attempt/workspace-tools.mjs"
      )

  defp execute(box, name, arguments) do
    output =
      Command.run(
        "docker",
        [
          "exec",
          "-i",
          "-w",
          "/workspace",
          "-e",
          "EAB_BASH_TIMEOUT_SECONDS=#{@bash_timeout_seconds}",
          box.name,
          "/opt/pi/node",
          "/opt/eab-attempt/workspace-tools.mjs"
        ],
        input: Jason.encode!(%{"name" => name, "arguments" => arguments}) <> "\n",
        timeout: @tool_watchdog_seconds,
        limit: 8_000_000
      )

    # The runner writes its result as the last line; Node warnings may precede it.
    line = output["output"] |> String.split("\n", trim: true) |> List.last()

    case (output["returncode"] == 0 and not output["output_truncated"] and line) &&
           Jason.decode(line) do
      {:ok, %{"content" => content, "isError" => error} = result}
      when is_list(content) and is_boolean(error) ->
        result

      _ ->
        raise "the workspace tool runner did not return a result (exit #{output["returncode"]})"
    end
  end

  defp finish(state, agent_id, transcript, error) do
    unless is_binary(transcript),
      do: raise("The solver transcript did not reach the controller: #{error || "missing"}")

    entries = Transcript.parse(transcript)

    Store.write_text(
      "#{state.prefix}/claude-transcript.jsonl",
      Transcript.without_timing(entries),
      state.key
    )

    summary = Transcript.check!(entries, state.prompt, state.endpoint["model"])
    version!(state.box.run_id, summary["claude_code_version"])
    outcome = summary["outcome"]

    Activity.note(
      "Claude Code solver finished: #{outcome["kind"]}, #{summary["calls"]} model calls, " <>
        "#{summary["generated_tokens"]} output tokens (transcript, best effort)"
    )

    stop_reason =
      case outcome["kind"] do
        "completed" ->
          "agent_completed"

        kind when kind in ["context_limit", "response_limit"] ->
          kind

        "usage_limit" ->
          Broker.pause(
            "The Claude subscription usage limit was reached, so the controller recorded an evaluation error for the last case. " <>
              "Stop now and tell the user. When the limit resets, they release the pause on the benchmark website and run /solve-run again."
          )

          raise outcome["message"]

        _ ->
          raise outcome["message"]
      end

    %{
      "calls" => summary["calls"],
      "generated_tokens" => summary["generated_tokens"],
      "stop_reason" => stop_reason,
      "usage" => summary["usage"],
      "claude_code" =>
        Map.take(
          summary,
          ~w(claude_code_version agent_id resolved_models compactions attachments over_declared_budget)
        )
        |> Map.put("agent_id", summary["agent_id"] || agent_id)
        |> Map.put("tool_calls", state.tools)
    }
  end

  # A run has one Claude Code version; the first attempt fixes it.
  defp version!(run_id, version) do
    path = Store.path("runs/#{run_id}/claude-code-version.txt")

    case File.write(path, version, [:exclusive]) do
      :ok ->
        :ok

      {:error, :eexist} ->
        recorded = File.read!(path)

        unless recorded == version,
          do: raise("Claude Code changed from #{recorded} to #{version} during this run")
    end
  end

  def recorded_version(run_id) do
    case File.read(Store.path("runs/#{run_id}/claude-code-version.txt")) do
      {:ok, version} -> version
      _ -> nil
    end
  end

  defp append(state, record) do
    path = Store.path("#{state.prefix}/claude-tool-calls.jsonl")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(Store.scrub(record, state.key)) <> "\n", [:append])
    File.chmod!(path, 0o600)
  end

  defp preview(arguments) do
    text = Jason.encode!(arguments)
    if byte_size(text) > 2000, do: binary_part(text, 0, 2000) <> "…", else: text
  rescue
    _ -> inspect(arguments, limit: 20)
  end

  @doc false
  def tool_runner_sha256, do: Inventory.hash_file(ClaudeCode.path("workspace-tools.mjs"))
end
