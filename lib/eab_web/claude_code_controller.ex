defmodule EabWeb.ClaudeCodeController do
  @moduledoc """
  Loopback endpoints for the Claude Code solver kit: the workspace MCP server and the
  receiver for its PreToolUse(Agent), PostToolUse(Agent) and SubagentStop hooks. Browsers
  always send an Origin header on these POSTs, so requests carrying one are refused.
  """
  use Phoenix.Controller, formats: [:json]
  alias Eab.ClaudeCode.{Broker, MCP}

  plug(:local_client)

  def mcp(%{method: "POST"} = conn, _) do
    case MCP.handle(conn.body_params) do
      {:reply, body} -> json(conn, body)
      :accepted -> send_resp(conn, 202, "")
    end
  end

  # No server-initiated stream and no sessions to end.
  def mcp(conn, _), do: send_resp(conn, 405, "")

  def hook(conn, _) do
    body = conn.body_params
    event = if is_map(body["event"]), do: body["event"], else: %{}

    case event["hook_event_name"] do
      "PreToolUse" ->
        # Solvers Claude Code finished without a SubagentStop (an API error ends a
        # subagent silently) free their slots; the hook uploads their transcripts.
        if is_list(body["recover"]),
          do: json(conn, %{"eab_upload" => Broker.recover(body["recover"])}),
          else: json(conn, pre_tool_use(event, body["kit"]))

      "PostToolUse" ->
        Broker.bind(event)
        json(conn, %{})

      "SubagentStop" ->
        # The hook first reports the stop at once, then uploads the settled transcript.
        if body["stopping"] == true,
          do: Broker.stopping(event),
          else: Broker.finish(event, body["transcript"], body["transcript_error"])

        json(conn, %{})

      _ ->
        json(conn, %{})
    end
  end

  defp pre_tool_use(event, kit) do
    # One claim wait bounds the whole call, whatever it ends up waiting for.
    deadline = System.monotonic_time(:millisecond) + wait()
    active = Eab.Runs.snapshot().active

    claude_run? =
      is_map(active) and get_in(active, ["model", "backend"]) == Eab.ClaudeCode.backend()

    run = if claude_run?, do: %{id: active["id"], parallel: active["parallel_attempts"] || 1}

    case Broker.claim(event, kit, run, wait()) do
      {:ok, attempt} ->
        # The whole input is replaced, so no model override or other option survives.
        # The solver runs in the background so the session can start the next one.
        input = %{
          "subagent_type" => attempt.agent,
          "description" => "Benchmark attempt",
          "prompt" => attempt.prompt,
          "run_in_background" => true
        }

        decision("allow", "Benchmark attempt #{attempt.case}", input)

      {:deny, reason} ->
        decision("deny", reason)

      :busy ->
        n = run.parallel

        decision(
          "deny",
          "All #{n} solver#{if n == 1, do: " is", else: "s are"} of this run working. " <>
            "Wait until a solver's completion notification arrives, then call the Agent tool again the same way."
        )

      :waiting ->
        # The run may have ended while this call waited for a workspace.
        cond do
          claude_run? and is_map(Eab.Runs.snapshot().active) ->
            decision(
              "deny",
              "No workspace is ready yet (#{active["message"] || "the controller is preparing the next case"}). " <>
                "Call the Agent tool again the same way to keep waiting."
            )

          # Between two runs in a row no run is active, yet the next one is already due.
          # Hold the call until it starts, so the session neither stops nor spins.
          await_queued_run(deadline) ->
            decision(
              "deny",
              "The next run of this row of benchmark runs is about to start or has just started. " <>
                "Call the Agent tool again the same way to keep waiting."
            )

          true ->
            decision(
              "deny",
              "No Claude Code run is active on the benchmark website: it has finished, was stopped, or has not started. Tell the user and stop."
            )
        end
    end
  end

  # Whether another Claude Code run is queued to start or has started, waiting until the
  # deadline for it while it is queued.
  defp await_queued_run(deadline) do
    snapshot = Eab.Runs.snapshot()
    claude? = &(&1 == Eab.ClaudeCode.backend())

    cond do
      is_map(snapshot.active) ->
        claude?.(get_in(snapshot.active, ["model", "backend"]))

      is_map(snapshot.queue) and snapshot.queue["remaining"] > 0 and
          claude?.(snapshot.queue["backend"]) ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(min(1000, wait()))
          await_queued_run(deadline)
        else
          true
        end

      true ->
        false
    end
  end

  defp decision(kind, reason, input \\ nil) do
    output = %{
      "hookEventName" => "PreToolUse",
      "permissionDecision" => kind,
      "permissionDecisionReason" => reason
    }

    %{"hookSpecificOutput" => if(input, do: Map.put(output, "updatedInput", input), else: output)}
  end

  defp wait, do: Application.get_env(:eab, :claude_code_claim_wait_ms, 300_000)

  defp local_client(conn, _) do
    json? =
      Enum.any?(
        get_req_header(conn, "content-type"),
        &String.starts_with?(&1, "application/json")
      )

    if get_req_header(conn, "origin") == [] and (conn.method != "POST" or json?) do
      conn
    else
      conn |> send_resp(403, "") |> halt()
    end
  end
end
