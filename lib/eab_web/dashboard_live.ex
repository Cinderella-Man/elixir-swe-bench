defmodule EabWeb.DashboardLive do
  use Phoenix.LiveView

  alias Eab.{
    ClaudeCode,
    Comparison,
    Evidence,
    Inventory,
    Model,
    Readiness,
    Results,
    Retention,
    Runner,
    Runs,
    Series,
    Storage,
    Store
  }

  alias Eab.ClaudeCode.Broker

  @defaults %{
    "window_tokens" => "",
    "response_tokens" => "",
    "max_tokens" => "65536",
    "seed" => "101",
    "reasoning_effort" => ""
  }
  def mount(params, _, socket) do
    if connected?(socket) do
      Runs.subscribe()
      Process.send_after(self(), :poll_log, 1_000)
    end

    snapshot = Runs.snapshot()
    selected = (snapshot.active || List.first(snapshot.history) || %{})["id"]

    socket =
      assign(socket,
        snapshot: snapshot,
        endpoint: nil,
        url: "",
        local_url: "",
        local_key: "",
        claude_key: "",
        provider: "local",
        accounts: Eab.ChatGPTAuth.accounts(),
        account: params["chatgpt"] || "",
        models: [],
        key: "",
        settings: @defaults,
        saved_settings: %{
          "local" => @defaults,
          "chatgpt" => subscription_defaults(),
          "claude" => claude_defaults(),
          "claude_code" => %{}
        },
        validation: false,
        parallel: 1,
        confirm_stop: false,
        check_kind: "",
        check_case: "",
        solver: Broker.status(),
        contribution: nil,
        series: nil,
        published_series: [],
        series_error: nil,
        error: Phoenix.Flash.get(socket.assigns.flash, :error),
        detecting: false,
        selected: selected,
        selected_run: if(selected, do: Store.run(selected)),
        history_offset: 0,
        comparison: nil,
        comparison_ids: [],
        comparison_offset: 0,
        history_page: Store.run_page(),
        case_offset: 0,
        cache_status: Retention.status(),
        cache_preview: nil,
        cache_busy: false,
        cache_message: nil,
        cache_failures: [],
        storage: nil,
        storage_busy: false,
        offline: Readiness.offline?(),
        readiness: nil,
        readiness_error: nil,
        selected_case: nil,
        log_case: nil,
        case_attempt: nil,
        log_text: "",
        log_available: false,
        follow_output: true,
        evidence_links: [],
        report_available: false,
        publishing: nil,
        publication_message: nil,
        result_added: false,
        cases: Enum.map(Inventory.all(), &Inventory.spec/1)
      )
      |> load_log()

    socket = if connected?(socket), do: check_readiness(socket), else: socket

    if params["chatgpt"],
      do:
        {:ok,
         discover_chatgpt(
           assign(switch_provider(socket, "chatgpt"), url: "https://api.openai.com")
         )},
      else: {:ok, socket}
  end

  defp subscription_defaults,
    do: Map.merge(@defaults, %{"max_tokens" => "262144", "reasoning_effort" => "high"})

  defp claude_defaults, do: Map.put(subscription_defaults(), "response_tokens", "")

  def handle_event("provider", %{"provider" => "chatgpt"}, socket) do
    Eab.ChatGPTAuth.retry_requests(socket.assigns.account)

    {:noreply,
     socket
     |> switch_provider("chatgpt")
     |> assign(url: "https://api.openai.com", key: "")
     |> discover_chatgpt()}
  end

  def handle_event("provider", %{"provider" => "claude"}, socket) do
    {:noreply,
     socket
     |> switch_provider("claude")
     |> assign(url: "https://api.anthropic.com", key: socket.assigns.claude_key)
     |> discover_claude()}
  end

  def handle_event("provider", %{"provider" => "claude_code"}, socket) do
    {:noreply,
     socket
     |> cancel_async(:discovery)
     |> switch_provider("claude_code")
     |> assign(url: "", key: "", models: [], endpoint: nil, detecting: false, error: nil)}
  end

  def handle_event("provider", %{"provider" => "local"}, socket) do
    handle_event(
      "connect",
      %{
        "connection" => %{
          "url" => socket.assigns.local_url,
          "key" => socket.assigns.local_key
        }
      },
      socket
    )
  end

  def handle_event("connect", %{"connection" => values}, socket) do
    url = values["url"] || ""
    key = values["key"] || ""

    socket =
      socket
      |> cancel_async(:discovery)
      |> assign(url: url, key: key, endpoint: nil, error: nil, detecting: String.trim(url) != "")

    cond do
      Eab.OpenAI.endpoint?(url) ->
        Eab.ChatGPTAuth.retry_requests(socket.assigns.account)
        {:noreply, discover_chatgpt(assign(switch_provider(socket, "chatgpt"), key: ""))}

      Eab.Anthropic.endpoint?(url) ->
        {:noreply,
         assign(socket,
           detecting: false,
           error:
             "Per-token Claude API runs are not offered. Benchmark Claude through Claude Code with your subscription."
         )}

      true ->
        {:noreply,
         socket
         |> switch_provider("local")
         |> assign(models: [], local_url: url, local_key: key)
         |> start_async(:discovery, fn ->
           try do
             {:ok, if(String.trim(url) == "", do: nil, else: Model.discover(url, key))}
           rescue
             e -> {:error, Exception.message(e)}
           end
         end)}
    end
  end

  def handle_event("claude_connect", %{"claude" => %{"key" => key}}, socket),
    do: {:noreply, discover_claude(assign(socket, claude_key: key, key: key))}

  def handle_event("claude_model", %{"model" => model}, socket) do
    row = Enum.find(socket.assigns.models, &(&1["id"] == model))
    endpoint = if row, do: Eab.Anthropic.endpoint(row)
    efforts = if row, do: row["efforts"], else: []
    effort = socket.assigns.settings["reasoning_effort"]

    # Keep the chosen effort when the newly selected model supports it.
    effort =
      cond do
        effort in efforts -> effort
        "high" in efforts -> "high"
        true -> "default"
      end

    {:noreply,
     assign(socket,
       endpoint: endpoint,
       settings: Map.put(socket.assigns.settings, "reasoning_effort", effort)
     )}
  end

  def handle_event("claude_code_model", %{"model" => model}, socket) do
    endpoint =
      if Enum.any?(ClaudeCode.profiles(), &(&1["model"] == model)),
        do: ClaudeCode.endpoint(model)

    {:noreply, assign(socket, endpoint: endpoint)}
  end

  def handle_event("parallel", %{"parallel" => value}, socket) do
    parallel =
      case Integer.parse(to_string(value)) do
        {n, ""} when n in 1..8 -> n
        _ -> socket.assigns.parallel
      end

    {:noreply, assign(socket, parallel: parallel)}
  end

  def handle_event("validation", params, socket),
    do: {:noreply, assign(socket, validation: params["validation"] == "true")}

  def handle_event("claude_code_scope", %{"scope" => scope}, socket) do
    kind = if scope["kind"] in ["dry_attempt", "escape_test"], do: scope["kind"], else: ""
    {:noreply, assign(socket, check_kind: kind, check_case: scope["case"] || "")}
  end

  def handle_event("release_pause", _, socket) do
    Broker.release_pause()
    {:noreply, assign(socket, solver: Broker.status())}
  end

  def handle_event("series", _, socket) do
    {series, error} =
      try do
        {Series.group(Store.runs()), nil}
      rescue
        error -> {[], Exception.message(error)}
      end

    {published, error} =
      try do
        {Enum.map(Results.load!(), &Results.aggregate/1), error}
      rescue
        problem -> {[], error || Exception.message(problem)}
      end

    {:noreply, assign(socket, series: series, published_series: published, series_error: error)}
  end

  def handle_event("contribute", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.published_series, &(&1["series_id"] == id)) do
      nil ->
        {:noreply, socket}

      series ->
        settings =
          series["settings"]
          |> Map.take(~w(window_tokens response_tokens max_tokens reasoning_effort))
          |> Map.reject(fn {_, value} -> is_nil(value) end)
          |> Map.new(fn {key, value} -> {key, to_string(value)} end)
          |> Map.put("seed", to_string(List.first(series["missing_seeds"]) || ""))

        {:noreply,
         assign(socket,
           contribution: series,
           settings: Map.merge(socket.assigns.settings, settings),
           validation: false
         )}
    end
  end

  def handle_event("cancel_contribution", _, socket),
    do: {:noreply, assign(socket, contribution: nil)}

  def handle_event("chatgpt_account", %{"account" => id}, socket) do
    Eab.ChatGPTAuth.retry_requests(id)
    {:noreply, discover_chatgpt(assign(socket, account: id, endpoint: nil))}
  end

  def handle_event("chatgpt_model", %{"model" => model}, socket) do
    row = Enum.find(socket.assigns.models, &(&1["slug"] == model))
    endpoint = if row, do: Eab.OpenAI.endpoint(socket.assigns.account, row)
    {:noreply, assign(socket, endpoint: endpoint)}
  end

  def handle_event("chatgpt_sign_out", _, socket) do
    active = socket.assigns.snapshot.active

    if active && get_in(active, ["model", "account_id"]) == socket.assigns.account,
      do: Runs.stop()

    message =
      case Eab.ChatGPTAuth.sign_out(socket.assigns.account) do
        {:ok, _} -> nil
        {:error, error} -> error
      end

    {:noreply,
     socket
     |> cancel_async(:discovery)
     |> assign(
       endpoint: nil,
       models: [],
       detecting: false,
       accounts: Eab.ChatGPTAuth.accounts(),
       error: message
     )}
  end

  def handle_event("settings", %{"settings" => values}, socket),
    do: {:noreply, assign(socket, settings: Map.merge(socket.assigns.settings, values))}

  def handle_event("run", _, %{assigns: %{endpoint: nil}} = socket),
    do: {:noreply, assign(socket, error: "Connect to a model first")}

  def handle_event("run", _, socket) do
    claude_code = socket.assigns.provider == "claude_code"

    opts = [
      parallel_attempts: socket.assigns.parallel,
      validation: socket.assigns.validation and claude_code,
      series: socket.assigns.contribution && socket.assigns.contribution["series_id"],
      check:
        if(claude_code and socket.assigns.check_kind != "",
          do: {socket.assigns.check_kind, socket.assigns.check_case}
        )
    ]

    case Runs.start(socket.assigns.endpoint, socket.assigns.key, socket.assigns.settings, opts) do
      {:ok, id} ->
        {:noreply, refresh(assign(socket, selected: id, selected_case: nil, error: nil))}

      {:error, message} ->
        {:noreply, assign(socket, error: message)}
    end
  end

  # Stopping interrupts the cases in progress, so the button only asks first.
  def handle_event("confirm_stop", _, socket), do: {:noreply, assign(socket, confirm_stop: true)}
  def handle_event("cancel_stop", _, socket), do: {:noreply, assign(socket, confirm_stop: false)}

  def handle_event("stop", _, socket) do
    Runs.stop()
    {:noreply, refresh(assign(socket, confirm_stop: false))}
  end

  def handle_event("add_result", _, %{assigns: %{publishing: id}} = socket) when not is_nil(id),
    do: {:noreply, socket}

  def handle_event("add_result", _, socket) do
    run = selected(socket.assigns)

    if run do
      id = run["id"]

      {:noreply,
       socket
       |> assign(publishing: id, publication_message: nil)
       |> start_async({:add_result, id}, fn ->
         try do
           {:ok, Results.publish!(Store.run(id))}
         rescue
           error -> {:error, Exception.message(error)}
         end
       end)}
    else
      {:noreply, assign(socket, error: "Select a completed run first")}
    end
  end

  def handle_event("cache_preview", %{"cache" => %{"case" => id}}, socket) do
    try do
      {:noreply,
       assign(socket,
         cache_preview: Retention.preview(id),
         cache_message: nil,
         cache_failures: [],
         error: nil
       )}
    rescue
      error -> {:noreply, assign(socket, error: Exception.message(error))}
    end
  end

  def handle_event("storage", _, %{assigns: %{storage_busy: true}} = socket),
    do: {:noreply, socket}

  def handle_event("storage", _, socket) do
    {:noreply,
     socket
     |> assign(storage_busy: true)
     |> start_async(:storage, fn ->
       try do
         {:ok, Storage.read()}
       rescue
         error -> {:error, Exception.message(error)}
       end
     end)}
  end

  def handle_event("readiness", _, socket), do: {:noreply, check_readiness(socket)}

  def handle_event("prepare_all", _, socket) do
    case Runs.prepare_all() do
      :ok -> {:noreply, refresh(assign(socket, error: nil))}
      {:error, message} -> {:noreply, assign(socket, error: message)}
    end
  end

  def handle_event("stop_preparation", _, socket) do
    Runs.stop_preparation()
    {:noreply, refresh(socket)}
  end

  def handle_event("cache_remove", _, %{assigns: %{cache_preview: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("cache_remove", _, socket) do
    plan = socket.assigns.cache_preview

    {:noreply,
     socket
     |> assign(cache_busy: true, error: nil)
     |> start_async(:cache_remove, fn ->
       try do
         {:ok, Retention.remove(plan["case"], plan["id"])}
       rescue
         error -> {:error, Exception.message(error)}
       end
     end)}
  end

  def handle_event("resume", _, %{assigns: %{endpoint: nil}} = socket),
    do: {:noreply, assign(socket, error: "Reconnect the same model before resuming")}

  def handle_event("resume", _, socket) do
    case Runs.resume(
           socket.assigns.selected,
           socket.assigns.endpoint,
           socket.assigns.key,
           socket.assigns.settings
         ) do
      {:ok, _} -> {:noreply, refresh(assign(socket, error: nil))}
      {:error, message} -> {:noreply, assign(socket, error: message)}
    end
  end

  def handle_event("history_page", %{"direction" => direction}, socket) do
    offset = max(socket.assigns.history_offset + if(direction == "next", do: 20, else: -20), 0)
    {:noreply, refresh(assign(socket, history_offset: offset))}
  end

  def handle_event("compare", params, socket) do
    try do
      ids = comparison_selection(socket, params)
      comparison = Comparison.load(ids)

      {:noreply,
       assign(socket,
         comparison: comparison,
         comparison_ids: ids,
         comparison_offset: 0,
         error: nil
       )}
    rescue
      error -> {:noreply, assign(socket, error: Exception.message(error))}
    end
  end

  def handle_event("comparison_select", params, socket),
    do: {:noreply, assign(socket, comparison_ids: comparison_selection(socket, params))}

  def handle_event("comparison_page", %{"direction" => direction}, socket) do
    offset = max(socket.assigns.comparison_offset + if(direction == "next", do: 25, else: -25), 0)
    {:noreply, assign(socket, comparison_offset: offset)}
  end

  def handle_event("case_page", %{"direction" => direction}, socket) do
    offset = max(socket.assigns.case_offset + if(direction == "next", do: 25, else: -25), 0)
    {:noreply, load_log(assign(socket, case_offset: offset, selected_case: nil))}
  end

  def handle_event("retry_cleanup", _, socket) do
    Runs.retry_cleanup()
    {:noreply, refresh(socket)}
  end

  def handle_event("select", %{"id" => id}, socket),
    do: {:noreply, refresh(assign(socket, selected: id, selected_case: nil, case_offset: 0))}

  def handle_event("select_case", %{"id" => id}, socket) do
    run = selected(socket.assigns)

    if run && id in run["cases"],
      do:
        {:noreply,
         load_log(
           assign(socket,
             selected_case: if(socket.assigns.selected_case == id, do: nil, else: id),
             follow_output: true
           )
         )},
      else: {:noreply, socket}
  end

  def handle_event("follow_output", _, socket),
    do: {:noreply, assign(socket, follow_output: not socket.assigns.follow_output)}

  def handle_async(:discovery, {:ok, {:catalog, rows}}, socket) do
    {:noreply, assign(socket, models: rows, detecting: false, error: nil)}
  end

  def handle_async(:discovery, {:ok, {:ok, endpoint}}, socket),
    do: {:noreply, assign(socket, endpoint: endpoint, detecting: false, error: nil)}

  def handle_async(:readiness, {:ok, {:ok, readiness}}, socket),
    do: {:noreply, assign(socket, readiness: readiness, readiness_error: nil)}

  def handle_async(:readiness, {:ok, {:error, error}}, socket),
    do: {:noreply, assign(socket, readiness: nil, readiness_error: error)}

  def handle_async(:readiness, {:exit, _}, socket),
    do:
      {:noreply,
       assign(socket, readiness: nil, readiness_error: "Readiness check stopped. Try again.")}

  def handle_async(:storage, {:ok, {:ok, storage}}, socket),
    do: {:noreply, assign(socket, storage: storage, storage_busy: false)}

  def handle_async({:add_result, _id}, {:ok, {:ok, _status}}, socket),
    do: {:noreply, socket |> assign(publishing: nil, publication_message: nil) |> load_log()}

  def handle_async({:add_result, id}, {:ok, {:error, message}}, socket),
    do:
      {:noreply, assign(socket, publishing: nil, publication_message: %{id: id, error: message})}

  def handle_async({:add_result, id}, {:exit, _}, socket),
    do:
      {:noreply,
       assign(socket,
         publishing: nil,
         publication_message: %{id: id, error: "Adding the result stopped. Try again."}
       )}

  def handle_async(:storage, {:ok, {:error, error}}, socket),
    do: {:noreply, assign(socket, storage_busy: false, error: error)}

  def handle_async(:storage, {:exit, _}, socket),
    do: {:noreply, assign(socket, storage_busy: false, error: "Storage inspection stopped")}

  def handle_async(:cache_remove, {:ok, {:ok, result}}, socket) do
    message =
      "Removed #{result["removed_images"]} images. #{length(result["retained_images"])} images could not be removed and were left untouched."

    {:noreply,
     assign(socket,
       cache_busy: false,
       cache_preview: nil,
       cache_status: Retention.status(),
       cache_failures: result["retained_images"],
       cache_message: message
     )
     |> check_readiness()}
  end

  def handle_async(:cache_remove, {:ok, {:error, error}}, socket),
    do: {:noreply, assign(socket, cache_busy: false, error: error)}

  def handle_async(:cache_remove, {:exit, _}, socket),
    do:
      {:noreply,
       assign(socket,
         cache_busy: false,
         error: "Cache removal stopped; review the remaining artifacts before retrying"
       )}

  def handle_async(:discovery, {:ok, {:error, error}}, socket),
    do: {:noreply, assign(socket, detecting: false, error: error)}

  def handle_async(:discovery, {:exit, {:shutdown, :cancel}}, socket),
    do: {:noreply, socket}

  def handle_async(:discovery, {:exit, _}, socket),
    do:
      {:noreply,
       assign(socket, detecting: false, error: "Model discovery stopped. Try connecting again.")}

  # Runs and preparation change what is ready, so the check repeats when either ends.
  def handle_info(:runs_changed, socket) do
    busy = busy?(socket.assigns.snapshot)
    socket = refresh(socket)

    {:noreply,
     if(busy and not busy?(socket.assigns.snapshot), do: check_readiness(socket), else: socket)}
  end

  def handle_info(:poll_log, socket) do
    Process.send_after(self(), :poll_log, 1_000)
    {:noreply, load_log(socket)}
  end

  defp check_readiness(socket) do
    start_async(socket, :readiness, fn ->
      try do
        {:ok, Readiness.check()}
      rescue
        error -> {:error, Exception.message(error)}
      end
    end)
  end

  defp preparing?(snapshot), do: (snapshot.preparation || %{})["status"] == "running"
  defp busy?(snapshot), do: not is_nil(snapshot.active) or preparing?(snapshot)

  # Each model source keeps its own unsaved settings while the user switches between them.
  defp switch_provider(%{assigns: %{provider: provider}} = socket, provider), do: socket

  defp switch_provider(socket, provider) do
    saved =
      Map.put(socket.assigns.saved_settings, socket.assigns.provider, socket.assigns.settings)

    assign(socket, provider: provider, saved_settings: saved, settings: saved[provider])
  end

  defp discover_claude(socket) do
    key = socket.assigns.claude_key

    socket =
      socket
      |> cancel_async(:discovery)
      |> assign(endpoint: nil, models: [], detecting: false, error: nil)

    if String.trim(key) == "" do
      # Replace any queued discovery so a stale catalog cannot reconnect.
      start_async(socket, :discovery, fn -> {:ok, nil} end)
    else
      socket
      |> assign(detecting: true)
      |> start_async(:discovery, fn ->
        try do
          {:catalog, Eab.Anthropic.catalog(key)}
        rescue
          e -> {:error, Store.redact(Exception.message(e), key)}
        end
      end)
    end
  end

  defp discover_chatgpt(socket) do
    accounts = Eab.ChatGPTAuth.accounts()
    account = socket.assigns.account
    selected = Enum.find(accounts, &(&1["id"] == account))

    socket =
      socket
      |> cancel_async(:discovery)
      |> assign(accounts: accounts, endpoint: nil, models: [], detecting: false, error: nil)

    if selected && selected["signed_in"] do
      socket
      |> assign(detecting: true)
      |> start_async(:discovery, fn ->
        try do
          {:catalog, Eab.OpenAI.catalog(account)}
        rescue
          e -> {:error, Exception.message(e)}
        end
      end)
    else
      # Replace the async reference too, so an already queued result from the
      # previous provider cannot reconnect it after the user switches away.
      start_async(socket, :discovery, fn -> {:ok, nil} end)
    end
  end

  defp refresh(socket) do
    snapshot = Runs.snapshot()
    selected = socket.assigns.selected || (snapshot.active && snapshot.active["id"])

    assign(socket,
      snapshot: snapshot,
      selected: selected,
      selected_run: if(selected && Store.valid_id?(selected), do: Store.run(selected)),
      history_page: Store.run_page(socket.assigns.history_offset),
      cache_status: Retention.status(),
      solver: Broker.status()
    )
    |> load_log()
  end

  defp comparison_selection(socket, params) do
    visible = Enum.map(socket.assigns.history_page.items, & &1["id"])
    selected = get_in(params, ["comparison", "ids"]) || []

    Enum.uniq(
      (socket.assigns.comparison_ids -- visible) ++ Enum.filter(selected, &(&1 in visible))
    )
  end

  defp load_log(socket) do
    run = selected(socket.assigns)
    id = run && socket.assigns.selected_case
    attempt = if run && id, do: case_attempt(run, id)
    socket = assign(socket, case_attempt: attempt)

    socket =
      assign(socket,
        evidence_links: if(run && id, do: Evidence.links(run["id"], id), else: []),
        report_available: run && match?({:ok, _}, Store.artifact(run["id"], "report.md")),
        result_added: run && Results.added?(run["id"])
      )

    case run && id && Store.tail_artifact(run["id"], "#{id}/activity.log") do
      {:ok, text} ->
        assign(socket, log_case: id, log_text: text, log_available: true)

      _ ->
        assign(socket,
          log_case: id,
          log_text: "No command output has been recorded for this case yet.",
          log_available: false
        )
    end
  end

  defp selected(assigns) do
    if assigns.snapshot.active && assigns.snapshot.active["id"] == assigns.selected,
      do: assigns.snapshot.active,
      else: assigns.selected_run
  end

  defp case_attempt(run, id) do
    record =
      if run["experiment_id"],
        do: Store.read("runs/#{run["id"]}/#{id}/attempt.json", get_in(run, ["attempts", id])),
        else: get_in(run, ["attempts", id])

    summary = get_in(run, ["attempts", id])

    if summary && summary["status"] == "error" && record && record["status"] != "error",
      do: summary,
      else: record
  rescue
    _ -> get_in(run, ["attempts", id])
  end

  defp outcome(nil), do: "Pending"
  defp outcome(%{"status" => "completed", "grade" => %{"passed" => true}}), do: "Passed"
  defp outcome(%{"status" => "completed", "grade" => %{"passed" => false}}), do: "Failed"
  defp outcome(attempt), do: String.capitalize(attempt["status"] || "incomplete")

  defp case_status(run, id) do
    phase = get_in(run, ["case_phases", id]) || if(run["current_case"] == id, do: run["phase"])

    if run["status"] == "running" do
      case phase do
        "preparing" -> "Preparing"
        "prepared" -> "Baseline saved"
        "qualifying" -> "Qualifying baseline"
        "ready" -> "Image ready"
        "warming" -> "Starting workspace"
        "warm" -> "Ready for #{Eab.Harness.agent(run)}"
        "running" -> "#{Eab.Harness.agent(run)} running"
        "submitted" -> "Waiting for grading"
        "grading" -> "Grading submission"
        _ -> outcome(run["attempts"][id])
      end
    else
      cond do
        run["status"] == "error" and run["current_case"] == id ->
          "Error"

        is_nil(run["attempts"][id]) ->
          "Not attempted"

        true ->
          outcome(run["attempts"][id])
      end
    end
  end

  defp case_tone(run, id) do
    case case_status(run, id) do
      "Passed" ->
        "passed"

      "Failed" ->
        "failed"

      "Error" ->
        "error"

      status
      when status in ["Pending", "Not attempted", "Incomplete", "Interrupted", "Cancelled"] ->
        "pending"

      _ ->
        "active"
    end
  end

  defp model_detail(endpoint, field) do
    metadata = endpoint["metadata"]["model"]
    get_in(metadata, ["meta", field]) || metadata[field] || "Not reported"
  end

  def render(assigns) do
    assigns = assign(assigns, run: selected(assigns))

    assigns =
      assign(assigns,
        case_count: length(assigns.cases),
        case_specs: Map.new(assigns.cases, &{&1["id"], &1}),
        score: if(assigns.run, do: Runner.score(assigns.run)),
        error_count:
          if(assigns.run,
            do: Enum.count(assigns.run["cases"], &(case_status(assigns.run, &1) == "Error")),
            else: 0
          ),
        project_counts: Enum.frequencies_by(assigns.cases, &(&1["project"] || &1["suite"]))
      )

    ~H"""
    <main>
      <header class="masthead">
        <a class="brand" href="/"><span class="mark">λ</span> ELIXIR / AGENT BENCHMARK</a>
        <span class="local"><i></i> LOCAL WORKSPACE</span>
      </header>
      <section class="intro">
        <div>
          <p class="eyebrow">MODEL EVALUATION</p>
          <h1>Benchmark dashboard</h1>
          <p class="lede">Real pull requests. Executable checks. Inspect every result.</p>
        </div>
        <div class="inventory-summary">
          <strong>{@case_count} cases</strong>
          <span>{Enum.map_join(Enum.sort(@project_counts), " · ", fn {project, count} ->
            "#{count} #{project}"
          end)}</span>
        </div>
      </section>
      <div :if={@error} class="notice error" role="alert">{@error}</div>
      <div :if={@snapshot.cleanup_error} class="notice error" role="alert">
        Container cleanup needs attention: {@snapshot.cleanup_error}
        <button class="secondary" phx-click="retry_cleanup">Retry cleanup</button>
      </div>
      <div class="workspace">
        <section class="panel setup">
          <div class="section-title">
            <span class="section-icon" aria-hidden="true">⌘</span><h2>Run configuration</h2>
          </div>
          <form id="provider-choice" phx-change="provider">
            <fieldset class="provider-options">
              <legend>Model source</legend>
              <div class="provider-tabs">
                <label
                  class={["provider-option", @provider == "local" && "is-selected"]}
                  title="Local server: llama.cpp or Strata"
                >
                  <input type="radio" name="provider" value="local" checked={@provider == "local"} />
                  <svg
                    aria-hidden="true"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.6"
                  >
                    <rect x="3" y="3" width="18" height="7" rx="2" /><rect
                      x="3"
                      y="14"
                      width="18"
                      height="7"
                      rx="2"
                    />
                    <path d="M7 6.5h.01M7 17.5h.01M11 6.5h6M11 17.5h6" stroke-linecap="round" />
                  </svg>
                  <span>Local</span>
                </label>
                <label
                  class={["provider-option", @provider == "chatgpt" && "is-selected"]}
                  title="ChatGPT: use your subscription"
                >
                  <input
                    type="radio"
                    name="provider"
                    value="chatgpt"
                    checked={@provider == "chatgpt"}
                  />
                  <svg
                    aria-hidden="true"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.6"
                  >
                    <path d="M20 11a8 8 0 0 1-8 8H5l-4 3V11a9 9 0 0 1 9-9h2a8 8 0 0 1 8 9Z" />
                    <path d="M7 9h8M7 13h5" />
                  </svg>
                  <span>ChatGPT</span>
                </label>
                <label
                  class={["provider-option", @provider == "claude_code" && "is-selected"]}
                  title="Claude Code: use your Claude subscription through the solver kit"
                >
                  <input
                    type="radio"
                    name="provider"
                    value="claude_code"
                    checked={@provider == "claude_code"}
                  />
                  <svg
                    aria-hidden="true"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.6"
                    stroke-linecap="round"
                  >
                    <path d="m8 8-4 4 4 4M16 8l4 4-4 4M13.5 5l-3 14" />
                  </svg>
                  <span>Claude Code</span>
                </label>
              </div>
            </fieldset>
          </form>
          <div
            id="provider-panel"
            class="provider-panel"
            role="group"
            aria-label={
              case @provider do
                "chatgpt" -> "ChatGPT settings"
                "claude" -> "Claude settings"
                "claude_code" -> "Claude Code settings"
                _ -> "Local server settings"
              end
            }
          >
            <form
              :if={@provider == "local"}
              id="connection"
              phx-change="connect"
              phx-submit="connect"
            >
              <p class="muted">Connect to a llama.cpp or Strata server you run.</p>
              <label for="endpoint">Server endpoint</label>
              <div class="input-row">
                <input
                  id="endpoint"
                  name="connection[url]"
                  type="url"
                  placeholder="http://localhost:8080"
                  value={@url}
                  phx-debounce="600"
                  required
                  autocomplete="url"
                /><button type="submit" class="secondary" disabled={@detecting}>Connect</button>
              </div>
              <details>
                <summary>Server credentials</summary><label for="key">API key
                <span class="muted">— optional, kept in memory</span></label><input
                  id="key"
                  name="connection[key]"
                  type="password"
                  value={@key}
                  phx-debounce="600"
                  autocomplete="off"
                />
              </details>
            </form>
            <div :if={@provider == "claude"} class="chatgpt-connection" id="claude-connection">
              <p class="muted">
                Connect with a Claude API key to choose a model. Usage is billed per token to the key's organization.
              </p>
              <form id="claude-key-form" phx-submit="claude_connect">
                <label for="claude-key">API key <span class="muted">— kept in memory</span></label>
                <div class="input-row">
                  <input
                    id="claude-key"
                    name="claude[key]"
                    type="password"
                    value={@claude_key}
                    autocomplete="off"
                    required
                  /><button type="submit" class="secondary" disabled={@detecting}>Connect</button>
                </div>
              </form>
              <p class="fine-print">
                <a href="https://platform.claude.com/settings/keys" target="_blank" rel="noreferrer">Manage API keys</a>
                ·
                <a href="https://platform.claude.com/usage" target="_blank" rel="noreferrer">Usage and cost</a>
              </p>
              <form :if={@models != []} id="claude-model-form" phx-change="claude_model">
                <label for="claude-model">Model</label>
                <select id="claude-model" name="model">
                  <option value="" selected={is_nil(@endpoint)}>Choose a model</option>
                  <option
                    :for={model <- @models}
                    value={model["id"]}
                    selected={@endpoint && @endpoint["model"] == model["id"]}
                  >
                    {model["display_name"]}
                  </option>
                </select>
              </form>
            </div>
            <div
              :if={@provider == "claude_code"}
              class="chatgpt-connection"
              id="claude-code-connection"
            >
              <p class="muted">
                Claude models on your Claude subscription, attempting cases as locked-down Claude Code subagents. The run waits here until the solver session drives it.
              </p>
              <form id="claude-code-model-form" phx-change="claude_code_model">
                <label for="claude-code-model">Model</label>
                <select id="claude-code-model" name="model">
                  <option value="" selected={is_nil(@endpoint)}>Choose a model</option>
                  <option
                    :for={profile <- ClaudeCode.profiles()}
                    value={profile["model"]}
                    selected={@endpoint && @endpoint["model"] == profile["model"]}
                  >
                    {profile["name"]} · {profile["effort"]} effort
                  </option>
                </select>
              </form>
              <form id="validation-form" phx-change="validation">
                <label class="run-choice">
                  <input type="hidden" name="validation" value="false" />
                  <input
                    id="validation-run"
                    type="checkbox"
                    name="validation"
                    value="true"
                    checked={@validation}
                    disabled={not is_nil(@contribution)}
                  /> Validation run · decides which cases stay; never published or scored
                </label>
              </form>
              <form id="claude-code-scope" phx-change="claude_code_scope">
                <label for="claude-code-check">Run scope</label>
                <select id="claude-code-check" name="scope[kind]">
                  <option value="" selected={@check_kind == ""}>Every case</option>
                  <option value="dry_attempt" selected={@check_kind == "dry_attempt"}>
                    Unscored dry attempt on one case
                  </option>
                  <option value="escape_test" selected={@check_kind == "escape_test"}>
                    Unscored escape test in one case's workspace
                  </option>
                </select>
                <select :if={@check_kind != ""} id="claude-code-case" name="scope[case]">
                  <option value="" selected={@check_case == ""}>Choose a case</option>
                  <option
                    :for={spec <- @cases}
                    value={spec["id"]}
                    selected={@check_case == spec["id"]}
                  >
                    {spec["id"]}
                  </option>
                </select>
              </form>
              <p :if={@check_kind == "escape_test"} class="fine-print">
                The solver gets a frozen probe instead of the task and tries to leave its sandbox; the controller flags any tool beyond the four workspace tools, host file content or network access in the transcript. Review the transcript too.
              </p>
              <ol class="fine-print">
                <li>Install the kit: <code>scripts/install-claude-code-kit.sh ~/eab-solver</code></li>
                <li>Open that folder in a new Claude desktop Code session and trust it.</li>
                <li>Start the run here, then type <code>/solve-run</code> in that session.</li>
              </ol>
              <div id="solver-status" class="model-card" role="status">
                <p :if={is_nil(@solver.kit)}>Solver session: not connected yet.</p>
                <p :if={@solver.kit && @solver.kit["problems"] == []}>
                  Solver kit: matches this controller.
                </p>
                <p :if={@solver.kit && @solver.kit["problems"] != []} class="notice error">
                  Solver kit differs: {Enum.join(@solver.kit["problems"], "; ")}. Reinstall it.
                </p>
                <p :if={@solver.waiting != []}>
                  Workspaces ready for solvers: {Enum.join(@solver.waiting, ", ")}
                </p>
                <p :if={@solver.launching != []}>
                  Solvers starting: {Enum.join(@solver.launching, ", ")}
                </p>
                <p :for={solver <- @solver.active}>
                  Solver <code>{solver.agent_id}</code> working on {solver.case}
                </p>
                <div :if={@solver.pause} class="notice error">
                  {@solver.pause}
                  <button class="secondary" phx-click="release_pause">Release usage-limit pause</button>
                </div>
              </div>
            </div>
            <div :if={@provider == "chatgpt"} class="chatgpt-connection" id="chatgpt-connection">
              <p class="muted">Sign in to choose a model available to your ChatGPT account.</p>
              <form :if={@accounts != []} id="chatgpt-account-form" phx-change="chatgpt_account">
                <label for="chatgpt-account">ChatGPT account / workspace</label>
                <select id="chatgpt-account" name="account">
                  <option value="" selected={@account == ""}>Add an account or workspace</option>
                  <option
                    :for={account <- @accounts}
                    value={account["id"]}
                    selected={@account == account["id"]}
                  >
                    {account["label"]}{if account["signed_in"], do: "", else: " (sign in required)"}
                  </option>
                </select>
              </form>
              <a
                class="secondary chatgpt-sign-in"
                href={EabWeb.ChatGPTController.base_url() <> "/auth/chatgpt?" <> URI.encode_query(%{"account" => @account})}
              >Continue with ChatGPT</a>
              <p class="fine-print">
                Use your usual sign-in method, including Google, on the next page.
              </p>
              <button
                :if={Enum.any?(@accounts, &(&1["id"] == @account and &1["signed_in"]))}
                type="button"
                class="secondary"
                phx-click="chatgpt_sign_out"
              >Sign out</button>
              <p class="fine-print">
                Uses your ChatGPT plan allowance.
                <a href="https://chatgpt.com/settings/usage" target="_blank" rel="noreferrer">Manage usage and access</a>
              </p>
              <form :if={@models != []} id="chatgpt-model-form" phx-change="chatgpt_model">
                <label for="chatgpt-model">Available model</label>
                <select id="chatgpt-model" name="model">
                  <option value="" selected={is_nil(@endpoint)}>Choose a model</option>
                  <option
                    :for={model <- @models}
                    value={model["slug"]}
                    selected={@endpoint && @endpoint["model"] == model["slug"]}
                  >
                    {model["display_name"] || model["slug"]}
                  </option>
                </select>
              </form>
            </div>
            <div :if={@detecting} class="model-card" role="status">Reading model details…</div>
            <div :if={@endpoint} class="model-card">
              <span class="badge">CONNECTED · {case @endpoint["backend"] do
                "openai_subscription" -> "CHATGPT"
                "anthropic" -> "CLAUDE API"
                "claude_code" -> "CLAUDE CODE"
                "strata" -> "STRATA"
                _ -> "LLAMA.CPP"
              end}</span>
              <h3>{Eab.ModelIdentity.label(@endpoint)}</h3>
              <dl :if={@provider == "claude_code"}>
                <div>
                  <dt>Model ID</dt><dd>{@endpoint["model"]}</dd>
                </div><div>
                  <dt>Solver agent</dt><dd>{@endpoint["profile"]["agent"]}</dd>
                </div><div>
                  <dt>Effort</dt><dd>{@endpoint["profile"]["effort"]}</dd>
                </div><div>
                  <dt>Kit</dt><dd>
                    <code>{String.slice(@endpoint["profile"]["kit_sha256"], 0, 12)}</code>
                  </dd>
                </div>
              </dl>
              <dl :if={@provider == "claude"}>
                <div>
                  <dt>Model ID</dt><dd>{@endpoint["model"]}</dd>
                </div><div>
                  <dt>Context window</dt><dd>{@endpoint["context"] || "Not reported"} tokens</dd>
                </div><div>
                  <dt>Max output</dt><dd>
                    {@endpoint["profile"]["max_tokens"] || "Not reported"} tokens
                  </dd>
                </div>
              </dl>
              <dl :if={@provider == "local"}>
                <div>
                  <dt>Context capacity</dt><dd>{@endpoint["context"]} tokens</dd>
                </div><div>
                  <dt>Quantization</dt><dd>
                    {Eab.ModelIdentity.details(@endpoint)["quantization"] || "Not reported"}
                  </dd>
                </div><div>
                  <dt>Model weights</dt><dd>{Eab.ModelIdentity.size_label(@endpoint)}</dd>
                </div><div>
                  <dt>Parameters</dt><dd>{model_detail(@endpoint, "n_params")}</dd>
                </div><div>
                  <dt>Server build</dt><dd>{@endpoint["profile"]["build_info"] || "Not reported"}</dd>
                </div>
              </dl>
              <p class="fine-print">
                {@endpoint["identity_note"] ||
                  "Server-reported metadata. Artifact identity is unverified."}
              </p>
              <p :if={@provider == "local"} id="memory-collection-status" class="fine-print">
                {Eab.MemoryMonitor.configuration_label(@endpoint)}
              </p>
              <p :if={@provider == "local"} id="server-thinking" class="fine-print">
                Server thinking preset: {Eab.Thinking.reported(@endpoint) || "Not reported"}
              </p>
            </div>
            <form id="settings" phx-change="settings">
              <label :if={@provider == "claude" and @endpoint}>
                Effort
                <select id="claude-effort" name="settings[reasoning_effort]">
                  <option
                    :for={effort <- (@endpoint["profile"]["efforts"] || []) ++ ["default"]}
                    value={effort}
                    selected={@settings["reasoning_effort"] == effort}
                  >
                    {Eab.Anthropic.effort_label(effort)}
                  </option>
                </select>
              </label>
              <p :if={@provider == "claude" and @endpoint} class="fine-print">
                Sent as the API effort level with adaptive thinking on every request. Thinking counts toward the token limits.
              </p>
              <label :if={@provider == "local"}>
                Model host thinking preset
                <input
                  name="settings[reasoning_effort]"
                  value={@settings["reasoning_effort"]}
                  list="thinking-presets"
                  maxlength="64"
                  placeholder="Automatic if reported; otherwise enter the host preset"
                />
                <datalist id="thinking-presets">
                  <option
                    :for={effort <- ~w(off on minimal low medium high xhigh max default unsupported)}
                    value={effort}
                  />
                </datalist>
              </label>
              <p :if={@provider == "local"} class="fine-print">
                Records the preset selected on your model host; does not change it.
                Use “on” for thinking without a level, or enter the exact level name.
                Blank uses server metadata when available; otherwise it is saved as not reported.
              </p>
              <p :if={@provider != "claude_code"} id="case-timing-status" class="fine-print">
                Case timing is always recorded. Preparation and grading are excluded.
              </p>
              <p :if={@provider == "claude_code"} class="fine-print">
                Pi's exact instructions declare a 262,144 generated-token threshold that Claude Code cannot enforce; usage above it is flagged. Compaction is off, a full context grades the current patch, a usage-limit stop is an evaluation error, there is no seed and no timing is stored.
              </p>
              <details :if={@provider != "claude_code"} class="advanced">
                <summary>Advanced run settings</summary>
                <p :if={@provider == "local"} class="fine-print">
                  Defaults use the detected context up to 262,144 tokens. Full history is retained.
                  Model and tool calls are unlimited.
                </p>
                <p :if={@provider == "chatgpt"} class="fine-print">
                  Full history is retained. The generated-token threshold is checked between completed responses and can be exceeded by one response. OpenAI controls context and response limits; seed and strict response caps are unavailable. Reasoning tokens count toward the threshold.
                </p>
                <p :if={@provider == "claude"} class="fine-print">
                  Full history is retained. The generated-token threshold is checked between completed responses and can be exceeded by one response. The Claude API enforces the model's context window; seed is unavailable. Thinking tokens count toward the threshold and each response cap.
                </p>
                <label :if={@provider == "chatgpt"}>
                  Reasoning effort
                  <select name="settings[reasoning_effort]">
                    <option
                      :for={effort <- ~w(default low medium high xhigh)}
                      value={effort}
                      selected={@settings["reasoning_effort"] == effort}
                    >
                      {effort}
                    </option>
                  </select>
                </label>
                <div class="settings-grid">
                  <label :for={
                    {key, title} <-
                      case @provider do
                        "chatgpt" ->
                          [{"max_tokens", "Generated-token threshold per case"}]

                        "claude" ->
                          [
                            {"max_tokens", "Generated-token threshold per case"},
                            {"response_tokens", "Tokens per response (blank = up to 64,000)"}
                          ]

                        _ ->
                          [
                            {"window_tokens", "Context tokens (blank = automatic)"},
                            {"response_tokens", "Tokens per response (blank = up to 8,192)"},
                            {"max_tokens", "Generated tokens per case"},
                            {"seed", "Seed"}
                          ]
                      end
                  }>{title}<input
                    type="number"
                    min={if key == "seed", do: "0", else: "1"}
                    name={"settings[#{key}]"}
                    value={@settings[key]}
                  /></label>
                </div>
              </details>
            </form>
            <form id="parallel-form" phx-change="parallel">
              <label for="parallel-attempts">
                Parallel attempts<input
                  id="parallel-attempts"
                  type="number"
                  min="1"
                  max="8"
                  name="parallel"
                  value={@parallel}
                />
              </label>
              <p class="fine-print">
                Cases worked on at once. Keep 1 for a model on a single local server; above 1, no elapsed times are recorded.
              </p>
            </form>
          </div>
          <button
            id="run"
            class="primary"
            phx-click="run"
            disabled={
              is_nil(@endpoint) or @detecting or @cache_busy or busy?(@snapshot) or
                @snapshot.cleaning or
                not is_nil(@snapshot.cleanup_error)
            }
          >Run benchmark <span>↗</span></button>
          <div :if={@contribution} id="contribution" class="notice" role="status">
            Contributing to run series <code>{String.slice(@contribution["series_id"], 0, 12)}</code>
            ({@contribution["model"]["name"]}, {@contribution["run_count"]}/{@contribution[
              "required_runs"
            ]} runs<span :if={@contribution["missing_seeds"] != []}>, missing seeds {Enum.join(@contribution["missing_seeds"], ", ")}</span>).
            The run starts only if this endpoint and these settings match its setup.
            <button class="secondary" phx-click="cancel_contribution">Cancel contribution</button>
          </div>
          <p class="fine-print">
            Each agent works on one case; up to the run's parallel attempts work at once. Upcoming cases prepare in the background, and submitted repairs are graded independently. Prepared images and fixture checks are reused across runs.
          </p>
        </section>
        <section class="panel results">
          <div class="section-title">
            <span class="section-icon" aria-hidden="true">▤</span><h2>Benchmark results</h2><button
              :if={@snapshot.active}
              id="stop-run"
              class="danger"
              phx-click="confirm_stop"
            >Stop run</button>
          </div>
          <div
            :if={@confirm_stop and @snapshot.active}
            class="modal-backdrop"
            phx-click="cancel_stop"
            phx-window-keydown="cancel_stop"
            phx-key="Escape"
          >
            <div
              id="stop-confirm"
              class="modal"
              role="dialog"
              aria-modal="true"
              aria-labelledby="stop-confirm-title"
              phx-click={%Phoenix.LiveView.JS{}}
            >
              <h3 id="stop-confirm-title">Are you sure?</h3>
              <p>
                Stopping ends this run now. Cases in progress are interrupted; finished results are kept, and the run can be resumed later.
              </p>
              <div class="modal-actions">
                <button
                  id="stop-confirm-no"
                  class="secondary"
                  phx-click="cancel_stop"
                  phx-mounted={Phoenix.LiveView.JS.focus()}
                >No, keep running</button>
                <button id="stop-confirm-yes" class="danger" phx-click="stop">Yes, stop the run</button>
              </div>
            </div>
          </div>
          <div :if={is_nil(@run)} class="empty">
            <div class="empty-glyph">⌘</div><h3>Ready when you are.</h3><p>
              Connect your model and start a run.<br />Progress and results will appear here.
            </p>
          </div>
          <div :if={@run}>
            <div class="run-heading">
              <span class="badge">{String.upcase(@run["status"])}</span><code>{@run["id"]}</code>
            </div>
            <h3 class="run-model">{Eab.ModelIdentity.label(@run["model"])}</h3>
            <p id="run-harness" class="fine-print">
              Harness: {Eab.Harness.label(@run)} · Parallel attempts: {@run["parallel_attempts"] || 1}<span :if={
                @run["validation"]
              }> · Validation run, never published or scored</span><span :if={@run["series"]}> · Contribution to series <code>{String.slice(
                @run["series"],
                0,
                12
              )}</code></span>
            </p>
            <p
              class="run-message"
              role="status"
            >
              {@run["message"]}
            </p>
            <p id="run-thinking" class="fine-print">
              Thinking: {Eab.Thinking.label(@run["settings"])} · {get_in(@run, [
                "settings",
                "reasoning_effort_source"
              ]) || "Source not recorded"}
            </p>
            <p :if={@run["release_id"]} class="fine-print">
              Release <code>{String.slice(@run["release_id"], 0, 12)}</code>
              · Experiment <code>{String.slice(@run["experiment_id"], 0, 12)}</code>
              · {@run["resume_count"] || 0} resumptions
            </p>
            <p :if={@run["selection"]} class="fine-print">
              Partial run based on {@run["selection"]["source_run"]}. Original outcomes are preserved;
              this run has no full benchmark score.
            </p>
            <button
              :if={@run["release_id"] && @run["status"] in ["interrupted", "cancelled", "error"]}
              id="resume"
              class="secondary"
              phx-click="resume"
              disabled={
                is_nil(@endpoint) or @detecting or @cache_busy or busy?(@snapshot) or
                  @snapshot.cleaning or
                  not is_nil(@snapshot.cleanup_error)
              }
            >
              Resume unfinished cases
            </button>
            <div class="scoreboard" aria-label="Run score">
              <div class="metric passed">
                <span>Passed</span><strong>{@score["passed"]}</strong>
              </div>
              <div class="metric failed">
                <span>Failed</span><strong>{@score["failed"]}</strong>
              </div>
              <div class="metric error">
                <span>Errors</span><strong>{@error_count}</strong>
              </div>
              <div class="metric final-score">
                <span>Final score</span>
                <strong>{if @score["score_percent"], do: "#{@score["score_percent"]}%", else: "—"}</strong>
              </div>
            </div>
            <p :if={@run["memory"]} class="fine-print" id="run-memory">
              Sampled memory peaks: {Eab.MemoryMonitor.label(@run["memory"])}.
              <a href={"/artifacts/#{@run["id"]}/memory.json"} download>Summary</a>
              · <a href={"/artifacts/#{@run["id"]}/memory-samples.jsonl"} download>Samples</a>
            </p>
            <div class="progress-heading">
              <span>Cases graded</span><strong>{@score["passed"] + @score["failed"]}/{@score[
                "planned"
              ]}</strong>
            </div>
            <svg
              class="run-progress"
              viewBox={"0 0 #{max(@score["planned"], 1)} 1"}
              preserveAspectRatio="none"
              role="progressbar"
              aria-label="Cases graded"
              aria-valuenow={@score["passed"] + @score["failed"]}
              aria-valuemin="0"
              aria-valuemax={max(@score["planned"], 1)}
            >
              <rect class="progress-passed" width={@score["passed"]} height="1" />
              <rect class="progress-failed" x={@score["passed"]} width={@score["failed"]} height="1" />
            </svg>
            <div class="score-note">
              <p class="fine-print">Errors and incomplete attempts prevent a final score.</p>
              <div class="run-actions">
                <a :if={@report_available} href={"/artifacts/#{@run["id"]}/report.md"} download>Download report ↓</a>
                <button
                  :if={
                    @run["status"] == "completed" && is_nil(@run["selection"]) &&
                      !is_nil(@score["score_percent"]) &&
                      (@run["validation"] != true || Eab.Series.admitted_validation?(@run))
                  }
                  id="add-result"
                  class="secondary"
                  phx-click="add_result"
                  disabled={
                    @publishing != nil ||
                      (@result_added &&
                         !(@publication_message && @publication_message.id == @run["id"]))
                  }
                >
                  {cond do
                    @publishing == @run["id"] ->
                      "Adding…"

                    @publication_message && @publication_message.id == @run["id"] ->
                      "Retry adding result"

                    @result_added ->
                      "Added to results page"

                    true ->
                      "Add to results page"
                  end}
                </button>
              </div>
            </div>
            <p :if={@result_added} id="result-publication" class="fine-print" role="status">
              Added to the local results page.
              <a href="/results/" target="_blank" rel="noopener">View results ↗</a>
              · Push the result file to GitHub to update the public page.
            </p>
            <p
              :if={@publication_message && @publication_message.id == @run["id"]}
              id="result-publication-error"
              class="notice error"
              role="alert"
            >
              Could not add result: {@publication_message.error}
            </p>
            <div class="cases-heading">
              <h3>Cases <span>{@score["planned"]}</span></h3>
              <span>Expand a case to inspect its evidence</span>
            </div>
            <div class="case-list">
              <article
                :for={
                  {id, index} <-
                    Enum.with_index(Enum.slice(@run["cases"], @case_offset, 25), @case_offset + 1)
                }
                class={["case-item", id == @log_case && "is-expanded"]}
              >
                <h4 class="case-heading">
                  <button
                    id={"case-#{id}"}
                    class="case-toggle"
                    phx-click="select_case"
                    phx-value-id={id}
                    aria-controls={"case-panel-#{id}"}
                    aria-expanded={to_string(id == @log_case)}
                  >
                    <span class="case-index">{String.pad_leading(to_string(index), 2, "0")}</span>
                    <span class="case-name">
                      <span class="case-id">{id}</span>
                      <span :if={@case_specs[id]} class="case-description">{@case_specs[id]["title"]}</span>
                    </span>
                    <span class={"case-status " <> case_tone(@run, id)}><i aria-hidden="true"></i>{case_status(
                      @run,
                      id
                    )}</span>
                    <svg
                      class="case-chevron"
                      width="16"
                      height="16"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="1.8"
                      aria-hidden="true"
                    ><path d="m6 9 6 6 6-6" /></svg>
                  </button>
                </h4>
                <section
                  :if={id == @log_case}
                  id={"case-panel-#{id}"}
                  class="case-console"
                  role="region"
                  aria-labelledby={"case-#{id}"}
                >
                  <p
                    :if={@run["status"] == "running"}
                    class="fine-print"
                  >
                    {get_in(@run, ["case_messages", @log_case]) ||
                      if(@run["current_case"] == @log_case, do: @run["message"])}
                  </p>
                  <p :if={get_in(@run, ["attempts", @log_case, "error"])} class="notice error">
                    {get_in(@run, ["attempts", @log_case, "error"])}
                  </p>
                  <section id="case-verdict" aria-label="Case result explanation" tabindex="-1">
                    <p :if={Eab.Harness.name(@run) != "claude_code"} id="case-time" class="fine-print">
                      Case time: {Eab.Measurement.label((@case_attempt || %{})["measurement"])} · Pi startup through completion, excluding preparation and grading.
                    </p>
                    <h4>
                      {if is_nil(@case_attempt) and case_tone(@run, id) == "active",
                        do: "Awaiting evaluation",
                        else: Evidence.verdict(@case_attempt)}
                    </h4>
                    <p
                      :if={
                        @case_attempt && @case_attempt["status"] in ["completed", "error"] &&
                          is_integer(@case_attempt["generated_tokens"]) &&
                          is_integer(@run["settings"]["max_tokens"])
                      }
                      class="fine-print"
                    >
                      Generated tokens: {@case_attempt["generated_tokens"]} / {@run["settings"][
                        "max_tokens"
                      ]}.
                      <span :if={@run["settings"]["budget_policy"] == "response_boundary_soft_limit"}>Soft threshold, checked between responses. Context is provider-enforced.</span>
                      <span :if={@run["settings"]["budget_policy"] != "response_boundary_soft_limit"}>Context limit: {@run[
                        "settings"
                      ]["window_tokens"]} tokens.</span>
                      Prompt tokens include conversation history and tool output; the generation budget counts model output.
                    </p>
                    <p
                      :if={get_in(@run, ["case_phases", @log_case]) == "qualifying"}
                      class="fine-print"
                    >
                      Checking the unchanged application, reference repair and negative controls before the agent starts this case.
                    </p>
                    <p :if={get_in(@run, ["attempts", @log_case, "stop_reason"])} class="fine-print">
                      {Eab.Harness.agent(@run)} stopped: {get_in(@run, [
                        "attempts",
                        @log_case,
                        "stop_reason"
                      ])}
                    </p>
                    <p
                      :if={
                        get_in(@run, ["attempts", @log_case, "claude_code", "over_declared_budget"])
                      }
                      class="notice"
                    >
                      Flagged: the transcript shows more output than the declared 262,144 generated tokens. The attempt is not failed for it.
                    </p>
                    <p
                      :if={get_in(@run, ["attempts", @log_case, "escape_test"])}
                      id="escape-verdict"
                      class={[
                        "notice",
                        !get_in(@run, ["attempts", @log_case, "escape_test", "passed"]) && "error"
                      ]}
                    >
                      Escape test: {if get_in(@run, ["attempts", @log_case, "escape_test", "passed"]),
                        do: "no breach found in the transcript. Review it before scored runs.",
                        else:
                          Enum.join(
                            get_in(@run, ["attempts", @log_case, "escape_test", "findings"]),
                            "; "
                          )}
                    </p>
                    <p :if={get_in(@run, ["attempts", @log_case, "claude_code"])} class="fine-print">
                      Claude Code {get_in(@run, [
                        "attempts",
                        @log_case,
                        "claude_code",
                        "claude_code_version"
                      ])} · {get_in(@run, ["attempts", @log_case, "claude_code", "compactions"]) || 0} compactions · usage read from the transcript, best effort.
                    </p>
                    <div
                      :for={check <- Evidence.checks(@case_attempt)}
                      class="check-result"
                    >
                      <p>
                        <strong>{check["label"]}: {if check["passed"],
                          do: "passed",
                          else: "did not pass"}</strong><span :if={check["completed"] == false}> — check execution did not complete</span>
                      </p>
                      <p :if={check["reason"]}>{check["reason"]}</p>
                      <p :if={check["label"] == "Regression coverage"} class="fine-print">
                        This check runs submitted tests against the original broken code. Failing tests here are expected; they must pass with the submitted repair.
                      </p>
                      <ul :if={check["failures"] != []}>
                        <li :for={failure <- check["failures"]}>
                          <code>{failure["name"]}</code>: expected {failure["expected"]}, observed {failure[
                            "observed"
                          ]}
                        </li>
                      </ul>
                      <p :if={check["failure_count"] > length(check["failures"])} class="fine-print">
                        {check["failure_count"] - length(check["failures"])} additional failures in full grading evidence.
                      </p>
                      <details :if={check["excerpt"]}>
                        <summary>Error excerpt</summary><pre>{check["excerpt"]}</pre>
                      </details>
                    </div>
                    <ul class="artifacts">
                      <li :for={link <- @evidence_links}>
                        <a href={"/artifacts/#{@run["id"]}/#{link["path"]}"} download>{link["label"]} ↓</a>
                      </li>
                    </ul>
                  </section>
                  <div class="console-actions">
                    <span class="console-label">COMMAND OUTPUT</span>
                    <button
                      class="secondary"
                      phx-click="follow_output"
                      aria-pressed={to_string(@follow_output)}
                    >Follow output: {if @follow_output,
                      do: "on",
                      else: "off"}</button>
                    <a
                      :if={@log_available}
                      id="case-log-download"
                      href={"/artifacts/#{@run["id"]}/#{@log_case}/activity.log"}
                      download
                    >Download full log ↓</a>
                  </div>
                  <pre
                    id="case-log"
                    phx-hook="LogTail"
                    data-follow={to_string(@follow_output)}
                    data-case={"#{@run["id"]}/#{@log_case}"}
                    tabindex="0"
                  >{@log_text}</pre>
                  <p class="fine-print">
                    Updates every second. Docker setup, test output, model responses and agent tool commands appear here.
                  </p>
                </section>
              </article>
            </div>
            <nav :if={length(@run["cases"]) > 25} aria-label="Case pages">
              <button
                class="secondary"
                phx-click="case_page"
                phx-value-direction="previous"
                disabled={@case_offset == 0}
              >Previous cases</button>
              <span>{@case_offset + 1}–{min(@case_offset + 25, length(@run["cases"]))} of {length(
                @run["cases"]
              )}</span>
              <button
                class="secondary"
                phx-click="case_page"
                phx-value-direction="next"
                disabled={@case_offset + 25 >= length(@run["cases"])}
              >Next cases</button>
            </nav>
            <details>
              <summary>Run settings and evidence</summary><pre>{Jason.encode!(@run["settings"], pretty: true)}</pre>
              <p class="fine-print">
                Select a case for its patch, transcript, environment and grading evidence. Resuming preserves completed failures and evaluation errors; it restarts only unfinished work.
              </p>
              <table :if={@run["case_metadata"]} aria-label="Results by project and task">
                <thead>
                  <tr>
                    <th>Group</th><th>Passed</th><th>Failed</th><th>Incomplete / error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- Runner.breakdowns(@run)}>
                    <td>{String.replace(row["value"], "_", " ")}</td>
                    <td>{row["passed"]}/{row["planned"]}</td>
                    <td>{row["failed"]}</td><td>{row["pending_or_error"]}</td>
                  </tr>
                </tbody>
              </table>
              <a href={"/artifacts/#{@run["id"]}/run.json"} download>Complete run record ↓</a>
              <p :if={@run["release_id"]}>
                <a href={"/artifacts/#{@run["id"]}/release.json"} download>Frozen release manifest ↓</a>
              </p>
              <div :if={(@run["attempt_history"] || []) != []}>
                <h4>Interrupted generations</h4>
                <p :for={entry <- @run["attempt_history"]}>
                  {entry["case"]}, generation {entry["generation"]}: {entry["generated_tokens"] ||
                    "unknown"} generated tokens, {entry["calls"] || "unknown"} model calls.
                  <a href={"/artifacts/#{@run["id"]}/#{entry["artifacts"]}/activity.log"} download>Prior activity log</a>
                </p>
              </div>
            </details>
          </div>
        </section>
      </div>
      <section id="offline-readiness" class="history panel">
        <div class="section-title">
          <h2>Offline readiness</h2><span class="muted">What a run needs with no internet.</span>
        </div>
        <p :if={@offline} id="offline-mode" class="notice">
          Offline mode is on. Nothing is downloaded or built, and missing cases stop a run from starting.
        </p>
        <p :if={@readiness_error} class="notice error">{@readiness_error}</p>
        <p :if={is_nil(@readiness) and is_nil(@readiness_error)} role="status">
          Checking prepared cases…
        </p>
        <div :if={@readiness} id="readiness-summary">
          <p :if={@readiness["ready"] == @readiness["total"]}>
            <strong>{@readiness["ready"]} of {@readiness["total"]} cases are ready.</strong>
            You can disconnect from the internet.
          </p>
          <p :if={@readiness["ready"] != @readiness["total"]}>
            <strong>{@readiness["ready"]} of {@readiness["total"]} cases are ready.</strong>
            Stay online and prepare the rest.
          </p>
          <ul :if={@readiness["ready"] != @readiness["total"]}>
            <li :for={row <- Enum.reject(@readiness["cases"], & &1["ready"])}>
              {row["case"]}: needs {Enum.join(row["missing"], ", ")}
            </li>
          </ul>
        </div>
        <div :if={@snapshot.preparation} id="preparation-status" role="status">
          <p>
            {@snapshot.preparation["finished"]} of {@snapshot.preparation["total"]} cases finished. {@snapshot.preparation[
              "message"
            ]}
          </p>
          <details :if={@snapshot.preparation["errors"] != %{}} open>
            <summary>{map_size(@snapshot.preparation["errors"])} cases could not be prepared</summary>
            <div :for={{id, error} <- Enum.sort(@snapshot.preparation["errors"])}>
              <strong>{id}</strong>
              <pre>{error}</pre>
            </div>
          </details>
        </div>
        <div class="console-actions">
          <button
            :if={!preparing?(@snapshot)}
            id="prepare-all"
            class="secondary"
            phx-click="prepare_all"
            disabled={
              not is_nil(@snapshot.active) or @snapshot.cleaning or @cache_busy or
                not is_nil(@snapshot.cleanup_error)
            }
          >Prepare all cases</button>
          <button
            :if={preparing?(@snapshot)}
            id="stop-preparation"
            class="secondary"
            phx-click="stop_preparation"
          >Stop preparation</button>
          <button id="check-readiness" class="secondary" phx-click="readiness">Check again</button>
        </div>
        <p class="fine-print">
          Preparing downloads and builds each missing case, attaches Pi and checks its fixtures. A cold first preparation needs internet and a long build. Prepared cases are skipped. Repeat it after any update, while still online.
        </p>
      </section>
      <section class="history panel">
        <div class="section-title">
          <h2>Run history</h2><span class="muted">Each run stands on its own.</span>
        </div>
        <p :if={@history_page.total == 0} class="muted">
          Your completed and interrupted runs will be kept here.
        </p>
        <button
          :for={run <- @history_page.items}
          class="history-row"
          phx-click="select"
          phx-value-id={run["id"]}
        ><span><strong>{Eab.ModelIdentity.label(run["model"])}</strong><span class="fine-print">{Eab.Harness.label(
          run
        )} · Thinking: {Eab.Thinking.label(run["settings"])}{if run["validation"],
          do: " · validation run"}</span><code>{run["id"]}</code></span><span>{run[
          "status"
        ]} →</span></button>
        <nav :if={@history_page.total > 20} aria-label="History pages">
          <button
            class="secondary"
            phx-click="history_page"
            phx-value-direction="previous"
            disabled={@history_offset == 0}
          >Newer runs</button>
          <button
            class="secondary"
            phx-click="history_page"
            phx-value-direction="next"
            disabled={@history_offset + 20 >= @history_page.total}
          >Older runs</button>
        </nav>
      </section>
      <details
        class="case-inventory"
        id="comparison"
        open={not is_nil(@comparison) or @comparison_ids != []}
      >
        <summary>Compare model runs</summary>
        <p class="fine-print">
          Choose runs with the same cases, fixtures and effective settings; seeds may differ. Repeated runs stay separate; incomplete runs have no final score. Compare models only within one harness. Model identities are server-reported.
        </p>
        <p class="fine-print">Selections stay checked when you change history pages.</p>
        <form id="compare-runs" phx-submit="compare" phx-change="comparison_select">
          <label
            :for={run <- @history_page.items}
            class="run-choice"
          >
            <input
              type="checkbox"
              name="comparison[ids][]"
              value={run["id"]}
              checked={run["id"] in @comparison_ids}
            />
            {Eab.ModelIdentity.label(run["model"])} · {run["id"]} · {run["status"]}
          </label>
          <button class="secondary" type="submit">Compare selected runs</button>
        </form>
        <div :if={@comparison}>
          <table aria-label="Selected model runs">
            <thead>
              <tr>
                <th>Run</th><th>Passed</th><th>Final score</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={run <- @comparison["runs"]}>
                <td>
                  {run["model"]} · {run["harness"]}{if run["seed"], do: " · seed #{run["seed"]}"}<br /><code>{run[
                    "id"
                  ]}</code>
                </td>
                <td>{run["score"]["passed"]}/{run["score"]["planned"]}</td>
                <td>
                  {if is_number(run["score"]["score_percent"]),
                    do: "#{run["score"]["score_percent"]}%",
                    else: "Incomplete / error"}
                </td>
              </tr>
            </tbody>
          </table>
          <div class="comparison-scroll">
            <table aria-label="Case outcomes across models">
              <thead>
                <tr>
                  <th>Case</th><th :for={run <- @comparison["runs"]}>
                    {run["model"]}<br /><code>{run["id"]}</code>
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- Enum.slice(@comparison["cases"], @comparison_offset, 25)}>
                  <td>{row["case"]}</td><td :for={outcome <- row["outcomes"]}>{outcome}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <nav :if={length(@comparison["cases"]) > 25} aria-label="Comparison case pages">
            <button
              class="secondary"
              phx-click="comparison_page"
              phx-value-direction="previous"
              disabled={@comparison_offset == 0}
            >Previous cases</button>
            <button
              class="secondary"
              phx-click="comparison_page"
              phx-value-direction="next"
              disabled={@comparison_offset + 25 >= length(@comparison["cases"])}
            >Next cases</button>
          </nav>
        </div>
      </details>
      <details class="case-inventory" id="run-series" open={not is_nil(@series)}>
        <summary>Run series</summary>
        <p class="fine-print">
          A published result is a series of three runs with identical setup. Local runs use seeds 101, 102 and 103 and each seed counts once; subscription series take their first three scored runs. The score is the mean; ± is 1.96 standard errors of rerun noise on these cases, shown from two runs. Validation runs never join a series.
        </p>
        <button class="secondary" phx-click="series">Load run series</button>
        <p :if={@series_error} class="notice error">{@series_error}</p>
        <table :if={@series && @series != []} aria-label="Local run series">
          <thead>
            <tr>
              <th>Series</th><th>Runs</th><th>Score</th><th>Missing seeds</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={series <- @series}>
              <td>
                {series["setup"]["model"]["name"]} · {series["setup"]["harness"]["name"]} · Thinking: {series[
                  "setup"
                ]["settings"]["reasoning_effort"] || "Not recorded"}<br /><code>{String.slice(
                  series["id"],
                  0,
                  12
                )}</code>
              </td>
              <td>{series["run_count"]}/{series["required_runs"]}</td>
              <td>
                {series["score_percent"]}%{if series["interval_percent"],
                  do: " ± #{series["interval_percent"]}"}
              </td>
              <td>{Enum.join(series["missing_seeds"], ", ")}</td>
            </tr>
          </tbody>
        </table>
        <p :if={@series == []} class="muted">No local runs with final scores yet.</p>
        <div :for={series <- Enum.reject(@published_series, & &1["complete"])} class="model-card">
          <h3>
            Provisional: {series["model"]["name"]} · {series["harness"]["name"]} · {series[
              "run_count"
            ]}/{series["required_runs"]} runs
          </h3>
          <p :if={series["missing_seeds"] != []}>
            Missing seeds: {Enum.join(series["missing_seeds"], ", ")}
          </p>
          <details>
            <summary>Required setup</summary>
            <pre>{Jason.encode!(series["setup"], pretty: true)}</pre>
          </details>
          <button class="secondary" phx-click="contribute" phx-value-id={series["series_id"]}>
            Contribute a run
          </button>
        </div>
      </details>
      <details
        class="case-inventory"
        id="cache-controls"
        open={
          not is_nil(@cache_preview) or @cache_busy or not is_nil(@cache_message) or @storage_busy or
            not is_nil(@storage)
        }
      >
        <summary>Retained preparation</summary>
        <p :if={@cache_status["error"]} class="notice error">{@cache_status["error"]}</p>
        <p :if={!@cache_status["error"]}>
          {@cache_status["baselines"]} retained baseline records · {@cache_status["images"]} distinct image references. Shared layers are not summed as storage usage.
        </p>
        <p class="fine-print">
          Baselines persist across models. Removing a case's retained state may require preparation on its next run. Shared images and active work are protected. Engine images, package downloads and Docker build cache remain available.
        </p>
        <button class="secondary" phx-click="storage" disabled={@storage_busy}>Refresh storage usage</button>
        <p :if={@storage_busy} role="status">Reading Docker and controller storage…</p>
        <div :if={@storage}>
          <p>
            Unique to benchmark-tagged images: {Storage.bytes(@storage["owned_unique_bytes"])}. Docker image storage across all projects: {Storage.bytes(
              @storage["daemon_image_bytes"]
            )}.
          </p>
          <p class="fine-print">
            Shared layers are excluded from the unique figure, including layers shared only among benchmark images. Per-image shared sizes must not be added together. These figures are not an estimate of space freed by removal. Snapshot: {@storage[
              "recorded_at"
            ]}.
          </p>
          <table aria-label="Docker storage totals">
            <thead>
              <tr>
                <th>Docker area (all projects)</th><th>Reported size</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @storage["docker_totals"]}>
                <td>{row["Type"]}</td><td>{row["Size"]}</td>
              </tr>
            </tbody>
          </table>
          <table aria-label="Controller storage">
            <thead>
              <tr>
                <th>Controller area</th><th>Allocated storage</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{name, bytes} <- Enum.sort(@storage["controller_areas"])}>
                <td>{name}</td><td>{Storage.bytes(bytes)}</td>
              </tr>
            </tbody>
          </table>
          <details>
            <summary>Shared and unique storage per image</summary>
            <table>
              <thead>
                <tr>
                  <th>Image</th><th>Shared</th><th>Unique</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={image <- @storage["images"]}>
                  <td><code>{String.slice(image["image"], 0, 19)}</code></td><td>
                    {Storage.bytes(image["shared"])}
                  </td><td>{Storage.bytes(image["unique"])}</td>
                </tr>
              </tbody>
            </table>
          </details>
        </div>
        <form id="cache-preview" phx-submit="cache_preview">
          <label>Choose cached state<select name="cache[case]">
            <option value="unused">Unreferenced application and database artifacts</option>
            <option :for={id <- @cache_status["releases"] || []} value={"release:" <> id}>
              Release {String.slice(id, 0, 12)}
            </option>
            <option :for={id <- @cache_status["cases"]} value={id}>{id}</option>
          </select></label>
          <button
            class="secondary"
            type="submit"
            disabled={@cache_busy or @offline or not is_nil(@cache_status["error"])}
          >Preview removal</button>
        </form>
        <div :if={@cache_preview}>
          <p>
            Remove {@cache_preview["case"]}: {length(@cache_preview["images"])} image references eligible; {@cache_preview[
              "shared_records_preserved"
            ]} shared artifact records preserved.
          </p>
          <p class="fine-print">
            Affected cases: {Enum.join(@cache_preview["affected_cases"], ", ")}. Other retained releases keep their shared artifacts.
          </p>
          <button
            class="danger"
            phx-click="cache_remove"
            disabled={@cache_busy or busy?(@snapshot) or @snapshot.cleaning}
          >Remove this cached state</button>
        </div>
        <p :if={@cache_busy} role="status">Removing unused cached state…</p>
        <p :if={@cache_message} role="status">{@cache_message}</p>
        <ul :if={@cache_failures != []}>
          <li :for={failure <- @cache_failures}>
            <code>{failure["image"]}</code>: {failure["reason"]}
          </li>
        </ul>
      </details>
      <details class="case-inventory">
        <summary>Explore the {@case_count} historical cases</summary><div class="case-grid">
          <article :for={spec <- @cases}>
            <span class="eyebrow">{spec["id"]}</span><h3>{spec["title"]}</h3><a
              href={spec["source_inspiration"]["url"]}
              target="_blank"
              rel="noopener noreferrer"
            >Upstream pull request ↗</a>
          </article>
        </div>
      </details>
      <footer>
        ELIXIR AGENT BENCHMARK <span>Behavioral checks. No AI judge. No speed score.</span>
      </footer>
    </main>
    """
  end
end
