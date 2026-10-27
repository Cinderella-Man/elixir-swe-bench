defmodule Eab.CheckpointsTest do
  use ExUnit.Case, async: false
  alias Eab.{Checkpoints, Evidence, Inventory, Model, Release, Store}

  setup do
    old = Application.fetch_env!(:eab, :data_dir)
    dir = Path.join(System.tmp_dir!(), "eab-checkpoints-#{System.unique_integer([:positive])}")
    Application.put_env(:eab, :data_dir, dir)

    on_exit(fn ->
      Application.put_env(:eab, :data_dir, old)
      File.rm_rf!(dir)
    end)

    endpoint = %{
      "url" => "http://fixture",
      "backend" => "llama_cpp",
      "model" => "synthetic",
      "context" => 32768,
      "profile" => %{"model_path" => "fixture.gguf"}
    }

    release = Release.freeze()
    settings = Model.settings(endpoint)

    run = %{
      "id" => "fixture",
      "cases" => Inventory.all(),
      "model" => endpoint,
      "settings" => settings,
      "protocol" => release["protocol"],
      "release_id" => release["id"],
      "experiment_id" => Release.experiment(release["id"], endpoint, settings),
      "attempts" => %{}
    }

    Store.write("runs/fixture/run.json", run)

    for id <- run["cases"],
        do:
          Store.write("runs/fixture/#{id}/runtime.json", %{
            "image" => "synthetic",
            "services" => %{}
          })

    %{run: run, id: hd(run["cases"])}
  end

  test "same immutable release is reusable and frozen fixture corruption is rejected", %{
    run: run,
    id: id
  } do
    assert Release.freeze()["id"] == run["release_id"]
    path = Store.path("releases/#{run["release_id"]}/cases/#{id}/ticket.md")
    assert File.read!(path) == Inventory.file(id, "ticket.md")
    File.write!(path, "corrupt")

    assert_raise RuntimeError, ~r/Frozen release fixture is corrupt/, fn ->
      Release.read!(run["release_id"])
    end
  end

  test "resume rejects changed model, settings and reordered cases", %{run: run} do
    assert :ok = Checkpoints.validate_run!(run, run["model"], run["settings"])

    for candidate <- [
          put_in(run, ["model", "model"], "another"),
          put_in(run, ["settings", "seed"], 999),
          Map.update!(run, "cases", &Enum.reverse/1)
        ] do
      assert_raise RuntimeError, ~r/differ/, fn ->
        Checkpoints.validate_run!(candidate, run["model"], run["settings"])
      end
    end

    assert_raise RuntimeError, ~r/differ/, fn ->
      Checkpoints.validate_run!(run, Map.put(run["model"], "model", "other"), run["settings"])
    end
  end

  test "resume survives a benchmark code change but not a changed agent", %{run: run} do
    # A release frozen by earlier benchmark code: same cases, fixtures and Pi.
    older = put_in(run["protocol"], ["implementation"], String.duplicate("0", 64))
    id = Eab.Cache.key(older)
    File.cp_r!(Store.path("releases/#{run["release_id"]}"), Store.path("releases/#{id}"))

    Store.write("releases/#{id}/manifest.json", %{"version" => 1, "id" => id, "protocol" => older})

    resumed =
      Map.merge(run, %{
        "protocol" => older,
        "release_id" => id,
        "experiment_id" => Release.experiment(id, run["model"], run["settings"])
      })

    assert :ok = Checkpoints.validate_run!(resumed, run["model"], run["settings"])

    agent = put_in(older, ["agent", "version"], "0.0.1")
    id = Eab.Cache.key(agent)
    File.cp_r!(Store.path("releases/#{run["release_id"]}"), Store.path("releases/#{id}"))

    Store.write("releases/#{id}/manifest.json", %{"version" => 1, "id" => id, "protocol" => agent})

    changed =
      Map.merge(resumed, %{
        "protocol" => agent,
        "release_id" => id,
        "experiment_id" => Release.experiment(id, run["model"], run["settings"])
      })

    assert_raise RuntimeError, ~r/cases or agent changed/, fn ->
      Checkpoints.validate_run!(changed, run["model"], run["settings"])
    end
  end

  test "completed failure survives lost coordinator notification and detects changed evidence", %{
    run: run,
    id: id
  } do
    {record, _} =
      Checkpoints.submit(
        run["id"],
        id,
        %{"case" => id, "calls" => 40, "measurement" => %{"attempt_ms" => 1500}},
        "patch",
        ""
      )

    grade =
      Evidence.save(run["id"], id, %{"passed" => false, "reason" => "incomplete repair"}, "")

    record = Map.merge(record, %{"status" => "completed", "grade" => grade})
    Checkpoints.complete(run["id"], id, record, "")
    assert Checkpoints.plan(run).retained[id] == record
    assert Checkpoints.plan(run).retained[id]["measurement"] == %{"attempt_ms" => 1500}
    refute id in Checkpoints.plan(run).restart
    Store.write("runs/#{run["id"]}/#{id}/grade.json", %{"passed" => true})
    assert_raise RuntimeError, ~r/evidence is missing or changed/, fn -> Checkpoints.plan(run) end
  end

  test "sealed submission survives interruption and never becomes a fresh Pi attempt", %{
    run: run,
    id: id
  } do
    {record, patch} =
      Checkpoints.submit(run["id"], id, %{"case" => id, "calls" => 80}, "saved diff", "")

    Store.write("runs/#{run["id"]}/#{id}/attempt.json", Map.put(record, "status", "interrupted"))
    assert Checkpoints.plan(run).submissions[id] == {record, patch}
    refute id in Checkpoints.plan(run).restart
    Store.write_text("runs/#{run["id"]}/#{id}/model.patch", "different")
    assert_raise RuntimeError, ~r/patch changed/, fn -> Checkpoints.plan(run) end
  end

  test "incomplete generations retain usage and recovery handles a crash after archive rename", %{
    run: run,
    id: id
  } do
    prefix = "runs/#{run["id"]}/#{id}"
    Store.write("#{prefix}/attempt.json", %{"status" => "interrupted", "calls" => 2})
    Store.write("#{prefix}/agent-progress.json", %{"calls" => 3, "generated_tokens" => 42})
    Store.write_text("#{prefix}/model.patch", "partial unsealed work")
    assert id in Checkpoints.plan(run).restart
    next = Checkpoints.archive_unfinished(run, [id])
    assert next["generations"][id] == 2
    assert hd(next["attempt_history"])["generated_tokens"] == 42
    assert hd(next["attempt_history"])["calls"] == 3

    assert File.read!(Store.path("runs/fixture/prior-attempts/#{id}/1/model.patch")) ==
             "partial unsealed work"

    # The original run.json still points at generation one, modeling a crash.
    assert Checkpoints.archive_unfinished(run, [id]) == next
  end

  test "saved submission binds its prepared images and source receipt", %{run: run, id: id} do
    Checkpoints.submit(run["id"], id, %{"case" => id}, "sealed diff", "")

    Store.write("runs/#{run["id"]}/#{id}/runtime.json", %{
      "image" => "different",
      "services" => %{}
    })

    assert_raise RuntimeError, ~r/environment or patch changed/, fn ->
      Checkpoints.submission(run, id)
    end
  end

  test "evaluation errors are retained and environment changes cannot reuse a submission", %{
    run: run,
    id: id
  } do
    Store.write("runs/fixture/#{id}/attempt.json", %{
      "status" => "error",
      "error" => "service failed"
    })

    assert Checkpoints.plan(run).retained[id]["status"] == "error"
    refute id in Checkpoints.plan(run).restart
    File.rm!(Store.path("runs/fixture/#{id}/runtime.json"))
    runtime = %{"image" => "sha256:one", "services" => %{}, "baseline" => %{"id" => "one"}}
    Checkpoints.bind_runtime!(run["id"], id, runtime)

    assert :ok =
             Checkpoints.bind_runtime!(
               run["id"],
               id,
               Map.put(runtime, "build_log", "different.log")
             )

    assert_raise RuntimeError, ~r/environment changed/, fn ->
      Checkpoints.bind_runtime!(run["id"], id, Map.put(runtime, "image", "sha256:two"))
    end
  end

  test "runner prepares only unfinished cases, skips Pi for a sealed submission and preserves failures",
       %{run: run} do
    [failed, saved, fresh | rest] = run["cases"]

    for id <- [failed | rest] do
      {record, _} = Checkpoints.submit(run["id"], id, %{"case" => id}, "previous", "")
      grade = Evidence.save(run["id"], id, %{"passed" => id != failed}, "")

      Checkpoints.complete(
        run["id"],
        id,
        Map.merge(record, %{"status" => "completed", "grade" => grade}),
        ""
      )
    end

    Checkpoints.submit(run["id"], saved, %{"case" => saved, "calls" => 47}, "sealed diff", "")
    parent = self()

    assert :ok =
             Eab.Runner.execute(run, "", &send(parent, {:result, &1}),
               check_model: fn _, _ -> :ok end,
               baseline: fn _, _, _, _ -> :ok end,
               prepare: fn _, id, _, _ ->
                 send(parent, {:prepare, id})
                 %{}
               end,
               workspace: fn id, _, use ->
                 send(parent, {:workspace, id})
                 use.(:synthetic_box)
               end,
               submit: fn id, run_id, :synthetic_box, _, _, _, _ ->
                 send(parent, {:pi, id})
                 Checkpoints.submit(run_id, id, %{"case" => id, "calls" => 1}, "new diff", "")
               end,
               grade: fn id, run_id, {record, patch}, _, _, _, _ ->
                 send(parent, {:grade, id, patch})
                 grade = Evidence.save(run_id, id, %{"passed" => true}, "")

                 Checkpoints.complete(
                   run_id,
                   id,
                   Map.merge(record, %{"status" => "completed", "grade" => grade}),
                   ""
                 )
               end
             )

    assert_receive {:prepare, ^saved}
    assert_receive {:prepare, ^fresh}
    refute_receive {:prepare, ^failed}
    assert_receive {:pi, ^fresh}
    refute_receive {:pi, ^saved}
    refute_receive {:workspace, ^saved}
    assert_receive {:grade, ^saved, "sealed diff"}
    assert_receive {:grade, ^fresh, "new diff"}
    assert Checkpoints.completed(run, saved)["calls"] == 47
    assert Checkpoints.completed(run, failed)["grade"]["passed"] == false
  end

  test "a run's parallel attempts reach the pipeline: two attempts run at once", %{run: run} do
    run = %{run | "cases" => Enum.take(run["cases"], 3)} |> Map.put("parallel_attempts", 2)
    parent = self()

    runner =
      Task.async(fn ->
        Eab.Runner.execute(run, "", fn _ -> :ok end,
          check_model: fn _, _ -> :ok end,
          baseline: fn _, _, _, _ -> :ok end,
          prepare: fn _, _, _, _ -> %{} end,
          workspace: fn _, _, use -> use.(:synthetic_box) end,
          submit: fn id, run_id, :synthetic_box, _, _, _, _ ->
            send(parent, {:pi_started, id, self()})

            receive do
              :go -> Checkpoints.submit(run_id, id, %{"case" => id}, "diff", "")
            end
          end,
          grade: fn id, run_id, {record, _}, _, _, _, _ ->
            grade = Evidence.save(run_id, id, %{"passed" => true}, "")

            Checkpoints.complete(
              run_id,
              id,
              Map.merge(record, %{"status" => "completed", "grade" => grade}),
              ""
            )
          end
        )
      end)

    [a, b, c] = run["cases"]
    assert_receive {:pi_started, ^a, pi_a}, 5000
    assert_receive {:pi_started, ^b, pi_b}, 5000
    refute_receive {:pi_started, ^c, _}, 300
    send(pi_b, :go)
    assert_receive {:pi_started, ^c, pi_c}, 5000
    send(pi_a, :go)
    send(pi_c, :go)
    assert Task.await(runner, 10_000) == :ok
    assert Enum.all?(run["cases"], &Checkpoints.completed(run, &1)["grade"]["passed"])
  end
end
