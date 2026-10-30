defmodule Eab.RetentionTest do
  use ExUnit.Case, async: false
  alias Eab.{Cache, Retention}

  setup do
    old = Application.fetch_env!(:eab, :data_dir)
    root = Path.join(System.tmp_dir!(), "eab-retention-#{System.unique_integer([:positive])}")
    Application.put_env(:eab, :data_dir, root)
    File.mkdir_p!(root)

    on_exit(fn ->
      Application.put_env(:eab, :data_dir, old)
      File.rm_rf!(root)
    end)

    :ok
  end

  defp cache(kind, inputs, artifact) do
    Cache.fetch(kind, inputs, fn _ -> artifact end, image_exists?: fn _ -> true end)
  end

  test "removing one case preserves shared project and database references" do
    cache("projects", %{"source" => "same"}, %{"image" => "shared", "images" => ["shared"]})
    cache("databases", %{"migrations" => 1}, %{"images" => ["database"]})
    cache("agents", %{"project" => "shared"}, %{"images" => ["pi"]})
    runtime = %{"image" => "shared", "services" => %{"postgres" => "database"}}
    Retention.retain("first", runtime)
    Retention.retain("second", runtime)
    plan = Retention.preview("first")
    assert plan["images"] == []
    assert plan["shared_records_preserved"] == 3

    assert Retention.remove("first", plan["id"],
             remove_image: fn _ -> flunk("shared image deletion") end
           )["removed_images"] == 0

    plan = Retention.preview("second")
    assert Enum.sort(plan["images"]) == ["database", "pi", "shared"]

    assert Retention.remove("second", plan["id"], remove_image: fn _ -> :ok end)["removed_images"] ==
             3

    assert Retention.status()["baselines"] == 0
    assert Cache.records("projects") == []
  end

  test "offline mode refuses removal, because nothing can be rebuilt" do
    on_exit(fn -> Application.delete_env(:eab, :offline) end)
    cache("projects", %{"source" => 1}, %{"images" => ["one"]})
    Retention.retain("case", %{"image" => "one"})
    plan = Retention.preview("case")
    Application.put_env(:eab, :offline, true)

    assert_raise RuntimeError, ~r/Offline mode keeps prepared state/, fn ->
      Retention.remove("case", plan["id"], remove_image: fn _ -> flunk("offline removal") end)
    end

    assert Retention.status()["baselines"] == 1
  end

  test "active leases and nested uses prevent removal, and stale previews are rejected" do
    cache("projects", %{"source" => 1}, %{"images" => ["one"]})
    Retention.retain("case", %{"image" => "one"})
    plan = Retention.preview("case")
    Retention.lease("run")
    assert_raise RuntimeError, ~r/in use/, fn -> Retention.remove("case", plan["id"]) end
    Retention.release("run")

    Retention.with_use(fn ->
      Retention.with_use(fn -> :ok end)
      assert_raise RuntimeError, ~r/in use/, fn -> Retention.remove("case", plan["id"]) end
    end)

    Retention.retain("other", %{"image" => "one"})

    assert_raise RuntimeError, ~r/references changed/, fn ->
      Retention.remove("case", plan["id"])
    end
  end

  test "removing one release detaches its ownership but preserves another release's exact baseline" do
    first = String.duplicate("a", 64)
    second = String.duplicate("b", 64)
    cache("projects", %{"source" => "same"}, %{"image" => "shared", "images" => ["shared"]})
    runtime = %{"image" => "shared"}
    Retention.retain("case", runtime, first)
    Retention.retain("case", runtime, second)
    Retention.retain("case", runtime)
    Eab.Store.write("runtimes/case.json", runtime)
    plan = Retention.preview("release:" <> first)
    assert plan["images"] == []
    assert plan["affected_cases"] == ["case"]

    Retention.remove("release:" <> first, plan["id"],
      remove_image: fn _ -> flunk("shared release image") end
    )

    assert Retention.status()["releases"] == [second]
    assert Eab.Store.read("runtimes/case.json") == runtime
    plan = Retention.preview("release:" <> second)
    assert plan["images"] == ["shared"]
    Retention.remove("release:" <> second, plan["id"], remove_image: fn _ -> :ok end)
    assert Retention.status()["baselines"] == 0
    assert Eab.Store.read("runtimes/case.json") == nil
  end

  test "retained descendants protect their database seed and eviction failures stay visible" do
    cache("databases", %{"migrations" => 1}, %{"images" => ["base"], "depth" => 1})

    cache("databases", %{"migrations" => 2}, %{
      "images" => ["child"],
      "depth" => 2,
      "seed" => Cache.key(%{"migrations" => 1})
    })

    Retention.retain("older", %{"services" => %{"postgres" => "base"}})
    Retention.retain("newer", %{"services" => %{"postgres" => "child"}})
    assert Retention.preview("older")["images"] == []
    plan = Retention.preview("newer")

    result =
      Retention.remove("newer", plan["id"], remove_image: fn _ -> {:error, "external tag"} end)

    assert result["retained_images"] == [%{"image" => "child", "reason" => "external tag"}]
    assert length(Cache.records("databases")) == 2
  end

  test "low free space rejects a missing build but never evicts or blocks a valid cache hit" do
    inputs = %{"source" => 1}
    opts = [reserve_bytes: 100, free_bytes: fn _ -> 99 end, image_exists?: fn _ -> true end]

    assert_raise RuntimeError, ~r/free space/, fn ->
      Cache.fetch("projects", inputs, fn _ -> flunk("build started") end, opts)
    end

    cache("projects", inputs, %{"images" => ["one"]})

    assert {%{"images" => ["one"]}, :reused} =
             Cache.fetch("projects", inputs, fn _ -> flunk("warm build") end, opts)
  end

  test "corrupt retention roots remain visible and prevent removal" do
    Eab.Store.write_text("retained/broken/one.json", "invalid JSON")
    assert Retention.status()["error"] =~ "Cache records need attention"
    assert_raise Jason.DecodeError, fn -> Retention.preview("unused") end
  end
end
