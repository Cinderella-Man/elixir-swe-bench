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

  # The series of the current benchmark release on a built page.
  defp built(path) do
    payload = Results.read!(path)
    Enum.find(payload["releases"], & &1["current"])["results"]
  end

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

  # A llama.cpp attempt's measurement, as Eab.ModelSpeed sums it: fractional milliseconds.
  defp llama_measurement do
    %{
      "attempt_ms" => 120_000,
      "model_speed" => %{
        "source" => "server_reported",
        "calls" => 12,
        "prompt_tokens" => 4000,
        "prompt_ms" => 2000.4,
        "generated_tokens" => 1000,
        "generation_ms" => 20_000.6,
        "draft_tokens" => 800,
        "draft_accepted" => 600
      }
    }
  end

  defp strata_measurement do
    %{
      "attempt_ms" => 60_000,
      "model_speed" => %{
        "source" => "controller_timed",
        "calls" => 3,
        "prompt_tokens" => 1000,
        "prompt_ms" => 500,
        "generated_tokens" => 299,
        "generation_ms" => 10_000
      }
    }
  end

  test "preserves tokens and model calls, and each run states its case times and model speed" do
    source =
      run()
      |> put_in(["attempts", "case-a", "generated_tokens"], 1234)
      |> put_in(["attempts", "case-a", "calls"], 12)
      |> put_in(["attempts", "case-a", "measurement"], llama_measurement())
      |> put_in(["attempts", "case-b", "measurement"], strata_measurement())

    run = entry(Results.export!(source))
    [a, b] = run["cases"]
    assert a["generated_tokens"] == 1234 and a["model_calls"] == 12

    assert a["timing"] == %{
             "time_ms" => 120_000,
             "model_speed" => %{
               "source" => "server_reported",
               "calls" => 12,
               "prompt_tokens" => 4000,
               "prompt_ms" => 2000,
               "generated_tokens" => 1000,
               "generation_ms" => 20_001,
               "draft_tokens" => 800,
               "draft_accepted" => 600
             }
           }

    assert b["timing"]["model_speed"]["draft_tokens"] == nil

    assert run["timing"] == %{
             "measured_cases" => 2,
             "time_ms" => 180_000,
             "model_speed" => %{
               "source" => "mixed",
               "calls" => 15,
               "prompt_tokens" => 5000,
               "prompt_ms" => 2500,
               "generated_tokens" => 1299,
               "generation_ms" => 30_001,
               "draft_tokens" => 800,
               "draft_accepted" => 600
             }
           }

    # Only measured cases count; a case timed without model speed adds its time alone.
    partial =
      source
      |> put_in(["attempts", "case-a", "measurement"], %{"attempt_ms" => 5000})
      |> put_in(["attempts", "case-b", "measurement"], %{"not_measured" => "parallel"})

    partial = entry(Results.export!(partial))

    assert Enum.map(partial["cases"], & &1["timing"]) == [
             %{"time_ms" => 5000, "model_speed" => nil},
             nil
           ]

    assert partial["timing"] == %{"measured_cases" => 1, "time_ms" => 5000, "model_speed" => nil}

    # Concurrent attempts' times are not comparable, so none is published (ADR 0014).
    parallel = entry(Results.export!(Map.put(source, "parallel_attempts", 2)))
    assert parallel["timing"] == nil and Enum.all?(parallel["cases"], &is_nil(&1["timing"]))

    untimed = entry(Results.export!(run()))
    assert untimed["timing"] == nil and Enum.all?(untimed["cases"], &is_nil(&1["timing"]))
  end

  test "a published run's timing must add up, and only a one-case-at-a-time Pi run has any" do
    record =
      run()
      |> put_in(["attempts", "case-a", "measurement"], llama_measurement())
      |> Results.export!()

    change = fn fun -> update_in(record, ["runs"], fn [run] -> [fun.(run)] end) end

    set_case = fn key, value ->
      change.(&put_in(&1, ["cases", Access.at(0), "timing", key], value))
    end

    for {message, bad} <- [
          {~r/must sum/, change.(&put_in(&1, ["timing", "time_ms"], 1))},
          {~r/must sum/, change.(&put_in(&1, ["timing"], nil))},
          {~r/one case at a time/, change.(&put_in(&1, ["deployment", "parallel_attempts"], 2))},
          {~r/nonnegative/, set_case.("time_ms", -1)},
          {~r/Unexpected case timing/, set_case.("wall_ms", 1)},
          {~r/Unexpected model speed/,
           set_case.("model_speed", Map.delete(llama_measurement()["model_speed"], "calls"))},
          {~r/Draft tokens/,
           change.(
             &put_in(&1, ["cases", Access.at(0), "timing", "model_speed", "draft_accepted"], 900)
           )}
        ] do
      assert_raise ArgumentError, message, fn -> Results.validate!(bad) end
    end

    claude_code = %{
      "name" => "claude_code",
      "version" => "2.3.0",
      "agent" => "solver",
      "kit_sha256" => String.duplicate("c", 64),
      "preamble_sha256" => String.duplicate("d", 64)
    }

    assert_raise ArgumentError, ~r/Only Pi/, fn ->
      Results.validate!(Map.put(record, "harness", claude_code))
    end
  end

  test "older series stay valid unchanged and are upgraded when they take another run" do
    timed = fn source ->
      put_in(source, ["attempts", "case-a", "measurement"], llama_measurement())
    end

    record = Results.export!(timed.(run()))
    assert record["schema_version"] == 12

    published =
      record
      |> Map.put("schema_version", 8)
      |> update_in(["runs"], fn [run] ->
        [
          run
          |> Map.drop(["timing", "machine"])
          |> Map.update!("cases", fn cases ->
            Enum.map(cases, &Map.drop(&1, ["timing", "patch_passed", "peak_context_tokens"]))
          end)
        ]
      end)

    assert Results.validate!(published)

    assert_raise ArgumentError, fn ->
      Results.validate!(Map.put(published, "schema_version", 9))
    end

    assert_raise ArgumentError, fn ->
      Results.validate!(put_in(published, ["runs", Access.at(0), "timing"], nil))
    end

    second =
      run()
      |> Map.merge(%{"id" => "test-run-2", "created_at" => "2026-10-18T12:00:00Z"})
      |> put_in(["settings", "seed"], 102)
      |> timed.()
      |> Results.export!()

    merged = Results.merge!(published, second)
    assert merged["schema_version"] == 12
    [first, added] = merged["runs"]
    assert first["timing"] == nil and Enum.all?(first["cases"], &is_nil(&1["timing"]))
    assert first["machine"] == nil
    # Before schema 11 a case's outcome was its patch's verdict; before 12 no peak was recorded.
    assert Enum.all?(first["cases"], &(&1["patch_passed"] == &1["passed"]))
    assert Enum.all?(first["cases"], &is_nil(&1["peak_context_tokens"]))
    assert added["timing"]["time_ms"] == 120_000

    # A repeated click keeps the published file as it was.
    assert Results.merge!(published, record) == published
  end

  # A run's memory record from the model host, with the server's command line.
  defp machine_memory(args, ram \\ 137_438_953_472) do
    identity =
      Map.take(snapshot(), ~w(model_artifact backend backend_version context_tokens kv_cache cpu))
      |> Map.merge(%{
        "host" => "private-machine",
        "service" => "private.service",
        "server_args" => args
      })

    %{
      "kind" => "run_samples",
      "status" => "complete",
      "sample_count" => 2,
      "peaks" => %{
        "vram_bytes" => 100,
        "service_ram_bytes" => 80,
        "process_rss_bytes" => 90,
        "combined_bytes" => 120
      },
      "sessions" => [
        %{
          "identity" => identity,
          "started_at" => "2026-10-18T00:00:00Z",
          "finished_at" => "2026-10-18T00:00:02Z",
          "sample_count" => 2,
          "interval_ms" => 1000,
          "gap_count" => 0,
          "host_ram_bytes" => ram,
          "gpus" => [
            %{
              "uuid" => "private-gpu",
              "name" => "fixture",
              "capacity_bytes" => 1000,
              "used_bytes" => 100
            }
          ]
        }
      ]
    }
  end

  @server_args [
    "/private/bin/llama-server",
    "--model",
    "/models/private-model.gguf",
    "-ngl",
    "99",
    "-ts",
    "1,1",
    "-fa",
    "on",
    "--no-mmap",
    "-ctk",
    "q8_0",
    "--model-draft",
    "/models/private-dir/draft-0.6B.gguf",
    "-ot",
    "exps=CPU",
    "-ot",
    "blk.1=CUDA0",
    "-t",
    "-1",
    "--parallel=1",
    "--host",
    "10.9.8.7",
    "--port",
    "8414",
    "--api-key-file",
    "/private/secret-key"
  ]

  defp with_machine(source, args \\ @server_args) do
    source
    |> put_in(["settings", "window_tokens"], 262_144)
    |> Map.put("memory", machine_memory(args))
  end

  test "each run names its machine: GPUs, CPU, RAM, server and its speed flags, never paths or keys" do
    record = Results.export!(with_machine(run()))

    assert entry(record)["machine"] == %{
             "gpus" => [%{"name" => "fixture", "memory_bytes" => 1000}],
             "cpu" => "fixture",
             "ram_bytes" => 137_438_953_472,
             "server" => "llama_cpp",
             "server_build" => "fixture",
             "kv_cache" => "f16",
             "flags" => %{
               "--n-gpu-layers" => "99",
               "--tensor-split" => "1,1",
               "--flash-attn" => "on",
               "--no-mmap" => true,
               "--cache-type-k" => "q8_0",
               "--model-draft" => "draft-0.6B.gguf",
               "--override-tensor" => "exps=CPU blk.1=CUDA0",
               "--threads" => "-1",
               "--parallel" => "1"
             }
           }

    for private <-
          ~w(private-machine private.service private-gpu private-model private-dir secret-key 10.9.8.7 8414 /private/),
        do: refute(Jason.encode!(record) =~ private)

    # Without a memory record, or a command line, nothing is invented.
    assert entry(Results.export!(run()))["machine"] == nil
    assert entry(Results.export!(with_machine(run(), [])))["machine"]["flags"] == nil

    change = fn fun -> update_in(record, ["runs"], fn [run] -> [fun.(run)] end) end

    for {message, bad} <- [
          {~r/Unexpected server flag/,
           change.(&put_in(&1, ["machine", "flags", "--api-key-file"], "/secret"))},
          {~r/Invalid value/, change.(&put_in(&1, ["machine", "flags", "--threads"], 4))},
          {~r/Unknown model server/, change.(&put_in(&1, ["machine", "server"], "vllm"))},
          {~r/Invalid system RAM/, change.(&put_in(&1, ["machine", "ram_bytes"], 0))},
          {~r/Unexpected machine fields/, change.(&put_in(&1, ["machine", "host"], "rig"))}
        ] do
      assert_raise ArgumentError, message, fn -> Results.validate!(bad) end
    end

    # A run whose sessions saw different machines cannot say which one it ran on.
    source = with_machine(run())
    [session] = source["memory"]["sessions"]
    other = Map.put(session, "host_ram_bytes", 68_719_476_736)

    assert_raise ArgumentError, ~r/different machines/, fn ->
      Results.export!(put_in(source, ["memory", "sessions"], [session, other]))
    end
  end

  # A completed speed run of case-b, the example benchmark's only speed case here.
  defp speed_run do
    run()
    |> with_machine()
    |> Map.merge(%{
      "cases" => ["case-b"],
      "selection" => %{"kind" => "speed", "cases" => ["case-b"]}
    })
    |> put_in(["attempts", "case-b", "measurement"], llama_measurement())
    |> Map.update!("attempts", &Map.take(&1, ["case-b"]))
  end

  test "a speed run publishes its speed cases' times and its machine, apart from any series" do
    speed = Results.export_speed!(speed_run(), speed_cases: ["case-b"])
    assert speed["kind"] == "speed_run" and speed["schema_version"] == 12
    assert speed["series_id"] == Eab.Series.id(with_machine(run()))
    assert speed["run"]["run_id"] == "test-run"
    assert Enum.map(speed["run"]["cases"], & &1["id"]) == ["case-b"]
    assert Map.keys(speed["case_fixtures"]) == ["case-b"]
    assert speed["run"]["timing"]["time_ms"] == 120_000
    assert speed["run"]["machine"]["flags"]["--tensor-split"] == "1,1"
    refute Jason.encode!(speed) =~ "private"

    for {message, bad} <- [
          {~r/not this benchmark's speed cases/,
           fn -> Results.export_speed!(speed_run(), speed_cases: ["case-a"]) end},
          {~r/one case at a time/,
           fn ->
             Results.export_speed!(Map.put(speed_run(), "parallel_attempts", 2),
               speed_cases: ["case-b"]
             )
           end},
          {~r/states its time/,
           fn ->
             speed_run()
             |> put_in(["attempts", "case-b", "measurement"], %{"not_measured" => "off"})
             |> Results.export_speed!(speed_cases: ["case-b"])
           end},
          {~r/names the machine/,
           fn ->
             Results.export_speed!(Map.delete(speed_run(), "memory"), speed_cases: ["case-b"])
           end},
          {~r/published on its own/, fn -> Results.export!(speed_run()) end},
          {~r/Only a speed run/, fn -> Results.export_speed!(run(), speed_cases: ["case-b"]) end}
        ] do
      assert_raise ArgumentError, message, bad
    end
  end

  test "speed runs are added beside the series, listed on the page and kept on repeat clicks",
       %{dir: dir} do
    page = page(dir)
    inventory = Eab.Inventory.definition()
    cases = Eab.Inventory.speed_cases()
    full = current() |> with_machine()

    source =
      full
      |> Map.merge(%{
        "id" => "speed-run",
        "cases" => cases,
        "selection" => %{"kind" => "speed", "cases" => cases}
      })
      |> Map.update!("attempts", fn attempts ->
        attempts
        |> Map.take(cases)
        |> Map.new(fn {id, attempt} ->
          {id, Map.put(attempt, "measurement", llama_measurement())}
        end)
      end)

    opts = [page_root: page, inventory: inventory]
    assert Results.publish!(source, opts) == :added
    assert File.regular?(Path.join([page, "speed", "speed-run.json"]))
    assert Results.added?("speed-run", page_root: page)
    assert Results.publish!(source, opts) == :already_added
    assert Path.wildcard(Path.join(page, "results/*.json")) == []

    payload = Results.read!(Path.join(page, "dist/results.json"))
    assert payload["schema_version"] == 12
    release = Enum.find(payload["releases"], & &1["current"])
    assert release["speed_cases"] == cases
    assert [%{"run" => %{"run_id" => "speed-run"}}] = release["speed_runs"]

    # A full run beside it publishes as before, with its machine.
    assert Results.publish!(full, opts) == :added
    [series] = built(Path.join(page, "dist/results.json"))
    assert entry(series)["machine"]["cpu"] == "fixture"
  end

  test "speed cases are current cases in inventory order, named for this benchmark" do
    definition = Eab.Inventory.definition()
    cases = Eab.Inventory.speed_cases(definition)
    assert Enum.filter(definition["cases"], &(&1 in cases)) == cases

    assert_raise ArgumentError, ~r/another benchmark/, fn ->
      Eab.Inventory.speed_cases(Map.put(definition, "id", "another-benchmark"))
    end

    assert_raise ArgumentError, ~r/inventory order/, fn ->
      Eab.Inventory.speed_cases(Map.put(definition, "cases", Enum.reverse(definition["cases"])))
    end

    # A speed run resumes on exactly its speed cases.
    release = %{"protocol" => %{"inventory" => definition}}

    speed = fn cases ->
      %{"cases" => cases, "selection" => %{"kind" => "speed", "cases" => cases}}
    end

    assert Eab.Checkpoints.validate_cases!(speed.(cases), release) == :ok

    assert_raise RuntimeError, ~r/differ from the frozen selection/, fn ->
      Eab.Checkpoints.validate_cases!(speed.(Enum.reverse(cases)), release)
    end
  end

  test "each case says which budget cut its attempt off, including older Pi runs" do
    cut = fn stop, tokens, backend ->
      Results.cutoff(%{"stop_reason" => stop, "generated_tokens" => tokens}, 65_536, backend)
    end

    assert cut.("token_budget", 65_536, "llama_cpp") == "generation_budget"
    assert cut.("context_budget", 43_807, "llama_cpp") == "context_budget"
    assert cut.("response_budget", 46_267, "strata") == "response_budget"
    assert cut.("agent_completed", 40_000, "llama_cpp") == nil
    # Older Pi runs recorded a final reply cut at the remaining budget as agent_completed.
    assert cut.("agent_completed", 65_536, "llama_cpp") == "generation_budget"
    # Subscriptions treat the budget as a soft threshold; Claude Code cannot enforce it.
    assert cut.("agent_completed", 70_000, "anthropic") == nil
    assert cut.("agent_completed", 300_000, "claude_code") == nil
    assert cut.("context_limit", 90_000, "claude_code") == "context_budget"
    assert cut.("response_limit", 90_000, "claude_code") == "response_budget"

    source =
      run()
      |> put_in(["attempts", "case-a", "stop_reason"], "response_budget")
      |> put_in(["attempts", "case-b", "generated_tokens"], 65_536)

    record = Results.export!(source)

    assert Enum.map(entry(record)["cases"], & &1["cutoff"]) == [
             "response_budget",
             "generation_budget"
           ]

    bad = fn cutoff, harness ->
      record
      |> update_in(["runs"], fn [run] ->
        [
          update_in(run["cases"], fn [a, b] ->
            [%{a | "cutoff" => cutoff}, %{b | "cutoff" => nil}]
          end)
        ]
      end)
      |> Map.put("harness", harness)
    end

    assert_raise ArgumentError, ~r/cutoff must be/, fn ->
      Results.validate!(bad.("tired", record["harness"]))
    end

    claude_code = %{
      "name" => "claude_code",
      "version" => "2.3.0",
      "agent" => "solver",
      "kit_sha256" => String.duplicate("c", 64),
      "preamble_sha256" => String.duplicate("d", 64)
    }

    assert Results.validate!(bad.("context_budget", claude_code))

    assert_raise ArgumentError, ~r/Only Pi enforces/, fn ->
      Results.validate!(bad.("generation_budget", claude_code))
    end
  end

  test "each published run states its parallel attempts; older records without it still validate" do
    assert entry(Results.export!(run()))["deployment"]["parallel_attempts"] == 1
    record = Results.export!(Map.put(run(), "parallel_attempts", 4))
    assert entry(record)["deployment"]["parallel_attempts"] == 4

    older =
      update_in(record, ["runs"], fn [run] ->
        [update_in(run["deployment"], &Map.delete(&1, "parallel_attempts"))]
      end)

    assert Results.validate!(older)

    for bad <- [0, 9, "4"] do
      invalid =
        update_in(record, ["runs"], fn [run] ->
          [put_in(run, ["deployment", "parallel_attempts"], bad)]
        end)

      assert_raise ArgumentError, fn -> Results.validate!(invalid) end
    end
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

    # An owner's label is a display name; the artifact still has to be the series'.
    labelled = Results.export!(source, resources: snapshot(), model_label: "Swift 1.5 27B")
    assert labelled["model"]["name"] == "Swift 1.5 27B"
    assert entry(labelled)["resources"]["model_artifact"] == "Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf"

    for {key, value} <- [
          {"context_tokens", 65536},
          {"model_artifact", "Other-Q4_K_M.gguf"},
          {"model_artifact", "Swift-1.5-Qwen3.8-27B-Q5_K_M.gguf"},
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

    # Strata reports only its pack folder; the collector names the GGUF shards behind it.
    shards = ~w(Model-1017-UD-IQ1_M-00001-of-00002.gguf Model-1017-UD-IQ1_M-00002-of-00002.gguf)

    pack =
      source
      |> Map.put("model", %{
        "model" => "model-alias",
        "backend" => "strata",
        "profile" => %{"model_path" => "/private/hot/model/pack"}
      })
      |> update_in(["memory", "sessions", Access.at(0), "identity"], fn identity ->
        Map.merge(identity, %{
          "model_artifact" => "pack",
          "backend" => "strata",
          "weight_files" => %{
            "size_bytes" => 30,
            "files" => Enum.map(shards, &%{"name" => &1, "size_bytes" => 15})
          }
        })
      end)

    result = Results.export!(pack)
    assert result["model"]["name"] == "Model-1017"
    assert result["model"]["quantization"] == "UD-IQ1_M"
    assert result["model"]["quantization_source"] == "artifact_files"
    assert result["model"]["size_bytes"] == 30
    assert result["setup"]["model"]["name"] == "model-alias"
    assert result["setup"]["model"]["artifact"] == nil
    refute Jason.encode!(result) =~ "/private/hot"

    unobserved =
      update_in(
        pack,
        ["memory", "sessions", Access.at(0), "identity"],
        &Map.delete(&1, "weight_files")
      )

    result = Results.export!(unobserved)
    assert result["model"]["name"] == "model-alias"
    assert result["model"]["quantization_source"] == "not_reported"
    assert entry(result)["resources"]["model_artifact"] == "pack"

    assert Results.export!(unobserved, quantization: "IQ1_M")["model"]["quantization_source"] ==
             "owner_supplied"

    # An owner value that contradicts the observed files is still rejected.
    assert_raise ArgumentError, ~r/different model artifact/, fn ->
      Results.export!(pack, quantization: "IQ1_M")
    end
  end

  test "the maker comes from the served file, or from the publisher when the file names none" do
    artifact = "Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf"
    weights = %{"size_bytes" => 1234, "files" => [%{"name" => artifact, "size_bytes" => 1234}]}

    session = fn files ->
      %{
        "sample_count" => 1,
        "identity" => %{
          "model_artifact" => artifact,
          "backend" => "llama_cpp",
          "weight_files" => files
        }
      }
    end

    named =
      Map.put(run(), "memory", %{
        "sessions" => [session.(Map.put(weights, "quantized_by", "ukisai"))]
      })

    result = Results.export!(named, resources: nil)
    assert result["model"]["quantized_by"] == "ukisai"
    assert result["model"]["quantized_by_source"] == "artifact_files"
    assert result["setup"]["model"]["quantized_by"] == "ukisai"

    assert Results.export!(named, resources: nil, quantized_by: "ukisai")["model"][
             "quantized_by_source"
           ] ==
             "artifact_files"

    assert_raise ArgumentError, ~r/names its maker as ukisai/, fn ->
      Results.export!(named, resources: nil, quantized_by: "bartowski")
    end

    # A file that names no one takes the publisher's word, shown but not part of the identity.
    silent = Results.export!(run(), quantized_by: "ukisai")
    assert silent["model"]["quantized_by"] == "ukisai"
    assert silent["model"]["quantized_by_source"] == "owner_supplied"
    refute Map.has_key?(silent["setup"]["model"], "quantized_by")
    assert silent["series_id"] != result["series_id"]
    assert Results.export!(run())["model"]["quantized_by_source"] == "not_reported"

    assert_raise ArgumentError, ~r/unreported maker/, fn ->
      Results.validate!(put_in(silent, ["model", "quantized_by_source"], "not_reported"))
    end
  end

  test "the declared source, the hashed files and the GGUF's release details are published" do
    artifact = "Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf"
    sha = String.duplicate("e", 64)
    commit = String.duplicate("1", 40)
    file = %{"name" => artifact, "size_bytes" => 1234, "sha256" => sha}

    {:ok, declared} =
      Eab.ModelSource.declare(
        "https://huggingface.co/ukisai/Swift-GGUF/blob/main/#{artifact}",
        "v2"
      )

    source =
      Map.put(declared, "lookup", %{
        "commit" => String.duplicate("3", 40),
        "commit_date" => "2026-11-12T00:00:00.000Z",
        "files" => [
          %{
            "path" => artifact,
            "size_bytes" => 1234,
            "sha256" => sha,
            "last_commit" => commit,
            "last_commit_date" => "2026-11-10T00:00:00.000Z"
          }
        ]
      })

    session = %{
      "sample_count" => 1,
      "identity" => %{
        "model_artifact" => artifact,
        "backend" => "llama_cpp",
        "weight_files" => %{
          "size_bytes" => 1234,
          "files" => [Map.delete(file, "sha256")],
          "gguf" => %{"general.version" => "v2", "quantize.imatrix.chunks_count" => 720}
        }
      },
      "weight_hashes" => %{"status" => "hashed", "files" => [file]}
    }

    traced =
      run()
      |> put_in(["model", "source"], source)
      |> Map.put("memory", %{"sessions" => [session]})

    result = Results.export!(traced, resources: nil, network: false)
    model = result["model"]
    assert model["weight_files"] == [file]
    assert result["setup"]["model"]["sha256"] == [sha]
    assert model["gguf"] == %{"general.version" => "v2", "quantize.imatrix.chunks_count" => 720}

    assert Map.take(model["source"], ~w(author repository release_label commit verification)) ==
             %{
               "author" => "ukisai",
               "repository" => "ukisai/Swift-GGUF",
               "release_label" => "v2",
               "commit" => commit,
               "verification" => "verified"
             }

    refute Jason.encode!(result) =~ "lookup"

    # Without hashes the source is published unchecked; a label needs a source.
    plain = put_in(run(), ["model", "source"], declared)
    unchecked = Results.export!(plain, network: false)["model"]
    assert unchecked["source"]["verification"] == "not_checked"
    assert unchecked["weight_files"] == nil and unchecked["gguf"] == nil

    assert_raise ArgumentError, ~r/needs the model's source/, fn ->
      Results.export!(run(), release_label: "v3")
    end

    # The publisher can name the source of an older run; a bad link or field is refused.
    supplied =
      Results.export!(run(),
        source_url: "https://example.com/#{artifact}",
        release_label: "v1",
        network: false
      )["model"]["source"]

    assert supplied["declared_by"] == "publisher" and supplied["release_label"] == "v1"

    assert_raise ArgumentError, fn ->
      Results.export!(run(), source_url: "https://huggingface.co/x")
    end

    assert_raise ArgumentError, ~r/verified source/, fn ->
      Results.validate!(
        put_in(result, ["model", "weight_files"], nil)
        |> put_in(["setup", "model"], %{})
      )
    end

    assert_raise ArgumentError, ~r/Unexpected GGUF key/, fn ->
      Results.validate!(put_in(result, ["model", "gguf"], %{"tokenizer.chat_template" => "x"}))
    end

    assert_raise ArgumentError, ~r/setup's weight hashes/, fn ->
      Results.validate!(put_in(result, ["setup", "model", "sha256"], [String.duplicate("f", 64)]))
    end
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
    [built] = built(Path.join(output, "results.json"))
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
    assert built(Path.join(output, "results.json")) == []
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
    [built] = built(Path.join(page, "dist/results.json"))
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
    [series] = built(Path.join(page, "dist/results.json"))
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

  test "an earlier release stays on the page beside the current one, which takes new runs",
       %{dir: dir} do
    page = page(dir)
    source = current()
    inventory = source["protocol"]["inventory"]
    opts = [page_root: page, inventory: inventory]

    # A series published on an earlier release: another benchmark ID and other case files.
    earlier =
      source
      |> Map.put("id", "earlier-run")
      |> Results.export!()
      |> Map.put("benchmark", "example-benchmark-v1")
      |> update_in(["case_fixtures"], fn fixtures ->
        Map.new(fixtures, fn {id, files} ->
          {id, Map.put(files, "ticket.md", String.duplicate("e", 64))}
        end)
      end)

    folder = Path.join(page, "releases/v1")
    File.mkdir_p!(folder)
    Results.write!(Path.join(folder, earlier["series_id"] <> ".json"), earlier)

    # It is checked against its own series, not the current cases, and does not take runs.
    assert [%{"id" => "example-benchmark-v1", "records" => [_]}] = Results.frozen!(page)
    assert Results.load!(Path.join(page, "results")) == []
    assert Results.added?("earlier-run", page_root: page)

    # Without settings the current release is the one the page shows first.
    assert Results.publish!(source, opts) == :added
    payload = Results.read!(Path.join(page, "dist/results.json"))
    assert payload["primary"] == inventory["id"]

    assert [
             %{"label" => "v1", "current" => false, "results" => [old]},
             %{"current" => true, "results" => [new]}
           ] = payload["releases"]

    assert hd(payload["releases"])["benchmark"] == %{
             "id" => "example-benchmark-v1",
             "case_count" => length(inventory["cases"])
           }

    assert entry(old)["run_id"] == "earlier-run" and entry(new)["run_id"] == source["id"]
    assert old["score_percent"] == 100.0

    # releases.json names the release shown first and a note for each.
    Results.write!(Path.join(page, "releases.json"), %{
      "primary" => "example-benchmark-v1",
      "notes" => %{"example-benchmark-v1" => "Earlier limits."}
    })

    Results.build!(Results.load!(Path.join(page, "results")), Path.join(page, "dist"), opts)
    payload = Results.read!(Path.join(page, "dist/results.json"))
    assert payload["primary"] == "example-benchmark-v1"
    assert hd(payload["releases"])["note"] == "Earlier limits."
    assert List.last(payload["releases"])["note"] == nil

    Results.write!(Path.join(page, "releases.json"), %{"primary" => "no-such-benchmark"})

    assert_raise ArgumentError, ~r/not a release on this page/, fn ->
      Results.build!([], Path.join(page, "dist"), opts)
    end

    Results.write!(Path.join(page, "releases.json"), %{"main" => "example-benchmark-v1"})
    assert_raise ArgumentError, ~r/releases.json holds/, fn -> Results.page_settings(page) end
    File.rm!(Path.join(page, "releases.json"))

    # Series of one earlier release must agree with each other.
    stray =
      earlier
      |> Map.put("series_id", String.duplicate("d", 64))
      |> Map.put("benchmark", "example-benchmark-v0")
      |> put_in(["runs", Access.at(0), "run_id"], "stray-run")

    Results.write!(Path.join(folder, stray["series_id"] <> ".json"), stray)
    assert_raise ArgumentError, ~r/must share its benchmark/, fn -> Results.frozen!(page) end
    File.rm!(Path.join(folder, stray["series_id"] <> ".json"))

    # An earlier release cannot carry the current benchmark's ID.
    same = Map.put(earlier, "benchmark", inventory["id"])
    Results.write!(Path.join(folder, earlier["series_id"] <> ".json"), same)

    assert_raise ArgumentError, ~r/belong in results/, fn ->
      Results.build!([], Path.join(page, "dist"), opts)
    end
  end

  test "the repository's own page settings name a release it holds" do
    releases = Enum.map(Results.frozen!(), & &1["id"]) ++ [Eab.Inventory.definition()["id"]]
    settings = Results.page_settings()
    assert (settings["primary"] || List.last(releases)) in releases
    assert Map.keys(settings["notes"] || %{}) -- releases == []
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

  test "every current case has the summary page its name links to" do
    assert Results.missing_case_pages(Eab.Inventory.all()) == []
    assert Results.missing_case_pages(["no-such-case"]) == ["no-such-case"]
  end

  defp allowance(cases, tokens) do
    %{
      "validator" => "Fixture validator",
      "multiple" => 2,
      "minimum_tokens" => 16_384,
      "validator_tokens" => Map.new(cases, &{&1, [tokens]})
    }
  end

  test "under token allowances a series records them and each case's patch verdict" do
    source =
      run()
      |> put_in(["protocol", "inventory", "allowance"], allowance(~w(case-a case-b), 40_000))
      |> put_in(["attempts", "case-b"], %{
        "status" => "completed",
        "stop_reason" => "token_budget",
        "generated_tokens" => 80_000,
        "grade" => %{"passed" => false, "patch_passed" => true}
      })

    record = Results.export!(source)
    assert record["schema_version"] == 12
    assert record["setup"]["allowance"]["tokens"] == %{"case-a" => 80_000, "case-b" => 80_000}
    assert record["series_id"] != Results.export!(run())["series_id"]

    [inside, stopped] = entry(record)["cases"]
    assert inside["passed"] and inside["patch_passed"]
    refute stopped["passed"]
    assert stopped["patch_passed"] and stopped["cutoff"] == "generation_budget"

    # A case cannot pass on a failing patch, and every case needs its allowance.
    assert_raise ArgumentError, ~r/patch_passed/, fn ->
      Results.validate!(
        put_in(record, ["runs", Access.at(0), "cases", Access.at(0), "patch_passed"], false)
      )
    end

    assert_raise ArgumentError, ~r/token allowance/, fn ->
      Results.validate!(
        update_in(record, ["setup", "allowance", "tokens"], &Map.delete(&1, "case-b"))
      )
    end
  end

  test "a page takes only series made under the current release's token allowances", %{dir: dir} do
    inventory = Eab.Inventory.definition()
    limited = Map.put(inventory, "allowance", allowance(inventory["cases"], 40_000))
    output = Path.join(dir, "dist")
    made_without = Results.export!(current())
    made_under = Results.export!(put_in(current(), ["protocol", "inventory"], limited))

    assert_raise ArgumentError, ~r/other token allowances/, fn ->
      Results.build!([made_under], output)
    end

    assert_raise ArgumentError, ~r/other token allowances/, fn ->
      Results.build!([made_without], output, inventory: limited)
    end

    Results.build!([made_under], output, inventory: limited)
    [built] = built(Path.join(output, "results.json"))
    assert built["setup"]["allowance"]["tokens"][hd(inventory["cases"])] == 80_000
  end

  test "each case's peak context is published and gives the series a score at every context size",
       %{dir: dir} do
    inventory = Eab.Inventory.definition()
    [first, second | _] = inventory["cases"]

    source =
      current()
      |> Map.update!("attempts", fn attempts ->
        Map.new(attempts, fn {id, attempt} ->
          {id,
           Map.put(attempt, "peak_context_tokens", if(id == first, do: 200_000, else: 50_000))}
        end)
      end)
      # The window cut this attempt off; its patch passed, but it did not finish inside any size.
      |> update_in(["attempts", second], &Map.put(&1, "stop_reason", "context_budget"))

    record = Results.export!(source)
    cases = Map.new(entry(record)["cases"], &{&1["id"], &1})
    assert cases[first]["peak_context_tokens"] == 200_000
    assert cases[second]["cutoff"] == "context_budget" and cases[second]["passed"]

    assert_raise ArgumentError, ~r/peak_context_tokens/, fn ->
      Results.validate!(
        put_in(record, ["runs", Access.at(0), "cases", Access.at(0), "peak_context_tokens"], 0)
      )
    end

    output = Path.join(dir, "dist")

    # Another series of the same model, made without recording peaks.
    unrecorded =
      current()
      |> Map.put("id", "no-peaks-run")
      |> put_in(["settings", "max_tokens"], 100_000)
      |> Results.export!()

    Results.build!([record, unrecorded], output)
    payload = Results.read!(Path.join(output, "results.json"))
    release = Enum.find(payload["releases"], & &1["current"])
    assert release["context_sizes"] == Eab.ContextSize.sizes()

    [with_peaks] = Enum.filter(release["results"], & &1["by_context"])
    total = length(inventory["cases"])
    assert with_peaks["score_percent"] == 100.0
    # Inside 65,536 tokens: everything but the large attempt and the one that was cut off.
    assert with_peaks["by_context"]["65536"]["score_percent"] ==
             Float.round(100 * (total - 2) / total, 2)

    assert with_peaks["by_context"]["65536"]["case_passes"][first] == 0
    # Inside 262,144: the large attempt fits; the cut-off one still does not count.
    assert with_peaks["by_context"]["262144"]["case_passes"][first] == 1
    assert with_peaks["by_context"]["262144"]["case_passes"][second] == 0

    # A run that recorded no peaks has no score at a size.
    assert Enum.find(release["results"], &(&1["series_id"] == unrecorded["series_id"]))[
             "by_context"
           ] == nil
  end
end
