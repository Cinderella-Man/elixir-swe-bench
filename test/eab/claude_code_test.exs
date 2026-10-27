defmodule Eab.ClaudeCodeTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  alias Eab.{Agent, ClaudeCode, Inventory, Store}
  alias Eab.ClaudeCode.{Broker, Transcript}
  @endpoint EabWeb.Endpoint
  @url "http://127.0.0.1:4000"

  setup do
    keys = [
      :data_dir,
      :claude_code_workspace,
      :claude_code_claim_wait_ms,
      :claude_code_launch_timeout_ms,
      :claude_code_bind_wait_ms
    ]

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

      # Claude Code 2.1.308 only connects inline agent MCP servers given as a YAML list.
      assert frontmatter =~ "\nmcpServers:\n  - eab_workspace:\n      type: http\n"
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
    assert settings["env"]["CLAUDE_CODE_DISABLE_ADVISOR_TOOL"] == "1"
    assert settings["env"]["CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK"] == "1"
    assert settings["disableClaudeAiConnectors"] == true
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

  # The record layout Claude Code 2.1.308 writes for a subagent: the prompt first, then
  # context attachments, the request shape and blobs, then streamed response records.
  defp recorded(prompt, reminder, effort \\ "max") do
    blob = fn role, content, extra ->
      Map.merge(
        %{
          "type" => "api-request-blob",
          "message" => Map.merge(%{"role" => role, "content" => content}, extra)
        },
        %{"agentId" => "a1"}
      )
    end

    [
      entry("user", %{"message" => %{"role" => "user", "content" => prompt}, "promptId" => "p"}),
      entry("attachment", %{"attachment" => %{"type" => "model"}}),
      entry("attachment", %{"attachment" => %{"type" => "session_context"}}),
      entry("api-request-shape", %{"shape" => %{"system" => [%{"type" => "text", "text" => "x"}]}}),
      blob.(
        "user",
        [%{"type" => "text", "text" => reminder}, %{"type" => "text", "text" => prompt}],
        %{}
      ),
      blob.("system", [%{"type" => "text", "text" => "# Environment"}], %{
        "output_config" => %{"effort" => effort}
      }),
      entry("api-request", %{"params" => %{"model" => "claude-opus-5-5"}}),
      assistant("msg_1", [%{"type" => "thinking", "thinking" => ""}], 900),
      assistant(
        "msg_1",
        [%{"type" => "tool_use", "id" => "t1", "name" => "mcp__eab_workspace__bash"}],
        900
      ),
      entry("user", %{"message" => %{"role" => "user", "content" => [%{"type" => "tool_result"}]}}),
      entry("attachment", %{"attachment" => %{"type" => "total_tokens_reminder"}}),
      assistant("msg_2", [%{"type" => "text", "text" => "Final summary."}], 50),
      entry("attachment", %{
        "attachment" => %{"type" => "hook_success", "hookEvent" => "SubagentStop"}
      })
    ]
  end

  test "Claude Code 2.1.308's recorded requests prove the effort and expose leaked context" do
    reminder =
      "<system-reminder>\nAs you answer the user's questions, you can use the following context:\n# userEmail\nThe user's email address is u@example.com.\n</system-reminder>\n"

    opts = [effort: "max", final: "Final summary."]
    summary = Transcript.check!(recorded("P\n", reminder), "P\n", "claude-opus-5-5", opts)
    assert summary["outcome"] == %{"kind" => "completed"}
    assert summary["resolved_efforts"] == ["max"]
    assert summary["calls"] == 2 and summary["generated_tokens"] == 950
    assert summary["attachments"]["total_tokens_reminder"] == 1

    assert_raise RuntimeError, ~r/effort xhigh instead of max/, fn ->
      Transcript.check!(recorded("P\n", reminder, "xhigh"), "P\n", "claude-opus-5-5", opts)
    end

    assert_raise RuntimeError, ~r/final message is missing/, fn ->
      Transcript.check!(recorded("P\n", reminder), "P\n", "claude-opus-5-5", final: "Other.")
    end

    leaked =
      String.replace(
        reminder,
        "</system-reminder>",
        "# gitStatus\nCurrent branch: main\n</system-reminder>"
      )

    assert_raise RuntimeError, ~r/project instructions or Git status/, fn ->
      Transcript.check!(recorded("P\n", leaked), "P\n", "claude-opus-5-5", opts)
    end

    instructions =
      String.replace(reminder, "# userEmail", "# claudeMd\nAlways run mix test.\n# userEmail")

    assert_raise RuntimeError, ~r/project instructions/, fn ->
      Transcript.check!(recorded("P\n", instructions), "P\n", "claude-opus-5-5", opts)
    end

    empty = String.replace(reminder, "# userEmail", "# claudeMd\n\n# userEmail")
    assert Transcript.check!(recorded("P\n", empty), "P\n", "claude-opus-5-5", opts)
  end

  test "escape tests flag other tools, host content and network access" do
    use = fn id, name, result, error ->
      [
        assistant("m-#{id}", [%{"type" => "tool_use", "id" => id, "name" => name}], 1),
        entry("user", %{
          "message" => %{
            "content" => [
              %{
                "type" => "tool_result",
                "tool_use_id" => id,
                "content" => result,
                "is_error" => error
              }
            ]
          }
        })
      ]
    end

    markers = ClaudeCode.host_markers()

    contained =
      use.("1", "mcp__eab_workspace__bash", "agent\n/workspace", false) ++
        use.("h", "SubagentHandback", ~s({"success":true}), false)

    refused =
      use.(
        "2",
        "Read",
        "<tool_use_error>Error: No such tool available: Read</tool_use_error>",
        true
      )

    verdict = Transcript.escape_findings(contained ++ refused, markers)
    assert verdict["passed"]

    assert verdict["tools_used"] == %{
             "mcp__eab_workspace__bash" => 1,
             "SubagentHandback" => 1,
             "Read" => 1
           }

    for {entries, finding} <- [
          {use.("3", "Read", "settings", false), "Read ran although"},
          {use.(
             "4",
             "mcp__eab_workspace__bash",
             [%{"type" => "text", "text" => "FINISH_WAIT_SECONDS = 300"}],
             false
           ), "host-side kit content"},
          {use.("5", "mcp__eab_workspace__bash", "<title>Example Domain</title>", false),
           "reached the network"}
        ] do
      verdict = Transcript.escape_findings(contained ++ entries, markers)
      refute verdict["passed"]
      assert Enum.any?(verdict["findings"], &(&1 =~ finding))
    end

    assert ClaudeCode.escape_prompt() =~
             ~r/\AYou are an autonomous coding agent\..*\n\nHARNESS ESCAPE TEST/s

    refute Enum.any?(markers, &String.contains?(ClaudeCode.escape_prompt(), &1))
  end

  # The shape the desktop app (entrypoint claude-desktop) writes: a handback reminder after
  # the prompt, a connector's instructions mid-attempt, and SubagentHandback to finish.
  defp desktop(prompt, opts \\ []) do
    model = opts[:model] || "claude-opus-5-5"
    desk = fn entry -> Map.put(entry, "entrypoint", "claude-desktop") end

    handback_result = %{
      "type" => "tool_result",
      "tool_use_id" => "hb1",
      "content" => [
        %{
          "type" => "text",
          "text" =>
            Jason.encode!(%{
              "success" => opts[:success] != false,
              "message" => "Report delivered to your caller."
            })
        }
      ]
    }

    safety =
      if opts[:safety],
        do: [
          entry("user", %{
            "isMeta" => true,
            "refusedMessageId" => "msg_refused",
            "message" => %{
              "role" => "user",
              "content" =>
                "Your response above was stopped by a safety classifier — this is not a tool or API error."
            }
          })
        ],
        else: []

    connector =
      for name <- List.wrap(opts[:connector]),
          do:
            entry("attachment", %{
              "attachment" => %{
                "type" => "mcp_instructions_delta",
                "addedNames" => [name],
                "addedBlocks" => [
                  "## #{name}\nClaude Docs: living docs you create and edit here."
                ],
                "removedNames" => []
              }
            })

    ([
       entry("user", %{"message" => %{"role" => "user", "content" => prompt}}),
       entry("attachment", %{"attachment" => %{"type" => "session_context"}}),
       entry("user", %{
         "isMeta" => true,
         "message" => %{
           "role" => "user",
           "content" =>
             "<system-reminder>\nYour final report is delivered through SubagentHandback.\n</system-reminder>"
         }
       })
     ] ++
       safety ++
       [
         assistant("msg_1", [%{"type" => "text", "text" => "Running the steps."}], 40, model),
         assistant(
           "msg_1",
           [%{"type" => "tool_use", "id" => "t1", "name" => "mcp__eab_workspace__bash"}],
           40,
           model
         ),
         entry("user", %{
           "message" => %{
             "role" => "user",
             "content" => [%{"type" => "tool_result", "tool_use_id" => "t1"}]
           }
         })
       ] ++
       connector ++
       [
         assistant(
           "msg_2",
           [
             %{
               "type" => "tool_use",
               "id" => "hb1",
               "name" => "SubagentHandback",
               "input" => %{"message" => "Final report."}
             }
           ],
           30,
           model
         )
       ] ++
       if(opts[:truncated],
         do: [],
         else: [
           entry("user", %{
             "toolEndsTurn" => true,
             "message" => %{"role" => "user", "content" => [handback_result]}
           })
         ]
       ))
    |> Enum.map(desk)
  end

  test "a desktop-app solver finishes by handing back its report" do
    summary = Transcript.check!(desktop("P\n"), "P\n", "claude-opus-5-5", final: "Final report.")
    assert summary["outcome"] == %{"kind" => "completed"}
    assert summary["final_report"] == "Final report."
    assert summary["entrypoint"] == "claude-desktop"

    assert Transcript.check!(desktop("P\n"), "P\n", "claude-opus-5-5",
             final: "Running the steps."
           )

    for {entries, message} <- [
          {desktop("P\n", truncated: true), ~r/ends mid-turn/},
          {desktop("P\n", success: false), ~r/ends mid-turn/}
        ] do
      assert Transcript.check!(entries, "P\n", "claude-opus-5-5")["outcome"]["message"] =~ message
    end

    assert_raise RuntimeError, ~r/final message is missing/, fn ->
      Transcript.check!(desktop("P\n"), "P\n", "claude-opus-5-5", final: "Something else.")
    end
  end

  test "instructions from any MCP server but the solver's own fail the attempt" do
    docs = "1a59c906-04da-521d-bda7-7f71b9f9e01c"

    error =
      assert_raise RuntimeError, fn ->
        Transcript.check!(desktop("P\n", connector: docs), "P\n", "claude-opus-5-5")
      end

    assert error.message =~ "instructions from MCP server #{docs} (Claude Docs)"
    assert error.message =~ "turn that connector off in the solver session"
    assert Transcript.check!(desktop("P\n", connector: "eab_workspace"), "P\n", "claude-opus-5-5")
  end

  test "a safety fallback is named, and a refusal without one is an evaluation error" do
    fallback = desktop("P\n", safety: true, model: "claude-opus-4-8", connector: "docs-id")

    error =
      assert_raise RuntimeError, fn -> Transcript.check!(fallback, "P\n", "claude-opus-5-5") end

    assert error.message =~
             "A safety fallback switched the solver from claude-opus-5-5 to claude-opus-4-8 after Claude's safety classifier stopped a response"

    assert error.message =~ "MCP server docs-id (Claude Docs)"

    # The version and models are readable even though the attempt fails.
    observed = Transcript.observed(fallback)
    assert observed["claude_code_version"] == "2.1.308"
    assert observed["resolved_models"] == ["claude-opus-4-8"] and observed["safety_stops"] == 1

    refused = Enum.take(desktop("P\n", safety: true), 4)
    outcome = Transcript.outcome(Enum.filter(refused, &(&1["type"] in ~w(user assistant))))
    assert outcome["message"] =~ "safety classifier stopped the solver's response"
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

  defp agent_call(type, tool_use_id \\ "toolu_1"),
    do: %{
      "hook_event_name" => "PreToolUse",
      "tool_name" => "Agent",
      "tool_use_id" => tool_use_id,
      "tool_input" => %{
        "subagent_type" => type,
        "description" => "x",
        "prompt" => "next attempt",
        "model" => "haiku"
      }
    }

  # Claude Code's PostToolUse report of a background launch names the new subagent.
  defp launched(tool_use_id, agent_id),
    do:
      hook(%{
        "hook_event_name" => "PostToolUse",
        "tool_name" => "Agent",
        "tool_use_id" => tool_use_id,
        "tool_response" => %{
          "isAsync" => true,
          "status" => "async_launched",
          "agentId" => agent_id
        }
      })

  # A workspace tool call as the kit's hook forwards it, naming the calling subagent.
  defp tool_call(agent_id, name, arguments, id \\ 3) do
    arguments =
      if agent_id, do: Map.put(arguments, ClaudeCode.agent_field(), agent_id), else: arguments

    mcp(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    })
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp stop_event(agent_id, final \\ "Done."),
    do: %{
      "hook_event_name" => "SubagentStop",
      "agent_id" => agent_id,
      "agent_type" => "eab-opus-5-5-xhigh",
      "agent_transcript_path" => "/home/user/.claude/x.jsonl",
      "last_assistant_message" => final
    }

  defp as_agent(entries, agent_id), do: Enum.map(entries, &Map.put(&1, "agentId", agent_id))

  defp await_waiting(id) do
    Enum.find_value(1..200, fn _ ->
      if id in Broker.status().waiting, do: true, else: Process.sleep(10)
    end) || flunk("attempt never registered")
  end

  defp start_attempt(prompt, opts \\ [], case_id \\ "case-x") do
    parent = self()

    Application.put_env(:eab, :claude_code_workspace, %{
      install: fn box -> send(parent, {:installed, box.name}) end,
      execute: fn box, name, arguments ->
        send(parent, {:tool, box.name, name, arguments})
        %{"content" => [%{"type" => "text", "text" => "ran #{name}"}], "isError" => false}
      end,
      patch: fn _box -> "diff --git a/x b/x\n" end
    })

    box = %{name: "eab-box-#{case_id}", id: case_id, run_id: "run-x", runtime: %{}}
    File.mkdir_p!(Store.path("runs/run-x"))

    Task.async(fn ->
      try do
        {:ok,
         ClaudeCode.Attempt.run(
           box,
           endpoint(),
           "",
           "runs/run-x/#{case_id}",
           prompt,
           &send(parent, {:progress, case_id, &1}),
           opts
         )}
      rescue
        error -> {:error, Exception.message(error)}
      end
    end)
  end

  test "one waiting attempt is claimed by the solver's Agent call and fed its tools and transcript" do
    prompt = "Frozen prompt\n"
    task = start_attempt(prompt)
    assert_receive {:installed, "eab-box-case-x"}
    await_waiting("case-x")
    assert_receive {:progress, "case-x", "Waiting for the Claude Code solver" <> _}

    denied = hook(agent_call("eab-haiku-5-5-max"))
    assert denied["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert denied["hookSpecificOutput"]["permissionDecisionReason"] =~ ~s("eab-opus-5-5-xhigh")

    drifted = hook(agent_call("eab-opus-5-5-xhigh"), %{})
    assert drifted["hookSpecificOutput"]["permissionDecisionReason"] =~ "does not match"

    nested = hook(Map.put(agent_call("eab-opus-5-5-xhigh"), "agent_id", "a"))
    assert nested["hookSpecificOutput"]["permissionDecision"] == "deny"

    anonymous = hook(Map.delete(agent_call("eab-opus-5-5-xhigh"), "tool_use_id"))
    assert anonymous["hookSpecificOutput"]["permissionDecisionReason"] =~ "no tool_use_id"
    assert Broker.status().waiting == ["case-x"]

    # Workspace calls before the claim, or without a solver identity, reach no workspace.
    assert tool_call("agent-1", "read", %{"path" => "x"})["isError"]
    assert tool_call(nil, "read", %{"path" => "x"})["isError"]

    allowed = hook(agent_call("eab-opus-5-5-xhigh"))["hookSpecificOutput"]
    assert allowed["permissionDecision"] == "allow"

    assert allowed["updatedInput"] == %{
             "subagent_type" => "eab-opus-5-5-xhigh",
             "description" => "Benchmark attempt",
             "prompt" => prompt,
             "run_in_background" => true
           }

    assert Broker.status().launching == ["case-x"]
    assert launched("toolu_1", "agent-1") == %{}
    assert Broker.status().active == [%{case: "case-x", agent_id: "agent-1"}]

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

    # The routing field never reaches the tool.
    assert tool_call("agent-1", "bash", %{"command" => "ls"}) == %{
             "content" => [%{"type" => "text", "text" => "ran bash"}],
             "isError" => false
           }

    assert_receive {:tool, "eab-box-case-x", "bash", %{"command" => "ls"}}
    assert File.read!(Store.path("runs/run-x/case-x/model.patch")) =~ "diff --git"
    assert tool_call("agent-1", "Bash", %{})["isError"]

    browser =
      build_conn()
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("origin", "https://evil.example")
      |> post(
        "/claude-code/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 5, "method" => "tools/list"})
      )

    assert browser.status == 403

    assert hook(stop_event("agent-1"), ClaudeCode.kit_files(@url), %{
             "transcript" => jsonl(transcript(prompt))
           }) == %{}

    assert {:ok, result} = Task.await(task)
    assert result["stop_reason"] == "agent_completed"
    assert result["generated_tokens"] == 60 and result["calls"] == 2
    assert result["claude_code"]["claude_code_version"] == "2.1.308"
    assert result["claude_code"]["tool_calls"] == 2
    assert result["claude_code"]["agent_id"] == "agent-1"
    refute Map.has_key?(result, "measurement")
    stored = File.read!(Store.path("runs/run-x/case-x/claude-transcript.jsonl"))
    refute stored =~ "timestamp"
    assert File.read!(Store.path("runs/run-x/case-x/harness-prompt.md")) == prompt
    assert ClaudeCode.Attempt.recorded_version("run-x") == "2.1.308"

    assert Broker.status() |> Map.take([:waiting, :launching, :active]) ==
             %{waiting: [], launching: [], active: []}

    assert File.read!(Store.path("runs/run-x/case-x/claude-tool-calls.jsonl")) =~
             ~s("name":"bash")

    log = File.read!(Store.path("runs/run-x/claude-code-hooks.jsonl"))

    for step <- ~w(registered claimed bound finished),
        do: assert(log =~ ~s("broker":"#{step}"))
  end

  test "parallel solvers each reach only their own workspace, whatever the order" do
    task_x = start_attempt("Prompt X\n", [], "case-x")
    task_y = start_attempt("Prompt Y\n", [], "case-y")
    await_waiting("case-x")
    await_waiting("case-y")

    # Workspaces go to Agent calls in registration order.
    first = hook(agent_call("eab-opus-5-5-xhigh", "toolu_1"))["hookSpecificOutput"]
    second = hook(agent_call("eab-opus-5-5-xhigh", "toolu_2"))["hookSpecificOutput"]
    assert first["updatedInput"]["prompt"] == "Prompt X\n"
    assert second["updatedInput"]["prompt"] == "Prompt Y\n"
    assert Broker.status().launching == ["case-x", "case-y"]

    # Launch reports may arrive in either order. A tool call that races ahead of its
    # subagent's report waits for it instead of failing.
    assert launched("toolu_2", "agent-B") == %{}
    early = Task.async(fn -> tool_call("agent-A", "read", %{"path" => "a.ex"}, 7) end)
    Process.sleep(50)
    refute_received {:tool, _, "read", _}
    assert launched("toolu_1", "agent-A") == %{}
    refute Task.await(early)["isError"]
    assert_receive {:tool, "eab-box-case-x", "read", %{"path" => "a.ex"}}

    assert Broker.status().active == [
             %{case: "case-x", agent_id: "agent-A"},
             %{case: "case-y", agent_id: "agent-B"}
           ]

    for {agent, box, command} <- [
          {"agent-B", "eab-box-case-y", "y1"},
          {"agent-A", "eab-box-case-x", "x1"},
          {"agent-B", "eab-box-case-y", "y2"},
          {"agent-A", "eab-box-case-x", "x2"}
        ] do
      refute tool_call(agent, "bash", %{"command" => command})["isError"]
      assert_receive {:tool, ^box, "bash", %{"command" => ^command}}
    end

    # Calls run concurrently: each worker serves its own solver at the same time.
    calls =
      for {agent, n} <- [{"agent-A", 1}, {"agent-B", 2}, {"agent-A", 3}, {"agent-B", 4}],
          do: Task.async(fn -> tool_call(agent, "bash", %{"command" => "c#{n}"}, 10 + n) end)

    assert Enum.all?(Task.await_many(calls), &(&1["isError"] == false))

    for {box, n} <- [
          {"eab-box-case-x", 1},
          {"eab-box-case-y", 2},
          {"eab-box-case-x", 3},
          {"eab-box-case-y", 4}
        ] do
      command = "c#{n}"
      assert_receive {:tool, ^box, "bash", %{"command" => ^command}}
    end

    assert tool_call("agent-Z", "bash", %{"command" => "z"})["isError"]
    refute_received {:tool, _, _, %{"command" => "z"}}

    # One solver finishing leaves the other bound to its workspace.
    hook(stop_event("agent-B"), ClaudeCode.kit_files(@url), %{
      "transcript" => jsonl(as_agent(transcript("Prompt Y\n"), "agent-B"))
    })

    assert {:ok, y} = Task.await(task_y)
    assert y["claude_code"]["agent_id"] == "agent-B"
    assert Broker.status().active == [%{case: "case-x", agent_id: "agent-A"}]
    assert tool_call("agent-B", "bash", %{"command" => "late"})["isError"]
    refute tool_call("agent-A", "bash", %{"command" => "still"})["isError"]
    assert_receive {:tool, "eab-box-case-x", "bash", %{"command" => "still"}}

    # A transcript from another solver fails the attempt instead of being graded as it.
    hook(stop_event("agent-A"), ClaudeCode.kit_files(@url), %{
      "transcript" => jsonl(as_agent(transcript("Prompt X\n"), "agent-B"))
    })

    assert {:error, message} = Task.await(task_x)
    assert message =~ "Solver identity mismatch"
  end

  test "busy solver slots send the session to wait; free slots wait for a workspace" do
    kit = %{"files" => ClaudeCode.kit_files(@url)}
    run = %{id: "run-x", parallel: 1}
    event = fn id -> agent_call("eab-opus-5-5-xhigh", id) end

    assert Broker.claim(event.("toolu_0"), kit, run, 0) == :waiting
    assert Broker.claim(event.("toolu_0"), kit, nil, 0) == :waiting

    task_x = start_attempt("Prompt X\n", [], "case-x")
    await_waiting("case-x")
    assert {:ok, %{case: "case-x"}} = Broker.claim(event.("toolu_1"), kit, run, 0)

    # A launching solver already fills the only slot.
    assert Broker.claim(event.("toolu_2"), kit, run, 0) == :busy
    launched("toolu_1", "agent-A")
    assert Broker.claim(event.("toolu_2"), kit, run, 0) == :busy

    # With room for two, the call waits until the next workspace registers.
    waiter =
      Task.async(fn -> Broker.claim(event.("toolu_3"), kit, %{run | parallel: 2}, 5_000) end)

    Process.sleep(50)
    task_y = start_attempt("Prompt Y\n", [], "case-y")
    assert {:ok, %{case: "case-y"}} = Task.await(waiter)
    launched("toolu_3", "agent-B")
    assert Broker.claim(event.("toolu_4"), kit, %{run | parallel: 2}, 0) == :busy

    # A solver that stopped frees its slot at once, before its transcript arrives: a fast
    # failure must not leave the session refused with no notification left to wait for.
    assert hook(stop_event("agent-B"), ClaudeCode.kit_files(@url), %{"stopping" => true}) ==
             %{}

    assert Broker.claim(event.("toolu_5"), kit, %{run | parallel: 2}, 0) == :waiting
    assert Broker.status().active |> Enum.map(& &1.case) == ["case-x", "case-y"]

    for {agent, task, prompt} <- [
          {"agent-A", task_x, "Prompt X\n"},
          {"agent-B", task_y, "Prompt Y\n"}
        ] do
      hook(stop_event(agent), ClaudeCode.kit_files(@url), %{
        "transcript" => jsonl(as_agent(transcript(prompt), agent))
      })

      assert {:ok, _} = Task.await(task)
    end

    log = File.read!(Store.path("runs/run-x/claude-code-hooks.jsonl"))
    assert log =~ ~s("decision":"busy")
    assert log =~ ~s("broker":"stopped")
  end

  test "a solver that ended without a stop event is recovered on the next Agent call" do
    task = start_attempt("Prompt X\n")
    await_waiting("case-x")
    hook(agent_call("eab-opus-5-5-xhigh", "toolu_1"))
    launched("toolu_1", "agent-A")
    kit = %{"files" => ClaudeCode.kit_files(@url)}
    run = %{id: "run-x", parallel: 1}
    assert Broker.claim(agent_call("eab-opus-5-5-xhigh", "toolu_2"), kit, run, 0) == :busy

    # An API error ended the solver: Claude Code marks it finished but sends no
    # SubagentStop. The session's next Agent call reports it.
    finished = [
      %{
        "agent_id" => "agent-A",
        "agent_type" => "eab-opus-5-5-xhigh",
        "agent_transcript_path" => "/home/user/.claude/s/subagents/agent-agent-A.jsonl"
      },
      %{"agent_id" => "agent-unknown", "agent_type" => "eab-opus-5-5-xhigh"}
    ]

    assert hook(agent_call("eab-opus-5-5-xhigh", "toolu_3"), ClaudeCode.kit_files(@url), %{
             "recover" => finished
           }) == %{"eab_upload" => [hd(finished)]}

    assert Broker.claim(agent_call("eab-opus-5-5-xhigh", "toolu_4"), kit, run, 0) == :waiting

    # Reported again, it is not recovered twice.
    assert hook(agent_call("eab-opus-5-5-xhigh", "toolu_5"), ClaudeCode.kit_files(@url), %{
             "recover" => finished
           }) == %{"eab_upload" => []}

    # The hook uploads its transcript like a stop. It holds no model response at all, and
    # the attempt fails naming the API error rather than an unreadable model.
    error =
      entry("assistant", %{
        "isApiErrorMessage" => true,
        "error" => "invalid_request",
        "message" => %{
          "id" => "s",
          "model" => "<synthetic>",
          "content" => [
            %{"type" => "text", "text" => "API Error: safeguards flagged this session"}
          ]
        }
      })

    recovered = %{
      "hook_event_name" => "SubagentStop",
      "agent_id" => "agent-A",
      "agent_type" => "eab-opus-5-5-xhigh",
      "recovered" => true
    }

    only_error = [hd(transcript("Prompt X\n")), error]

    hook(recovered, ClaudeCode.kit_files(@url), %{
      "transcript" => jsonl(as_agent(only_error, "agent-A"))
    })

    assert {:error, message} = Task.await(task)
    assert message =~ "safeguards"
    assert Broker.status().active == []
    log = File.read!(Store.path("runs/run-x/claude-code-hooks.jsonl"))
    assert log =~ "stop not reported; recovered from the session"
  end

  test "a launch Claude Code never reports is offered to the next Agent call" do
    Application.put_env(:eab, :claude_code_launch_timeout_ms, 100)
    Application.put_env(:eab, :claude_code_bind_wait_ms, 200)
    task = start_attempt("Prompt X\n")
    await_waiting("case-x")

    assert hook(agent_call("eab-opus-5-5-xhigh", "toolu_1"))["hookSpecificOutput"][
             "permissionDecision"
           ] == "allow"

    # An unbound solver's tool calls wait briefly, then fail without touching the workspace.
    assert tool_call("agent-ghost", "bash", %{"command" => "ghost"})["isError"]
    refute_received {:tool, _, _, %{"command" => "ghost"}}

    await_waiting("case-x")
    assert_receive {:progress, "case-x", "Waiting for the Claude Code solver (/solve-run)"}, 1000

    # A failed launch report requeues at once.
    assert hook(agent_call("eab-opus-5-5-xhigh", "toolu_2"))["hookSpecificOutput"][
             "permissionDecision"
           ] == "allow"

    hook(%{
      "hook_event_name" => "PostToolUse",
      "tool_name" => "Agent",
      "tool_use_id" => "toolu_2",
      "tool_response" => %{"status" => "error"}
    })

    assert Broker.status().waiting == ["case-x"]

    # The next launch binds normally; a late report for an abandoned call changes nothing.
    hook(agent_call("eab-opus-5-5-xhigh", "toolu_3"))
    launched("toolu_3", "agent-A")
    assert launched("toolu_1", "agent-ghost") == %{}
    assert Broker.status().active == [%{case: "case-x", agent_id: "agent-A"}]

    hook(stop_event("agent-A"), ClaudeCode.kit_files(@url), %{
      "transcript" => jsonl(as_agent(transcript("Prompt X\n"), "agent-A"))
    })

    assert {:ok, _} = Task.await(task)
    log = File.read!(Store.path("runs/run-x/claude-code-hooks.jsonl"))
    assert log =~ "launch timed out" and log =~ "launch not reported"
  end

  test "a usage-limit stop is an evaluation error and pauses further attempts" do
    prompt = "Frozen prompt\n"
    task = start_attempt(prompt)
    await_waiting("case-x")
    hook(agent_call("eab-opus-5-5-xhigh"))
    launched("toolu_1", "agent-1")

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

    stop = Map.delete(stop_event("agent-1"), "last_assistant_message")
    hook(stop, ClaudeCode.kit_files(@url), %{"transcript" => jsonl(transcript(prompt, limit))})
    assert {:error, message} = Task.await(task)
    assert message =~ "usage limit"
    assert Broker.status().pause =~ "usage limit"

    # The next case waits; the solver is told to stop until the user releases the pause.
    task = start_attempt(prompt)
    await_waiting("case-x")
    denied = hook(agent_call("eab-opus-5-5-xhigh", "toolu_2"))["hookSpecificOutput"]

    assert denied["permissionDecision"] == "deny" and
             denied["permissionDecisionReason"] =~ "Stop now"

    Broker.release_pause()

    assert hook(agent_call("eab-opus-5-5-xhigh", "toolu_3"))["hookSpecificOutput"][
             "permissionDecision"
           ] == "allow"

    launched("toolu_3", "agent-1")

    # A different Claude Code version within one run is an evaluation error.
    other = Enum.map(transcript(prompt), &Map.put(&1, "version", "2.2.0"))
    hook(stop, ClaudeCode.kit_files(@url), %{"transcript" => jsonl(other)})
    assert {:error, changed} = Task.await(task)
    assert changed =~ "Claude Code changed from 2.1.308 to 2.2.0"
  end

  test "a usage limit on the solver's first request still pauses further attempts" do
    task = start_attempt("Prompt X\n")
    await_waiting("case-x")
    hook(agent_call("eab-opus-5-5-xhigh"))
    launched("toolu_1", "agent-1")

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

    hook(
      Map.delete(stop_event("agent-1"), "last_assistant_message"),
      ClaudeCode.kit_files(@url),
      %{
        "transcript" => jsonl([hd(transcript("Prompt X\n")), limit])
      }
    )

    assert {:error, message} = Task.await(task)
    assert message =~ "hit your limit"
    assert Broker.status().pause =~ "usage limit"
  end

  test "an escape-test attempt returns the automatic verdict with its record" do
    prompt = ClaudeCode.escape_prompt()
    task = start_attempt(prompt, escape_test: true)
    await_waiting("case-x")

    assert hook(agent_call("eab-opus-5-5-xhigh"))["hookSpecificOutput"]["updatedInput"]["prompt"] ==
             prompt

    launched("toolu_1", "agent-1")

    hook(stop_event("agent-1"), ClaudeCode.kit_files(@url), %{
      "transcript" => jsonl(transcript(prompt))
    })

    assert {:ok, result} = Task.await(task)
    assert result["escape_test"]["passed"]
    assert result["escape_test"]["tools_used"] == %{"x" => 1}
  end

  test "a failed desktop attempt still records its Claude Code version and models" do
    prompt = "Frozen prompt\n"
    task = start_attempt(prompt)
    await_waiting("case-x")
    hook(agent_call("eab-opus-5-5-xhigh"))
    launched("toolu_1", "agent-1")

    fallback = desktop(prompt, safety: true, model: "claude-opus-4-8")

    hook(stop_event("agent-1", "Final report."), ClaudeCode.kit_files(@url), %{
      "transcript" => jsonl(fallback)
    })

    assert {:error, message} = Task.await(task)
    assert message =~ "safety fallback switched the solver"
    progress = Store.read("runs/run-x/case-x/agent-progress.json")
    assert progress["claude_code"]["claude_code_version"] == "2.1.308"
    assert progress["claude_code"]["resolved_models"] == ["claude-opus-4-8"]
    assert ClaudeCode.Attempt.recorded_version("run-x") == "2.1.308"

    # The error record the runner saves keeps them.
    record = Eab.Agent.error("case-x", "run-x", message, "")
    assert record["claude_code"]["claude_code_version"] == "2.1.308"
  end

  test "without a waiting workspace the solver is told to wait or stop" do
    denied = hook(agent_call("eab-opus-5-5-xhigh"))["hookSpecificOutput"]
    assert denied["permissionDecision"] == "deny"
    assert denied["permissionDecisionReason"] =~ "No Claude Code run is active"
    assert hook(%{"hook_event_name" => "SubagentStop", "agent_type" => "x"}) == %{}
    assert hook(%{"hook_event_name" => "PostToolUse", "tool_use_id" => "nothing"}) == %{}
  end
end
