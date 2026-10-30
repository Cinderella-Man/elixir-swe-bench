defmodule Eab.CacheTest do
  use ExUnit.Case, async: false
  alias Eab.{Cache, Store}

  setup do
    previous = Store.root()
    root = Path.join(System.tmp_dir!(), "eab-artifacts-#{System.unique_integer([:positive])}")
    Application.put_env(:eab, :data_dir, root)

    on_exit(fn ->
      Application.put_env(:eab, :data_dir, previous)
      File.rm_rf!(root)
    end)

    %{opts: [image_exists?: fn _ -> true end]}
  end

  test "a warm artifact skips building and a missing component invalidates only its entry", %{
    opts: opts
  } do
    inputs = %{"version" => 1, "case" => "one"}
    artifact = %{"images" => ["project", "postgres", "clickhouse"]}
    assert {^artifact, :built} = Cache.fetch("test", inputs, fn _ -> artifact end, opts)

    assert {^artifact, :reused} =
             Cache.fetch("test", inputs, fn _ -> flunk("warm build") end, opts)

    assert {:missing, "a cached image is missing from Docker"} =
             Cache.lookup("test", Cache.key(inputs), image_exists?: &(&1 != "clickhouse"))

    assert {:missing, "no saved artifact"} =
             Cache.lookup("test", Cache.key(%{"case" => "two"}), opts)

    assert {:ok, ^artifact} = Cache.lookup("test", Cache.key(inputs), opts)
  end

  test "offline mode reuses prepared artifacts and refuses to build missing ones", %{opts: opts} do
    on_exit(fn -> Application.delete_env(:eab, :offline) end)
    artifact = %{"images" => []}
    Cache.fetch("test", %{"case" => "prepared"}, fn _ -> artifact end, opts)
    Application.put_env(:eab, :offline, true)

    assert {^artifact, :reused} =
             Cache.fetch("test", %{"case" => "prepared"}, fn _ -> flunk("warm build") end, opts)

    assert_raise RuntimeError, ~r/Offline mode cannot prepare test: no saved artifact/, fn ->
      Cache.fetch("test", %{"case" => "missing"}, fn _ -> flunk("offline build") end, opts)
    end
  end

  test "failed or incomplete publication cannot become reusable", %{opts: opts} do
    inputs = %{"case" => "failed"}

    assert_raise RuntimeError, "bootstrap failed", fn ->
      Cache.fetch("test", inputs, fn _ -> raise("bootstrap failed") end, opts)
    end

    assert_raise RuntimeError, "Cannot publish missing cache images", fn ->
      Cache.fetch("test", inputs, fn _ -> %{"images" => ["missing"]} end,
        image_exists?: fn _ -> false end
      )
    end

    assert {:missing, _} = Cache.lookup("test", Cache.key(inputs), opts)
    assert Cache.records("test") == []
    Store.write_text("cache/test/#{Cache.key(inputs)}.json", "{partial")
    assert {:missing, _} = Cache.lookup("test", Cache.key(inputs), opts)
    assert Cache.records("test") == []
  end

  test "artifact mutation is detected and keys survive persistence", %{opts: opts} do
    inputs = %{"version" => 1, "commands" => ["one", "two"], "nested" => %{"enabled" => true}}
    assert Cache.key(inputs) == Cache.key(inputs |> Jason.encode!() |> Jason.decode!())
    Cache.fetch("test", inputs, fn _ -> %{"images" => [], "value" => "original"} end, opts)
    path = "cache/test/#{Cache.key(inputs)}.json"
    record = Store.read(path) |> put_in(["artifact", "value"], "tampered")
    Store.write(path, record)
    assert {:missing, "invalid artifact record"} = Cache.lookup("test", Cache.key(inputs), opts)
  end

  test "concurrent requests share one preparation and cancellation releases the lock", %{
    opts: opts
  } do
    parent = self()

    build = fn _ ->
      send(parent, {:building, self()})

      receive do
        :finish -> %{"images" => []}
      end
    end

    first = Task.async(fn -> Cache.fetch("test", %{"case" => "shared"}, build, opts) end)
    assert_receive {:building, worker}
    second = Task.async(fn -> Cache.fetch("test", %{"case" => "shared"}, build, opts) end)
    send(worker, :finish)
    assert {_, :built} = Task.await(first)
    assert {_, :reused} = Task.await(second)
    refute_received {:building, _}

    cancelled = spawn(fn -> Cache.fetch("test", %{"case" => "cancelled"}, build, opts) end)
    monitor = Process.monitor(cancelled)
    assert_receive {:building, ^cancelled}
    Process.exit(cancelled, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^cancelled, :killed}

    assert {_, :built} =
             Cache.fetch("test", %{"case" => "cancelled"}, fn _ -> %{"images" => []} end, opts)
  end
end
