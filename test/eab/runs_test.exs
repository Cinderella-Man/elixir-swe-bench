defmodule Eab.RunsTest do
  use ExUnit.Case, async: false
  alias Eab.{Runs, Store}

  setup do
    keys = [:data_dir, :runner, :cleanup, :memory_monitor]
    old = Map.new(keys, &{&1, Application.get_env(:eab, &1)})
    Supervisor.terminate_child(Eab.Supervisor, Runs)
    root = Path.join(System.tmp_dir!(), "eab-run-test-#{System.unique_integer([:positive])}")
    Application.put_env(:eab, :data_dir, root)
    Application.put_env(:eab, :cleanup, fn _ -> :ok end)
    Supervisor.restart_child(Eab.Supervisor, Runs)

    on_exit(fn ->
      Runs.subscribe()
      Runs.stop()
      await_cleanup()
      Supervisor.terminate_child(Eab.Supervisor, Runs)

      for {k, v} <- old do
        if v == nil, do: Application.delete_env(:eab, k), else: Application.put_env(:eab, k, v)
      end

      Supervisor.restart_child(Eab.Supervisor, Runs)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "memory collection starts before work and finalizes on completion, error and cancellation" do
    parent = self()
    Runs.subscribe()

    Application.put_env(:eab, :memory_monitor,
      hosts: ["fixture"],
      target: "fixture",
      collector: "fixture",
      known_hosts: "fixture",
      executable: "/opt/pi/node",
      args: ["test/support/memory_collector.mjs", "normal"]
    )

    endpoint = %{
      "url" => "http://fixture:8414",
      "backend" => "strata",
      "model" => "fixture",
      "context" => 262_144,
      "profile" => %{"model_path" => "/models/fixture-Q4_K_M.gguf"}
    }

    Application.put_env(:eab, :runner, fn run, _, _ ->
      send(parent, {:started, self(), run})

      receive do
        {:finish, result} -> result
      end
    end)

    for {status, result} <- [
          {"completed", :ok},
          {"error", {:error, "fixture error"}},
          {"cancelled", :stop}
        ] do
      {:ok, id} = Runs.start(endpoint, "", %{})
      assert_receive {:started, worker, run}, 3000
      assert run["memory"]["sample_count"] == 1
      if result == :stop, do: Runs.stop(), else: send(worker, {:finish, result})
      await_terminal(id)
      await_cleanup()
      saved = Store.run(id)
      assert saved["status"] == status
      assert saved["memory"]["status"] == "complete"
      assert saved["memory"]["sample_count"] == 2
      assert File.read!(Store.path("runs/#{id}/report.md")) =~ "Sampled model-service memory"
    end

    config = Application.get_env(:eab, :memory_monitor)

    Application.put_env(
      :eab,
      :memory_monitor,
      Keyword.put(config, :args, ["test/support/memory_collector.mjs", "startup_error"])
    )

    assert {:error, message} = Runs.start(endpoint, "", %{})
    assert message =~ "Memory collection could not start"
    refute_receive {:started, _, _}
    assert Runs.snapshot().active == nil
  end

  defp endpoint, do: %{"model" => "fixture", "context" => 32768}

  test "error retries are fresh, bounded to errors, preserve the source and have no full score" do
    parent = self()
    Runs.subscribe()
    {source, [passed, _failed, error_a, error_b | _]} = partial_source()
    settings = source["settings"]

    original = source_files()

    Application.put_env(:eab, :runner, fn run, _, _ ->
      send(parent, {:retry, run, Eab.Checkpoints.plan(run)})

      receive do
        :finish -> :ok
      end
    end)

    assert {:ok, id} = Runs.retry_errors("source", "")
    assert id != "source"
    assert_receive {:retry, run, plan}, 3000
    assert run["cases"] == [error_a, error_b]
    assert plan.restart == [error_a, error_b]
    assert plan.retained == %{} and plan.submissions == %{}
    assert run["settings"] == settings and run["model"] == endpoint()
    assert run["selection"]["source_run"] == "source"
    assert run["experiment_id"] != source["experiment_id"]
    assert :ok = Eab.Checkpoints.validate_run!(run, endpoint(), settings)

    for changed <- [
          Map.put(run, "cases", [passed]),
          put_in(run, ["selection", "source_run"], "changed")
        ] do
      assert_raise RuntimeError, fn ->
        Eab.Checkpoints.validate_run!(changed, endpoint(), settings)
      end
    end

    assert {:error, _} = Runs.retry_errors("source", "")
    assert {:error, _} = Runs.start(endpoint(), "", %{})
    assert source_files() == original

    complete =
      Map.merge(run, %{
        "status" => "completed",
        "attempts" =>
          Map.new(run["cases"], &{&1, %{"status" => "completed", "grade" => %{"passed" => true}}})
      })

    assert Eab.Runner.score(complete)["passed"] == 2
    assert Eab.Runner.score(complete)["score_percent"] == nil
    Eab.Report.write(complete)
    assert File.read!(Store.path("runs/#{id}/report.md")) =~ "Unavailable: partial run"
    Runs.stop()
    await_cleanup()

    for case_id <- [error_a, error_b],
        do: Store.write("runs/source/#{case_id}/attempt.json", %{"status" => "interrupted"})

    assert {:error, message} = Runs.retry_errors("source", "")
    assert message =~ "No evaluation errors"
  end

  test "explicit repeats run only selected completed cases from scratch and retain every prior outcome" do
    parent = self()
    Runs.subscribe()
    {source, [passed, failed | _]} = partial_source()
    source = Map.put(source, "status", "completed")
    Store.write("runs/source/run.json", source)
    Store.index_run(source)
    original = source_files()

    Application.put_env(:eab, :runner, fn run, _, _ ->
      send(parent, {:repeat, run, Eab.Checkpoints.plan(run)})

      receive do
        :finish -> :ok
      end
    end)

    for cases <- [[], [passed, passed], ["unknown"], nil] do
      assert {:error, message} = Runs.repeat_cases("source", cases, "")
      assert message =~ "Choose distinct cases"
    end

    assert {:ok, id} = Runs.repeat_cases("source", [failed, passed], "")
    assert_receive {:repeat, run, plan}, 3000
    assert run["cases"] == [passed, failed]
    assert plan.restart == [passed, failed]
    assert plan.retained == %{} and plan.submissions == %{}
    assert run["selection"]["kind"] == "case_repeat"

    assert run["selection"]["source_run_hash"] ==
             Eab.Inventory.hash_file(Store.path("runs/source/run.json"))

    assert run["model"] == source["model"] and run["settings"] == source["settings"]
    assert :ok = Eab.Checkpoints.validate_run!(run, endpoint(), source["settings"])
    assert {:error, _} = Runs.repeat_cases("source", [passed], "")
    assert source_files() == original

    Eab.Report.write(run)
    assert File.read!(Store.path("runs/#{id}/report.md")) =~ "Selected-case repeat of source"
    Runs.stop()
    await_cleanup()
    assert source_files() == original
    assert {:ok, ^id} = Runs.resume(id, endpoint(), "", source["settings"])
    assert_receive {:repeat, resumed, resumed_plan}, 3000
    assert resumed["cases"] == [passed, failed]
    assert resumed_plan.restart == [passed, failed]
    assert source_files() == original
  end

  defp partial_source do
    release = Eab.Release.freeze()
    cases = release["protocol"]["inventory"]["cases"]
    [passed, failed, error_a, error_b | _] = cases
    settings = Eab.Model.settings(endpoint())

    source = %{
      "id" => "source",
      "created_at" => "2026-01-01",
      "status" => "error",
      "cleanup_pending" => false,
      "model" => endpoint(),
      "settings" => settings,
      "cases" => cases,
      "protocol" => release["protocol"],
      "release_id" => release["id"],
      "experiment_id" => Eab.Release.experiment(release["id"], endpoint(), settings),
      "attempts" => %{}
    }

    Store.write("runs/source/run.json", source)
    Store.index_run(source)

    for id <- [passed, failed] do
      Store.write("runs/source/#{id}/runtime.json", %{"image" => "synthetic", "services" => %{}})
      {record, _} = Eab.Checkpoints.submit("source", id, %{"case" => id}, "original patch", "")
      grade = Eab.Evidence.save("source", id, %{"passed" => id == passed}, "")

      Eab.Checkpoints.complete(
        "source",
        id,
        Map.merge(record, %{"status" => "completed", "grade" => grade}),
        ""
      )
    end

    for id <- [error_a, error_b] do
      Store.write("runs/source/#{id}/attempt.json", %{
        "status" => "error",
        "error" => "server_is_overloaded"
      })

      Store.write_text("runs/source/#{id}/model.patch", "original partial patch")
    end

    {source, cases}
  end

  defp source_files do
    Store.path("runs/source/**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{&1, File.read!(&1)})
  end

  test "concurrent starts admit one run; cancellation preserves history and stops the worker" do
    parent = self()

    Application.put_env(:eab, :runner, fn run, _, _ ->
      id = hd(run["cases"])
      Store.write("runs/#{run["id"]}/#{id}/attempt.json", %{"status" => "running", "case" => id})
      Store.write_text("runs/#{run["id"]}/#{id}/model.patch", "saved work")
      send(parent, {:worker, self()})

      receive do
        :finish -> :ok
      end
    end)

    replies = for _ <- 1..2, do: Task.async(fn -> Runs.start(endpoint(), "", %{}) end)
    replies = Enum.map(replies, &Task.await/1)
    assert Enum.count(replies, &match?({:ok, _}, &1)) == 1
    assert Enum.count(replies, &match?({:error, _}, &1)) == 1
    assert_receive {:worker, worker}
    ref = Process.monitor(worker)
    assert :ok = Runs.stop()
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    [saved] = Store.runs()
    assert saved["status"] == "cancelled"
    assert saved["score"]["score_percent"] == nil
    report = File.read!(Store.path("runs/#{saved["id"]}/report.md"))
    assert report =~ "Status: cancelled"
    assert report =~ "Unavailable: run incomplete or contains errors"
    id = hd(saved["cases"])
    assert saved["attempts"][id]["status"] == "cancelled"
    assert Store.read("runs/#{saved["id"]}/#{id}/attempt.json")["status"] == "cancelled"
    assert File.read!(Store.path("runs/#{saved["id"]}/#{id}/model.patch")) == "saved work"
  end

  test "restart marks persisted active work interrupted without resuming" do
    Store.write("runs/old/run.json", %{
      "id" => "old",
      "created_at" => "2026-01-01",
      "status" => "running",
      "phase" => "running",
      "cases" => ["a"],
      "attempts" => %{}
    })

    Store.write("runs/old/a/attempt.json", %{"status" => "running", "case" => "a"})

    Supervisor.terminate_child(Eab.Supervisor, Runs)
    Supervisor.restart_child(Eab.Supervisor, Runs)
    assert Store.read("runs/old/run.json")["status"] == "interrupted"
    assert Store.read("runs/old/a/attempt.json")["status"] == "interrupted"
    assert Store.read("runs/old/run.json")["attempts"]["a"]["status"] == "interrupted"
    assert Runs.snapshot().active == nil
  end

  test "restart recovers orphan leases without overwriting corrupt run evidence" do
    parent = self()
    Runs.subscribe()
    Application.put_env(:eab, :cleanup, fn id -> send(parent, {:cleaned, id}) end)
    Eab.Retention.lease("orphan")
    Eab.Retention.lease("damaged")
    Store.write_text("runs/damaged/run.json", "corrupt original")
    Supervisor.terminate_child(Eab.Supervisor, Runs)
    Supervisor.restart_child(Eab.Supervisor, Runs)
    assert_receive {:cleaned, "orphan"}, 3000
    assert_receive {:cleaned, "damaged"}, 3000
    await_cleanup()
    assert Eab.Retention.leased_runs() == []
    assert File.read!(Store.path("runs/damaged/run.json")) == "corrupt original"
    refute File.exists?(Store.path("runs/orphan/run.json"))
  end

  test "Claude Code validation runs record their harness and are never publishable" do
    parent = self()
    Runs.subscribe()

    Application.put_env(:eab, :runner, fn run, _, _ ->
      send(parent, {:started, run})

      # The first attempt's Claude Code version becomes the run's.
      if run["harness"]["name"] == "claude_code",
        do: File.write!(Store.path("runs/#{run["id"]}/claude-code-version.txt"), "2.1.308")

      :ok
    end)

    endpoint = Eab.ClaudeCode.endpoint("claude-opus-5-5")
    assert {:ok, id} = Runs.start(endpoint, "", %{}, validation: true)
    assert_receive {:started, run}, 3000
    assert run["validation"] == true
    assert run["harness"]["name"] == "claude_code"
    assert run["harness"]["agent"] == "eab-opus-5-5-xhigh"
    assert run["settings"]["budget_policy"] == "declared_not_enforced"
    assert run["code_versions"] == [run["protocol"]["implementation"]]
    await_terminal(id)
    await_cleanup()
    saved = Store.run(id)
    assert saved["harness"]["claude_code_version"] == "2.1.308"
    assert File.read!(Store.path("runs/#{id}/report.md")) =~ "never published or scored"

    assert_raise ArgumentError, ~r/never published/, fn ->
      Eab.Results.export!(Map.put(saved, "status", "completed"))
    end

    assert {:ok, pi} = Runs.start(endpoint(), "", %{})
    assert_receive {:started, run}, 3000
    assert run["harness"]["name"] == "pi" and is_nil(run["validation"])
    await_terminal(pi)
  end

  test "worker errors are saved without the API credential" do
    Application.put_env(:eab, :runner, fn _, _, _ -> raise "echoed secret-key" end)
    Runs.subscribe()
    assert {:ok, id} = Runs.start(endpoint(), "secret-key", %{})
    await_terminal(id)
    run = Store.read("runs/#{id}/run.json")
    assert run["status"] == "error"
    refute Jason.encode!(run) =~ "secret-key"
    assert run["message"] =~ "[REDACTED]"
    refute File.read!(Store.path("runs/#{id}/report.md")) =~ "secret-key"
  end

  test "background progress cannot replace active Pi or regress a case phase" do
    parent = self()

    Application.put_env(:eab, :runner, fn _, _, _ ->
      send(parent, {:worker, self()})

      receive do
        :finish -> :ok
      end
    end)

    assert {:ok, id} = Runs.start(endpoint(), "", %{})
    assert_receive {:worker, _}
    [a, b, c | _] = Runs.snapshot().active["cases"]

    progress = fn case_id, phase, message ->
      send(
        Runs,
        {:progress, id,
         %{"case_phase" => %{"case" => case_id, "phase" => phase, "message" => message}}}
      )
    end

    progress.(a, "running", "Pi editing")
    progress.(b, "qualifying", "Checking next case")
    progress.(c, "preparing", "Building later case")
    run = Runs.snapshot().active
    assert run["current_case"] == a
    assert run["message"] == "Pi editing"
    assert run["case_phases"][b] == "qualifying"
    assert run["case_phases"][c] == "preparing"

    progress.(a, "grading", "Grading submitted patch")
    progress.(b, "running", "Pi editing next case")
    progress.(b, "ready", "Delayed earlier event")
    run = Runs.snapshot().active
    assert run["current_case"] == b
    assert run["case_phases"][a] == "grading"
    assert run["case_phases"][b] == "running"
    assert run["case_messages"][b] == "Pi editing next case"

    send(
      Runs,
      {:progress, id,
       %{"case_result" => {a, %{"status" => "completed", "grade" => %{"passed" => true}}}}}
    )

    progress.(a, "grading", "Delayed grader event")
    assert Runs.snapshot().active["case_phases"][a] == "completed"
  end

  test "restart finalizes submitted and grading attempts as interrupted" do
    Store.write("runs/handoff/run.json", %{
      "id" => "handoff",
      "created_at" => "2026-01-01",
      "status" => "running",
      "cases" => ["a", "b"],
      "attempts" => %{}
    })

    for {id, status} <- [{"a", "submitted"}, {"b", "grading"}] do
      Store.write("runs/handoff/#{id}/attempt.json", %{"case" => id, "status" => status})
      Store.write_text("runs/handoff/#{id}/model.patch", "saved #{id}")
    end

    Supervisor.terminate_child(Eab.Supervisor, Runs)
    Supervisor.restart_child(Eab.Supervisor, Runs)

    for id <- ["a", "b"] do
      assert Store.read("runs/handoff/#{id}/attempt.json")["status"] == "interrupted"
      assert File.read!(Store.path("runs/handoff/#{id}/model.patch")) == "saved #{id}"
    end

    assert Store.read("runs/handoff/run.json")["score"]["score_percent"] == nil
  end

  test "stop drains all pipeline workers before installation container cleanup" do
    parent = self()

    Application.put_env(:eab, :runner, fn _, _, _ ->
      Eab.Pipeline.run(["a", "b"], %{
        prepare: fn
          "a" ->
            :ready

          "b" ->
            send(parent, {:preparing, self()})

            receive do
              :never -> :ready
            end
        end,
        workspace: fn _, use -> use.(:box) end,
        attempt: fn _, _, _ ->
          send(parent, {:pi, self()})

          receive do
            :never -> :submission
          end
        end
      })
    end)

    Application.put_env(:eab, :cleanup, fn id -> send(parent, {:cleanup, id}) end)
    assert {:ok, id} = Runs.start(endpoint(), "", %{})
    assert_receive {:pi, pi}, 3000
    assert_receive {:preparing, preparing}, 3000
    Runs.stop()
    assert_receive {:cleanup, ^id}, 3000
    refute Process.alive?(pi)
    refute Process.alive?(preparing)
    assert Store.read("runs/#{id}/run.json")["status"] == "cancelled"
  end

  defp await_terminal(id) do
    if Store.read("runs/#{id}/run.json")["status"] == "running" do
      receive do
        :runs_changed -> await_terminal(id)
      after
        2000 -> flunk("Worker did not finish")
      end
    end
  end

  defp await_cleanup do
    if Runs.snapshot().cleaning do
      receive do
        :runs_changed -> await_cleanup()
      after
        3000 -> flunk("Cleanup did not finish")
      end
    end
  end

  test "resume keeps completed failures and saved submissions, archives partial attempts, and rejects changed settings" do
    parent = self()
    Runs.subscribe()

    Application.put_env(:eab, :runner, fn run, _, _ ->
      [done, saved, partial | _] = run["cases"]

      for id <- [done, saved],
          do:
            Store.write("runs/#{run["id"]}/#{id}/runtime.json", %{
              "image" => "synthetic",
              "services" => %{}
            })

      {record, _} =
        Eab.Checkpoints.submit(run["id"], done, %{"case" => done}, "completed patch", "")

      grade = Eab.Evidence.save(run["id"], done, %{"passed" => false}, "")

      Eab.Checkpoints.complete(
        run["id"],
        done,
        Map.merge(record, %{"status" => "completed", "grade" => grade}),
        ""
      )

      Eab.Checkpoints.submit(
        run["id"],
        saved,
        %{"case" => saved, "calls" => 9},
        "saved patch",
        ""
      )

      Store.write("runs/#{run["id"]}/#{partial}/attempt.json", %{
        "status" => "running",
        "calls" => 2
      })

      Store.write("runs/#{run["id"]}/#{partial}/agent-progress.json", %{
        "calls" => 3,
        "generated_tokens" => 51
      })

      send(parent, {:ready, done, saved, partial})

      receive do
        :wait -> :ok
      end
    end)

    assert {:ok, id} = Runs.start(endpoint(), "", %{})
    assert_receive {:ready, done, saved, partial}, 3000
    Runs.stop()
    await_cleanup()
    assert {:error, mismatch} = Runs.resume(id, endpoint(), "", %{"seed" => "102"})
    assert mismatch =~ "settings differ"

    Application.put_env(:eab, :runner, fn run, _, _ ->
      send(parent, {:resumed, run, Eab.Checkpoints.plan(run)})

      receive do
        :wait -> :ok
      end
    end)

    assert {:ok, ^id} = Runs.resume(id, endpoint(), "", %{})
    assert_receive {:resumed, resumed, plan}, 3000
    assert resumed["attempts"][done]["grade"]["passed"] == false
    assert plan.submissions[saved] |> elem(1) == "saved patch"
    assert resumed["generations"][partial] == 2
    assert hd(resumed["attempt_history"])["generated_tokens"] == 51
    assert resumed["resume_count"] == 1
  end
end
