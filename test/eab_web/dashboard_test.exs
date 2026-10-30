defmodule EabWeb.DashboardTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint EabWeb.Endpoint

  test "saved presets and synthetic durations appear in case details and indexed history" do
    id = "thinking-duration-ui"
    case_id = "synthetic-case"
    settings = Eab.Thinking.settings(%{}, %{"reasoning_effort" => "off"})

    attempt = %{
      "status" => "completed",
      "grade" => %{"passed" => true},
      "measurement" => %{"attempt_ms" => 1234}
    }

    run = %{
      "id" => id,
      "created_at" => "9999-01-01T00:00:00Z",
      "status" => "completed",
      "cases" => [case_id],
      "attempts" => %{case_id => attempt},
      "settings" => settings,
      "model" => %{"model" => "fixture"}
    }

    Eab.Store.write("runs/#{id}/run.json", run)
    Eab.Store.write("runs/#{id}/#{case_id}/attempt.json", attempt)
    Eab.Store.index_run(run)
    on_exit(fn -> File.rm_rf!(Eab.Store.path("runs/#{id}")) end)
    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, "#run-thinking", "Thinking: Off")
    assert has_element?(view, ".history-row", "Thinking: Off")
    view |> element("#case-#{case_id}") |> render_click()
    assert has_element?(view, "#case-time", "Case time: 1.234 s")
  end

  test "a retired case in a saved run still shows and follows its command output" do
    id = "live-log-test"
    case_id = "plausible-pr-6300"

    Eab.Store.write("runs/#{id}/run.json", %{
      "id" => id,
      "created_at" => "9999-01-01T00:00:00Z",
      "status" => "running",
      "phase" => "qualifying",
      "message" => "Checking tests",
      "current_case" => case_id,
      "cases" => [case_id],
      "attempts" => %{},
      "settings" => %{},
      "model" => %{"model" => "synthetic"}
    })

    Eab.Store.write_text("runs/#{id}/#{case_id}/activity.log", "$ mix test\nCompiling project\n")
    on_exit(fn -> File.rm_rf!(Eab.Store.path("runs/#{id}")) end)
    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, "#case-#{case_id}[aria-expanded=false]")
    refute has_element?(view, "#case-log")
    view |> element("#case-#{case_id}") |> render_click()
    assert has_element?(view, "#case-#{case_id}[aria-expanded=true]")
    assert has_element?(view, "#case-panel-#{case_id} #case-log", "Compiling project")
    assert has_element?(view, "#case-log", "$ mix test")

    Eab.Store.write_text(
      "runs/#{id}/#{case_id}/activity.log",
      "$ mix test\nCompiling project\nTests finished\n"
    )

    send(view.pid, :poll_log)
    assert render(view) =~ "Tests finished"

    assert has_element?(
             view,
             "#case-log-download[href='/artifacts/#{id}/#{case_id}/activity.log']"
           )

    view |> element("#case-#{case_id}") |> render_click()
    assert has_element?(view, "#case-#{case_id}[aria-expanded=false]")
    refute has_element?(view, "#case-panel-#{case_id}")
    send(view.pid, :poll_log)
    refute has_element?(view, "#case-log")
    view |> element("#case-#{case_id}") |> render_click()
    assert has_element?(view, "#case-panel-#{case_id} #case-log", "Tests finished")
  end

  test "local setup page shows current PR cases and waits for a model connection" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Benchmark dashboard"
    assert html =~ "Model and tool calls are unlimited."
    refute has_element?(view, "input[name='settings[max_calls]']")
    assert has_element?(view, "input[name='settings[reasoning_effort]'][value='']")
    assert has_element?(view, "#thinking-presets option[value='on']")
    assert has_element?(view, "#thinking-presets option[value='max']")
    assert has_element?(view, "#case-timing-status", "Case timing is always recorded")
    assert has_element?(view, "#run[disabled]")
    assert html =~ "plausible-pr-5939"
    refute html =~ "plausible-pr-6300"
    refute html =~ "plausible-pr-6763"
    refute html =~ "plausible-pr-6441"
    ids = Eab.Inventory.all()
    assert has_element?(view, ".inventory-summary strong", "#{length(ids)} cases")

    for id <- ids, do: assert(has_element?(view, ".case-inventory article .eyebrow", id))
  end

  test "offline readiness lists what is missing and preparation can be started and stopped" do
    parent = self()
    cleanup = Application.get_env(:eab, :cleanup)
    Application.put_env(:eab, :cleanup, fn _ -> :ok end)

    on_exit(fn ->
      Application.delete_env(:eab, :qualification)

      if cleanup,
        do: Application.put_env(:eab, :cleanup, cleanup),
        else: Application.delete_env(:eab, :cleanup)
    end)

    Application.put_env(:eab, :qualification, fn emit, _ ->
      emit.("first: preparing")
      send(parent, :preparing)

      receive do
        :finish -> %{"status" => "qualified"}
      end
    end)

    {:ok, view, _} = live(build_conn(), "/")
    total = length(Eab.Inventory.all())
    assert render_async(view) =~ "0 of #{total} cases are ready."
    assert has_element?(view, "#readiness-summary li", "plausible-pr-5939: needs source check")
    assert has_element?(view, "#readiness-summary", "Stay online and prepare the rest.")

    view |> element("#prepare-all") |> render_click()
    assert_receive :preparing, 3000
    assert has_element?(view, "#stop-preparation")
    refute has_element?(view, "#prepare-all")
    assert has_element?(view, "#run[disabled]")
    assert render(view) =~ "0 of #{total} cases finished."

    view |> element("#stop-preparation") |> render_click()
    assert has_element?(view, "#preparation-status", "Finished cases stay prepared")
    assert has_element?(view, "#prepare-all")

    Enum.find(1..200, fn _ ->
      Process.sleep(10)
      not Eab.Runs.snapshot().cleaning
    end)
  end

  test "offline mode says so and keeps prepared state from being removed" do
    on_exit(fn -> Application.delete_env(:eab, :offline) end)
    Application.put_env(:eab, :offline, true)
    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, "#offline-mode", "Nothing is downloaded or built")
    assert has_element?(view, "#cache-preview button[disabled]", "Preview removal")
  end

  test "completed runs can be added from the dashboard and viewed without exporting a file" do
    run = publication_run()
    page = publication_page(run)
    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, "#add-result:not([disabled])", "Add to results page")
    view |> element("#add-result") |> render_click()
    assert render_async(view) =~ "Added to the local results page"
    assert has_element?(view, "#add-result[disabled]", "Added to results page")
    assert has_element?(view, "#result-publication a[href='/results/']")
    assert render(view) =~ "Push the result file to GitHub"

    [public] = Eab.Results.load!(Path.join(page, "results"))
    assert public == Eab.Results.export!(run, inventory: run["protocol"]["inventory"])
    [built] = Eab.Results.read!(Path.join(page, "dist/results.json"))["results"]
    assert built["score_percent"] == 100.0 and built["run_count"] == 1
    assert built["total"] == length(run["cases"])
    assert Enum.map(hd(built["runs"])["cases"], & &1["id"]) == run["cases"]
    assert built["model"]["quantization"] == "Q4_K_M"
    refute Jason.encode!(built) =~ "private-host"

    # A repeated event and a reloaded tab cannot add another copy.
    render_click(view, "add_result")
    render_async(view)
    assert length(Eab.Results.load!(Path.join(page, "results"))) == 1
    {:ok, reloaded, _} = live(build_conn(), "/")
    assert has_element?(reloaded, "#add-result[disabled]")

    assert redirected_to(get(build_conn(), "/results")) == "/results/"
    assert html_response(get(build_conn(), "/results/"), 200) =~ "Elixir SWE Bench"
    response = get(build_conn(), "/results/results.json")
    assert json_response(response, 200)["results"] == [built]

    for script <- ~w(app.js results.js) do
      conn = build_conn() |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
      assert get(conn, "/results/#{script}").status == 200
    end

    assert get(build_conn(), "/results/README.md").status == 404
    assert get(build_conn(), "/results/results/#{run["id"]}.json").status == 404
  end

  test "publication rejects unfinished or selected-case runs, including forged events" do
    source = publication_run()
    page = publication_page(source)

    for run <- [
          Map.put(source, "status", "running"),
          Map.put(source, "selection", %{"kind" => "case_repeat"})
        ] do
      Eab.Store.write("runs/#{run["id"]}/run.json", run)
      {:ok, view, _} = live(build_conn(), "/")
      refute has_element?(view, "#add-result")
      render_click(view, "add_result")
      render_async(view)
      assert has_element?(view, "#result-publication-error", "Could not add result")
      assert Eab.Results.load!(Path.join(page, "results")) == []
    end
  end

  test "publication failure is visible and the user can retry after fixing the page" do
    run = publication_run()
    page = publication_page(run)
    source = File.read!(Path.join(page, "app.js"))
    File.rm!(Path.join(page, "app.js"))
    {:ok, view, _} = live(build_conn(), "/")
    view |> element("#add-result") |> render_click()
    render_async(view)
    assert has_element?(view, "#result-publication-error", "Could not add result")
    assert has_element?(view, "#add-result:not([disabled])")
    assert Path.wildcard(Path.join(page, "results/*.json")) == []
    File.write!(Path.join(page, "app.js"), source)
    view |> element("#add-result") |> render_click()
    render_async(view)
    assert has_element?(view, "#result-publication")
    refute has_element?(view, "#result-publication-error")
  end

  test "run summary separates failed repairs from evaluation errors" do
    id = "score-summary-test"
    [a, b, c | _] = Eab.Inventory.all()

    Eab.Store.write("runs/#{id}/run.json", %{
      "id" => id,
      "created_at" => "9999-01-01T00:00:00Z",
      "status" => "completed",
      "cases" => [a, b, c],
      "attempts" => %{
        a => %{"status" => "completed", "grade" => %{"passed" => true}},
        b => %{"status" => "completed", "grade" => %{"passed" => false}},
        c => %{"status" => "error", "error" => "Endpoint unavailable"}
      },
      "settings" => %{},
      "model" => %{"model" => "synthetic"}
    })

    on_exit(fn -> File.rm_rf!(Eab.Store.path("runs/#{id}")) end)
    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, ".metric.passed strong", "1")
    assert has_element?(view, ".metric.failed strong", "1")
    assert has_element?(view, ".metric.error strong", "1")
    assert has_element?(view, ".metric.final-score strong", "—")
    assert has_element?(view, "[role=progressbar][aria-valuenow='2'][aria-valuemax='3']")
    view |> element("#case-#{c}") |> render_click()
    assert has_element?(view, "#case-panel-#{c}", "Endpoint unavailable")
    assert has_element?(view, "#case-panel-#{c} #case-verdict", "Evaluation error")
  end

  test "concurrent case stages and selected background messages remain visible" do
    id = "concurrent-progress-test"
    [a, b, c | _] = Eab.Inventory.all()

    Eab.Store.write("runs/#{id}/run.json", %{
      "id" => id,
      "created_at" => "9999-01-01T00:00:00Z",
      "status" => "running",
      "phase" => "running",
      "message" => "Pi editing",
      "current_case" => a,
      "cases" => [a, b, c],
      "attempts" => %{},
      "settings" => %{},
      "model" => %{"model" => "synthetic"},
      "case_phases" => %{a => "running", b => "qualifying", c => "grading"},
      "case_messages" => %{
        a => "Pi editing",
        b => "Checking upcoming fixture",
        c => "Grading prior patch"
      }
    })

    Eab.Store.write_text("runs/#{id}/#{b}/activity.log", "qualification output")
    on_exit(fn -> File.rm_rf!(Eab.Store.path("runs/#{id}")) end)
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Pi running"
    assert html =~ "Qualifying baseline"
    assert html =~ "Grading"
    view |> element("#case-#{b}") |> render_click()
    assert render(view) =~ "Checking upcoming fixture"
    assert has_element?(view, "#case-panel-#{b} #case-log", "qualification output")
    view |> element("button[phx-click=follow_output]") |> render_click()
    assert has_element?(view, "#case-log[data-follow=false]")
    view |> element("#case-#{a}") |> render_click()
    refute has_element?(view, "#case-panel-#{b}")
    assert has_element?(view, "#case-#{b}[aria-expanded=false]")
    assert has_element?(view, "#case-panel-#{a}", "Pi editing")
    assert has_element?(view, "#case-log[data-follow=true]")
  end

  test "a connected model enables Run without host configuration" do
    Application.put_env(:eab, :http_request, fn opts ->
      body =
        case URI.parse(opts[:url]).path do
          "/health" ->
            %{"status" => "ok"}

          "/v1/models" ->
            %{"data" => [%{"id" => "test-model"}]}

          "/props" ->
            %{"model_alias" => "test-model", "default_generation_settings" => %{"n_ctx" => 32768}}
        end

      {:ok, %{status: 200, body: body}}
    end)

    on_exit(fn -> Application.delete_env(:eab, :http_request) end)
    {:ok, view, _} = live(build_conn(), "/")
    view |> form("#connection", connection: %{url: "http://fixture", key: ""}) |> render_change()
    assert render_async(view) =~ "test-model"
    assert has_element?(view, "#run:not([disabled])")
  end

  test "the per-token Claude API is not offered, and its address is not contacted" do
    parent = self()
    Application.put_env(:eab, :http_request, fn opts -> send(parent, {:request, opts}) end)
    on_exit(fn -> Application.delete_env(:eab, :http_request) end)
    {:ok, view, _} = live(build_conn(), "/")
    refute has_element?(view, "#provider-choice input[value=claude]")
    assert has_element?(view, "#provider-choice input[value=claude_code]")

    html =
      view
      |> form("#connection", connection: %{url: "https://api.anthropic.com", key: "sk-ant-x"})
      |> render_change()

    assert html =~ "Per-token Claude API runs are not offered"
    refute_received {:request, _}
    assert has_element?(view, "#run[disabled]")
  end

  test "Claude Code runs start on the website, can be validation runs and show the solver" do
    parent = self()
    old = Map.new([:runner, :cleanup], &{&1, Application.get_env(:eab, &1)})
    Application.put_env(:eab, :cleanup, fn _ -> :ok end)

    Application.put_env(:eab, :runner, fn run, _, _ ->
      send(parent, {:started, run})

      receive do
        :finish -> :ok
      end
    end)

    on_exit(fn ->
      Eab.Runs.stop()

      # Cleanup runs asynchronously; keep the stub until it has finished.
      Enum.find(1..1000, fn _ ->
        snapshot = Eab.Runs.snapshot()
        (is_nil(snapshot.active) and not snapshot.cleaning) || Process.sleep(10)
      end)

      for {k, v} <- old do
        if v == nil, do: Application.delete_env(:eab, k), else: Application.put_env(:eab, k, v)
      end
    end)

    {:ok, view, _} = live(build_conn(), "/")
    view |> form("#provider-choice", provider: "claude_code") |> render_change()
    assert has_element?(view, "#provider-panel[aria-label='Claude Code settings']")
    # The broker is application-wide; other tests may already have reported a kit.
    assert has_element?(view, "#solver-status", "Solver")
    assert has_element?(view, "#run[disabled]")
    refute has_element?(view, "#case-timing-status")

    view |> form("#claude-code-model-form", model: "claude-opus-5-5") |> render_change()
    assert render(view) =~ "CLAUDE CODE"
    assert has_element?(view, "#provider-panel dd", "eab-opus-5-5-xhigh")
    view |> form("#validation-form", validation: "true") |> render_change()
    assert has_element?(view, "#validation-run[checked]")

    # Parallel attempts accepts 1 to 8 and ignores anything else.
    assert has_element?(view, "#parallel-attempts[value='1']")
    view |> form("#parallel-form", parallel: "9") |> render_change()
    assert has_element?(view, "#parallel-attempts[value='1']")
    view |> form("#parallel-form", parallel: "2") |> render_change()
    assert has_element?(view, "#parallel-attempts[value='2']")

    view |> element("#run") |> render_click()
    assert_receive {:started, run}, 15_000
    assert run["parallel_attempts"] == 2
    assert has_element?(view, "#run-harness", "Parallel attempts: 2")
    assert run["validation"] == true and run["harness"]["name"] == "claude_code"
    assert run["model"]["model"] == "claude-opus-5-5"
    assert has_element?(view, "#run-harness", "Validation run, never published or scored")

    view |> element("#run-series button", "Load run series") |> render_click()
    assert has_element?(view, "#run-series")

    # Stop asks first; No, Escape and the backdrop all keep the run going.
    view |> element("#stop-run") |> render_click()
    assert has_element?(view, "#stop-confirm[role=dialog]", "Are you sure?")
    assert Eab.Runs.snapshot().active
    view |> element("#stop-confirm-no") |> render_click()
    refute has_element?(view, "#stop-confirm")
    view |> element("#stop-run") |> render_click()
    render_keydown(view, "cancel_stop", %{"key" => "Escape"})
    refute has_element?(view, "#stop-confirm")
    view |> element("#stop-run") |> render_click()
    view |> element(".modal-backdrop") |> render_click()
    refute has_element?(view, "#stop-confirm")
    assert Eab.Runs.snapshot().active

    # Only Yes stops it.
    view |> element("#stop-run") |> render_click()
    view |> element("#stop-confirm-yes") |> render_click()
    refute has_element?(view, "#stop-confirm")
    refute Eab.Runs.snapshot().active

    Enum.find(1..1000, fn _ ->
      snapshot = Eab.Runs.snapshot()
      (is_nil(snapshot.active) and not snapshot.cleaning) || Process.sleep(10)
    end)

    # The page learns of the finished cleanup by broadcast; wait for it, not only the server.
    Enum.find(1..500, fn _ -> has_element?(view, "#run:not([disabled])") || Process.sleep(10) end)

    # An escape test runs the frozen probe in one case's workspace.
    id = hd(Eab.Inventory.all())
    view |> form("#claude-code-scope", scope: %{kind: "escape_test"}) |> render_change()
    view |> form("#claude-code-scope", scope: %{kind: "escape_test", case: id}) |> render_change()
    html = view |> element("#run") |> render_click()
    refute html =~ "notice error"
    assert_receive {:started, run}, 15_000
    assert run["selection"] == %{"kind" => "escape_test", "cases" => [id]}
  end

  test "clearing an endpoint cancels pending discovery and cannot restore its stale model" do
    parent = self()

    Application.put_env(:eab, :http_request, fn _ ->
      send(parent, {:discovering, self()})

      receive do
        :release -> {:error, :unavailable}
      end
    end)

    on_exit(fn -> Application.delete_env(:eab, :http_request) end)
    {:ok, view, _} = live(build_conn(), "/")
    view |> form("#connection", connection: %{url: "http://fixture", key: ""}) |> render_change()
    assert_receive {:discovering, pid}
    ref = Process.monitor(pid)
    view |> form("#connection", connection: %{url: "", key: ""}) |> render_change()
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    html = render_async(view)
    refute html =~ "Reading model details"
    refute html =~ "Model discovery stopped"
    assert has_element?(view, "#run[disabled]")
  end

  test "entering server credentials recovers from Strata's authentication error" do
    Application.put_env(:eab, :http_request, fn opts ->
      if URI.parse(opts[:url]).path == "/health" or
           {"authorization", "Bearer synthetic-key"} in opts[:headers] do
        body =
          case URI.parse(opts[:url]).path do
            "/health" ->
              %{"status" => "ok", "service" => "strata", "loaded" => true}

            "/v1/models" ->
              %{"data" => [%{"id" => "test-model"}]}

            "/props" ->
              %{
                "model_alias" => "test-model",
                "default_generation_settings" => %{"n_ctx" => 32768}
              }
          end

        {:ok, %{status: 200, body: body}}
      else
        {:ok, %{status: 401, body: %{"error" => %{"message" => "missing or wrong API key"}}}}
      end
    end)

    on_exit(fn -> Application.delete_env(:eab, :http_request) end)
    {:ok, view, _} = live(build_conn(), "/")
    view |> form("#connection", connection: %{url: "http://fixture", key: ""}) |> render_change()
    assert render_async(view) =~ "requires an API key (HTTP 401)"
    assert has_element?(view, "#run[disabled]")

    view
    |> form("#connection", connection: %{url: "http://fixture", key: "synthetic-key"})
    |> render_change()

    assert render_async(view) =~ "CONNECTED · STRATA"
    refute has_element?(view, "[role=alert]")
    assert has_element?(view, "#run:not([disabled])")
  end

  test "a large synthetic inventory is paginated and failures explain named checks before raw logs" do
    id = "large-inventory-test"
    cases = for n <- 1..500, do: "synthetic-#{n}"

    grade =
      Eab.Evidence.summarize(%{
        "passed" => false,
        "hidden" => %{
          "passed" => false,
          "completed" => true,
          "test_results" => %{"required behavior" => "failed"},
          "output" => "  1) required behavior\nAssertion failed"
        }
      })

    Eab.Store.write("runs/#{id}/run.json", %{
      "id" => id,
      "created_at" => "9999-01-01T00:00:00Z",
      "status" => "cancelled",
      "phase" => "cancelled",
      "cases" => cases,
      "attempts" => %{"synthetic-1" => %{"status" => "completed", "grade" => grade}},
      "settings" => %{},
      "model" => %{"model" => "fixture"}
    })

    Eab.Store.write("runs/#{id}/synthetic-1/grade.json", %{"full" => "output"})
    on_exit(fn -> File.rm_rf!(Eab.Store.path("runs/#{id}")) end)
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "/500"
    assert has_element?(view, "#case-synthetic-25")
    refute has_element?(view, "#case-synthetic-26")
    view |> element("#case-synthetic-1") |> render_click()
    assert has_element?(view, "#case-panel-synthetic-1 #case-verdict", "Acceptance did not pass")
    assert has_element?(view, "#case-verdict", "required behavior")
    assert has_element?(view, "#case-verdict a[href='/artifacts/#{id}/synthetic-1/grade.json']")
    view |> element("button[phx-click='case_page'][phx-value-direction='next']") |> render_click()
    assert has_element?(view, "#case-synthetic-26")
    refute has_element?(view, "#case-synthetic-1")
    refute has_element?(view, "#case-log")
  end

  test "comparison keeps choices across history pages and paginates case outcomes" do
    cases = for n <- 1..26, do: "synthetic-#{n}"
    ids = for n <- 1..21, do: "comparison-ui-#{n}"
    on_exit(fn -> Enum.each(ids, &File.rm_rf!(Eab.Store.path("runs/#{&1}"))) end)

    for {id, n} <- Enum.with_index(ids, 1) do
      Eab.Store.write("runs/#{id}/run.json", %{
        "id" => id,
        "created_at" => "9999-01-#{String.pad_leading(to_string(n), 2, "0")}T00:00:00Z",
        "status" => "completed",
        "cases" => cases,
        "attempts" =>
          Map.new(cases, &{&1, %{"status" => "completed", "grade" => %{"passed" => n == 21}}}),
        "settings" => %{"max_tokens" => 65536},
        "release_id" => String.duplicate("a", 64),
        "experiment_id" => String.duplicate("b", 64),
        "model" => %{"model" => "Synthetic #{n}"}
      })
    end

    {:ok, view, _} = live(build_conn(), "/")
    view |> form("#compare-runs", comparison: %{ids: ["comparison-ui-21"]}) |> render_change()

    view
    |> element("button[phx-click='history_page'][phx-value-direction='next']")
    |> render_click()

    view |> form("#compare-runs", comparison: %{ids: ["comparison-ui-1"]}) |> render_change()
    view |> form("#compare-runs", comparison: %{ids: ["comparison-ui-1"]}) |> render_submit()
    assert has_element?(view, "table[aria-label='Selected model runs']", "Synthetic 21")
    assert has_element?(view, "table[aria-label='Selected model runs']", "Synthetic 1")
    assert has_element?(view, "table[aria-label='Case outcomes across models']", "Passed")
    assert has_element?(view, "table[aria-label='Case outcomes across models']", "Failed")
    refute has_element?(view, "table[aria-label='Case outcomes across models']", "synthetic-26")

    view
    |> element("button[phx-click='comparison_page'][phx-value-direction='next']")
    |> render_click()

    assert has_element?(view, "table[aria-label='Case outcomes across models']", "synthetic-26")

    view
    |> element("button[phx-click='history_page'][phx-value-direction='previous']")
    |> render_click()

    assert has_element?(view, "input[value='comparison-ui-21'][checked]")
  end

  defp publication_run do
    inventory = Eab.Inventory.definition()

    %{
      "id" => "publish-button-test",
      "experiment_id" => String.duplicate("b", 64),
      "created_at" => "9999-01-01T00:00:00Z",
      "status" => "completed",
      "cases" => inventory["cases"],
      "attempts" =>
        Map.new(
          inventory["cases"],
          &{&1, %{"status" => "completed", "grade" => %{"passed" => true}}}
        ),
      "settings" => %{"max_tokens" => 65536},
      "release_id" => String.duplicate("a", 64),
      "protocol" => %{
        "inventory" => inventory,
        "fixtures" => Map.new(inventory["cases"], &{&1, Eab.Results.fixture_hashes(&1)})
      },
      "model" => %{
        "model" => "alias",
        "backend" => "llama_cpp",
        "url" => "http://private-host",
        "profile" => %{"model_path" => "/private/Fixture-Q4_K_M.gguf"}
      }
    }
  end

  defp publication_page(run) do
    page = Path.join(System.tmp_dir!(), "eab-page-#{System.unique_integer([:positive])}")
    File.mkdir_p!(page)

    for file <- ~w(index.html styles.css app.js),
        do: File.cp!(Path.join(Eab.Results.root(), file), Path.join(page, file))

    previous = Application.get_env(:eab, :results_page_root)
    Application.put_env(:eab, :results_page_root, page)
    Eab.Store.write("runs/#{run["id"]}/run.json", run)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:eab, :results_page_root, previous),
        else: Application.delete_env(:eab, :results_page_root)

      File.rm_rf!(page)
      File.rm_rf!(Eab.Store.path("runs/#{run["id"]}"))
    end)

    page
  end
end
