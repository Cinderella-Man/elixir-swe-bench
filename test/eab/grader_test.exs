defmodule Eab.GraderTest do
  use ExUnit.Case, async: true
  alias Eab.Grader

  defp result(rows, opts \\ []) do
    output =
      Enum.map_join(rows, "\n", fn {id, state} -> "EAB_TEST:#{state}:#{Base.encode64(id)}" end)

    output =
      output <>
        if(Keyword.get(opts, :finish, true), do: "\nEAB_SUITE_FINISHED:#{length(rows)}", else: "")

    %{
      "returncode" => opts[:code] || 0,
      "output" => output <> (opts[:extra] || ""),
      "output_truncated" => opts[:truncated] || false
    }
  end

  test "an early zero exit, missing completion, duplicates and truncation cannot pass" do
    for raw <- [
          result([]),
          result([{"x", "passed"}], finish: false),
          result([{"x", "passed"}, {"x", "passed"}]),
          result([{"x", "passed"}], truncated: true)
        ] do
      refute Grader.parse(raw)["passed"]
    end
  end

  test "only declared exclusions pass, skipped or all-excluded suites fail" do
    tag = "\nEAB_EXCLUDED_TAGS:#{Base.encode64("enterprise")}:#{Base.encode64("ee_only")}"
    raw = result([{"a", "passed"}, {"enterprise", "excluded"}], extra: tag)
    assert Grader.parse(raw, ["ee_only"])["passed"]
    refute Grader.parse(raw)["passed"]
    refute Grader.parse(result([{"a", "passed"}, {"b", "skipped"}]))["passed"]
    refute Grader.parse(result([{"enterprise", "excluded"}], extra: tag), ["ee_only"])["passed"]
  end

  test "changed and missing protected tests fail" do
    expected = Grader.parse(result([{"a", "passed"}, {"b", "passed"}]))
    actual = Grader.parse(result([{"a", "passed"}]))
    refute Grader.control_tests(actual, expected)["passed"]
  end

  test "only a failure in a completed test body establishes coverage" do
    body = "\nEAB_FAILURE_PHASE:#{Base.encode64("a")}:test"
    setup = "\nEAB_FAILURE_PHASE:#{Base.encode64("a")}:setup"

    assert Grader.behavioral_failures(
             Grader.parse(result([{"a", "failed"}], code: 2, extra: body))
           ) == ["a"]

    assert Grader.behavioral_failures(
             Grader.parse(result([{"a", "failed"}], code: 2, extra: setup))
           ) == []
  end

  test "a test file that cannot compile on the starting source neither counts nor hides others" do
    contract = %{"model_tests" => "behavioral"}
    submission = Grader.parse(result([{"good", "passed"}, {"doc", "passed"}]))
    stopped = Grader.parse(result([], code: 1, finish: false, extra: "** (CompileError)"))
    body = "\nEAB_FAILURE_PHASE:#{Base.encode64("good")}:test"
    alone = Grader.parse(result([{"good", "failed"}], code: 2, extra: body))

    refute Grader.coverage(contract, stopped, %{}, submission)["passed"]
    refute Grader.coverage(contract, stopped, %{"doc_test.exs" => stopped}, submission)["passed"]

    coverage =
      Grader.coverage(
        contract,
        stopped,
        %{"doc_test.exs" => stopped, "good_test.exs" => alone},
        submission
      )

    assert coverage["passed"]
    assert coverage["detected_tests"] == ["good"]
  end

  test "trusted formatter records survive progress dots written between them" do
    Code.require_file(Eab.Inventory.path("priv/fixtures/grade_formatter.exs"))

    failed = %ExUnit.Test{
      module: Example,
      name: :"test a",
      state: {:failed, [{:error, %RuntimeError{message: "boom"}, []}]},
      tags: %{}
    }

    excluded = %ExUnit.Test{
      module: Example,
      name: :"test b",
      state: {:excluded, "due to ee_only filter"},
      tags: %{ee_only: true}
    }

    # Loaded at runtime from the fixture, like the grader does.
    formatter = Module.concat(ElixirAgentBenchmark, TrustedFormatter)

    writes =
      writes(fn ->
        for test <- [failed, excluded], do: formatter.handle_cast({:test_finished, test}, 0)
        formatter.handle_cast({:suite_finished, %{}}, 2)
      end)

    # ExUnit's own formatter prints progress dots between any two writes.
    output = Enum.join(writes, "..")
    raw = %{"returncode" => 2, "output" => output, "output_truncated" => false}
    parsed = Grader.parse(raw, ["ee_only"])

    assert parsed["completed"]
    assert parsed["failure_phases"] == %{"Elixir.Example::test a" => "test"}
    assert parsed["failure_types"] == %{"Elixir.Example::test a" => ["Elixir.RuntimeError"]}
    assert parsed["exclusion_tags"] == %{"Elixir.Example::test b" => ["ee_only"]}
  end

  defp writes(fun) do
    leader = spawn_link(fn -> collect_writes([]) end)
    previous = Process.group_leader()
    Process.group_leader(self(), leader)

    try do
      fun.()
    after
      Process.group_leader(self(), previous)
    end

    send(leader, {:writes, self()})

    receive do
      {:writes, writes} -> writes
    end
  end

  defp collect_writes(acc) do
    receive do
      {:io_request, from, ref, {:put_chars, _encoding, chars}} ->
        send(from, {:io_reply, ref, :ok})
        collect_writes([IO.chardata_to_string(chars) | acc])

      {:io_request, from, ref, {:put_chars, _encoding, module, function, args}} ->
        send(from, {:io_reply, ref, :ok})
        collect_writes([IO.chardata_to_string(apply(module, function, args)) | acc])

      {:writes, to} ->
        send(to, {:writes, Enum.reverse(acc)})
    end
  end

  test "new test files join explicit test selections and bare mix test stays broad" do
    assert Grader.test_command("mix test test/original_test.exs", ["test/new_test.exs"]) =~
             "test/new_test.exs"

    refute Grader.test_command("mix test --seed 7", ["test/new_test.exs"]) =~ "test/new_test.exs"
    assert_raise RuntimeError, fn -> Grader.test_command("echo success") end
  end

  test "patches cannot escape edit areas, create links or modify configuration" do
    spec = %{"allowed_edit_prefixes" => ["lib/", "test/"]}

    for path <- ["../secret", "lib/../../secret", "config/config.exs", ".git/config"] do
      assert {:error, _} = Grader.validate_patch("diff --git a/#{path} b/#{path}\n", spec)
    end

    assert {:error, _} =
             Grader.validate_patch("diff --git a/lib/x b/lib/x\nnew file mode 120000\n", spec)

    assert {:ok, []} = Grader.validate_patch("diff --git a/lib/x.ex b/lib/x.ex\n", spec)
  end

  test "all retained PR reference patches satisfy edit rules and have partial controls" do
    ids = Eab.Inventory.all()
    assert ids != []
    refute "plausible-pr-6300" in ids
    refute "plausible-pr-6763" in ids
    refute "plausible-pr-6441" in ids

    for id <- ids do
      spec = Eab.Inventory.spec(id)
      assert spec["source_inspiration"]["url"] =~ "/pull/"
      assert {:ok, _} = Grader.validate_patch(Eab.Inventory.file(id, "reference.patch"), spec)
      assert Grader.partial_patch(id) != ""
      assert File.exists?(Eab.Inventory.case_path(id, "acceptance.patch"))
    end
  end

  test "delete-and-recreate patches cannot disguise configuration as a new helper" do
    spec = %{"allowed_edit_prefixes" => ["lib/", "test/"]}

    deleted =
      "diff --git a/mix.exs b/mix.exs\ndeleted file mode 100644\n--- a/mix.exs\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n"

    added =
      "diff --git a/mix.exs b/mix.exs\nnew file mode 100644\n--- /dev/null\n+++ b/mix.exs\n@@ -0,0 +1 @@\n+replacement\n"

    assert {:error, _} = Grader.validate_patch(deleted <> added, spec)
    assert {:error, _} = Grader.validate_patch(added <> deleted, spec)

    assert {:ok, ["repro.exs"]} =
             Grader.validate_patch(String.replace(added, "mix.exs", "repro.exs"), spec)
  end
end
