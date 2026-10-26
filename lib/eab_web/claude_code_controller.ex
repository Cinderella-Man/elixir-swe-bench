defmodule EabWeb.ClaudeCodeController do
  @moduledoc """
  Loopback endpoints for the Claude Code solver kit: the workspace MCP server and the
  receiver for its PreToolUse(Agent) and SubagentStop hooks. Browsers always send an
  Origin header on these POSTs, so requests carrying one are refused.
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
        json(conn, pre_tool_use(event, body["kit"]))

      "SubagentStop" ->
        Broker.finish(event, body["transcript"], body["transcript_error"])
        json(conn, %{})

      _ ->
        json(conn, %{})
    end
  end

  defp pre_tool_use(event, kit) do
    active = Eab.Runs.snapshot().active

    claude_run? =
      is_map(active) and get_in(active, ["model", "backend"]) == Eab.ClaudeCode.backend()

    case Broker.claim(event, kit, claude_run?, wait()) do
      {:ok, attempt} ->
        # The whole input is replaced, so no model override or other option survives.
        input = %{
          "subagent_type" => attempt.agent,
          "description" => "Benchmark attempt",
          "prompt" => attempt.prompt
        }

        decision("allow", "Benchmark attempt #{attempt.case}", input)

      {:deny, reason} ->
        decision("deny", reason)

      :waiting when claude_run? ->
        decision(
          "deny",
          "No workspace is ready yet (#{active["message"] || "the controller is preparing the next case"}). " <>
            "Call the Agent tool again the same way to keep waiting."
        )

      :waiting ->
        decision(
          "deny",
          "No Claude Code run is active on the benchmark website: it has finished, was stopped, or has not started. Tell the user and stop."
        )
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
