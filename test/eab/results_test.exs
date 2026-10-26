defmodule Eab.ResultsTest do
  use ExUnit.Case, async: true
  alias Eab.Results

  setup do
    dir = Path.join(System.tmp_dir!(), "eab-results-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp run do
    %{
      "id" => "test-run",
      "created_at" => "2026-10-17T12:00:00Z",
      "status" => "completed",
      "model" => %{
        "model" => "volta-a",
        "backend" => "llama_cpp",
        "url" => "http://private-host",
        "account_id" => "private-account",
        "profile" => %{
          "model_ftype" => "Q4_K - Medium",
          "model_path" => "/models/Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf"
        },
        "metadata" => %{"model" => %{"meta" => %{"size" => 17_431_404_544}}}
      },
      "release_id" => String.duplicate("a", 64),
      "cases" => ~w(case-a case-b),
      "protocol" => %{
        "inventory" => %{"id" => "example-v1", "cases" => ~w(case-a case-b)},
        "fixtures" => %{
          "case-a" => %{"case.json" => String.duplicate("a", 64)},
          "case-b" => %{"case.json" => String.duplicate("b", 64)}
        }
      },
      "settings" => %{"max_tokens" => 65536, "seed" => 101, "compaction" => false},
      "attempts" => %{
        "case-a" => %{
          "status" => "completed",
          "grade" => %{"passed" => true},
          "trace" => "private-trace"
        },
        "case-b" => %{"status" => "completed", "grade" => %{"passed" => false}}
      }
    }
  end

  defp current do
    inventory = Eab.Inventory.definition()

    Map.merge(run(), %{
      "cases" => inventory["cases"],
      "protocol" => %{
        "inventory" => inventory,
        "fixtures" => Map.new(inventory["cases"], &{&1, Results.fixture_hashes(&1)})
      },
      "attempts" =>
        Map.new(
          inventory["cases"],
          &{&1, %{"status" => "completed", "grade" => %{"passed" => true}}}
        )
    })
  end

  defp snapshot do
    %{
      "kind" => "loaded_snapshot",
      "observed_at" => "2026-10-17T12:00:00Z",
      "model_artifact" => "Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf",
      "backend" => "llama_cpp",
      "backend_version" => "fixture",
      "context_tokens" => 262_144,
      "kv_cache" => "f16",
      "cpu" => "fixture",
      "gpus" => [%{"name" => "Fixture GPU", "capacity_bytes" => 1000, "used_bytes" => 800}],
      "ram_rss_bytes" => 100,
      "ram_lifetime_peak_bytes" => 200,
      "service_ram_bytes" => nil,
      "service_ram_lifetime_peak_bytes" => nil
    }
  end

  defp entry(record), do: hd(record["runs"])

  test "public export uses exact artifact identity, outcomes and weight size, and omits private data" do
    result = Results.export!(run())
    assert Enum.map(entry(result)["cases"], & &1["passed"]) == [true, false]
    assert entry(result)["seed"] == 101 and result["seeds"] == [101, 102, 103]
    refute Map.has_key?(result["settings"], "seed")
    assert result["harness"] == %{"name" => "pi", "version" => "unknown"}
    assert result["series_id"] == Eab.Series.id(run())
    assert result["model"]["name"] == "Swift-1.5-Qwen3.8-27B"
    assert result["model"]["quantization"] == "Q4_K_M"
    assert result["model"]["size_bytes"] == 17_431_404_544
    assert result["model"]["size_source"] == "reported"

    for private <- ["private-host", "private-account", "private-trace", "/models/"],
        do: refute(Jason.encode!(result) =~ private)
  end

  test "preserves tokens and model calls but publishes no timing" do
    source =
      run()
      |> put_in(["attempts", "case-a", "generated_tokens"], 1234)
      |> put_in(["attempts", "case-a", "calls"], 12)
      |> put_in(["attempts", "case-a", "measurement"], %{
        "attempt_ms" => 120_000
      })

    [a, b] = entry(Results.export!(source))["cases"]
    assert a["generated_tokens"] == 1234 and a["model_calls"] == 12
    assert b["generated_tokens"] == nil
    refute Jason.encode!(Results.export!(source)) =~ "attempt_ms"
  end

  test "thinking presets survive public export without backfilling old runs" do
    assert Results.export!(run())["settings"]["reasoning_effort"] == nil

    for effort <- ~w(off on low medium high xhigh max ultra default unsupported) do
      settings =
        Eab.Thinking.settings(%{}, %{"reasoning_effort" => effort})
        |> Map.merge(run()["settings"])

      result = Results.export!(Map.put(run(), "settings", settings))
      assert result["settings"]["reasoning_effort"] == effort
      assert result["settings"]["reasoning_effort_source"] == "operator_declared"
    end
  end

  test "snapshots must match artifact, backend and context" do
    source = put_in(run(), ["settings", "window_tokens"], 262_144)
    assert entry(Results.export!(source, resources: snapshot()))["resources"] == snapshot()

    for {key, value} <- [
          {"context_tokens", 65536},
          {"model_artifact", "Other-Q4_K_M.gguf"},
          {"backend", "strata"},
          {"kind", "benchmark_peak"},
          {"api_key", "private"}
        ] do
      assert_raise ArgumentError, fn ->
        Results.export!(source, resources: Map.put(snapshot(), key, value))
      end
    end
  end

  test "run memory exports simultaneous peaks without private host, service or GPU identity" do
    identity =
      Map.take(snapshot(), ~w(model_artifact backend backend_version context_tokens kv_cache cpu))
      |> Map.merge(%{"host" => "private-machine", "service" => "private.service"})

    session = %{
      "identity" => identity,
      "started_at" => "2026-10-18T00:00:00Z",
      "finished_at" => "2026-10-18T00:00:02Z",
      "sample_count" => 2,
      "interval_ms" => 1000,
      "gap_count" => 0,
      "gpus" => [
        %{
          "uuid" => "private-gpu",
          "name" => "fixture",
          "capacity_bytes" => 1000,
          "used_bytes" => 100
        }
      ]
    }

    memory = %{
      "kind" => "run_samples",
      "status" => "complete",
      "sessions" => [session],
      "sample_count" => 2,
      "peaks" => %{
        "vram_bytes" => 100,
        "service_ram_bytes" => 80,
        "process_rss_bytes" => 90,
        "combined_bytes" => 120
      }
    }

    source = run() |> put_in(["settings", "window_tokens"], 262_144) |> Map.put("memory", memory)
    result = Results.export!(source)
    assert entry(result)["resources"]["peak_combined_bytes"] == 120

    for private <- ~w(private-machine private.service private-gpu),
        do: refute(Jason.encode!(result) =~ private)

    assert entry(Results.export!(put_in(source, ["memory", "status"], "partial")))["resources"][
             "coverage"
           ] == "partial"

    other = put_in(session, ["identity", "host"], "another-machine")

    assert_raise ArgumentError, ~r/different deployments/, fn ->
      Results.export!(put_in(source, ["memory", "sessions"], [session, other]))
    end

    other = put_in(session, ["gpus", Access.at(0), "uuid"], "another-gpu")

    assert_raise ArgumentError, ~r/physical GPUs/, fn ->
      Results.export!(put_in(source, ["memory", "sessions"], [session, other]))
    end

    # Servers may omit weight size even though the collector can stat the model files.
    source = put_in(source, ["model", "metadata"], %{})
    assert Results.export!(source)["model"]["size_bytes"] == nil

    weights = %{
      "size_bytes" => 1234,
      "files" => [%{"name" => identity["model_artifact"], "size_bytes" => 1234}]
    }

    source =
      put_in(source, ["memory", "sessions", Access.at(0), "identity", "weight_files"], weights)

    result = Results.export!(source)
    assert result["model"]["size_bytes"] == 1234
    assert result["model"]["size_source"] == "artifact_files"
    refute Map.has_key?(entry(result)["resources"], "weight_files")
    assert Results.export!(source, size_bytes: 5678)["model"]["size_bytes"] == 5678
    assert Results.export!(source, size_bytes: 5678)["model"]["size_source"] == "owner_supplied"

    reported = put_in(source, ["model", "metadata"], %{"model" => %{"size" => 9876}})
    assert Results.export!(reported)["model"]["size_bytes"] == 9876
    assert Results.export!(reported)["model"]["size_source"] == "reported"
  end

  test "incomplete, partial, mismatched and duplicated runs cannot be published" do
    variants = [
      Map.put(run(), "status", "error"),
      put_in(run(), ["attempts", "case-b", "status"], "error"),
      update_in(run(), ["attempts"], &Map.delete(&1, "case-b")),
      put_in(run(), ["attempts", "case-b", "grade"], %{}),
      Map.put(run(), "selection", %{"kind" => "case_repeat"}),
      Map.put(run(), "validation", true),
      Map.put(run(), "cases", ["case-a"]),
      run()
      |> Map.put("cases", ~w(case-a case-a))
      |> put_in(["protocol", "inventory", "cases"], ~w(case-a case-a))
    ]

    for source <- variants, do: assert_raise(ArgumentError, fn -> Results.export!(source) end)
  end

  test "sharded artifacts and publisher overrides keep provenance; aliases do not imply quantization" do
    source =
      Map.put(run(), "model", %{
        "model" => "flash-next",
        "backend" => "strata",
        "profile" => %{
          "model_path" =>
            "/models/Qwen3.8-Flash-Next-GSQ-RCO-abliterated-IQ3_S-00001-of-00002.gguf"
        }
      })

    model = Results.export!(source)["model"]

    assert model["name"] == "Qwen3.8-Flash-Next-GSQ-RCO-abliterated" and
             model["quantization"] == "IQ3_S"

    assert model["size_bytes"] == nil

    assert Results.export!(source, size_bytes: 83_863_586_496, size_source: "artifact_files")[
             "model"
           ]["size_source"] == "artifact_files"

    assert_raise ArgumentError, fn -> Results.export!(source, size_bytes: 0) end

    source =
      Map.put(run(), "model", %{"model" => "Name-that-mentions-Q8", "backend" => "llama_cpp"})

    assert Results.export!(source)["model"]["quantization"] == nil

    assert Results.export!(source, quantization: "Q6_K")["model"]["quantization_source"] ==
             "owner_supplied"
  end

  test "current-case projection excludes retired cases and rejects changed fixtures" do
    source = current()
    inventory = source["protocol"]["inventory"]
    ids = source["cases"] ++ ~w(retired-a retired-b)

    source =
      source
      |> Map.put("cases", ids)
      |> put_in(["protocol", "inventory"], %{"id" => "older", "cases" => ids})

    source =
      Enum.reduce(~w(retired-a retired-b), source, fn id, acc ->
        acc
        |> put_in(["attempts", id], %{"status" => "completed", "grade" => %{"passed" => false}})
        |> put_in(["protocol", "fixtures", id], %{"case.json" => String.duplicate("a", 64)})
      end)

    result = Results.export!(source, inventory: inventory)
    assert Enum.map(entry(result)["cases"], & &1["id"]) == inventory["cases"]
    assert Enum.all?(entry(result)["cases"], & &1["passed"])
    assert Map.keys(result["case_fixtures"]) == Enum.sort(inventory["cases"])
    refute Jason.encode!(result) =~ "retired-"
    assert source["cases"] == inventory["cases"] ++ ~w(retired-a retired-b)

    bad =
      put_in(
        source,
        ["protocol", "fixtures", hd(inventory["cases"]), "ticket.md"],
        String.duplicate("b", 64)
      )

    assert_raise ArgumentError, ~r/fixtures differ/, fn ->
      Results.export!(bad, inventory: inventory)
    end
  end

  test "private records, unexpected settings and unsafe links are rejected" do
    assert_raise ArgumentError, fn -> Results.validate!(run()) end

    assert_raise ArgumentError, fn ->
      Results.export!(run()) |> Map.put("evidence_url", false) |> Results.validate!()
    end

    assert_raise ArgumentError, fn ->
      Results.export!(run()) |> put_in(["runs", Access.at(0), "url"], "x") |> Results.validate!()
    end

    assert_raise ArgumentError, fn -> Results.export!(run(), resources: false) end

    assert_raise ArgumentError, fn ->
      Results.export!(run()) |> Map.put("account_id", "secret") |> Results.validate!()
    end

    assert_raise ArgumentError, fn ->
      Results.export!(put_in(run(), ["settings", "api_key"], "secret"))
    end

    for url <- ["javascript:alert(1)", "https://user:password@example.com/results"],
        do: assert_raise(ArgumentError, fn -> Results.export!(run(), evidence_url: url) end)
  end

  test "build validates duplicates and fixtures, escapes script data, and supports an empty page",
       %{dir: dir} do
    source = current()
    record = Results.export!(source, model_label: "<img src=x onerror=alert(1)>")
    Results.write!(Path.join(dir, "first.json"), record)
    assert_raise ArgumentError, ~r/series ID/, fn -> Results.load!(dir) end
    File.rm!(Path.join(dir, "first.json"))
    Results.write!(Path.join(dir, record["series_id"] <> ".json"), record)
    other = Map.put(record, "series_id", String.duplicate("c", 64))
    Results.write!(Path.join(dir, other["series_id"] <> ".json"), other)
    assert_raise ArgumentError, ~r/more than one series/, fn -> Results.load!(dir) end
    File.rm!(Path.join(dir, other["series_id"] <> ".json"))
    output = Path.join(dir, "dist")
    Results.build!(Results.load!(dir), output)
    [built] = Results.read!(Path.join(output, "results.json"))["results"]
    assert built["score_percent"] == 100.0 and built["run_count"] == 1
    assert built["total"] == length(source["cases"])
    assert built["interval_percent"] == nil and built["missing_seeds"] == [102, 103]
    assert Enum.map(entry(built)["cases"], & &1["id"]) == source["cases"]
    refute File.read!(Path.join(output, "results.js")) =~ "<img"

    assert Enum.sort(File.ls!(output)) ==
             Enum.sort(~w(index.html app.js styles.css results.js results.json .nojekyll))

    assert File.read!(Path.join(output, "index.html")) =~ ~r/styles\.css\?v=[a-f0-9]{12}/

    altered =
      put_in(
        record,
        ["case_fixtures", hd(entry(record)["cases"])["id"], "ticket.md"],
        String.duplicate("b", 64)
      )

    assert_raise ArgumentError, ~r/does not match/, fn -> Results.build!([altered], output) end
    Results.build!([], output)
    assert Results.read!(Path.join(output, "results.json"))["results"] == []
  end

  test "publication builds the page, keeps overrides on repeat clicks and leaves private data out",
       %{dir: dir} do
    source = current()
    page = page(dir)
    opts = [page_root: page, inventory: source["protocol"]["inventory"]]
    assert Results.publish!(source, opts) == :added
    dest = Path.join([page, "results", Eab.Series.id(source) <> ".json"])
    record = Results.read!(dest)
    assert entry(record)["run_id"] == source["id"]
    Results.write!(dest, Map.put(record, "note", "Reviewed note"))
    assert Results.publish!(source, opts) == :already_added
    assert Results.added?(source["id"], page_root: page)
    [built] = Results.read!(Path.join(page, "dist/results.json"))["results"]
    assert built["note"] == "Reviewed note"
    assert built["score_percent"] == 100.0
    assert built["total"] == length(source["cases"])
    assert Enum.map(entry(built)["cases"], & &1["id"]) == source["cases"]
    refute Jason.encode!(built) =~ "private-host"
    refute Jason.encode!(built) =~ "private-account"
    refute Jason.encode!(built) =~ "private-trace"
    assert File.stat!(dest).uid == File.stat!(page).uid
    assert Path.wildcard(Path.join(page, ".publish-*")) == []
  end

  test "concurrent publication retains every result and duplicate requests are harmless", %{
    dir: dir
  } do
    page = page(dir)
    source = current()

    second =
      source
      |> Map.merge(%{"id" => "second-run", "created_at" => "2026-10-18T12:00:00Z"})
      |> put_in(["settings", "seed"], 102)

    runs = [source, source, second]

    tasks =
      Enum.map(runs, fn run -> Task.async(fn -> Results.publish!(run, page_root: page) end) end)

    assert Enum.sort(Enum.map(tasks, &Task.await/1)) == [:added, :added, :already_added]
    [series] = Results.read!(Path.join(page, "dist/results.json"))["results"]
    assert Enum.map(series["runs"], & &1["run_id"]) == ["test-run", "second-run"]
    assert series["run_count"] == 2 and series["missing_seeds"] == [103]
    assert length(Path.wildcard(Path.join(page, "results/*.json"))) == 1
  end

  test "invalid runs and failed builds never leave a new public record", %{dir: dir} do
    page = page(dir)
    source = current()

    assert_raise ArgumentError, fn ->
      Results.publish!(Map.put(source, "status", "running"), page_root: page)
    end

    File.rm!(Path.join(page, "app.js"))
    assert_raise File.Error, fn -> Results.publish!(source, page_root: page) end
    assert Path.wildcard(Path.join(page, "results/*.json")) == []
    assert Path.wildcard(Path.join(page, ".publish-*")) == []
  end

  test "preview serves only public generated files", %{dir: dir} do
    output = Path.join(dir, "dist")
    Results.build!([], output)
    File.write!(Path.join(output, "private.json"), "secret")
    opts = Eab.Results.Preview.init(output)
    assert Eab.Results.Preview.call(Plug.Test.conn(:get, "/"), opts).status == 200
    assert Eab.Results.Preview.call(Plug.Test.conn(:get, "/styles.css?v=123"), opts).status == 200
    assert Eab.Results.Preview.call(Plug.Test.conn(:get, "/private.json"), opts).status == 404
  end

  defp page(dir) do
    page = Path.join(dir, "page")
    File.mkdir_p!(page)

    for file <- ~w(index.html styles.css app.js),
        do: File.cp!(Path.join(Results.root(), file), Path.join(page, file))

    page
  end
end
