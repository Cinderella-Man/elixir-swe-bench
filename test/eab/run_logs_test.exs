defmodule Eab.RunLogsTest do
  use ExUnit.Case, async: true
  alias Eab.{Inventory, RunLogs, Store}

  setup do
    id = "run-logs-#{System.unique_integer([:positive])}"
    home = Path.join(System.tmp_dir!(), "eab-#{id}/verification")
    File.mkdir_p!(home)

    on_exit(fn ->
      File.rm_rf!(Path.dirname(home))
      File.rm_rf!(Store.path("runs/#{id}"))
    end)

    {:ok, id: id, root: Path.join(home, "runs")}
  end

  defp grade(passed) do
    %{
      "passed" => passed,
      "hidden" => %{
        "passed" => passed,
        "test_results" => %{"a" => "passed", "b" => if(passed, do: "passed", else: "failed")}
      },
      "regression" => %{"passed" => true, "test_results" => %{"c" => "passed", "d" => "excluded"}},
      "submission" => %{"passed" => true, "test_results" => %{}},
      "regression_coverage" => %{"passed" => true},
      "submitted_test_files" => ["test/a_test.exs"]
    }
  end

  defp pi_run(id) do
    run = %{
      "id" => id,
      "created_at" => "2026-11-18T00:00:00Z",
      "status" => "completed",
      "cases" => ["case-a", "case-b"],
      "release_id" => String.duplicate("a", 64),
      "code_versions" => [String.duplicate("c", 64)],
      "harness" => %{"name" => "pi", "package" => "pi-agent", "version" => "1.2.0"},
      "settings" => %{"seed" => 101, "window_tokens" => 262_144},
      "protocol" => %{
        "inventory" => %{"id" => "benchmark-test", "cases" => ["case-a", "case-b"]},
        "fixtures" => %{"case-a" => %{"case.json" => "f1"}, "case-b" => %{"case.json" => "f2"}}
      },
      "model" => %{
        "backend" => "llama_cpp",
        "model" => "alias",
        "context" => 262_144,
        "url" => "http://modelrig.tail0a1b2c.ts.net:8460",
        "identity" => %{"name" => "Fixture", "artifact" => "/srv/models/Fixture-Q4_K_M.gguf"},
        "metadata" => %{"props" => %{"model_path" => "/srv/models/Fixture-Q4_K_M.gguf"}}
      },
      "memory" => %{
        "sessions" => [
          %{"identity" => %{"host" => "rigBIGIRON", "service" => "llm@fixture.service"}}
        ]
      },
      "attempts" => %{
        "case-a" => %{
          "status" => "completed",
          "grade" => %{"passed" => true},
          "calls" => 2,
          "generated_tokens" => 126,
          "stop_reason" => "agent_completed"
        },
        "case-b" => %{
          "status" => "completed",
          "grade" => %{"passed" => false},
          "calls" => 1,
          "generated_tokens" => 9,
          "stop_reason" => "context_budget"
        }
      }
    }

    Store.write("runs/#{id}/run.json", run)

    for {case_id, passed, calls} <- [
          {"case-a", true, [{2070, 86}, {9000, 40}]},
          {"case-b", false, [{500, 9}]}
        ] do
      prefix = "runs/#{id}/#{case_id}"

      Store.write_text(
        "#{prefix}/activity.log",
        "Preparing #{case_id}\ncurl rigbigiron:8460\nssh root@RIGBIGIRON\nthe rigbigiron is fast\n"
      )

      Store.write_text("#{prefix}/pi-events.jsonl", ~s({"type":"session"}\n))
      Store.write_text("#{prefix}/instructions.md", "Fix #{case_id}.\n")
      Store.write_text("#{prefix}/model.patch", "diff --git a/#{case_id} b/#{case_id}\n")
      Store.write("#{prefix}/grade.json", grade(passed))
      # Never kept: the controller's copy of a request, and each call's timing.
      Store.write("#{prefix}/request-0000.json", %{"messages" => []})

      for {{input, output}, n} <- Enum.with_index(calls) do
        step = n |> Integer.to_string() |> String.pad_leading(4, "0")

        Store.write("#{prefix}/usage-#{step}.json", %{
          "input_tokens" => input,
          "output_tokens" => output,
          "speed" => %{"generation_ms" => 1234}
        })
      end
    end

    run
  end

  defp files(folder) do
    folder
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, folder))
    |> Enum.sort()
  end

  test "a Pi run's logs are saved in one folder with a manifest", %{id: id, root: root} do
    run = pi_run(id)
    refute RunLogs.saved?(id, root: root)
    saved = RunLogs.save!(run, root: root)
    folder = Path.join(root, "run-#{id}")
    assert saved["path"] == folder and RunLogs.saved?(id, root: root)

    per_case =
      ~w(grade-summary.json instructions.md logs/activity.log logs/grade.json logs/pi-events.jsonl model.patch)

    assert files(folder) ==
             Enum.sort(
               ~w(calls.json manifest.json run-summary.json) ++
                 for(c <- ~w(case-a case-b), f <- per_case, do: "#{c}/#{f}")
             )

    assert saved["files"] == length(files(folder))

    # Every call's prompt and output tokens, in order, and nothing of its timing.
    calls = File.read!(Path.join(folder, "calls.json"))

    assert Jason.decode!(calls) == %{
             "run_id" => id,
             "fields" => ["prompt_tokens", "output_tokens"],
             "cases" => %{"case-a" => [[2070, 86], [9000, 40]], "case-b" => [[500, 9]]}
           }

    assert calls =~ ~s(    "case-a": [[2070,86],[9000,40]],\n)
    refute calls =~ "generation_ms"

    summary = Jason.decode!(File.read!(Path.join(folder, "case-b/grade-summary.json")))
    patch = File.read!(Path.join(folder, "case-b/model.patch"))

    assert %{
             "case" => "case-b",
             "status" => "completed",
             "passed" => false,
             "stop_reason" => "context_budget",
             "model_calls" => 1,
             "generated_tokens" => 9,
             "peak_context_tokens" => 509,
             "hidden" => %{"passed" => false, "tests" => 2, "failed" => ["b"]},
             "regression" => %{"passed" => true, "tests" => 2, "failed" => []},
             "regression_coverage" => true,
             "submitted_test_files" => ["test/a_test.exs"],
             "agent" => "pi-agent",
             "agent_version" => "1.2.0"
           } = summary

    assert summary["model_patch_sha256"] == Inventory.hash(patch)

    # What was run, so a later reader can tell the release, the case files and the model.
    about = Jason.decode!(File.read!(Path.join(folder, "run-summary.json")))
    assert about["benchmark"] == "benchmark-test" and about["cases"] == ["case-a", "case-b"]
    assert about["case_fixtures"]["case-a"] == %{"case.json" => "f1"}
    assert about["settings"]["seed"] == 101

    assert about["model"]["identity"] == %{
             "name" => "Fixture",
             "artifact" => "Fixture-Q4_K_M.gguf"
           }

    # The manifest lists every other file with its size and hash.
    manifest = Jason.decode!(File.read!(Path.join(folder, "manifest.json")))
    assert Map.keys(manifest["files"]) |> Enum.sort() == files(folder) -- ["manifest.json"]

    for {relative, %{"bytes" => bytes, "sha256" => hash}} <- manifest["files"] do
      body = File.read!(Path.join(folder, relative))
      assert byte_size(body) == bytes and Inventory.hash(body) == hash
    end
  end

  test "the machine that served the model is not named", %{id: id, root: root} do
    saved = RunLogs.save!(pi_run(id), root: root)
    folder = saved["path"]
    everything = folder |> files() |> Enum.map_join(&File.read!(Path.join(folder, &1)))

    for name <- ~w(modelrig tail0a1b2c rigBIGIRON RIGBIGIRON llm@fixture /srv/models),
        do: refute(everything =~ name)

    # A bare name is replaced where it is written as an address, whatever its case. Elsewhere
    # it could be any word, and stays.
    log = File.read!(Path.join(folder, "case-a/logs/activity.log"))

    assert log ==
             "Preparing case-a\ncurl [redacted host]:8460\nssh root@[redacted host]\nthe rigbigiron is fast\n"

    assert saved["replacements"] == 4
  end

  test "a Claude Code run keeps its transcripts without the account's identifiers",
       %{id: id, root: root} do
    organization = "0f3a9c1e-1111-2222-3333-444455556666"

    lines =
      [
        %{"type" => "system", "organizationUuid" => organization},
        %{
          "type" => "user",
          "message" => %{"content" => "The user's email address is someone@example.org."}
        },
        %{
          "type" => "assistant",
          "message" => %{
            "id" => "m1",
            "usage" => %{
              "input_tokens" => 3,
              "cache_read_input_tokens" => 1000,
              "output_tokens" => 40
            }
          }
        }
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)

    run = %{
      "id" => id,
      "status" => "completed",
      "cases" => ["case-a"],
      "harness" => %{"name" => "claude_code", "agent" => "eab-solver", "kit_sha256" => "k1"},
      # Not a machine: the word after the scheme must stay readable in the logs.
      "model" => %{
        "model" => "haiku",
        "backend" => "claude_code",
        "url" => "claude-code://subscription"
      },
      "attempts" => %{
        "case-a" => %{
          "status" => "completed",
          "grade" => %{"passed" => true},
          "calls" => 1,
          "generated_tokens" => 40,
          "stop_reason" => "agent_completed",
          "claude_code" => %{
            "resolved_models" => ["claude-haiku-5-5"],
            "claude_code_version" => "2.1.321",
            "agent_id" => "agent-1",
            "compactions" => 0
          }
        }
      }
    }

    Store.write("runs/#{id}/run.json", run)
    Store.write_text("runs/#{id}/claude-code-hooks.jsonl", ~s({"org":"#{organization}"}\n))
    Store.write_text("runs/#{id}/case-a/claude-transcript.jsonl", lines <> "\n")

    Store.write_text(
      "runs/#{id}/case-a/activity.log",
      "signed in as someone@example.org with a subscription\n"
    )

    Store.write("runs/#{id}/case-a/grade.json", grade(true))

    saved = RunLogs.save!(run, root: root)
    folder = saved["path"]

    assert files(folder) ==
             ~w(calls.json case-a/grade-summary.json case-a/logs/activity.log
                case-a/logs/claude-transcript.jsonl case-a/logs/grade.json
                claude-code-hooks.jsonl manifest.json run-summary.json)

    everything = folder |> files() |> Enum.map_join(&File.read!(Path.join(folder, &1)))
    refute everything =~ organization
    refute everything =~ "someone@example.org"
    assert saved["replacements"] == 4

    transcript = File.read!(Path.join(folder, "case-a/logs/claude-transcript.jsonl"))
    assert transcript =~ ~s("organizationUuid":"[redacted organization]")
    assert transcript =~ "email address is [redacted email]."

    assert File.read!(Path.join(folder, "case-a/logs/activity.log")) ==
             "signed in as [redacted email] with a subscription\n"

    assert Jason.decode!(File.read!(Path.join(folder, "calls.json")))["cases"] == %{
             "case-a" => [[1003, 40]]
           }

    assert %{
             "model" => "claude-haiku-5-5",
             "agent" => "eab-solver",
             "kit_sha256" => "k1",
             "claude_code_version" => "2.1.321",
             "solver_agent_id" => "agent-1",
             "compactions" => 0,
             "peak_context_tokens" => 1043
           } = Jason.decode!(File.read!(Path.join(folder, "case-a/grade-summary.json")))
  end

  test "a copied folder is checked against its manifest", %{id: id, root: root} do
    assert RunLogs.check(id, root: root) == {:error, ["manifest.json: missing"]}
    folder = RunLogs.save!(pi_run(id), root: root)["path"]
    assert RunLogs.check(id, root: root) == :ok

    File.write!(Path.join(folder, "case-a/logs/activity.log"), "cut short")
    File.rm!(Path.join(folder, "case-b/model.patch"))
    File.write!(Path.join(folder, "case-b/extra.txt"), "added on the way")

    assert RunLogs.check(id, root: root) ==
             {:error,
              [
                "case-a/logs/activity.log: changed",
                "case-b/extra.txt: not in the manifest",
                "case-b/model.patch: missing"
              ]}
  end

  test "saving again replaces the folder, and leaves nothing half written", %{id: id, root: root} do
    run = pi_run(id)
    folder = RunLogs.save!(run, root: root)["path"]
    File.write!(Path.join(folder, "stray.txt"), "left from before")
    Store.write_text("runs/#{id}/case-a/activity.log", "a later log\n")

    assert RunLogs.save!(run, root: root)["path"] == folder
    refute File.exists?(Path.join(folder, "stray.txt"))
    assert File.read!(Path.join(folder, "case-a/logs/activity.log")) == "a later log\n"
    assert File.ls!(root) == ["run-#{id}"]
  end

  test "a missing logs folder or run is an error, not a silent loss", %{id: id, root: root} do
    run = pi_run(id)
    File.rmdir!(Path.dirname(root))
    assert {:error, message} = RunLogs.save(run, root: root)
    assert message =~ "does not exist"
    refute File.exists?(root)

    File.mkdir_p!(Path.dirname(root))

    assert {:error, "The files of run" <> _} =
             RunLogs.save(%{run | "id" => "#{id}-gone"}, root: root)

    assert {:error, "Expected a run"} = RunLogs.save(%{"id" => "../x", "cases" => []}, root: root)
    assert File.ls(root) in [{:ok, []}, {:error, :enoent}]
  end
end
