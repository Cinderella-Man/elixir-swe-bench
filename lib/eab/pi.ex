defmodule Eab.Pi do
  @moduledoc "Launches the pinned Pi CLI in a problem's Docker workspace."
  alias Eab.{Command, Inventory, PiGateway, Sandbox, Store}
  # Hang guard for each bash tool command, twice the grader's test limit; not a speed budget.
  @bash_timeout_seconds 1200

  def identity do
    %{
      "package" => "@earendil-works/pi-coding-agent",
      "version" =>
        Inventory.read_json(Inventory.path("priv/pi/package.json"))["dependencies"][
          "@earendil-works/pi-coding-agent"
        ],
      "lock_sha256" => Inventory.hash_file(Inventory.path("priv/pi/package-lock.json"))
    }
  end

  def node_image(spec) do
    kind = if String.contains?(spec["runtime"]["image"], "alpine"), do: "musl", else: "glibc"
    Inventory.read_json(Inventory.path("priv/pi/runtime.json"))[kind]
  end

  def config(endpoint, settings, prompt, instructions) do
    strata = endpoint["backend"] == "strata"
    anthropic = endpoint["backend"] == "anthropic"
    subscription = endpoint["backend"] == "openai_subscription"
    provider = if subscription, do: "openai", else: "benchmark"

    compat =
      cond do
        strata ->
          %{
            "allowEmptySignature" => true,
            "supportsCacheControlOnTools" => false,
            "supportsEagerToolInputStreaming" => false
          }

        # The gateway freezes thinking and effort; this keeps Pi's own request consistent.
        anthropic ->
          %{"forceAdaptiveThinking" => true, "supportsTemperature" => false}

        true ->
          %{
            "supportsStore" => false,
            "supportsDeveloperRole" => false,
            "supportsReasoningEffort" => false,
            "supportsUsageInStreaming" => true,
            "maxTokensField" => "max_tokens"
          }
      end

    %{
      "model" => endpoint["model"],
      "provider" => provider,
      "api_prefix" => if(strata or anthropic, do: "", else: "/v1"),
      "prompt" => prompt,
      "instructions" => instructions,
      "bash_timeout_seconds" => @bash_timeout_seconds,
      "models" => %{
        "providers" => %{
          provider => %{
            "api" =>
              cond do
                subscription -> "openai-responses"
                strata or anthropic -> "anthropic-messages"
                true -> "openai-completions"
              end,
            "apiKey" => "local-transport",
            "compat" =>
              if(subscription,
                do: %{
                  "supportsDeveloperRole" => true,
                  "supportsMaxOutputTokens" => false,
                  "supportsStrictMode" => false
                },
                else: compat
              ),
            "models" => [
              %{
                "id" => endpoint["model"],
                "name" => endpoint["model"],
                "reasoning" =>
                  subscription or strata or anthropic or reasoning_supported?(endpoint),
                "input" => ["text"],
                # Pi requires numeric bookkeeping values. Subscription requests remove its
                # output cap; compaction is off and these are not provider capacity claims.
                "contextWindow" => settings["window_tokens"] || 262_144,
                "maxTokens" => settings["response_tokens"] || 8192,
                "cost" => %{"input" => 0, "output" => 0, "cacheRead" => 0, "cacheWrite" => 0}
              }
            ]
          }
        }
      },
      "settings" => %{
        "compaction" => %{"enabled" => false},
        "retry" => %{"enabled" => false, "provider" => %{"maxRetries" => 0}},
        "httpIdleTimeoutMs" => 1_260_000,
        "cacheWarming" => "off",
        "images" => %{"blockImages" => true},
        "defaultProjectTrust" => "never",
        "shellPath" => "/opt/pi/bash-watchdog.mjs"
      }
    }
  end

  defp reasoning_supported?(endpoint) do
    caps = get_in(endpoint, ["profile", "chat_template_caps"]) || %{}
    caps["supports_thinking"] == true or caps["supports_preserve_reasoning"] == true
  end

  def run(box, endpoint, key, settings, prefix, prompt, instructions, emit, opts \\ []) do
    Eab.Activity.note(
      "Starting Pi #{identity()["version"]} in #{box.name}, working directory /workspace"
    )

    Eab.Activity.note("Ticket prompt:\n" <> prompt)
    config = config(endpoint, settings, prompt, instructions)
    Store.write("#{prefix}/pi-config.json", Map.put(config, "agent", identity()), key)
    file = Store.path("#{prefix}/pi-config.json")
    Sandbox.copy_file(box, file, "/opt/eab-attempt/pi.json")

    state = %{
      state(endpoint, key, settings, prefix, emit, Keyword.get(opts, :measure, true))
      | snapshot: fn -> Store.write_text("#{prefix}/model.patch", Sandbox.patch(box), key) end
    }

    result =
      Command.exchange(
        "docker",
        [
          "exec",
          "-i",
          "-w",
          "/workspace",
          box.name,
          "/opt/pi/node",
          "/opt/pi/bridge.mjs",
          "/opt/eab-attempt/pi.json"
        ],
        state,
        &handle/2,
        timeout: :infinity
      )

    finish(result)
  end

  def state(endpoint, key, settings, prefix, emit, measure? \\ true) do
    %{
      endpoint: endpoint,
      key: key,
      settings: settings,
      prefix: prefix,
      emit: emit,
      calls: 0,
      generated_tokens: 0,
      measurement: Eab.Measurement.start(measure?),
      stop_reason: nil,
      error: nil,
      settled: false,
      assistant: false,
      exit_code: nil,
      snapshot: fn -> :ok end
    }
  end

  def handle(%{"type" => "request"} = frame, state), do: PiGateway.request(frame, state)

  def handle(%{"type" => "event", "event" => event}, state) do
    Eab.Activity.pi(event)
    # Session messages/tool results are the durable transcript; token deltas would duplicate it.
    if event["type"] not in ["message_update", "tool_execution_update"] do
      event = Map.drop(event, ["durationMs"])
      append(state, "pi-events.jsonl", event)
    end

    state =
      case event do
        %{
          "type" => "message_end",
          "message" => %{"role" => "assistant", "stopReason" => reason} = message
        }
        when reason in ["error", "aborted"] ->
          if state.stop_reason,
            do: state,
            else: %{state | error: message["errorMessage"] || "Pi model response #{reason}"}

        %{"type" => "message_end", "message" => %{"role" => "assistant"}} ->
          %{state | assistant: true}

        %{"type" => "agent_settled", "aborted" => false} ->
          %{state | settled: true}

        %{"type" => "tool_execution_start", "toolName" => name} ->
          state.emit.("Pi is using #{name}")
          state

        %{"type" => "turn_end"} ->
          state.snapshot.()
          state

        _ ->
          state
      end

    {nil, state}
  end

  def handle(%{"type" => "diagnostic", "text" => text}, state) do
    Eab.Activity.note("Pi: " <> text)
    append(state, "pi-diagnostics.jsonl", %{"text" => text})
    {nil, state}
  end

  def handle(%{"type" => "fatal", "message" => error}, state) do
    Eab.Activity.note("Pi error: " <> error)
    {nil, %{state | error: error}}
  end

  def handle(%{"type" => "exit", "code" => code}, state),
    do: {nil, %{state | exit_code: code}}

  def handle(_, _), do: raise("Unexpected Pi transport record")

  def finish(%{"state" => state, "returncode" => code}) do
    measurement = Eab.Measurement.finish(state.measurement)
    # Also preserve the final duration when Pi exits with a transport/tool error.
    PiGateway.persist(state, measurement)

    cond do
      state.error ->
        raise Store.redact(state.error, state.key)

      state.stop_reason ->
        summary(state, state.stop_reason, measurement)

      code != 0 or state.exit_code != 0 ->
        raise "Pi exited unsuccessfully; see pi-diagnostics.jsonl"

      not state.settled or not state.assistant or state.calls == 0 ->
        raise "Pi exited without completing an attempt; see pi-events.jsonl"

      true ->
        summary(state, "agent_completed", measurement)
    end
  end

  defp summary(state, reason, measurement) do
    %{
      "calls" => state.calls,
      "generated_tokens" => state.generated_tokens,
      "stop_reason" => reason,
      "measurement" => measurement
    }
  end

  defp append(state, file, data) do
    path = Store.path("#{state.prefix}/#{file}")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(Store.scrub(data, state.key)) <> "\n", [:append])
    File.chmod!(path, 0o600)
  end
end
