defmodule Eab.CandidatesTest do
  use ExUnit.Case, async: false
  alias Eab.{Cache, Candidates, Inventory, Store}

  setup do
    old = Store.root()
    root = Path.join(System.tmp_dir!(), "eab-candidate-#{System.unique_integer([:positive])}")
    Application.put_env(:eab, :data_dir, root)
    directory = Path.join(root, "draft")
    File.mkdir_p!(directory)
    spec = Inventory.spec("livebook-pr-2219")

    contract = %{
      "adapter" => "exunit",
      "acceptance" => "mix test test/acceptance_test.exs",
      "preservation" => "mix test test/original_test.exs",
      "protected_paths" => ["test/"],
      "test_suffixes" => ["_test.exs"],
      "required" => ["named assertion"],
      "starting_failures" => ["named assertion"],
      "model_tests" => "behavioral",
      "requirements" => [
        %{
          "id" => "outcome",
          "text" => "Provide the requested capability.",
          "kind" => "behavior",
          "checks" => ["named assertion"]
        }
      ]
    }

    spec =
      Map.merge(spec, %{
        "id" => "synthetic-candidate",
        "schema_version" => 2,
        "task_kind" => "feature",
        "grading" => contract
      })

    File.write!(Path.join(directory, "case.json"), Jason.encode!(spec))

    File.cp!(
      Inventory.case_path("livebook-pr-2219", "provenance.json"),
      Path.join(directory, "provenance.json")
    )

    for file <-
          ~w(reference.patch reference-tests.patch acceptance.patch incomplete.patch integrity.patch),
        do: File.write!(Path.join(directory, file), "")

    File.write!(Path.join(directory, "ticket.md"), "Synthetic contract, never admitted.")

    on_exit(fn ->
      Application.put_env(:eab, :data_dir, old)
      File.rm_rf!(root)
    end)

    %{directory: directory, root: root}
  end

  test "import stays outside inventory and changed artifacts require another version", %{
    directory: directory
  } do
    ids = Inventory.all()
    ref = Candidates.import(directory)
    assert Candidates.read!(ref)["id"] == "synthetic-candidate"
    assert Inventory.all() == ids
    assert_raise ArgumentError, fn -> Inventory.spec("synthetic-candidate") end
    File.write!(Path.join(directory, "ticket.md"), "Changed contract")
    next = Candidates.import(directory)
    refute next == ref

    assert Candidates.read!(ref)["files"]["ticket.md"] !=
             Candidates.read!(next)["files"]["ticket.md"]
  end

  test "review and source/execution evidence are separate admission gates", %{
    directory: directory,
    root: root
  } do
    ref = Candidates.import(directory)

    review = %{
      "author" => "curator",
      "reviewer" => "reviewer",
      "rationale" => "Synthetic evidence check",
      "decision" => "approve",
      "requirements_read_before_checks" => true,
      "assertion_mapping_checked" => true
    }

    assert_raise RuntimeError, fn ->
      Candidates.review(ref, Map.put(review, "reviewer", "curator"))
    end

    assert_raise RuntimeError, fn ->
      Candidates.review(ref, Map.delete(review, "assertion_mapping_checked"))
    end

    Candidates.review(ref, review)

    assert_raise RuntimeError, ~r/executable qualification/, fn ->
      Candidates.export(ref, Path.join(root, "export"))
    end

    # Synthetic receipts exercise identity gates only; no real candidate is qualified.
    proof = %{
      "candidate" => ref,
      "source" => %{"verified" => true},
      "controls" => %{"valid" => true},
      "grader" => Inventory.qualification_hash()
    }

    path = "candidates/#{ref["id"]}/#{ref["version"]}/qualification.json"
    destination = Path.join(root, "export")
    stale = Map.put(proof, "grader", "earlier")
    Store.write(path, Map.put(stale, "checksum", Cache.key(stale)))

    assert_raise RuntimeError, ~r/current grader/, fn ->
      Candidates.export(ref, destination)
    end

    Store.write(path, Map.put(proof, "checksum", Cache.key(proof)))
    Candidates.export(ref, destination)

    assert :ok ==
             Inventory.with_case(ref["id"], destination, fn ->
               Candidates.verify_admission!(ref["id"])
             end)

    # A later grader change leaves the admitted grader as history only.
    admission_path = Path.join(destination, "admission.json")
    admission = Jason.decode!(File.read!(admission_path))
    recorded = Map.put(admission["qualification"], "grader", "earlier") |> Map.delete("checksum")
    recorded = Map.put(recorded, "checksum", Cache.key(recorded))
    File.write!(admission_path, Jason.encode!(%{admission | "qualification" => recorded}))

    assert :ok ==
             Inventory.with_case(ref["id"], destination, fn ->
               Candidates.verify_admission!(ref["id"])
             end)

    File.write!(Path.join(destination, "ticket.md"), "Edited after review")

    assert_raise RuntimeError, ~r/match the case files/, fn ->
      Inventory.with_case(ref["id"], destination, fn ->
        Candidates.verify_admission!(ref["id"])
      end)
    end

    assert_raise ArgumentError, fn -> Inventory.spec(ref["id"]) end
  end

  test "candidate context is restored on exceptions", %{directory: directory} do
    assert_raise RuntimeError, fn ->
      Inventory.with_case("synthetic-candidate", directory, fn -> raise "cancelled" end)
    end

    assert_raise ArgumentError, fn -> Inventory.spec("synthetic-candidate") end
  end
end
