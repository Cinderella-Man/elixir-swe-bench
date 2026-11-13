defmodule Eab.TaskGradingDockerTest do
  use ExUnit.Case, async: false
  @moduletag :docker
  @moduletag timeout: 240_000
  alias Eab.{Command, Grader, Inventory, Store}

  test "feature and refactor grading reject no-ops, incomplete solutions and early exits while accepting alternatives" do
    previous = Store.root()
    root = Path.join(System.tmp_dir!(), "eab-task-grade-#{System.unique_integer([:positive])}")
    Application.put_env(:eab, :data_dir, root)
    tag = "elixir-agent-benchmark:synthetic-contract-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Eab.Sandbox.cleanup("synthetic-contract")
      Command.run("docker", ["image", "rm", tag])
      Application.put_env(:eab, :data_dir, previous)
      File.rm_rf!(root)
    end)

    source = Path.join(root, "context/source")
    File.mkdir_p!(Path.join(source, "lib"))
    File.mkdir_p!(Path.join(source, "test"))

    original =
      "import './exit.mjs';\nexport const existing = () => 3;\nexport const twice = null;\n"

    File.write!(Path.join(source, "lib/app.mjs"), original)
    File.write!(Path.join(source, "lib/exit.mjs"), "// trusted starting source\n")

    test =
      "import test from 'node:test';\nimport assert from 'node:assert/strict';\nimport {existing, twice} from '../lib/app.mjs';\n"

    File.write!(
      Path.join(source, "test/original.mjs"),
      test <> "test('preserve', () => assert.equal(existing(), 3));\n"
    )

    for args <- [
          ["init", "--quiet"],
          ["config", "user.name", "Synthetic"],
          ["config", "user.email", "test@localhost"],
          ["add", "."],
          ["commit", "--quiet", "-m", "Baseline"]
        ],
        do: Command.run!("git", args, cd: source)

    patch = fn files ->
      for {file, contents} <- files, do: File.write!(Path.join(source, file), contents)
      Command.run!("git", ["add", "--all"], cd: source)
      diff = Command.run!("git", ["diff", "--cached", "--binary", "HEAD"], cd: source)
      Command.run!("git", ["restore", "--source=HEAD", "--staged", "--worktree", "."], cd: source)
      Command.run!("git", ["clean", "-fd"], cd: source)
      diff
    end

    reference = patch.([{"lib/app.mjs", String.replace(original, "null", "n => n * 2")}])
    alternative = patch.([{"lib/app.mjs", String.replace(original, "null", "n => n + n")}])

    incomplete =
      patch.([{"lib/app.mjs", String.replace(original, "null", "n => Math.abs(n) * 2")}])

    reference_tests =
      patch.([
        {"test/new.mjs",
         test <>
           "test('new capability', () => { assert.equal(typeof twice, 'function'); assert.equal(twice(3), 6); });\n"}
      ])

    acceptance =
      patch.([
        {"test/acceptance.mjs",
         test <>
           "test('positive', () => { assert.equal(typeof twice, 'function'); assert.equal(twice(2), 4); });\ntest('negative', () => { assert.equal(typeof twice, 'function'); assert.equal(twice(-2), -4); });\n"}
      ])

    integrity = patch.([{"lib/exit.mjs", "process.exit(0);\n"}])

    File.write!(Path.join(root, "context/Dockerfile"), """
    FROM eab-tooling:dev
    ENV PATH=/opt/pi:$PATH HOME=/tmp
    WORKDIR /workspace
    COPY --chown=65534:65534 source/ /workspace/
    RUN chown -R 65534:65534 /workspace
    USER 65534:65534
    CMD ["sleep", "infinity"]
    """)

    Command.run!(
      "docker",
      ["build", "--network=none", "--provenance=false", "-t", tag, Path.join(root, "context")],
      timeout: 180
    )

    image =
      Command.run!("docker", ["image", "inspect", tag, "--format", "{{.Id}}"]) |> String.trim()

    for kind <- ~w(feature refactor) do
      id = "synthetic-#{kind}"
      directory = Path.join(root, id)
      File.mkdir_p!(directory)
      required = ["test/acceptance.mjs::positive", "test/acceptance.mjs::negative"]

      spec = %{
        "id" => id,
        "schema_version" => 2,
        "task_kind" => kind,
        "test_timeout" => 15,
        "runtime" => %{},
        "allowed_edit_prefixes" => ["lib/", "test/"],
        "acceptance_patch" => "acceptance.patch",
        "grading" => %{
          "adapter" => "node",
          "acceptance" => "node --test test/acceptance.mjs",
          "preservation" => "node --test test/original.mjs",
          "protected_paths" => ["test/"],
          "test_suffixes" => [".mjs"],
          "model_tests" => if(kind == "refactor", do: "preservation", else: "behavioral"),
          "required" => required,
          "starting_failures" => required,
          "requirements" => [
            %{
              "id" => "api",
              "text" => "Expose twice as a function.",
              "kind" => if(kind == "refactor", do: "structural", else: "behavior"),
              "checks" => required
            }
          ]
        }
      }

      for {file, contents} <- [
            {"case.json", Jason.encode!(spec)},
            {"reference.patch", reference},
            {"reference-tests.patch", reference_tests},
            {"acceptance.patch", acceptance},
            {"integrity.patch", integrity},
            {"incomplete.patch", incomplete}
          ],
          do: File.write!(Path.join(directory, file), contents)

      Inventory.with_case(id, directory, fn ->
        Store.write("runtimes/#{id}.json", %{
          "image" => image,
          "services" => %{},
          "fixture_hashes" => Inventory.fixture_hashes(id)
        })

        control =
          try do
            Grader.qualify(id, "synthetic-contract", fn _ -> :ok end)
          rescue
            error ->
              saved = Store.read("controls/#{id}.json")

              flunk(
                Exception.message(error) <>
                  "\n" <> inspect(saved, limit: :infinity, printable_limit: :infinity)
              )
          end

        assert control["valid"], inspect(control)

        assert Grader.grade(id, alternative <> reference_tests, "synthetic-contract",
                 expected: control["reference_patch"]
               )["passed"]

        refute Grader.grade(id, reference, "synthetic-contract",
                 expected: control["reference_patch"]
               )["passed"]

        # A stray file outside the edit area is discarded; the rest is graded as before.
        stray =
          "diff --git a/out.log b/out.log\nnew file mode 100644\n--- /dev/null\n+++ b/out.log\n@@ -0,0 +1 @@\n+noise\n"

        graded =
          Grader.grade(id, alternative <> reference_tests <> stray, "synthetic-contract",
            expected: control["reference_patch"]
          )

        assert graded["passed"]
        assert graded["discarded_files"] == ["out.log"]
      end)
    end
  end
end
