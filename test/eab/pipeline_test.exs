defmodule Eab.PipelineTest do
  use ExUnit.Case, async: true
  alias Eab.Pipeline

  defp start_pipeline(cases, opts \\ [], overrides \\ %{}) do
    parent = self()

    gate = fn kind, id, value ->
      send(parent, {kind, id, self()})

      receive do
        :continue -> value
        :fail -> raise "synthetic #{kind} failure"
      after
        10_000 -> raise "Test gate watchdog expired"
      end
    end

    callbacks = %{
      prepare: fn id -> gate.(:prepare, id, {:control, id}) end,
      workspace: fn id, use ->
        gate.(:workspace, id, :ok)

        try do
          use.({:box, id})
        after
          send(parent, {:closed, id})
        end
      end,
      attempt: fn id, box, control ->
        assert box == {:box, id}
        assert control == {:control, id}
        gate.(:attempt, id, {:submission, id})
      end,
      grade: fn id, submission, control ->
        assert submission == {:submission, id}
        assert control == {:control, id}

        gate.(:grade, id, %{"case" => id, "status" => "completed", "grade" => %{"passed" => true}})
      end,
      error: fn id, message -> %{"case" => id, "status" => "error", "error" => message} end,
      result: fn id, result -> send(parent, {:result, id, result}) end
    }

    owner =
      spawn(fn ->
        send(parent, {:finished, Pipeline.run(cases, Map.merge(callbacks, overrides), opts)})
      end)

    on_exit(fn ->
      Process.exit(owner, :kill)
      Pipeline.await_owner(owner)
    end)

    owner
  end

  defp release(kind, id) do
    assert_receive {^kind, ^id, pid}, 3000
    send(pid, :continue)
    pid
  end

  test "baseline ancestry outside lookahead finishes in order without warming or qualifying ancestors" do
    parent = self()

    baseline = fn id ->
      send(parent, {:baseline, id, self()})

      receive do
        :continue -> :ok
        :fail -> raise "synthetic seed failure"
      after
        10_000 -> raise "Baseline test watchdog expired"
      end
    end

    start_pipeline(
      ~w(new other middle old),
      [
        lookahead: 1,
        preparation_workers: 2,
        preparation_plan: %{
          "new" => ~w(old middle),
          "middle" => ["old"],
          "old" => [],
          "other" => []
        }
      ],
      %{baseline: baseline}
    )

    release(:baseline, "old")
    release(:baseline, "middle")
    release(:baseline, "new")
    release(:prepare, "new")
    refute_receive {:prepare, _, _}
    release(:workspace, "new")
    release(:attempt, "new")
    release(:grade, "new")
    release(:baseline, "other")

    for id <- ~w(other middle old) do
      release(:prepare, id)
      release(:workspace, id)
      release(:attempt, id)
      release(:grade, id)
    end

    refute_receive {:baseline, _, _}
    assert_receive {:finished, results}, 3000
    assert Enum.map(results, & &1["case"]) == ~w(new other middle old)
  end

  test "a failed ancestor is recorded once and later baselines may build independently" do
    parent = self()

    start_pipeline(
      ~w(new old),
      [preparation_plan: %{"new" => ["old"], "old" => []}],
      %{
        baseline: fn id ->
          send(parent, {:built, id})
          if id == "old", do: raise("seed unavailable")
          :ok
        end
      }
    )

    assert_receive {:result, "old", %{"status" => "error"}}, 3000
    release(:prepare, "new")
    release(:workspace, "new")
    release(:attempt, "new")
    release(:grade, "new")
    assert_receive {:finished, [new, old]}, 3000
    assert new["status"] == "completed"
    assert old["status"] == "error"
    assert_receive {:built, "old"}
    assert_receive {:built, "new"}
    refute_receive {:built, _}
  end

  test "first case starts alone, then preparation, one warm workspace and grading overlap in order" do
    start_pipeline(~w(a b c), lookahead: 2, preparation_workers: 2)
    assert_receive {:prepare, "a", prep_a}, 3000
    refute_receive {:prepare, _, _}
    send(prep_a, :continue)
    release(:workspace, "a")
    assert_receive {:attempt, "a", pi_a}, 3000
    assert_receive {:prepare, "b", prep_b}, 3000
    assert_receive {:prepare, "c", prep_c}, 3000

    # Out-of-order preparation does not change attempt order.
    send(prep_c, :continue)
    refute_receive {:workspace, "c", _}
    send(prep_b, :continue)
    release(:workspace, "b")
    refute_receive {:attempt, "b", _}
    refute_receive {:workspace, "c", _}

    send(pi_a, :continue)
    assert_receive {:closed, "a"}, 3000
    assert_receive {:grade, "a", grade_a}, 3000
    assert_receive {:attempt, "b", pi_b}, 3000
    release(:workspace, "c")
    send(pi_b, :continue)
    assert_receive {:closed, "b"}, 3000
    refute_receive {:attempt, "c", _}
    refute_receive {:grade, "b", _}

    # A completed submission applies backpressure until the one grader frees.
    send(grade_a, :continue)
    assert_receive {:grade, "b", grade_b}, 3000
    assert_receive {:attempt, "c", pi_c}, 3000
    send(pi_c, :continue)
    assert_receive {:closed, "c"}, 3000
    send(grade_b, :continue)
    release(:grade, "c")
    assert_receive {:finished, results}, 3000
    assert Enum.map(results, & &1["case"]) == ~w(a b c)
    assert Enum.all?(results, &(&1["status"] == "completed"))
  end

  test "parallel attempts start together, finish and grade out of order, and keep case order" do
    start_pipeline(~w(a b c d), parallel: 2, lookahead: 2, preparation_workers: 2)

    # Before the first attempt starts, only the first `parallel` cases prepare.
    assert_receive {:prepare, "a", prep_a}, 3000
    assert_receive {:prepare, "b", prep_b}, 3000
    refute_receive {:prepare, "c", _}
    send(prep_a, :continue)
    send(prep_b, :continue)
    release(:workspace, "a")
    release(:workspace, "b")
    assert_receive {:attempt, "a", pi_a}, 3000
    assert_receive {:attempt, "b", pi_b}, 3000

    # Up to two waiting workspaces, and no third attempt while two run.
    release(:prepare, "c")
    release(:prepare, "d")
    release(:workspace, "c")
    release(:workspace, "d")
    refute_receive {:attempt, "c", _}

    # b finishes first: its grading and c's attempt start while a still runs.
    send(pi_b, :continue)
    assert_receive {:closed, "b"}, 3000
    assert_receive {:grade, "b", grade_b}, 3000
    assert_receive {:attempt, "c", pi_c}, 3000
    refute_receive {:attempt, "d", _}

    # a finishes: a second grader runs beside b's, and d starts.
    send(pi_a, :continue)
    assert_receive {:closed, "a"}, 3000
    assert_receive {:grade, "a", grade_a}, 3000
    assert_receive {:attempt, "d", pi_d}, 3000

    # Two graders are busy, so c's and d's submissions queue until one frees.
    send(pi_c, :continue)
    send(pi_d, :continue)
    assert_receive {:closed, "c"}, 3000
    assert_receive {:closed, "d"}, 3000
    refute_receive {:grade, _, _}
    send(grade_b, :continue)
    assert_receive {:grade, "c", grade_c}, 3000
    refute_receive {:grade, "d", _}
    send(grade_a, :continue)
    assert_receive {:grade, "d", grade_d}, 3000
    send(grade_d, :continue)
    send(grade_c, :continue)

    assert_receive {:finished, results}, 3000
    assert Enum.map(results, & &1["case"]) == ~w(a b c d)
    assert Enum.all?(results, &(&1["status"] == "completed"))
  end

  test "a submission waiting for a free grader holds back the next parallel attempt" do
    start_pipeline(~w(a b c d e), parallel: 2, lookahead: 3, preparation_workers: 2)
    release(:prepare, "a")
    release(:prepare, "b")
    release(:workspace, "a")
    release(:workspace, "b")
    assert_receive {:attempt, "a", pi_a}, 3000
    assert_receive {:attempt, "b", pi_b}, 3000
    release(:prepare, "c")
    release(:prepare, "d")
    release(:prepare, "e")
    release(:workspace, "c")
    release(:workspace, "d")

    send(pi_a, :continue)
    assert_receive {:grade, "a", grade_a}, 3000
    assert_receive {:attempt, "c", pi_c}, 3000
    send(pi_b, :continue)
    assert_receive {:grade, "b", grade_b}, 3000
    assert_receive {:attempt, "d", pi_d}, 3000
    release(:workspace, "e")

    # c's submission waits behind two busy graders: e must not start, although only
    # d is running.
    send(pi_c, :continue)
    assert_receive {:closed, "c"}, 3000
    refute_receive {:attempt, "e", _}

    send(grade_a, :continue)
    assert_receive {:grade, "c", grade_c}, 3000
    assert_receive {:attempt, "e", pi_e}, 3000

    send(pi_d, :continue)
    send(pi_e, :continue)
    send(grade_b, :continue)
    send(grade_c, :continue)
    release(:grade, "d")
    release(:grade, "e")
    assert_receive {:finished, results}, 3000
    assert Enum.map(results, & &1["case"]) == ~w(a b c d e)
  end

  test "parallel attempts outside 1 to 8 are refused" do
    for parallel <- [0, 9, "2"] do
      assert_raise ArgumentError, "Invalid parallel attempts", fn ->
        Pipeline.init({self(), ~w(a), %{}, [parallel: parallel]})
      end
    end
  end

  test "lookahead and preparation worker limits hold independently" do
    start_pipeline(~w(a b c d e f), lookahead: 3, preparation_workers: 2)
    release(:prepare, "a")
    release(:workspace, "a")
    assert_receive {:attempt, "a", _}, 3000
    assert_receive {:prepare, "b", prep_b}, 3000
    assert_receive {:prepare, "c", prep_c}, 3000
    refute_receive {:prepare, _, _}
    send(prep_c, :continue)
    release(:prepare, "d")
    send(prep_b, :continue)
    release(:workspace, "b")
    refute_receive {:prepare, "e", _}
    refute_receive {:prepare, "f", _}
    refute_receive {:workspace, "c", _}
  end

  test "future preparation failure records an error without cancelling active Pi or later cases" do
    start_pipeline(~w(a b c))
    release(:prepare, "a")
    release(:workspace, "a")
    assert_receive {:attempt, "a", pi_a}, 3000
    assert_receive {:prepare, "b", prep_b}, 3000
    send(prep_b, :fail)
    assert_receive {:result, "b", %{"status" => "error"}}, 3000
    assert Process.alive?(pi_a)
    release(:prepare, "c")
    release(:workspace, "c")
    refute_receive {:attempt, "c", _}
    send(pi_a, :continue)
    release(:grade, "a")
    release(:attempt, "c")
    release(:grade, "c")
    assert_receive {:finished, [a, b, c]}, 3000
    assert a["status"] == c["status"] and a["status"] == "completed"
    assert b["status"] == "error"
  end

  test "a failed warm workspace cannot clear another case's active attempt" do
    start_pipeline(~w(a b c))
    release(:prepare, "a")
    release(:workspace, "a")
    assert_receive {:attempt, "a", pi_a}, 3000
    release(:prepare, "b")
    assert_receive {:workspace, "b", warm_b}, 3000
    send(warm_b, :fail)
    assert_receive {:result, "b", %{"status" => "error"}}, 3000
    release(:prepare, "c")
    release(:workspace, "c")
    refute_receive {:attempt, "c", _}
    send(pi_a, :continue)
    release(:grade, "a")
    release(:attempt, "c")
    release(:grade, "c")
    assert_receive {:finished, _}, 3000
  end

  test "cancellation drains active and preparing workers including a blocked subprocess callback" do
    parent = self()

    prepare = fn
      "a" ->
        {:control, "a"}

      "b" ->
        Eab.Command.exchange(
          "sh",
          ["-c", ~s(printf '{"pid":%s}\\n' "$$"; read reply)],
          nil,
          fn frame, state ->
            send(parent, {:subprocess, self(), frame["pid"]})

            receive do
              :never -> {nil, state}
            end
          end,
          timeout: 15
        )
    end

    owner = start_pipeline(~w(a b), [], %{prepare: prepare})
    release(:workspace, "a")
    assert_receive {:attempt, "a", pi}, 3000
    assert_receive {:subprocess, callback, os_pid}, 3000
    refs = Enum.map([pi, callback], &{Process.monitor(&1), &1})
    Process.exit(owner, :kill)
    Pipeline.await_owner(owner)
    for {ref, pid} <- refs, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 3000)
    {_, status} = System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
    assert status != 0
    refute_receive {:finished, _}
  end

  test "cancellation also drains an overlapping grader and the waiting workspace" do
    owner = start_pipeline(~w(a b c d))
    release(:prepare, "a")
    release(:workspace, "a")
    assert_receive {:attempt, "a", pi_a}, 3000
    release(:prepare, "b")
    release(:workspace, "b")
    release(:prepare, "c")
    send(pi_a, :continue)
    assert_receive {:grade, "a", grader}, 3000
    assert_receive {:attempt, "b", pi_b}, 3000
    warm_c = release(:workspace, "c")
    assert_receive {:prepare, "d", prepare_d}, 3000
    Process.exit(owner, :kill)
    Pipeline.await_owner(owner)
    for pid <- [grader, pi_b, warm_c, prepare_d], do: refute(Process.alive?(pid))
    refute_receive {:finished, _}
  end
end
