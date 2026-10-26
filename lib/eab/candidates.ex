defmodule Eab.Candidates do
  @moduledoc "Immutable candidate bundles, recorded review and qualification before release admission."
  alias Eab.{Cache, Fixtures, Grader, Inventory, Provenance, Store, TaskContract}

  def import(directory) do
    files = File.ls!(directory) |> Enum.sort()

    unless files != [] and length(files) <= 64 and "admission.json" not in files and
             Enum.all?(files, fn file ->
               Path.basename(file) == file and Path.extname(file) in ~w(.json .md .patch) and
                 File.lstat!(Path.join(directory, file)).type == :regular and
                 File.stat!(Path.join(directory, file)).size <= 4_194_304
             end),
           do: raise("Candidates require bounded, flat regular fixture files")

    spec = Inventory.read_json(Path.join(directory, "case.json"))
    id = spec["id"]

    unless Store.valid_id?(id) and id not in Inventory.all() and spec["schema_version"] == 2,
      do:
        raise(
          "Import needs a new candidate ID and schema version 2; admitted cases are immutable"
        )

    Inventory.with_case(id, directory, fn -> validate!(id) end)
    hashes = Map.new(files, &{&1, Inventory.hash_file(Path.join(directory, &1))})
    version = Cache.key(hashes)
    ref = %{"id" => id, "version" => version}

    Cache.locked({:candidate, id}, fn ->
      for {file, hash} <- hashes do
        content = File.read!(Path.join(directory, file))
        unless Inventory.hash(content) == hash, do: raise("Candidate changed during import")
        Store.write_text("#{prefix(ref)}/files/#{file}", content)
      end

      record = Map.merge(ref, %{"files" => hashes, "schema" => 1})
      Store.write("#{prefix(ref)}/manifest.json", record)
      ref
    end)
  end

  def read!(ref) do
    record = Store.read("#{prefix(ref)}/manifest.json") || raise("Candidate is missing")

    unless record["id"] == ref["id"] and record["version"] == ref["version"] and
             Cache.key(record["files"]) == ref["version"],
           do: raise("Candidate record is corrupt")

    for {file, hash} <- record["files"] do
      unless Path.basename(file) == file and
               Inventory.hash_file(Store.path("#{prefix(ref)}/files/#{file}")) == hash,
             do: raise("Candidate files changed; import a new version")
    end

    record
  end

  def review(ref, review) do
    read!(ref)

    unless is_map(review) and review["decision"] in ~w(approve reject defer) and
             Enum.all?(
               ~w(author reviewer rationale),
               &(is_binary(review[&1]) and String.trim(review[&1]) != "")
             ) and
             review["author"] != review["reviewer"],
           do: raise("Record an independent reviewer and a reason")

    if review["decision"] == "approve" and
         (review["requirements_read_before_checks"] != true or
            review["assertion_mapping_checked"] != true),
       do: raise("Approval requires requirements-first review and assertion mapping verification")

    entry =
      Map.merge(review, %{
        "candidate" => ref,
        "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    Store.write("#{prefix(ref)}/reviews/#{Cache.key(entry)}.json", entry)
    Store.write("#{prefix(ref)}/review.json", entry)
    entry
  end

  def qualify(ref, emit, opts \\ []) do
    read!(ref)
    id = ref["id"]

    if id in Inventory.all(),
      do: raise("Admitted cases cannot be prepared through a candidate override")

    run_id = "candidate-#{id}"

    Cache.locked({:candidate, id}, fn ->
      Eab.Retention.lease(run_id)

      try do
        Inventory.with_case(id, Store.path("#{prefix(ref)}/files"), fn ->
          validate!(id)

          try do
            stage(ref, "checking_source", emit)
            source = Provenance.verify(id, emit, opts)
            stage(ref, "preparing", emit)
            runtime = Fixtures.ensure(id, emit, Keyword.put(opts, :run_id, run_id))
            stage(ref, "qualifying", emit)
            controls = Grader.qualify(id, run_id, emit)

            proof = %{
              "candidate" => ref,
              "source" => source,
              "runtime" => runtime,
              "controls" => controls,
              "grader" => Inventory.qualification_hash()
            }

            Store.write(
              "#{prefix(ref)}/qualification.json",
              Map.put(proof, "checksum", Cache.key(proof))
            )

            stage(ref, "qualified", emit)
            proof
          rescue
            error ->
              Store.write("#{prefix(ref)}/job.json", %{
                "status" => "error",
                "error" => Exception.message(error)
              })

              reraise error, __STACKTRACE__
          end
        end)
      after
        Eab.Sandbox.cleanup(run_id)
        Eab.Retention.release(run_id)
      end
    end)
  end

  # Export a reviewable admission bundle. Placing it under cases/ activates it;
  # importing a candidate never changes the runnable folders.
  def export(ref, destination) do
    record = read!(ref)

    review =
      Store.read("#{prefix(ref)}/review.json") || raise("Candidate needs independent review")

    proof =
      Store.read("#{prefix(ref)}/qualification.json") ||
        raise("Candidate needs executable qualification")

    validate_evidence!(ref, review, proof)

    unless proof["grader"] == Inventory.qualification_hash(),
      do: raise("Admission needs qualification under the current grader")

    unless not File.exists?(destination), do: raise("Admission destination already exists")
    File.mkdir_p!(destination)

    for {file, _} <- record["files"],
        do: File.cp!(Store.path("#{prefix(ref)}/files/#{file}"), Path.join(destination, file))

    admission = %{
      "candidate" => ref,
      "files" => record["files"],
      "review" => review,
      "qualification" => proof
    }

    File.write!(Path.join(destination, "admission.json"), Jason.encode!(admission, pretty: true))
    admission
  end

  def verify_admission!(id) do
    proof = Inventory.read_json(Inventory.case_path(id, "admission.json"))
    files = Inventory.fixture_hashes(id) |> Map.delete("admission.json")
    ref = proof["candidate"]

    unless is_map(ref) and ref["id"] == id and ref["version"] == Cache.key(files) and
             files == proof["files"],
           do: raise("Admission does not match the case files")

    # The recorded grader is history. Runs re-qualify every case under the
    # current grader before any attempt, so grader changes never edit cases.
    validate_evidence!(ref, proof["review"], proof["qualification"])
    :ok
  end

  defp validate_evidence!(ref, review, proof) do
    unless is_map(review) and is_map(proof) and review["candidate"] == ref and
             review["decision"] == "approve" and review["author"] != review["reviewer"] and
             review["requirements_read_before_checks"] == true and
             review["assertion_mapping_checked"] == true and
             proof["candidate"] == ref and
             proof["checksum"] == Cache.key(Map.delete(proof, "checksum")) and
             get_in(proof, ["source", "verified"]) == true and
             get_in(proof, ["controls", "valid"]) == true and
             is_binary(proof["grader"]),
           do: raise("Admission needs matching source, review and qualification evidence")
  end

  defp validate!(id) do
    spec = Inventory.spec(id)
    contract = TaskContract.read(spec)
    Provenance.validate!(spec, Inventory.read_json(Inventory.case_path(id, "provenance.json")))

    for file <-
          ~w(ticket.md reference.patch reference-tests.patch acceptance.patch incomplete.patch integrity.patch) do
      unless File.regular?(Inventory.case_path(id, file)),
        do: raise("Missing candidate artifact: #{file}")
    end

    unless spec["acceptance_patch"] == "acceptance.patch",
      do: raise("Use the protected acceptance.patch artifact")

    for command <- [contract["acceptance"], contract["preservation"]],
        do: Eab.TestAdapter.command(contract["adapter"], command, [])

    for file <- ~w(reference-tests.patch acceptance.patch) do
      unless Grader.validate_patch(Inventory.file(id, file), %{
               "allowed_edit_prefixes" => contract["protected_paths"]
             }) == {:ok, []},
             do: raise("#{file} must only change protected test paths")
    end

    for file <- ~w(reference.patch incomplete.patch) do
      unless match?({:ok, _}, Grader.validate_patch(Inventory.file(id, file), spec)),
        do: raise("#{file} violates the allowed edit paths")
    end

    :ok
  end

  defp stage(ref, status, emit) do
    Store.write("#{prefix(ref)}/job.json", %{"status" => status})
    emit.("Candidate #{ref["id"]}: #{status}")
  end

  defp prefix(%{"id" => id, "version" => version}) do
    unless Store.valid_id?(id) and is_binary(version) and
             Regex.match?(~r/^[a-f0-9]{64}$/, version),
           do: raise("Invalid candidate reference")

    "candidates/#{id}/#{version}"
  end
end
