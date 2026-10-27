defmodule Eab.Grader do
  alias Eab.{Command, Inventory, Sandbox, Store, TaskContract, TestAdapter}

  def parse(result, permitted \\ []) do
    output = result["output"]
    rows = Regex.scan(~r/^EAB_TEST:([a-z]+):([A-Za-z0-9+\/=]+)$/m, output)
    tests = Map.new(rows, fn [_, state, identity] -> {Base.decode64!(identity), state} end)
    finished = Regex.scan(~r/^EAB_SUITE_FINISHED:(\d+)$/m, output)
    exclusions = tagged(output, "EAB_EXCLUDED_TAGS")

    phases =
      Map.new(Regex.scan(~r/^EAB_FAILURE_PHASE:([A-Za-z0-9+\/=]+):(test|setup)$/m, output), fn [
                                                                                                 _,
                                                                                                 identity,
                                                                                                 phase
                                                                                               ] ->
        {Base.decode64!(identity), phase}
      end)

    completed =
      not result["output_truncated"] and length(finished) == 1 and length(rows) > 0 and
        length(rows) == map_size(tests) and
        String.to_integer(hd(finished) |> List.last()) == length(rows)

    passed =
      result["returncode"] == 0 and completed and "passed" in Map.values(tests) and
        Enum.all?(tests, fn {id, state} ->
          state == "passed" or
            (state == "excluded" and Enum.any?(exclusions[id] || [], &(&1 in permitted)))
        end)

    Map.merge(result, %{
      "test_results" => tests,
      "exclusion_tags" => exclusions,
      "failure_phases" => phases,
      "failure_types" => tagged(output, "EAB_FAILURE_TYPES"),
      "completed" => completed,
      "passed" => passed
    })
  rescue
    ArgumentError ->
      Map.merge(result, %{
        "test_results" => %{},
        "failure_phases" => %{},
        "completed" => false,
        "passed" => false
      })
  end

  defp tagged(output, prefix) do
    Map.new(
      Regex.scan(Regex.compile!("^#{prefix}:([A-Za-z0-9+/=]+):([A-Za-z0-9+/=]*)$", "m"), output),
      fn [_, id, value] ->
        {Base.decode64!(id), String.split(Base.decode64!(value), ",", trim: true)}
      end
    )
  end

  def behavioral_failures(result) do
    for {id, "failed"} <- result["test_results"] || %{},
        get_in(result, ["failure_phases", id]) == "test",
        do: id
  end

  def control_tests(result, expected) do
    changes =
      Enum.reject(expected["test_results"], fn {id, state} ->
        result["test_results"][id] == state
      end)
      |> Map.new()

    Map.merge(result, %{
      "changed_control_states" => changes,
      "passed" => result["passed"] and map_size(changes) == 0
    })
  end

  def test_command(command, extra \\ []) do
    args = OptionParser.split(command)

    unless Enum.take(args, 2) == ["mix", "test"],
      do: raise("Grading requires an explicit mix test command")

    selected =
      Enum.any?(
        Enum.drop(args, 2),
        &(String.starts_with?(&1, "test/") or String.ends_with?(&1, ".exs") or &1 == "test")
      )

    args = args ++ if(selected, do: Enum.sort(extra -- args), else: [])
    args = args ++ if("--seed" in args, do: [], else: ["--seed", "0"])

    "elixir -r /opt/eab-grade/formatter.exs -S " <>
      Enum.map_join(
        args ++
          [
            "--formatter",
            "ExUnit.CLIFormatter",
            "--formatter",
            "ElixirAgentBenchmark.TrustedFormatter"
          ],
        " ",
        &Command.quote/1
      )
  end

  def run_tests(box, command, extra \\ []) do
    contract = TaskContract.read(box.spec)

    box
    |> Sandbox.command(TestAdapter.command(contract["adapter"], command, extra),
      timeout: box.spec["test_timeout"] || 240,
      limit: 2_097_152
    )
    |> parse(box.spec["permitted_exclusion_tags"] || [])
  end

  def validate_patch(patch, spec) do
    blocks = String.split(patch, "diff --git ") |> Enum.drop(1)

    touched =
      blocks
      |> Enum.flat_map(fn block ->
        case OptionParser.split(hd(String.split(block, "\n"))) do
          ["a/" <> a, "b/" <> b] -> Enum.uniq([a, b])
          _ -> []
        end
      end)
      |> Enum.frequencies()

    auxiliary =
      blocks
      |> Enum.flat_map(fn block ->
        lines = String.split(block, "\n")

        case OptionParser.split(hd(lines)) do
          [_, "b/" <> name] ->
            if Enum.any?(
                 Enum.take(lines, 4),
                 &(&1 in ["new file mode 100644", "new file mode 100755"])
               ) and
                 touched[name] == 1 and Path.basename(name) == name and
                 not String.starts_with?(name, ".") and
                 Path.extname(name) in [".ex", ".exs", ".md", ".txt", ".json"],
               do: [name],
               else: []

          _ ->
            []
        end
      end)

    valid =
      byte_size(patch) <= 1_048_576 and
        Enum.all?(String.split(patch, "\n"), fn
          "diff --git " <> header ->
            case OptionParser.split(header) do
              ["a/" <> a, "b/" <> b] -> Enum.all?([a, b], &allowed?(&1, spec, auxiliary))
              _ -> false
            end

          line ->
            line not in [
              "new file mode 120000",
              "new mode 120000",
              "new file mode 160000",
              "new mode 160000"
            ]
        end)

    if valid, do: {:ok, auxiliary}, else: {:error, "disallowed_or_oversized_patch"}
  rescue
    _ -> {:error, "unsupported_patch_header"}
  end

  defp allowed?(name, spec, auxiliary) do
    not String.starts_with?(name, "/") and not Enum.any?(Path.split(name), &(&1 in ["..", "."])) and
      (name in auxiliary or
         Enum.any?(spec["allowed_edit_prefixes"], &String.starts_with?(name, &1)))
  end

  def grade(id, patch, run_id, opts \\ []) do
    spec = Inventory.spec(id)

    case validate_patch(patch, spec) do
      {:error, reason} -> %{"passed" => false, "reason" => reason}
      {:ok, auxiliary} -> do_grade(id, patch, run_id, opts, auxiliary)
    end
  end

  defp do_grade(id, patch, run_id, opts, auxiliary) do
    contract = TaskContract.read(Inventory.spec(id))
    paths = Enum.map_join(contract["protected_paths"], " ", &Command.quote/1)

    {result, test_patch, changed} =
      Sandbox.with_box(id, run_id, fn box ->
        Sandbox.apply_patch(box, patch)
        Sandbox.command!(box, "git add -A")

        names =
          Sandbox.command!(box, "git -c core.quotepath=false diff --cached --name-only HEAD",
            limit: 2_097_152
          )
          |> String.split("\n", trim: true)

        unless Enum.all?(names, &allowed?(&1, box.spec, auxiliary)),
          do: raise("Submitted paths violate the case contract")

        changed =
          Sandbox.command!(
            box,
            "git diff --cached --name-only --diff-filter=ACMRT HEAD -- #{paths}",
            limit: 2_097_152
          )
          |> String.split("\n", trim: true)
          |> Enum.filter(&TaskContract.test_file?(contract, &1))

        test_patch =
          Sandbox.command!(box, "git diff --cached --binary HEAD -- #{paths}", limit: 1_048_576)

        TestAdapter.install(box)
        submission = run_tests(box, contract["preservation"], changed)
        restore_tests(box)
        Sandbox.apply_patch(box, Inventory.file(id, box.spec["acceptance_patch"]))
        hidden = run_tests(box, contract["acceptance"])

        required =
          Enum.all?(
            contract["required"],
            &(hidden["test_results"][&1] == "passed")
          )

        hidden = Map.update!(hidden, "passed", &(&1 and required))
        Sandbox.command!(box, "git add -A -- #{paths}")
        restore_tests(box)
        regression = run_tests(box, contract["preservation"])

        {hidden, regression} =
          if opts[:expected] do
            {control_tests(hidden, opts[:expected]["hidden"]),
             control_tests(regression, opts[:expected]["regression"])}
          else
            {hidden, regression}
          end

        {%{
           "passed" => submission["passed"] and hidden["passed"] and regression["passed"],
           "submission" => submission,
           "hidden" => hidden,
           "regression" => regression,
           "submitted_test_files" => changed,
           "auxiliary_files" => auxiliary
         }, test_patch, changed}
      end)

    if contract["model_tests"] != "optional" and Keyword.get(opts, :coverage, true) do
      coverage =
        if changed != [] and result["submission"]["passed"] do
          Sandbox.with_box(id, run_id, fn box ->
            Sandbox.apply_patch(
              box,
              if(contract["model_tests"] == "preservation", do: patch, else: test_patch)
            )

            TestAdapter.install(box)
            probe = run_tests(box, TestAdapter.selected(contract["adapter"], changed))

            # One added file that cannot compile on the starting source stops the whole
            # ExUnit run. Probing each file alone keeps it from hiding the others.
            file_probes =
              if contract["model_tests"] == "behavioral" and not probe["completed"] and
                   length(changed) > 1,
                 do:
                   Map.new(
                     changed,
                     &{&1, run_tests(box, TestAdapter.selected(contract["adapter"], [&1]))}
                   ),
                 else: %{}

            coverage(contract, probe, file_probes, result["submission"])
          end)
        else
          %{"passed" => false, "reason" => "No passing added or changed regression test"}
        end

      result
      |> Map.put("regression_coverage", coverage)
      |> Map.update!("passed", &(&1 and coverage["passed"]))
    else
      result
    end
  end

  @doc false
  def coverage(contract, probe, file_probes, submission) do
    # A file that cannot compile there counts for nothing; only completed runs do.
    detected =
      [probe | Map.values(file_probes)]
      |> Enum.filter(&(&1["completed"] and &1["returncode"] != 0))
      |> Enum.flat_map(&behavioral_failures/1)
      |> Enum.filter(&(submission["test_results"][&1] == "passed"))
      |> Enum.uniq()

    %{
      "passed" => coverage_passed?(contract, probe, detected, submission),
      "policy" => contract["model_tests"],
      "detected_tests" => detected,
      "test_probe" => probe,
      "file_probes" => file_probes,
      "broken_test_probe" => if(contract["model_tests"] == "behavioral", do: probe)
    }
  end

  defp coverage_passed?(%{"model_tests" => "preservation"}, probe, _detected, submission) do
    probe["passed"] and
      Enum.any?(probe["test_results"], fn {id, state} ->
        state == "passed" and submission["test_results"][id] == "passed"
      end)
  end

  defp coverage_passed?(_, _probe, detected, _), do: detected != []

  defp restore_tests(box) do
    paths = TaskContract.read(box.spec)["protected_paths"] |> Enum.map_join(" ", &Command.quote/1)
    # Restore tracked paths individually: a newly introduced test directory need
    # not exist at HEAD. Clean also removes newly added submitted/overlay tests.
    Sandbox.command!(
      box,
      "git reset -q HEAD -- #{paths} && git ls-tree -rz --name-only HEAD -- #{paths} | xargs -0 -r git restore --source=HEAD --staged --worktree -- && git clean -fd -- #{paths}"
    )
  end

  def qualify(id, run_id, emit) do
    runtime = Store.read("runtimes/#{id}.json")
    identity = qualification_identity(id, runtime)
    path = "qualifications/#{Eab.Cache.key(identity)}.json"
    Eab.Cache.locked({:qualification, path}, fn -> qualify(id, run_id, emit, identity, path) end)
  end

  def qualification_identity(id, runtime) do
    %{
      "runtime" => Map.take(runtime, ["image", "services", "baseline"]),
      "case" => Inventory.qualification_inputs(id),
      "grader" => Inventory.qualification_hash()
    }
  end

  defp qualify(id, run_id, emit, identity, path) do
    spec = Inventory.spec(id)
    contract = TaskContract.read(spec)
    cached = Store.read(path)

    if cached && cached["valid"] && cached["identity"] == identity do
      emit.("Reusing checked fixture for #{id}")
      Store.write("controls/#{id}.json", cached)
      cached
    else
      reason =
        cond do
          is_nil(cached) ->
            "no saved qualification"

          not cached["valid"] ->
            "previous qualification was invalid"

          get_in(cached, ["identity", "grader"]) != identity["grader"] ->
            "grading implementation changed"

          true ->
            "fixture or runtime identity changed"
        end

      emit.("Checking broken, reference, bypass and partial repairs for #{id}: #{reason}")

      reference =
        Inventory.file(id, "reference.patch") <>
          if(File.exists?(Inventory.case_path(id, "reference-tests.patch")),
            do: Inventory.file(id, "reference-tests.patch"),
            else: ""
          )

      emit.("Checking broken source for #{id}")
      empty = grade(id, "", run_id, coverage: false)
      emit.("Checking reference repair for #{id}")
      gold = grade(id, reference, run_id)

      halt =
        if spec["schema_version"] == 2 do
          Inventory.file(id, "integrity.patch")
        else
          "diff --git a/lib/eab_halt.ex b/lib/eab_halt.ex\nnew file mode 100644\n--- /dev/null\n+++ b/lib/eab_halt.ex\n@@ -0,0 +1 @@\n+System.halt(0)\n"
        end

      emit.("Checking early-exit rejection for #{id}")
      bypass = grade(id, reference <> halt, run_id, expected: gold)
      emit.("Checking partial-repair rejection for #{id}")
      partial = grade(id, partial_patch(id), run_id, expected: gold, coverage: false)

      valid =
        valid_controls?(contract, empty, gold, bypass, partial) and
          identity["grader"] == Inventory.qualification_hash()

      control = %{
        "valid" => valid,
        "identity" => identity,
        "empty_patch" => empty,
        "reference_patch" => gold,
        "early_exit" => bypass,
        "partial_repair" => partial
      }

      Store.write("controls/#{id}.json", control)
      Store.write(path, control)

      unless valid,
        do: raise("Fixture qualification failed for #{id}; see its saved control evidence")

      control
    end
  end

  def partial_patch(id) do
    if Inventory.spec(id)["schema_version"] == 2 do
      Inventory.file(id, "incomplete.patch")
    else
      legacy_partial_patch(id)
    end
  end

  def valid_controls?(contract, empty, gold, bypass, partial) do
    starting = contract["starting_failures"]
    empty_failures = behavioral_failures(empty["hidden"] || %{})
    partial_failures = behavioral_failures(partial["hidden"] || %{})
    starting_matches = starting == [] or Enum.sort(starting) == Enum.sort(empty_failures)
    incomplete_matches = starting == [] or Enum.any?(partial_failures, &(&1 in starting))
    preserved = contract["kind"] != "refactor" or get_in(empty, ["regression", "passed"]) == true
    bypass_executed = is_boolean(get_in(bypass, ["hidden", "completed"]))

    not empty["passed"] and get_in(empty, ["hidden", "completed"]) == true and
      empty_failures != [] and starting_matches and preserved and gold["passed"] and
      not bypass["passed"] and bypass_executed and
      get_in(partial, ["hidden", "completed"]) == true and
      partial_failures != [] and incomplete_matches
  end

  defp legacy_partial_patch(id) do
    patch = Inventory.file(id, "reference.patch")
    probe = Inventory.spec(id)["partial_repair_probe"]

    case probe["kind"] do
      "replace" ->
        unless length(String.split(patch, probe["before"])) - 1 == probe["occurrences"],
          do: raise("Partial-repair probe is stale")

        String.replace(patch, probe["before"], probe["after"])

      "file_only" ->
        [block] =
          String.split(patch, "diff --git ")
          |> Enum.drop(1)
          |> Enum.filter(&String.starts_with?(&1, "a/#{probe["path"]} b/#{probe["path"]}\n"))

        "diff --git " <> block

      _ ->
        raise "Missing partial-repair control"
    end
  end
end
