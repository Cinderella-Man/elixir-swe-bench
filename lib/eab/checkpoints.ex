defmodule Eab.Checkpoints do
  @moduledoc "Identity-bound submissions and completion receipts, with preserved interrupted generations."
  alias Eab.{Cache, Inventory, Release, Store}

  def identity(run_id, id) do
    run = Store.read("runs/#{run_id}/run.json") || raise "Run record is missing"
    unless id in run["cases"], do: raise("Case is outside the frozen run")

    %{
      "experiment_id" => run["experiment_id"],
      "generation" => get_in(run, ["generations", id]) || 1
    }
  end

  def submit(run_id, id, record, patch, key) do
    prefix = "runs/#{run_id}/#{id}"
    record = Map.merge(record, identity(run_id, id)) |> Map.put("status", "submitted")
    Store.write_text("#{prefix}/model.patch", patch, key)
    Store.write("#{prefix}/attempt.json", record, key)

    receipt = %{
      "identity" => Map.take(record, ~w(experiment_id generation)),
      "patch_hash" => Inventory.hash_file(Store.path("#{prefix}/model.patch")),
      "environment" => environment(prefix),
      "record" => Store.scrub(record, key)
    }

    seal("#{prefix}/submission.json", receipt)
    {record, Store.redact(patch, key)}
  end

  def complete(run_id, id, record, key) do
    prefix = "runs/#{run_id}/#{id}"
    run = Store.read("runs/#{run_id}/run.json")
    unless match?({:ok, _}, submission(run, id)), do: raise("No verified submission to complete")
    record = Store.scrub(record, key)
    Store.write("#{prefix}/attempt.json", record)

    seal("runs/#{run_id}/checkpoints/#{id}.json", %{
      "experiment_id" => run["experiment_id"],
      "record" => record,
      "submission_hash" => Inventory.hash_file(Store.path("#{prefix}/submission.json")),
      "grade_hash" => Inventory.hash_file(Store.path("#{prefix}/grade.json"))
    })

    record
  end

  def submission(run, id) do
    prefix = "runs/#{run["id"]}/#{id}"

    case unseal("#{prefix}/submission.json") do
      nil ->
        :none

      receipt ->
        unless receipt["identity"] == %{
                 "experiment_id" => run["experiment_id"],
                 "generation" => get_in(run, ["generations", id]) || 1
               } and
                 receipt["identity"] == Map.take(receipt["record"], ~w(experiment_id generation)) and
                 receipt["environment"] == environment(prefix) and
                 receipt["patch_hash"] == Inventory.hash_file(Store.path("#{prefix}/model.patch")),
               do: raise("Saved submission identity, environment or patch changed: #{id}")

        {:ok, {receipt["record"], File.read!(Store.path("#{prefix}/model.patch"))}}
    end
  end

  def completed(run, id) do
    case unseal("runs/#{run["id"]}/checkpoints/#{id}.json") do
      nil ->
        nil

      receipt ->
        prefix = "runs/#{run["id"]}/#{id}"
        record = receipt["record"]

        unless receipt["experiment_id"] == run["experiment_id"] and
                 record["experiment_id"] == run["experiment_id"] and
                 record["status"] == "completed" and
                 is_boolean(get_in(record, ["grade", "passed"])) and
                 receipt["submission_hash"] ==
                   Inventory.hash_file(Store.path("#{prefix}/submission.json")) and
                 receipt["grade_hash"] == Inventory.hash_file(Store.path("#{prefix}/grade.json")),
               do: raise("Completion evidence is missing or changed: #{id}")

        submission(run, id)
        record
    end
  end

  def validate_run!(run, endpoint, settings) do
    unless run["experiment_id"] && run["release_id"],
      do: raise("This historical run has no sealed checkpoints; start a new run")

    release = Release.read!(run["release_id"])
    Release.verify!(release)
    validate_cases!(run, release)

    unless run["protocol"] == release["protocol"] and
             run["experiment_id"] ==
               Release.experiment(
                 run["release_id"],
                 run["model"],
                 run["settings"],
                 run["selection"]
               ) and
             run["experiment_id"] ==
               Release.experiment(run["release_id"], endpoint, settings, run["selection"]),
           do: raise("Release, model or settings differ; start a new run")

    :ok
  end

  def validate_cases!(run, release) do
    inventory = release["protocol"]["inventory"]["cases"]
    cases = run["cases"]

    valid =
      case run["selection"] do
        nil ->
          cases == inventory

        %{"kind" => kind, "cases" => ^cases, "source_run" => source}
        when kind in ["error_retry", "case_repeat"] ->
          Store.valid_id?(source) and is_list(cases) and cases != [] and
            Enum.filter(inventory, &(&1 in cases)) == cases

        # Unscored single-case harness checks (ADR 0010).
        %{"kind" => kind, "cases" => [id] = ^cases} when kind in ["dry_attempt", "escape_test"] ->
          id in inventory

        _ ->
          false
      end

    unless valid, do: raise("Run cases differ from the frozen selection")
    :ok
  end

  def plan(run) do
    Enum.reduce(run["cases"], %{retained: %{}, submissions: %{}, restart: []}, fn id, plan ->
      record = Store.read("runs/#{run["id"]}/#{id}/attempt.json", get_in(run, ["attempts", id]))
      complete = completed(run, id)

      cond do
        complete ->
          %{plan | retained: Map.put(plan.retained, id, complete)}

        record && record["status"] == "completed" ->
          raise "Completed case has no valid checkpoint: #{id}"

        record && record["status"] == "error" ->
          %{plan | retained: Map.put(plan.retained, id, record)}

        true ->
          case submission(run, id) do
            {:ok, submission} -> %{plan | submissions: Map.put(plan.submissions, id, submission)}
            :none -> %{plan | restart: plan.restart ++ [id]}
          end
      end
    end)
  end

  def archive_unfinished(run, ids) do
    Enum.reduce(ids, run, fn id, run ->
      source = Store.path("runs/#{run["id"]}/#{id}")
      generation = get_in(run, ["generations", id]) || 1
      target = "runs/#{run["id"]}/prior-attempts/#{id}/#{generation}"

      if File.dir?(source) do
        if File.exists?(Store.path(target)),
          do: raise("Archived generation already exists: #{id}")

        File.mkdir_p!(Path.dirname(Store.path(target)))
        File.rename!(source, Store.path(target))
      end

      # A crash after the rename but before the run record update is recovered
      # from the same generation directory, never by overwriting its evidence.
      if File.dir?(Store.path(target)) do
        record = Store.read("#{target}/attempt.json", %{})
        progress = Store.read("#{target}/agent-progress.json", %{})

        history =
          Map.merge(record, progress)
          |> Map.take(~w(status calls generated_tokens stop_reason error))

        entry =
          Map.merge(history, %{
            "case" => id,
            "generation" => generation,
            "artifacts" => String.replace_prefix(target, "runs/#{run["id"]}/", "")
          })

        run
        |> Map.put("attempt_history", (run["attempt_history"] || []) ++ [entry])
        |> Map.put("generations", Map.put(run["generations"] || %{}, id, generation + 1))
      else
        run
      end
    end)
  end

  def bind_runtime!(run_id, id, runtime) do
    path = "runs/#{run_id}/#{id}/runtime.json"
    previous = Store.read(path)
    fields = ~w(image services baseline fixture_hashes source_receipt)

    if previous && Map.take(previous, fields) != Map.take(runtime, fields),
      do: raise("Prepared environment changed within this run: #{id}; start a new run")

    Store.write(path, runtime)
  end

  defp seal(path, payload),
    do:
      Store.write(path, %{"version" => 1, "checksum" => Cache.key(payload), "payload" => payload})

  defp environment(prefix) do
    runtime = Store.read("#{prefix}/runtime.json") || raise "Submission has no saved environment"
    Map.take(runtime, ~w(image services baseline fixture_hashes source_receipt))
  end

  defp unseal(path) do
    case Store.read(path) do
      nil ->
        nil

      %{"version" => 1, "checksum" => checksum, "payload" => payload} ->
        unless Cache.key(payload) == checksum, do: raise("Checkpoint checksum mismatch: #{path}")
        payload

      _ ->
        raise "Invalid checkpoint: #{path}"
    end
  end
end
