defmodule Eab.Provenance do
  @moduledoc "Verify both upstream trees and reconstruct the fixed tree from retained patches."
  alias Eab.{Cache, Command, Inventory, Source, Store}

  def verify(id, emit, opts \\ []) do
    spec = Inventory.spec(id)
    provenance = Inventory.read_json(Inventory.case_path(id, "provenance.json"))
    validate!(spec, provenance)

    tests = tests_patch(id)
    protected = Eab.TaskContract.read(spec)["protected_paths"]

    for file <- Enum.uniq([tests, "reference-tests.patch"]),
        File.regular?(Inventory.case_path(id, file)) do
      unless Eab.Grader.validate_patch(Inventory.file(id, file), %{
               "allowed_edit_prefixes" => protected
             }) == {:ok, []},
             do: raise("Upstream and curated test patches may only change protected tests")
    end

    if File.regular?(Inventory.case_path(id, "upstream-docs.patch")) do
      headers =
        String.split(Inventory.file(id, "upstream-docs.patch"), "\n")
        |> Enum.filter(&String.starts_with?(&1, "diff --git "))

      unless Enum.all?(headers, fn header ->
               case OptionParser.split(String.replace_prefix(header, "diff --git ", "")) do
                 ["a/" <> a, "b/" <> b] -> a == b and Path.extname(a) in [".md", ".txt"]
                 _ -> false
               end
             end),
             do: raise("Upstream documentation patch cannot hide implementation differences")
    end

    {receipt, _} =
      Cache.fetch(
        "provenance",
        inputs(id),
        fn _ ->
          patches = Enum.map(patches(id), &Inventory.case_path(id, &1))
          verify_pair(spec, provenance, patches, emit)
        end,
        opts
      )

    receipt
  end

  def inputs(id) do
    %{
      "provenance" => Inventory.read_json(Inventory.case_path(id, "provenance.json")),
      "patches" => Map.take(Inventory.fixture_hashes(id), patches(id)),
      "verifier" => Inventory.hash_file(Inventory.path("lib/eab/provenance.ex")),
      "exporter" => Inventory.hash_file(Inventory.path("lib/eab/source.ex"))
    }
  end

  defp patches(id), do: ["reference.patch", tests_patch(id), "upstream-docs.patch"]

  defp tests_patch(id) do
    if File.regular?(Inventory.case_path(id, "upstream-tests.patch")),
      do: "upstream-tests.patch",
      else: "reference-tests.patch"
  end

  def validate!(spec, provenance) do
    repo = spec["repository"] || %{}
    url = String.replace_suffix(repo["url"] || "", ".git", "")

    unless Regex.match?(~r{^https://github.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$}, url) and
             provenance["repository"] == url and repo["revision"] == provenance["broken_revision"] and
             Regex.match?(
               ~r{^#{Regex.escape(url)}/pull/[1-9][0-9]*$},
               provenance["pull_request"] || ""
             ) and
             Enum.all?(~w(broken_revision fixed_revision broken_tree fixed_tree), fn key ->
               Regex.match?(~r/^[a-f0-9]{40}$/, provenance[key] || "")
             end) and is_binary(provenance["pair_selection"]) and
             provenance["pair_selection"] != "",
           do: raise("Invalid or inconsistent source provenance")

    :ok
  end

  # Public for a bounded synthetic Git repository check. Production callers use
  # verify/3, which restricts sources to recorded GitHub PRs.
  def verify_pair(spec, provenance, patches, emit) do
    root = Store.path("scratch/provenance-#{System.unique_integer([:positive])}")
    broken = Path.join(root, "broken")
    fixed = Path.join(root, "fixed")
    for path <- [broken, fixed], do: File.mkdir_p!(path)

    try do
      first =
        Source.snapshot(spec["repository"], broken, emit,
          expected_tree: provenance["broken_tree"]
        )

      last =
        Source.snapshot(
          Map.put(spec["repository"], "revision", provenance["fixed_revision"]),
          fixed,
          emit,
          expected_tree: provenance["fixed_tree"]
        )

      Command.run!("git", ["init", "--quiet"], cd: broken)
      Command.run!("git", ["-c", "core.autocrlf=false", "add", "--force", "--all"], cd: broken)
      before = tree(broken)
      unless before == first["tree"], do: raise("Export cannot reconstruct the broken tree")

      for patch <- patches, File.regular?(patch), File.stat!(patch).size > 0 do
        Command.run!("git", ["apply", "--index", "--whitespace=nowarn", Path.expand(patch)],
          cd: broken
        )
      end

      after_ = tree(broken)

      unless after_ == last["tree"] do
        Command.run!("git", [
          "--git-dir",
          Path.join(broken, ".git"),
          "--work-tree",
          fixed,
          "-c",
          "core.autocrlf=false",
          "add",
          "--force",
          "--all"
        ])

        fixed_tree = tree(broken)
        diff = Command.run!("git", ["diff", "--stat", after_, fixed_tree], cd: broken)

        detail =
          Command.run!("git", ["diff", "--binary", after_, fixed_tree],
            cd: broken,
            limit: 4_194_304
          )

        key = Cache.key(provenance)
        Store.write_text("provenance-errors/#{key}.patch", detail)

        raise(
          "Reference implementation and tests do not reconstruct recorded fixed tree:\n#{diff}\nDetails: provenance-errors/#{key}.patch"
        )
      end

      %{"verified" => true, "broken" => first, "fixed" => last, "reconstructed_tree" => after_}
    after
      File.rm_rf!(root)
    end
  end

  defp tree(source), do: Command.run!("git", ["write-tree"], cd: source) |> String.trim()
end
