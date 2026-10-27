/* One shared plot of run series. All values come from the public export. */
(() => {
  "use strict";
  const data = window.BENCHMARK_DATA;
  const $ = id => document.getElementById(id);
  const node = (tag, className, text) => {
    const e = document.createElement(tag);
    if (className) e.className = className;
    if (text !== undefined) e.textContent = text;
    return e;
  };
  if (!data || data.schema_version !== 5) {
    $("chart").append(node("p", "empty", "Results could not be loaded. Please reload."));
    $("size-limit").disabled = true;
    return;
  }
  const records = data.results;
  if (records.length === 0) {
    document.querySelector(".size-control").remove();
    document.querySelector("footer").remove();
    $("chart").append(node("p", "empty", "No benchmark results yet."));
    return;
  }
  $("snapshot-note").hidden = !records.some(r => r.resources?.kind === "loaded_snapshot");
  const number = new Intl.NumberFormat("en-US");
  const fmt = value => number.format(value);
  const gb = bytes => bytes == null ? "Not recorded" : `${(bytes / 1e9).toFixed(1)} GB`;
  const hosted = r => ["openai_subscription", "anthropic", "claude_code"].includes(r.model.backend);
  const harness = r => r.harness.name === "claude_code" ? `Claude Code ${r.harness.version}` : `Pi ${r.harness.version}`;
  const scoreText = r => `${r.score_percent.toFixed(1)}%` + (r.interval_percent == null ? "" : ` ± ${r.interval_percent.toFixed(1)}`);
  const runsText = r => r.complete ? `${r.run_count} runs` :
    `Provisional · ${r.run_count}/${r.required_runs} runs` + (r.missing_seeds.length ? ` · missing seed ${r.missing_seeds.join(", ")}` : "");
  const thinking = r => ({unknown: "Not reported", on: "On (no level)", off: "Off",
    default: "Server/provider default", unsupported: "Not supported"})[r.settings.reasoning_effort] ||
    r.settings.reasoning_effort || "Not recorded";
  const vram = r => r.resources ? (r.resources.peak_vram_bytes ?? r.resources.gpus.reduce((sum, gpu) => sum + gpu.used_bytes, 0)) : null;
  const context = r => r.settings.window_tokens ? `${fmt(r.settings.window_tokens)} context` : "API";
  const sum = (run, key) => run.cases.every(c => Number.isInteger(c[key])) ? run.cases.reduce((n, c) => n + c[key], 0) : null;
  const readable = value => value == null ? "Not recorded" : typeof value === "boolean" ? (value ? "Enabled" : "Disabled") :
    typeof value === "number" ? fmt(value) : value.replaceAll("_", " ");
  const largest = records.reduce((max, r) => Math.max(max, (r.model.size_bytes || 0) / 1e9), 0);
  const allValue = Math.max(100, Math.ceil(largest / 10) * 10) + 1;
  $("size-limit").max = allValue;
  $("size-limit").value = allValue;
  const settings = {
    max_tokens: "Generation budget / case", budget_policy: "Budget policy", context_policy: "Context policy",
    window_tokens: "Context limit", response_tokens: "Tokens / response", safety_tokens: "Safety tokens",
    seed: "Seed", compaction: "History compaction", reasoning_effort: "Reasoning effort",
    reasoning_effort_source: "Thinking source", thinking_policy: "Thinking policy",
  };
  let selected = null;

  function ticks(total) {
    if (total <= 10) return Array.from({length: total + 1}, (_, i) => i);
    const rough = total / 6, magnitude = 10 ** Math.floor(Math.log10(rough));
    const step = [1, 2, 5, 10].find(n => n * magnitude >= rough) * magnitude;
    const values = Array.from({length: Math.floor(total / step) + 1}, (_, i) => i * step);
    if (values.at(-1) !== total) {
      if (total - values.at(-1) <= step / 2) values.pop();
      values.push(total);
    }
    return values;
  }
  function definitionList(entries) {
    const list = node("dl", "setting-list");
    for (const [label, value] of entries) list.append(node("dt", "", label), node("dd", "", value));
    return list;
  }
  function details(r) {
    const body = node("section", "run-detail");
    body.id = "run-detail";
    body.setAttribute("aria-label", `${r.model.name} details`);
    const heading = node("div", "detail-heading");
    heading.append(node("h2", "", `${r.model.name}${r.model.quantization ? ` · ${r.model.quantization}` : ""} · ${harness(r)} · Thinking: ${thinking(r)}`));
    const close = node("button", "close-detail", "Close ×");
    close.addEventListener("click", () => {
      selected = null;
      render();
      document.getElementById(`point-${r.series_id}`)?.focus();
    });
    heading.append(close);
    body.append(heading);
    body.append(node("p", "detail-note", `${scoreText(r)} · ${runsText(r)}. The score is the mean of the runs; ± is 1.96 standard errors of rerun noise on these cases, shown once two runs exist.`));
    if (r.note) body.append(node("p", "detail-note", r.note));
    const layout = node("div", "detail-layout");
    const outcomes = node("div");
    outcomes.append(node("h3", "", "Case outcomes"));
    const table = node("table", "case-table");
    const head = node("thead"), hr = node("tr");
    for (const title of ["Case", "Runs passed"]) hr.append(node("th", "", title));
    head.append(hr); table.append(head);
    const tbody = node("tbody");
    for (const c of r.runs[0].cases) {
      const row = node("tr"), count = r.case_passes[c.id];
      row.append(node("td", "case-id", c.id),
        node("td", count === r.run_count ? "passed" : count === 0 ? "failed" : "numeric", `${count}/${r.run_count}`));
      tbody.append(row);
    }
    table.append(tbody); outcomes.append(table);
    outcomes.append(node("h3", "settings-heading", "Runs"));
    const runs = node("table", "case-table");
    const runHead = node("thead"), runRow = node("tr");
    for (const title of ["Run", "Seed", "Parallel attempts", "Passed", "Output tokens", "Model calls"]) runRow.append(node("th", "", title));
    runHead.append(runRow); runs.append(runHead);
    const runBody = node("tbody");
    for (const run of r.runs) {
      const row = node("tr"), tokens = sum(run, "generated_tokens"), calls = sum(run, "model_calls");
      row.append(node("td", "case-id", `${run.created_at.slice(0, 10)} · ${run.run_id}`), node("td", "numeric", run.seed ?? "—"),
        node("td", "numeric", run.deployment?.parallel_attempts ?? 1),
        node("td", "numeric", `${run.cases.filter(c => c.passed).length}/${run.cases.length}`),
        node("td", "numeric", tokens == null ? "—" : fmt(tokens)), node("td", "numeric", calls == null ? "—" : fmt(calls)));
      runBody.append(row);
    }
    runs.append(runBody); outcomes.append(runs);
    if (!r.complete) {
      outcomes.append(node("h3", "settings-heading", "Required setup for the missing runs"));
      outcomes.append(definitionList(Object.entries(r.setup).map(([key, value]) =>
        [readable(key), typeof value === "object" && value !== null ? JSON.stringify(value) : readable(value)])));
    }
    const conditions = node("div");
    conditions.append(node("h3", "", "Memory & deployment"));
    const memory = [["Model weights", gb(r.model.size_bytes)], ["Context limit", context(r)]];
    if (r.resources) {
      const p = r.resources;
      if (p.kind === "run_samples") {
        memory.push(["Server context capacity", `${fmt(p.context_tokens)} tokens`], ["VRAM · run peak", gb(p.peak_vram_bytes)], ["Service RAM · run peak", gb(p.peak_ram_bytes)],
          ["RAM + VRAM · simultaneous peak", gb(p.peak_combined_bytes)], ["Process RSS · run peak", gb(p.peak_rss_bytes)],
          ["Memory coverage", `${p.coverage} · ${fmt(p.sample_count)} samples · ${p.interval_ms / 1000}s interval · highest run`],
          ["KV cache", p.kv_cache || "Not recorded"], ["Runtime", p.backend_version], ["CPU", p.cpu]);
        for (const [i, gpu] of p.gpus.entries()) memory.push([`GPU ${i + 1} · ${gpu.name} · peak`, `${gb(gpu.used_bytes)} / ${(gpu.capacity_bytes / 2**30).toFixed(0)} GiB`]);
        conditions.append(definitionList(memory), node("p", "detail-note", "From the series run with the highest simultaneous RAM + VRAM peak. Service RAM includes charged page cache. Configured context is capacity; actual occupancy varies with the tasks."));
      } else {
      memory.push(["GPU memory · sampled", gb(vram(r))], ["Engine RAM · sampled RSS", gb(p.ram_rss_bytes)],
        ["Engine RAM · lifetime peak RSS", gb(p.ram_lifetime_peak_bytes)],
        ["Service RAM · sampled", gb(p.service_ram_bytes)], ["Service RAM · lifetime peak", gb(p.service_ram_lifetime_peak_bytes)],
        ["KV cache", p.kv_cache || "Not recorded"], ["Runtime", p.backend_version], ["CPU", p.cpu]);
      for (const [i, gpu] of p.gpus.entries()) memory.push([`GPU ${i + 1} · ${gpu.name}`, `${gb(gpu.used_bytes)} / ${(gpu.capacity_bytes / 2**30).toFixed(0)} GiB`]);
      conditions.append(definitionList(memory), node("p", "detail-note", `Loaded-process observation: ${new Date(p.observed_at).toISOString().replace("T", " ")}. Lifetime peaks cover the process/service lifetime, not this run. The configured context limit does not establish a fully occupied context measurement.`));
      }
    } else {
      memory.push(["GPU / RAM observation", hosted(r) ? "Hosted API" : "Not captured"]);
      conditions.append(definitionList(memory));
    }
    conditions.append(node("h3", "settings-heading", "Run settings"), definitionList(
      Object.entries(r.settings).map(([key, value]) => [settings[key] || readable(key), readable(value)])));
    conditions.append(node("p", "record-id", `Series: ${r.series_id}`));
    if (r.evidence_url) {
      const link = node("a", "", "Recorded evidence ↗"); link.href = r.evidence_url; conditions.append(link);
    }
    layout.append(outcomes, conditions); body.append(layout);
    return body;
  }
  function plot(shown) {
    const figure = node("div", "plot");
    const area = node("div", "plot-area");
    area.style.setProperty("--row-count", Math.max(shown.length, 1));
    for (const value of ticks(data.benchmark.case_count)) {
      const line = node("div", "plot-grid");
      line.style.left = `${value / data.benchmark.case_count * 100}%`;
      line.append(node("span", "plot-tick", value));
      area.append(line);
    }
    for (const [i, r] of shown.entries()) {
      const position = r.score_percent / 100;
      const point = node("button", "plot-point" + (selected === r.series_id ? " selected" : "") + (position < .2 ? " near-start" : "") + (r.complete ? "" : " provisional"));
      point.id = `point-${r.series_id}`;
      point.style.left = `${position * 100}%`;
      point.style.setProperty("--score-position", position);
      point.style.setProperty("--row-index", i);
      point.setAttribute("aria-label", `${r.model.name}${r.model.quantization ? ` ${r.model.quantization}` : ""}, ${harness(r)}, thinking ${thinking(r)}, ${scoreText(r)} of ${r.total} cases, ${runsText(r)}. Show details`);
      point.setAttribute("aria-expanded", String(selected === r.series_id));
      if (selected === r.series_id) point.setAttribute("aria-controls", "run-detail");
      const label = node("span", "point-label");
      label.append(node("span", "model-name", r.model.name), node("span", "point-meta", [r.model.quantization, harness(r), `Thinking: ${thinking(r)}`,
        hosted(r) ? "API" : `${gb(r.model.size_bytes)} weights`, r.settings.window_tokens ? `${r.settings.window_tokens / 1024}K ctx` : null].filter(Boolean).join(" · ")),
        node("span", "point-meta", runsText(r)));
      if (r.resources) label.append(node("span", "point-memory", r.resources.kind === "run_samples" ?
        `${gb(vram(r))} VRAM · ${gb(r.resources.peak_ram_bytes)} RAM · ${r.resources.coverage === "complete" ? "run peaks" : "partial samples"}` :
        `${gb(vram(r))} VRAM · ${gb(r.resources.service_ram_lifetime_peak_bytes ?? r.resources.ram_lifetime_peak_bytes)} RAM peak¹`));
      else if (!hosted(r)) label.append(node("span", "point-memory", "RAM / VRAM not recorded"));
      if (records.filter(other => other.model.name === r.model.name && other.model.quantization === r.model.quantization).length > 1) {
        label.append(node("span", "point-meta", `Series ${r.series_id.slice(0, 8)}`));
      }
      const dot = node("span", "result-dot");
      const score = node("span", "point-score", scoreText(r));
      point.append(label, dot, score);
      if (r.interval_percent != null) {
        const low = Math.max(0, r.score_percent - r.interval_percent), high = Math.min(100, r.score_percent + r.interval_percent);
        const bar = node("span", "interval");
        // One score point is 1cqw of the plot; the bar starts from the dot's centre.
        bar.style.left = `calc(50% + ${low - r.score_percent}cqw)`;
        bar.style.width = `${high - low}cqw`;
        point.append(bar);
      }
      point.addEventListener("click", () => {
        selected = selected === r.series_id ? null : r.series_id;
        render();
        document.getElementById(point.id)?.focus();
      });
      area.append(point);
    }
    figure.append(area, node("div", "axis-caption", "Cases passed (mean of runs)"));
    return figure;
  }
  function render() {
    const cap = Number($("size-limit").value), all = cap === allValue;
    const shown = records.filter(r => all || r.model.size_bytes !== null && r.model.size_bytes / 1e9 <= cap)
      .sort((a, b) => b.score_percent - a.score_percent || a.model.name.localeCompare(b.model.name) || b.run_count - a.run_count);
    $("size-value").textContent = all ? "All" : `${cap} GB`;
    $("size-limit").setAttribute("aria-valuetext", all ? "All models" : `Up to ${cap} GB of model weights`);
    $("chart").replaceChildren();
    if (shown.length) $("chart").append(plot(shown));
    else $("chart").append(node("p", "empty", "No models within this size limit."));
    const active = shown.find(r => r.series_id === selected);
    if (active) $("chart").append(details(active)); else selected = null;
    const unknownSizes = records.some(r => r.model.size_bytes === null);
    $("result-status").textContent = `${shown.length} / ${records.length} run series` + (!all && unknownSizes ? " · API / unknown sizes hidden" : "");
  }
  $("size-limit").addEventListener("input", render);
  render();
})();
