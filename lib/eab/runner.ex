defmodule Eab.Runner do
  alias Eab.{
    Activity,
    Agent,
    Checkpoints,
    Fixtures,
    Grader,
    Model,
    Pipeline,
    Preparation,
    Provenance,
    Release,
    Sandbox,
    Store
  }

  def execute(run, key, emit, opts \\ []) do
    endpoint = run["model"]
    check_model = Keyword.get(opts, :check_model, &Model.unchanged!/2)
    prepare_case = Keyword.get(opts, :prepare, &prepare/4)
    baseline = Keyword.get(opts, :baseline, &baseline/4)

    workspace =
      Keyword.get(opts, :workspace, fn id, run_id, use ->
        Sandbox.with_box(id, run_id, use, agent: true)
      end)

    submit = Keyword.get(opts, :submit, &Agent.submit/7)
    grade = Keyword.get(opts, :grade, &Agent.grade/7)
    check_model.(endpoint, key)
    release = Release.read!(run["release_id"])
    Release.verify!(release)
    recovery = Checkpoints.plan(run)
    pending = Enum.reject(run["cases"], &Map.has_key?(recovery.retained, &1))

    context = fn id, fun -> Activity.with_case(run["id"], id, key, fun) end
    agent = Eab.Harness.agent(run)

    callbacks = %{
      baseline: fn id ->
        context.(id, fn ->
          verify!(release, endpoint, key, id, check_model)
          baseline.(run, id, key, emit)
        end)
      end,
      prepare: fn id ->
        context.(id, fn ->
          verify!(release, endpoint, key, id, check_model)
          prepare_case.(run, id, key, emit)
        end)
      end,
      workspace: fn id, use ->
        context.(id, fn ->
          if Map.has_key?(recovery.submissions, id) do
            use.(:saved_submission)
          else
            progress(emit, "warming", id, "Starting workspace and services for #{id}")

            workspace.(
              id,
              run["id"],
              fn box ->
                progress(emit, "warm", id, "Workspace ready for #{agent}")
                use.(box)
              end
            )
          end
        end)
      end,
      attempt: fn id, box, _control ->
        verify!(release, endpoint, key, id, check_model)

        submission =
          case Map.fetch(recovery.submissions, id) do
            {:ok, submission} ->
              submission

            :error ->
              progress(emit, "running", id, "Starting #{agent} for #{id}")

              submit.(
                id,
                run["id"],
                box,
                endpoint,
                key,
                run["settings"],
                &progress(emit, "running", id, &1)
              )
          end

        progress(emit, "submitted", id, "Submission saved; waiting for grading")
        submission
      end,
      grade: fn id, submission, control ->
        context.(id, fn ->
          verify!(release, endpoint, key, id, check_model)

          grade.(
            id,
            run["id"],
            submission,
            endpoint,
            key,
            control,
            &progress(emit, "grading", id, &1)
          )
        end)
      end,
      error: fn id, message ->
        context.(id, fn -> Agent.error(id, run["id"], message, key) end)
      end,
      result: fn id, result -> emit.(%{"case_result" => {id, result}}) end
    }

    pipeline_opts =
      Application.get_env(:eab, :pipeline, [])
      |> Keyword.put(:preparation_plan, Preparation.plan(pending))
      |> Keyword.put(:parallel, run["parallel_attempts"] || 1)

    results = Pipeline.run(pending, callbacks, pipeline_opts)

    verify!(release, endpoint, key, nil, check_model)

    if Enum.all?(results ++ Map.values(recovery.retained), &(&1["status"] == "completed")),
      do: :ok,
      else: {:error, "One or more cases could not be evaluated. See their saved errors."}
  end

  defp baseline(run, id, key, emit) do
    progress(emit, "preparing", id, "Preparing #{id}")

    try do
      Provenance.verify(id, &progress(emit, "preparing", id, &1))
      runtime = Fixtures.ensure(id, &progress(emit, "preparing", id, &1), run_id: run["id"])
      Eab.Retention.retain(id, runtime, run["release_id"])
      Checkpoints.bind_runtime!(run["id"], id, runtime)
      progress(emit, "prepared", id, "Pristine baseline saved for #{id}; fixture checks pending")
      runtime
    rescue
      error ->
        Activity.note("ERROR: " <> Exception.message(error))
        reraise error, __STACKTRACE__
    after
      for {source, target} <- [
            {(Store.read("runtimes/#{id}.json") || %{})["build_log"] || "build/#{id}/build.log",
             "build.log"}
          ] do
        case File.read(Store.path(source)) do
          {:ok, content} -> Store.write_text("runs/#{run["id"]}/#{id}/#{target}", content, key)
          _ -> :ok
        end
      end
    end
  end

  defp prepare(run, id, key, emit) do
    try do
      control = Grader.qualify(id, run["id"], &progress(emit, "qualifying", id, &1))
      progress(emit, "ready", id, "Image and fixture checks ready for #{id}")
      control
    after
      case File.read(Store.path("controls/#{id}.json")) do
        {:ok, content} ->
          Store.write_text("runs/#{run["id"]}/#{id}/qualification.json", content, key)

        _ ->
          :ok
      end
    end
  end

  defp progress(emit, phase, id, message) do
    Activity.note(message)
    emit.(%{"case_phase" => %{"case" => id, "phase" => phase, "message" => message}})
  end

  defp verify!(release, endpoint, key, id, check_model) do
    Release.verify!(release, id)
    check_model.(endpoint, key)
  end

  def breakdowns(run) do
    for field <- ~w(project task_kind),
        {value, ids} <-
          Enum.group_by(
            run["cases"],
            &(get_in(run, ["case_metadata", &1, field]) || "Not recorded")
          ),
        do:
          Map.merge(score(Map.put(run, "cases", ids)), %{"dimension" => field, "value" => value})
  end

  def score(run) do
    attempts = Enum.map(run["cases"], &get_in(run, ["attempts", &1]))

    passed =
      Enum.count(
        attempts,
        &(is_map(&1) and &1["status"] == "completed" and get_in(&1, ["grade", "passed"]) == true)
      )

    failed =
      Enum.count(
        attempts,
        &(is_map(&1) and &1["status"] == "completed" and get_in(&1, ["grade", "passed"]) == false)
      )

    total = length(attempts)

    complete =
      total > 0 and passed + failed == total and run["status"] == "completed" and
        is_nil(run["selection"])

    %{
      "passed" => passed,
      "failed" => failed,
      "pending_or_error" => total - passed - failed,
      "planned" => total,
      "score_percent" => if(complete, do: Float.round(100 * passed / total, 2), else: nil)
    }
  end
end
