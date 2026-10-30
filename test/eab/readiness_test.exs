defmodule Eab.ReadinessTest do
  use ExUnit.Case, async: false

  alias Eab.{
    AgentImage,
    Baseline,
    Cache,
    Fixtures,
    Grader,
    Inventory,
    Provenance,
    Qualification,
    Readiness,
    Store
  }

  @id "plausible-pr-5939"
  @opts [image_exists?: &__MODULE__.exists/1]

  def exists(_image), do: true

  setup do
    old = Application.fetch_env!(:eab, :data_dir)
    root = Path.join(System.tmp_dir!(), "eab-readiness-#{System.unique_integer([:positive])}")
    Application.put_env(:eab, :data_dir, root)

    on_exit(fn ->
      Application.put_env(:eab, :data_dir, old)
      Application.delete_env(:eab, :offline)
      File.rm_rf!(root)
    end)

    :ok
  end

  defp seed_baseline do
    spec = Inventory.spec(@id)
    inputs = Fixtures.build_inputs(@id, spec)
    project = %{"inputs" => inputs, "image" => "project", "images" => ["project"]}
    Cache.fetch("projects", inputs, fn _ -> project end, @opts)
    services = %{"postgres" => "engine"}
    engines = %{"services" => spec["services"]}
    engine = %{"services" => services, "images" => ["engine"]}
    Cache.fetch("engines", engines, fn _ -> engine end, @opts)
    database = Baseline.inputs(Map.put(project, "services", services), Baseline.policy(spec))

    Cache.fetch(
      "databases",
      database,
      fn _ ->
        %{"services" => %{"postgres" => "database"}, "images" => ["database"], "depth" => 1}
      end,
      @opts
    )

    Cache.fetch("provenance", Provenance.inputs(@id), fn _ -> %{"verified" => true} end, @opts)
  end

  defp seed_prepared do
    seed_baseline()
    runtime = Fixtures.ensure(@id, fn _ -> :ok end, @opts)
    agent = AgentImage.inputs(Inventory.spec(@id), runtime["image"])
    Cache.fetch("agents", agent, fn _ -> %{"image" => "pi", "images" => ["pi"]} end, @opts)
    identity = Grader.qualification_identity(@id, runtime)
    receipt = %{"valid" => true, "identity" => identity}
    Store.write("qualifications/#{Cache.key(identity)}.json", receipt)
  end

  defp check(existing \\ fn images -> MapSet.new(images) end),
    do: Readiness.check([@id], existing: existing)

  defp missing(existing \\ fn images -> MapSet.new(images) end),
    do: hd(check(existing)["cases"])["missing"]

  test "an empty installation needs every part" do
    assert check() == %{
             "total" => 1,
             "ready" => 0,
             "cases" => [
               %{
                 "case" => @id,
                 "ready" => false,
                 "missing" => [
                   "source check",
                   "project and database images",
                   "Pi image",
                   "fixture qualification"
                 ]
               }
             ]
           }
  end

  test "a case is ready only with its source check, images, Pi image and qualification" do
    seed_prepared()
    assert check()["ready"] == 1
    assert missing() == []
  end

  test "a baseline without Pi is not ready, because attaching Pi needs npm" do
    seed_baseline()
    Fixtures.ensure(@id, fn _ -> :ok end, @opts)
    assert "Pi image" in missing()
  end

  test "a record whose image left Docker is not ready" do
    seed_prepared()
    assert missing(&MapSet.new(&1 -- ["pi"])) == ["Pi image"]
    assert missing(&MapSet.new(&1 -- ["database"])) == ["project and database images"]
  end

  test "a qualification for another runtime does not count" do
    seed_prepared()
    runtime = Store.read("runtimes/#{@id}.json")

    File.rm!(
      Store.path("qualifications/#{Cache.key(Grader.qualification_identity(@id, runtime))}.json")
    )

    assert missing() == ["fixture qualification"]
  end

  test "changed fixtures need a new preparation" do
    seed_prepared()
    runtime = Store.read("runtimes/#{@id}.json")
    Store.write("runtimes/#{@id}.json", Map.put(runtime, "fixture_hashes", %{}))
    assert missing() == ["Pi image", "fixture qualification"]
  end

  test "enforcement names unprepared cases only in offline mode" do
    assert Readiness.enforce!([@id]) == :ok
    Application.put_env(:eab, :offline, true)

    assert_raise RuntimeError, ~r/Offline mode: 1 of 1 cases.*#{@id}.*Prepare all cases/, fn ->
      Readiness.enforce!([@id])
    end
  end

  test "preparing a case attaches Pi to its prepared image" do
    seed_baseline()
    parent = self()

    runtime =
      Qualification.prepare_case(
        @id,
        "preparation-test",
        nil,
        fn _ -> :ok end,
        @opts ++ [attach_agent: &send(parent, {:attached, &1["id"], &2})]
      )

    assert runtime["image"] == "project"
    assert_receive {:attached, @id, "project"}
  end
end
