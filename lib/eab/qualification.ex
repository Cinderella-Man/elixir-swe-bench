defmodule Eab.Qualification do
  @moduledoc "Prepare and qualify the frozen inventory without a model or Pi calls."
  alias Eab.{
    Activity,
    AgentImage,
    Fixtures,
    Grader,
    Inventory,
    Pipeline,
    Preparation,
    Provenance,
    Release,
    Retention,
    Sandbox,
    Store
  }

  def run(emit \\ fn _ -> :ok end, opts \\ []) do
    release = Release.freeze()
    ids = release["protocol"]["inventory"]["cases"]
    id = Keyword.get(opts, :id, "qualification-#{System.system_time(:second)}")
    on_result = Keyword.get(opts, :on_result, fn _, _ -> :ok end)
    unless Store.valid_id?(id), do: raise("Invalid qualification job ID")

    job = %{
      "id" => id,
      "release" => release["id"],
      "cases" => ids,
      "kind" => "fixture_qualification"
    }

    Retention.lease(id)
    Store.write("jobs/#{id}/job.json", Map.put(job, "status", "running"))

    try do
      callbacks = %{
        baseline: fn case_id ->
          Activity.with_case(id, case_id, "", fn ->
            Release.verify!(release, case_id)
            progress(id, case_id, "preparing", emit)
            prepare_case(case_id, id, release["id"], emit)
          end)
        end,
        prepare: fn case_id ->
          Activity.with_case(id, case_id, "", fn ->
            Release.verify!(release, case_id)
            progress(id, case_id, "qualifying", emit)
            Grader.qualify(case_id, id, emit)
          end)
        end,
        workspace: fn _, use -> use.(:no_model_workspace) end,
        attempt: fn _, _, control -> control end,
        grade: fn case_id, control, _ ->
          %{"case" => case_id, "status" => "qualified", "valid" => control["valid"]}
        end,
        error: fn case_id, error ->
          %{"case" => case_id, "status" => "error", "error" => error}
        end,
        result: fn case_id, result ->
          Store.write("jobs/#{id}/#{case_id}.json", result)
          on_result.(case_id, result)

          emit.(
            "#{case_id}: #{result["status"]}" <>
              if(result["error"], do: " — #{result["error"]}", else: "")
          )
        end
      }

      pipeline =
        Application.get_env(:eab, :pipeline, [])
        |> Keyword.merge(Keyword.take(opts, [:lookahead, :preparation_workers]))
        |> Keyword.put(:preparation_plan, Preparation.plan(ids))

      results = Pipeline.run(ids, callbacks, pipeline)
      Release.verify!(release)
      status = if Enum.all?(results, &(&1["valid"] == true)), do: "qualified", else: "error"
      report = Map.merge(job, %{"status" => status, "results" => results})
      Store.write("jobs/#{id}/job.json", report)
      report
    rescue
      error ->
        Store.write(
          "jobs/#{id}/job.json",
          Map.merge(job, %{"status" => "error", "error" => Exception.message(error)})
        )

        reraise error, __STACKTRACE__
    after
      Pipeline.await_owner(self())
      Sandbox.cleanup(id)
      Retention.release(id)
    end
  end

  @doc """
  Everything a case needs before its first attempt. Attempts would otherwise attach Pi on
  first use, and that build runs npm, so a case prepared here can start with no internet.
  """
  def prepare_case(case_id, id, release_id, emit, opts \\ []) do
    attach_agent = Keyword.get(opts, :attach_agent, &AgentImage.ensure/2)
    images = Keyword.take(opts, [:image_exists?])
    Provenance.verify(case_id, emit, images)
    runtime = Fixtures.ensure(case_id, emit, [run_id: id] ++ images)
    Retention.retain(case_id, runtime, release_id)
    emit.("#{case_id}: attaching Pi")
    attach_agent.(Inventory.spec(case_id), runtime["image"])
    runtime
  end

  defp progress(id, case_id, status, emit) do
    Store.write("jobs/#{id}/#{case_id}.json", %{"case" => case_id, "status" => status})
    emit.("#{case_id}: #{status}")
  end
end
