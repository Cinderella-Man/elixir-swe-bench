defmodule Eab.ClaudeCode.MCP do
  @moduledoc """
  The solver's four workspace tools over MCP's streamable HTTP transport, answered as
  plain JSON. Names, descriptions and schemas are Pi 1.2.0's, frozen in tools.json.
  """
  alias Eab.ClaudeCode
  alias Eab.ClaudeCode.Broker

  @versions ~w(2025-11-25 2025-06-18 2025-03-26 2024-11-05)

  @doc "Returns `{:reply, json}` for requests and `:accepted` for notifications."
  def handle(%{"jsonrpc" => "2.0", "method" => method} = request) when is_binary(method) do
    if Map.has_key?(request, "id"),
      do: {:reply, response(request["id"], method, request["params"] || %{})},
      else: :accepted
  end

  def handle(_), do: {:reply, error(nil, -32600, "Invalid JSON-RPC request")}

  defp response(id, "initialize", params) do
    requested = params["protocolVersion"]

    result(id, %{
      "protocolVersion" => if(requested in @versions, do: requested, else: hd(@versions)),
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "serverInfo" => %{"name" => "eab-workspace", "version" => "1"}
    })
  end

  defp response(id, "ping", _), do: result(id, %{})
  defp response(id, "tools/list", _), do: result(id, %{"tools" => ClaudeCode.tools()})

  defp response(id, "tools/call", %{"name" => name} = params) when is_binary(name) do
    case Broker.call_tool(name, params["arguments"] || %{}) do
      {:ok, outcome} ->
        result(id, outcome)

      {:error, message} ->
        result(id, %{"content" => [%{"type" => "text", "text" => message}], "isError" => true})
    end
  end

  defp response(id, "tools/call", _), do: error(id, -32602, "Missing tool name")
  defp response(id, method, _), do: error(id, -32601, "Method not found: #{method}")

  defp result(id, value), do: %{"jsonrpc" => "2.0", "id" => id, "result" => value}

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
end
