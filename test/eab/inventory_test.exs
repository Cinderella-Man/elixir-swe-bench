defmodule Eab.InventoryTest do
  use ExUnit.Case, async: false
  alias Eab.{Cache, Inventory, Release}

  setup do
    original_root = Inventory.root()
    root = Path.join(System.tmp_dir!(), "eab-inventory-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "config"))
    File.mkdir_p!(Path.join(root, "cases"))
    File.mkdir_p!(Path.join(root, "cases_approved"))

    for relative <- ["lib", "priv", "mix.lock"] do
      File.ln_s!(Path.join(original_root, relative), Path.join(root, relative))
    end

    File.write!(
      Path.join(root, "config/benchmark.json"),
      Jason.encode!(%{"id" => "test", "cases" => ["existing-case"], "defaults" => %{}})
    )

    Application.put_env(:eab, :root, root)

    on_exit(fn ->
      Application.put_env(:eab, :root, original_root)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "moving folders out and back restores the same release without config edits", %{root: root} do
    for id <- ["existing-case", "new-case"] do
      File.mkdir_p!(Inventory.path("cases/#{id}"))
      File.write!(Inventory.case_path(id, "case.json"), Jason.encode!(%{"id" => id}))
    end

    assert Inventory.all() == ["existing-case", "new-case"]
    protocol = Inventory.protocol()
    release = %{"id" => Cache.key(protocol), "protocol" => protocol}
    config = File.read!(Inventory.path("config/benchmark.json"))
    assert :ok = Release.verify!(release)

    for id <- Inventory.all() do
      File.rename!(Inventory.path("cases/#{id}"), Path.join(root, "cases_approved/#{id}"))
    end

    assert Inventory.all() == []
    assert_raise RuntimeError, ~r/cases or agent changed/, fn -> Release.verify!(release) end
    assert_raise RuntimeError, ~r/Invalid release case inventory/, fn -> Release.freeze() end

    for id <- ["existing-case", "new-case"] do
      File.rename!(Path.join(root, "cases_approved/#{id}"), Inventory.path("cases/#{id}"))
    end

    assert Inventory.all() == ["existing-case", "new-case"]
    assert Inventory.protocol() == protocol
    assert :ok = Release.verify!(release)
    assert File.read!(Inventory.path("config/benchmark.json")) == config
  end

  test "only direct case folders containing manifests are discovered" do
    File.mkdir_p!(Inventory.path("cases/unfinished"))
    File.write!(Inventory.path("cases/README.md"), "Ignored")
    File.mkdir_p!(Inventory.path("cases_approved/parked-case"))
    File.write!(Inventory.path("cases_approved/parked-case/case.json"), "{}")
    assert Inventory.all() == []
  end
end
