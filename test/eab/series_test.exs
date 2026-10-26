defmodule Eab.SeriesTest do
  use ExUnit.Case, async: false
  alias Eab.{Results, Series}

  setup do
    old = Application.get_env(:eab, :results_page_root)
    dir = Path.join(System.tmp_dir!(), "eab-series-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "results"))

    for file <- ~w(index.html styles.css app.js),
        do: File.cp!(Path.join(Results.root(), file), Path.join(dir, file))

    Application.put_env(:eab, :results_page_root, dir)

    on_exit(fn ->
      if old,
        do: Application.put_env(:eab, :results_page_root, old),
        else: Application.delete_env(:eab, :results_page_root)

      File.rm_rf!(dir)
    end)

    %{page: dir}
  end

  defp run(id, seed, outcomes, created \\ "2026-10-27T10:00:00Z") do
    inventory = Eab.Inventory.definition()
    cases = inventory["cases"]

    %{
      "id" => id,
      "created_at" => created,
      "status" => "completed",
      "release_id" => String.duplicate("a", 64),
      "model" => %{
        "model" => "alias-#{id}",
        "backend" => "llama_cpp",
        "url" => "http://machine-#{id}:8080",
        "profile" => %{
          "model_path" => "/srv/#{id}/Swift-27B-Q4_K_M.gguf",
          "build_info" => "b#{id}",
          "total_slots" => 1,
          "chat_template" => "{{ messages }}",
          "default_generation_settings" => %{
            "n_ctx" => 262_144,
            "params" => %{"temperature" => 0.6, "top_p" => 0.95, "seed" => 4_294_967_295}
          }
        }
      },
      "cases" => cases,
      "protocol" => %{
        "inventory" => inventory,
        "agent" => Eab.Pi.identity(),
        "implementation" => String.duplicate("b", 64),
        "fixtures" => Map.new(cases, &{&1, Results.fixture_hashes(&1)})
      },
      "settings" => %{"max_tokens" => 65_536, "window_tokens" => 262_144, "seed" => seed},
      "attempts" =>
        cases
        |> Enum.zip(outcomes ++ List.duplicate(true, length(cases)))
        |> Map.new(fn {id, passed} ->
          {id, %{"status" => "completed", "grade" => %{"passed" => passed}}}
        end)
    }
  end

  test "membership ignores deployment, seed and code version but not setup" do
    base = run("one", 101, [])
    assert Series.id(base) == Series.id(run("two", 102, [false]))

    assert Series.id(base) ==
             Series.id(put_in(base, ["protocol", "implementation"], String.duplicate("c", 64)))

    for changed <- [
          put_in(base, ["model", "profile", "model_path"], "/m/Other-27B-Q4_K_M.gguf"),
          put_in(base, ["model", "profile", "model_path"], "/m/Swift-27B-Q8_0.gguf"),
          put_in(base, ["model", "profile", "chat_template"], "other"),
          put_in(
            base,
            ["model", "profile", "default_generation_settings", "params", "top_p"],
            0.9
          ),
          put_in(base, ["model", "backend"], "strata"),
          put_in(base, ["settings", "window_tokens"], 131_072),
          put_in(base, ["settings", "reasoning_effort"], "high"),
          put_in(base, ["protocol", "agent", "version"], "9.9.9"),
          Map.put(base, "harness", %{"name" => "claude_code", "kit_sha256" => "x"})
        ],
        do: refute(Series.id(changed) == Series.id(base))

    # Sharded artifacts and server build, slots and seed defaults may differ.
    sharded =
      put_in(base, ["model", "profile", "model_path"], "/x/Swift-27B-Q4_K_M-00001-of-00002.gguf")

    assert Series.id(sharded) == Series.id(base)

    # The desktop app updates Claude Code between runs; the kit and prompt still pin a series.
    claude = fn version ->
      Map.put(base, "harness", %{
        "name" => "claude_code",
        "kit_sha256" => "x",
        "claude_code_version" => version
      })
    end

    assert Series.id(claude.("2.1.308")) == Series.id(claude.("2.1.311"))
  end

  test "each seed counts once, errored and validation runs leave it open" do
    first = run("first", 101, [false], "2026-10-27T10:00:00Z")
    later = run("later", 101, [], "2026-10-27T11:00:00Z")

    errored =
      run("errored", 102, []) |> put_in(["attempts", hd(first["cases"]), "status"], "error")

    validation = run("validation", 102, []) |> Map.put("validation", true)
    off_seed = run("off-seed", 7, [])
    third = run("third", 103, [false, false])

    [series] = Series.group([later, errored, validation, off_seed, third, first])
    assert series["runs"] == ["first", "third"]
    assert series["missing_seeds"] == [102]
    assert series["run_count"] == 2 and not series["complete"]

    # Subscription series have no seed and take their first three scored runs.
    api = fn id, at ->
      run(id, nil, [], at)
      |> put_in(["model", "backend"], "claude_code")
      |> put_in(["model", "model"], "claude-haiku-5-5")
    end

    runs = for n <- 1..4, do: api.("api-#{n}", "2026-10-2#{n}T00:00:00Z")
    [subscription] = Series.group(Enum.reverse(runs))
    assert subscription["runs"] == ~w(api-1 api-2 api-3) and subscription["complete"]
    assert subscription["missing_seeds"] == []
  end

  test "the score is the mean and the interval is 1.96 standard errors of rerun noise" do
    outcomes = fn passes ->
      %{
        "cases" =>
          Enum.map(Enum.with_index(passes), fn {p, i} -> %{"id" => "c#{i}", "passed" => p} end)
      }
    end

    summary =
      Series.summary([
        outcomes.([true, false]),
        outcomes.([true, true]),
        outcomes.([false, false])
      ])

    assert summary["score_percent"] == 50.0
    assert summary["case_passes"] == %{"c0" => 2, "c1" => 1}
    # sqrt((2/9 + 2/9) / 2) / 2 * 1.96 = 0.4620
    assert summary["interval_percent"] == 46.2
    assert Series.summary([outcomes.([true, false])])["interval_percent"] == nil
    assert Series.summary([outcomes.([true]), outcomes.([true])])["interval_percent"] == 0.0
  end

  test "a point's memory is the highest RAM + VRAM peak across its runs" do
    low = %{"peak_combined_bytes" => 10, "peak_vram_bytes" => 8}
    high = %{"peak_combined_bytes" => 30, "peak_vram_bytes" => 5}
    assert Series.peak_resources([low, nil, high]) == high
    assert Series.peak_resources([nil]) == nil
  end

  test "published series take each seed once and at most three runs", %{page: page} do
    opts = [page_root: page]
    assert Results.publish!(run("first", 101, [false]), opts) == :added

    assert_raise ArgumentError, ~r/Seed 101 already has a run/, fn ->
      Results.publish!(run("again", 101, [], "2026-10-27T11:00:00Z"), opts)
    end

    assert_raise ArgumentError, ~r/never published/, fn ->
      Results.publish!(Map.put(run("checked", 102, []), "validation", true), opts)
    end

    for {id, seed} <- [{"second", 102}, {"third", 103}],
        do:
          assert(
            Results.publish!(run(id, seed, [], "2026-10-28T00:00:0#{seed - 100}Z"), opts) ==
              :added
          )

    [series] = Results.load!(Path.join(page, "results"))
    assert Results.aggregate(series)["complete"]
  end

  test "contributions must match the published setup and use a missing seed", %{page: page} do
    first = run("first", 101, [false])
    Results.publish!(first, page_root: page)
    id = Series.id(first)

    assert :ok = Series.contribution!(run("next", 102, []), id)

    assert_raise RuntimeError, ~r/missing seeds: 102, 103/, fn ->
      Series.contribution!(run("next", 101, []), id)
    end

    assert_raise RuntimeError, ~r/chat template sha256, model differ/, fn ->
      run("next", 102, [])
      |> put_in(["model", "profile", "chat_template"], "other")
      |> put_in(["model", "profile", "model_path"], "/m/Other-Q4_K_M.gguf")
      |> Series.contribution!(id)
    end

    second = run("second", 102, [], "2026-10-27T12:00:00Z") |> Map.put("series", id)
    assert Results.publish!(second, page_root: page) == :added
    record = Results.series!(id)
    assert Enum.map(record["runs"], & &1["seed"]) == [101, 102]
    built = Results.aggregate(record)
    assert built["missing_seeds"] == [103] and built["run_count"] == 2
    assert is_float(built["interval_percent"])

    # A run started for one series cannot be filed under another.
    moved = run("moved", 103, []) |> Map.put("series", String.duplicate("f", 64))

    assert_raise ArgumentError, ~r/no longer matches/, fn ->
      Results.publish!(moved, page_root: page)
    end
  end
end
