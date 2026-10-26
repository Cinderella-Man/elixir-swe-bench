defmodule Eab.ClaudeCodeTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  alias Eab.{Agent, ClaudeCode, Inventory, Store}
  alias Eab.ClaudeCode.{Broker, Transcript}
  @endpoint EabWeb.Endpoint
  @url "http://127.0.0.1:4000"

  setup do
    keys = [:data_dir, :claude_code_workspace, :claude_code_claim_wait_ms]
    old = Map.new(keys, &{&1, Application.get_env(:eab, &1)})
    dir = Path.join(System.tmp_dir!(), "eab-claude-code-#{System.unique_integer([:positive])}")
    Application.put_env(:eab, :data_dir, dir)
    Application.put_env(:eab, :claude_code_claim_wait_ms, 0)
    Broker.release_pause()

    on_exit(fn ->
      for {k, v} <- old do
        if v == nil, do: Application.delete_env(:eab, k), else: Application.put_env(:eab, k, v)
      end

      Broker.release_pause()
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp endpoint, do: ClaudeCode.endpoint("claude-opus-5-5")

  defp entry(type, fields),
    do:
      Map.merge(
        %{
          "type" => type,
          "isSidechain" => true,
          "agentId" => "agent-1",
          "version" => "2.1.308",
          "timestamp" => "2026-10-26T12:00:00.000Z",
          "uuid" => "u-#{System.unique_integer([:positive])}"
        },
        fields
      )

  defp assistant(id, content, output, model \\ "claude-opus-5-5"),
    do:
      entry("assistant", %{
        "message" => %{
          "id" => id,
          "role" => "assistant",
          "model" => model,
          "content" => content,
          "usage" => %{
            "input_tokens" => 3,
            "cache_creation_input_tokens" => 1000,
            "cache_read_input_tokens" => 50,
            "output_tokens" => output
          }
        }
      })

  defp transcript(prompt, tail \\ nil) do
    [
      entry("user", %{"message" => %{"role" => "user", "content" => prompt}}),
      assistant("msg_1", [%{"type" => "thinking", "thinking" => "plan"}], 7),
      assistant("msg_1", [%{"type" => "tool_use", "id" => "t1", "name" => "x"}], 40),
      entry("user", %{
        "message" => %{"role" => "user", "content" => [%{"type" => "tool_result"}]},
        "toolUseResult" => %{"durationMs" => 12}
      }),
      tail || assistant("msg_2", [%{"type" => "text", "text" => "Done."}], 20)
    ]
  end

  defp jsonl(entries), do: Enum.map_join(entries, "", &(Jason.encode!(&1) <> "\n"))

  test "the prompt is the frozen preamble, then Pi's exact instructions, then the ticket" do
    id = hd(Inventory.all())
    spec = Inventory.spec(id)
    settings = ClaudeCode.settings(endpoint())
    instructions = Agent.instructions(spec, settings)
    ticket = Inventory.file(id, "ticket.md")

    # Claude Code declares exactly the subscription sentence Pi gets for 262,144 tokens.
    subscription = %{"budget_policy" => "response_boundary_soft_limit", "max_tokens" => 262_144}
    assert instructions == Agent.instructions(spec, subscription)
    assert instructions =~ "Stop after 262144 generated tokens total"

    assert ClaudeCode.prompt(instructions, ticket) ==
             ClaudeCode.preamble() <> "\n\n" <> instructions <> "\n" <> ticket

    assert ClaudeCode.preamble() =~ ~r/^You are an autonomous coding agent\./
    assert settings["seed"] == nil and settings["reasoning_effort"] == "xhigh"
    assert Eab.Model.settings(endpoint(), %{"seed" => "5"}) == settings
    assert Eab.Model.unchanged!(endpoint(), "") == :ok
  end

  test "every model profile pins its model and effort in an empty, four-tool agent file" do
    kit = ClaudeCode.kit(@url)

    for profile <- ClaudeCode.profiles() do
      body = kit[".claude/agents/#{profile["agent"]}.md"]
      [frontmatter] = Regex.run(~r/\A---\n(.*)\n---\n\z/s, body, capture: :all_but_first)
      assert frontmatter =~ "\nmodel: #{profile["model"]}\n"
      assert frontmatter =~ "\neffort: #{profile["effort"]}\n"
      assert frontmatter =~ "\nomitClaudeMd: true\n"

      [tools] = Regex.run(~r/\ntools: (.*)\n/, frontmatter, capture: :all_but_first)

      assert String.split(tools, ", ") ==
               Enum.map(~w(read bash edit write), &"mcp__eab_workspace__#{&1}")

      assert frontmatter =~ "url: #{@url}/claude-code/mcp"
    end

    assert Enum.map(ClaudeCode.profiles(), &{&1["agent"], &1["effort"]}) == [
             {"eab-opus-5-5-xhigh", "xhigh"},
             {"eab-sonnet-5-5-max", "max"},
             {"eab-haiku-5-5-max", "max"}
           ]

    settings = Jason.decode!(kit[".claude/settings.json"])
    deny = settings["permissions"]["deny"]

    for rule <-
          ~w|Agent(fork) Agent(general-purpose) Agent(Explore) Agent(Plan) Agent(claude) WebFetch WebSearch Skill|,
        do: assert(rule in deny)

    assert settings["env"]["DISABLE_COMPACT"] == "1"
    assert settings["env"]["CLAUDE_CODE_FORK_SUBAGENT"] == "0"
    refute Enum.any?(Map.values(kit), &String.contains?(&1, "__EAB_CONTROLLER_URL__"))
    assert Map.has_key?(kit, ".claude/commands/solve-run.md")

    # Pi 1.2.0's own four tools, frozen for tools/list.
    assert Enum.map(ClaudeCode.tools(), & &1["name"]) == ~w(read bash edit write)
  end

  test "the installer writes exactly the kit the controller expects", %{dir: dir} do
    target = Path.join(dir, "solver")

    {output, 0} =
      System.cmd("bash", ["scripts/install-claude-code-kit.sh", "--url", @url, target],
        cd: Inventory.root(),
        stderr_to_stdout: true
      )

    assert output =~ "Installed"

    installed =
      Path.wildcard(Path.join(target, ".claude/**/*"), match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Map.new(&{Path.relative_to(&1, target), Inventory.hash_file(&1)})

    assert installed == ClaudeCode.kit_files(@url)
    assert ClaudeCode.kit_problems(%{"files" => installed}, @url) == []

    # Reinstalling removes stray files.
    File.write!(Path.join(target, ".claude/agents/extra.md"), "x")

    {_, 0} =
      System.cmd("bash", ["scripts/install-claude-code-kit.sh", "--url", @url, target],
        cd: Inventory.root()
      )

    refute File.exists?(Path.join(target, ".claude/agents/extra.md"))

    File.mkdir_p!(Path.join(dir, "repo/.git"))

    assert {refusal, 1} =
             System.cmd(
               "bash",
               ["scripts/install-claude-code-kit.sh", Path.join(dir, "repo/solver")],
               cd: Inventory.root(),
               stderr_to_stdout: true
             )

    assert refusal =~ "Git repository"

    assert {_, 1} =
             System.cmd(
               "bash",
               ["scripts/install-claude-code-kit.sh", "--url", "http://example.com", target],
               cd: Inventory.root(),
               stderr_to_stdout: true
             )
  end

  test "kit drift, repositories and instruction files are reported" do
    files = ClaudeCode.kit_files(@url)
    [first | _] = Map.keys(files)

    report = %{
      "files" =>
        files
        |> Map.put(first, String.duplicate("0", 64))
        |> Map.delete(".claude/settings.json")
        |> Map.put(".claude/settings.local.json", String.duplicate("1", 64)),
      "repository" => ["/home/user"],
      "instructions" => ["/home/user/CLAUDE.md"]
    }

    problems = ClaudeCode.kit_problems(report, @url)
    assert "changed #{first}" in problems
    assert "missing .claude/settings.json" in problems
    assert "unexpected .claude/settings.local.json" in problems
    assert "Git repository at /home/user" in problems
    assert "instruction file /home/user/CLAUDE.md" in problems
    assert ClaudeCode.kit_problems(nil, @url) |> length() == map_size(files)
  end

  test "transcripts must begin with the exact prompt and use the pinned model" do
    prompt = "Prompt\nwith a trailing newline\n"
    summary = Transcript.check!(transcript(prompt), prompt, "claude-opus-5-5")

    assert summary["calls"] == 2
    assert summary["generated_tokens"] == 60

    assert summary["usage"] == %{
             "source" => "claude_code_transcript_best_effort",
             "uncached_input_tokens" => 6,
             "cache_creation_input_tokens" => 2000,
             "cache_read_input_tokens" => 100,
             "output_tokens" => 60
           }

    assert summary["claude_code_version"] == "2.1.308"
    assert summary["compactions"] == 0 and summary["over_declared_budget"] == false
    assert summary["outcome"] == %{"kind" => "completed"}

    for {entries, message} <- [
          {transcript(String.trim_trailing(prompt)), ~r/prompt differs/},
          {[
             entry("attachment", %{"attachment" => %{"type" => "skill_listing"}})
             | transcript(prompt)
           ], ~r/does not begin/},
          {transcript(prompt, assistant("msg_2", [], 1, "claude-haiku-5-5")), ~r/instead of/},
          {Enum.map(transcript(prompt), &Map.put(&1, "version", "x" <> &1["uuid"])), ~r/mixes/},
          {Enum.map(transcript(prompt), &put_in(&1, ["message", "model"], "<synthetic>")),
           ~r/resolved model/}
        ] do
      assert_raise RuntimeError, message, fn ->
        Transcript.check!(entries, prompt, "claude-opus-5-5")
      end
    end

    dated = transcript(prompt, assistant("msg_2", [], 1, "claude-opus-5-5-20261001"))

    assert Transcript.check!(dated, prompt, "claude-opus-5-5")["resolved_models"] ==
             ~w(claude-opus-5-5 claude-opus-5-5-20261001)

    big = transcript(prompt, assistant("msg_2", [], 262_200))
    assert Transcript.check!(big, prompt, "claude-opus-5-5")["over_declared_budget"]

    compacted = transcript(prompt) ++ [entry("system", %{"subtype" => "compact_boundary"})]
    assert Transcript.check!(compacted, prompt, "claude-opus-5-5")["compactions"] == 1

    assert_raise RuntimeError, ~r/line 2/, fn -> Transcript.parse("{}\nnot json\n") end
    stored = Transcript.without_timing(transcript(prompt))
    refute stored =~ "timestamp" or stored =~ "durationMs"
  end

  test "solver endings map to completion, budget limits and evaluation errors" do
    error = fn type, text ->
      entry("assistant", %{
        "isApiErrorMessage" => true,
        "error" => type,
        "message" => %{
          "id" => "s",
          "model" => "<synthetic>",
          "content" => [%{"type" => "text", "text" => text}]
        }
      })
    end

    kind = fn tail ->
      Transcript.check!(transcript("p", tail), "p", "claude-opus-5-5")["outcome"]["kind"]
    end

    assert kind.(error.("rate_limit", "You've hit your limit · resets 5pm")) == "usage_limit"
    assert kind.(error.("invalid_request", "Prompt is too long")) == "context_limit"

    assert kind.(
             error.(
               "max_output_tokens",
               "API Error: The model has reached its context window limit."
             )
           ) ==
             "context_limit"

    assert kind.(
             error.(
               "max_output_tokens",
               "API Error: Claude's response exceeded the 128000 output token maximum."
             )
           ) ==
             "response_limit"

    assert kind.(error.("authentication_failed", "Failed to authenticate")) == "error"

    assert kind.(entry("user", %{"message" => %{"content" => [%{"type" => "tool_result"}]}})) ==
             "error"
  end

  defp hook(event, kit \\ ClaudeCode.kit_files(@url), extra \\ %{}) do
    build_conn()
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post(
      "/claude-code/hook",
      Jason.encode!(Map.merge(%{"event" => event, "kit" => %{"files" => kit}}, extra))
    )
    |> json_response(200)
  end

  defp mcp(body) do
    build_conn()
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post("/claude-code/mcp", Jason.encode!(body))
  end

  defp agent_call(type),
    do: %{
      "hook_event_name" => "PreToolUse",
      "tool_name" => "Agent",
      "tool_input" => %{
        "subagent_type" => type,
        "description" => "x",
        "prompt" => "next attempt",
        "model" => "haiku"
      }
    }

  defp await_waiting(id) do
    Enum.find_value(1..200, fn _ ->
      if Broker.status().waiting == id, do: true, else: Process.sleep(10)
    end) || flunk("attempt never registered")
  end

  defp start_attempt(prompt) do
    parent = self()

    Application.put_env(:eab, :claude_code_workspace, %{
      install: fn box -> send(parent, {:installed, box.name}) end,
      execute: fn _box, name, arguments ->
        send(parent, {:tool, name, arguments})
        %{"content" => [%{"type" => "text", "text" => "ran #{name}"}], "isError" => false}
      end,
      patch: fn _box -> "diff --git a/x b/x\n" end
    })

    box = %{name: "eab-box", id: "case-x", run_id: "run-x", runtime: %{}}
    File.mkdir_p!(Store.path("runs/run-x"))

    Task.async(fn ->
      try do
        {:ok,
         ClaudeCode.Attempt.run(
           box,
           endpoint(),
           "",
           "runs/run-x/case-x",
           prompt,
           &send(parent, {:progress, &1})
         )}
      rescue
        error -> {:error, Exception.message(error)}
      end
    end)
  end

  test "one waiting attempt is claimed by the solver's Agent call and fed its tools and transcript" do
    prompt = "Frozen prompt\n"
    task = start_attempt(prompt)
    assert_receive {:installed, "eab-box"}
    await_waiting("case-x")
    assert_receive {:progress, "Waiting for the Claude Code solver" <> _}

    denied = hook(agent_call("eab-haiku-5-5-max"))
    assert denied["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert denied["hookSpecificOutput"]["permissionDecisionReason"] =~ ~s("eab-opus-5-5-xhigh")

    drifted = hook(agent_call("eab-opus-5-5-xhigh"), %{})
    assert drifted["hookSpecificOutput"]["permissionDecisionReason"] =~ "does not match"

    nested = hook(Map.put(agent_call("eab-opus-5-5-xhigh"), "agent_id", "a"))
    assert nested["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert Broker.status().waiting == "case-x"

    # MCP calls before the claim reach no workspace.
    early =
      mcp(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "read", "arguments" => %{}}
      })

    assert json_response(early, 200)["result"]["isError"]

    allowed = hook(agent_call("eab-opus-5-5-xhigh"))["hookSpecificOutput"]
    assert allowed["permissionDecision"] == "allow"

    assert allowed["updatedInput"] == %{
             "subagent_type" => "eab-opus-5-5-xhigh",
             "description" => "Benchmark attempt",
             "prompt" => prompt
           }

    assert Broker.status().active == "case-x"
    busy = hook(agent_call("eab-opus-5-5-xhigh"))
    assert busy["hookSpecificOutput"]["permissionDecisionReason"] =~ "already working"

    init =
      mcp(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2025-06-18"}
      })

    assert json_response(init, 200)["result"]["protocolVersion"] == "2025-06-18"
    assert mcp(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}).status == 202
    list = json_response(mcp(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}), 200)
    assert Enum.map(list["result"]["tools"], & &1["name"]) == ~w(read bash edit write)

    call =
      mcp(%{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{"name" => "bash", "arguments" => %{"command" => "ls"}}
      })

    assert json_response(call, 200)["result"] == %{
             "content" => [%{"type" => "text", "text" => "ran bash"}],
             "isError" => false
           }

    assert_receive {:tool, "bash", %{"command" => "ls"}}
    assert File.read!(Store.path("runs/run-x/case-x/model.patch")) =~ "diff --git"

    unknown =
      mcp(%{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{"name" => "Bash"}
      })

    assert json_response(unknown, 200)["result"]["isError"]

    browser =
      build_conn()
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("origin", "https://evil.example")
      |> post(
        "/claude-code/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 5, "method" => "tools/list"})
      )

    assert browser.status == 403

    stop = %{
      "hook_event_name" => "SubagentStop",
      "agent_id" => "agent-1",
      "agent_type" => "eab-opus-5-5-xhigh",
      "agent_transcript_path" => "/home/user/.claude/x.jsonl"
    }

    assert hook(stop, ClaudeCode.kit_files(@url), %{"transcript" => jsonl(transcript(prompt))}) ==
             %{}

    assert {:ok, result} = Task.await(task)
    assert result["stop_reason"] == "agent_completed"
    assert result["generated_tokens"] == 60 and result["calls"] == 2
    assert result["claude_code"]["claude_code_version"] == "2.1.308"
    assert result["claude_code"]["tool_calls"] == 2
    refute Map.has_key?(result, "measurement")
    stored = File.read!(Store.path("runs/run-x/case-x/claude-transcript.jsonl"))
    refute stored =~ "timestamp"
    assert File.read!(Store.path("runs/run-x/case-x/harness-prompt.md")) == prompt
    assert ClaudeCode.Attempt.recorded_version("run-x") == "2.1.308"
    assert Broker.status() |> Map.take([:waiting, :active]) == %{waiting: nil, active: nil}

    assert File.read!(Store.path("runs/run-x/case-x/claude-tool-calls.jsonl")) =~
             ~s("name":"bash")
  end

  test "a usage-limit stop is an evaluation error and pauses further attempts" do
    prompt = "Frozen prompt\n"
    task = start_attempt(prompt)
    await_waiting("case-x")
    hook(agent_call("eab-opus-5-5-xhigh"))

    limit =
      entry("assistant", %{
        "isApiErrorMessage" => true,
        "error" => "rate_limit",
        "message" => %{
          "id" => "s",
          "model" => "<synthetic>",
          "content" => [%{"type" => "text", "text" => "You've hit your limit"}]
        }
      })

    stop = %{
      "hook_event_name" => "SubagentStop",
      "agent_id" => "agent-1",
      "agent_type" => "eab-opus-5-5-xhigh"
    }

    hook(stop, ClaudeCode.kit_files(@url), %{"transcript" => jsonl(transcript(prompt, limit))})
    assert {:error, message} = Task.await(task)
    assert message =~ "usage limit"
    assert Broker.status().pause =~ "usage limit"

    # The next case waits; the solver is told to stop until the user releases the pause.
    task = start_attempt(prompt)
    await_waiting("case-x")
    denied = hook(agent_call("eab-opus-5-5-xhigh"))["hookSpecificOutput"]

    assert denied["permissionDecision"] == "deny" and
             denied["permissionDecisionReason"] =~ "Stop now"

    Broker.release_pause()

    assert hook(agent_call("eab-opus-5-5-xhigh"))["hookSpecificOutput"]["permissionDecision"] ==
             "allow"

    # A different Claude Code version within one run is an evaluation error.
    other = Enum.map(transcript(prompt), &Map.put(&1, "version", "2.2.0"))
    hook(stop, ClaudeCode.kit_files(@url), %{"transcript" => jsonl(other)})
    assert {:error, changed} = Task.await(task)
    assert changed =~ "Claude Code changed from 2.1.308 to 2.2.0"
  end

  test "without a waiting workspace the solver is told to wait or stop" do
    denied = hook(agent_call("eab-opus-5-5-xhigh"))["hookSpecificOutput"]
    assert denied["permissionDecision"] == "deny"
    assert denied["permissionDecisionReason"] =~ "No Claude Code run is active"
    assert hook(%{"hook_event_name" => "SubagentStop", "agent_type" => "x"}) == %{}
  end
end
