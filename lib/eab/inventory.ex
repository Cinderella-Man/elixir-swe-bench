defmodule Eab.Inventory do
  def root, do: Application.fetch_env!(:eab, :root)
  def path(relative), do: Path.join(root(), relative)
  def read_json(path), do: path |> File.read!() |> Jason.decode!()

  def definition do
    config = read_json(path("config/benchmark.json"))

    present =
      path("cases/*/case.json")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&(Path.dirname(&1) |> Path.basename()))

    # The configured list preserves historical ordering; folders determine
    # membership, including new cases that have never appeared in that list.
    ordered = Enum.filter(config["cases"] || [], &(&1 in present))
    Map.put(config, "cases", ordered ++ Enum.sort(present -- ordered))
  end

  def all, do: definition()["cases"]

  @doc """
  The benchmark's speed cases, in inventory order (ADR 0020). They live apart from
  `config/benchmark.json` so that naming them does not change the frozen release.
  """
  def speed_cases(definition \\ definition()) do
    config = read_json(path("config/speed-cases.json"))
    cases = config["cases"]

    unless config["benchmark"] == definition["id"],
      do:
        raise(
          ArgumentError,
          "The speed cases name another benchmark; update config/speed-cases.json"
        )

    unless is_list(cases) and cases != [] and
             Enum.filter(definition["cases"], &(&1 in cases)) == cases,
           do: raise(ArgumentError, "Speed cases must be current cases, in inventory order")

    cases
  end

  def spec(id) do
    unless Process.get({__MODULE__, id}) || id in all(),
      do: raise(ArgumentError, "Unknown benchmark case")

    read_json(case_path(id, "case.json"))
  end

  def case_path(id, file),
    do: Path.join(Process.get({__MODULE__, id}) || path("cases/#{id}"), file)

  # Candidate qualification uses the same evaluator without adding the case to
  # the published inventory. Overrides are scoped to this process and restored
  # even on failure; model workers never inherit candidate files.
  def with_case(id, directory, fun) do
    key = {__MODULE__, id}
    previous = Process.put(key, Path.expand(directory))

    try do
      fun.()
    after
      if previous, do: Process.put(key, previous), else: Process.delete(key)
    end
  end

  def file(id, file), do: File.read!(case_path(id, file))

  def hash_file(path) do
    file = File.open!(path, [:read, :binary, :raw])

    try do
      hash_chunks(file, :crypto.hash_init(:sha256), path)
      |> Base.encode16(case: :lower)
    after
      File.close(file)
    end
  end

  defp hash_chunks(file, state, path) do
    case :file.read(file, 1_048_576) do
      {:ok, bytes} -> hash_chunks(file, :crypto.hash_update(state, bytes), path)
      :eof -> :crypto.hash_final(state)
      {:error, reason} -> raise File.Error, reason: reason, action: "hash", path: path
    end
  end

  def hash(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  def fixture_hashes(id) do
    Path.wildcard(case_path(id, "*"))
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.basename(&1), hash_file(&1)})
  end

  def implementation_hash do
    files =
      Path.wildcard(path("lib/**/*.ex")) ++
        Enum.filter(Path.wildcard(path("priv/pi/*")), &File.regular?/1) ++
        [path("mix.lock")] ++ Path.wildcard(path("priv/fixtures/**/*.{exs,mjs,json}"))

    files
    |> Enum.sort()
    |> Enum.map_join(fn p -> Path.relative_to(p, root()) <> hash_file(p) end)
    |> hash()
  end

  def qualification_hash do
    # Agent, endpoint and presentation changes cannot change fixture controls.
    # Runtime image identities independently invalidate controls after rebuilds.
    files = ~w(command grader inventory sandbox task_contract test_adapter)

    (Enum.map(files, &path("lib/eab/#{&1}.ex")) ++
       [
         path("mix.lock"),
         path("priv/fixtures/grade_formatter.exs"),
         path("priv/fixtures/node_runner.mjs")
       ])
    |> Enum.sort()
    |> Enum.map_join(fn p -> Path.relative_to(p, root()) <> hash_file(p) end)
    |> hash()
  end

  def qualification_inputs(id) do
    spec = spec(id)
    # Admission and exact-upstream reconstruction do not execute in the grader.
    # They still bind the release and are verified before a baseline is used.
    # An explicitly selected acceptance patch is executable regardless of name.
    audit_files =
      ~w(case.json ticket.md provenance.json admission.json upstream-tests.patch upstream-docs.patch) --
        [spec["acceptance_patch"]]

    %{
      # Unknown future manifest fields invalidate controls by default. Only
      # known descriptive fields and inputs already covered by the images are
      # excluded; a new grading rule must never silently reuse old controls.
      "contract" =>
        Map.drop(spec, ~w(id title family suite project domains repository runtime services
          clarifications source_inspiration)),
      "before_test_commands" => spec["runtime"]["before_test_commands"] || [],
      "files" => Map.drop(fixture_hashes(id), audit_files)
    }
  end

  def protocol do
    %{
      "inventory" => definition(),
      "agent" => Eab.Pi.identity(),
      "implementation" => implementation_hash(),
      "fixtures" => Map.new(all(), &{&1, fixture_hashes(&1)})
    }
  end
end
