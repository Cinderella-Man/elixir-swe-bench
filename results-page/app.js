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
    $("memory-limit").disabled = true;
    return;
  }
  const records = data.results;
  if (records.length === 0) {
    document.querySelector(".memory-control").remove();
    document.querySelector("footer").remove();
    $("chart").append(node("p", "empty", "No benchmark results yet."));
    return;
  }
  const number = new Intl.NumberFormat("en-US");
  const fmt = value => number.format(value);
  const gb = bytes => bytes == null ? "Not recorded" : `${(bytes / 1e9).toFixed(1)} GB`;
  // Cards are sold by GiB, so a GPU's use is shown against its capacity in the same unit.
  const card = gpu => `${(gpu.used_bytes / 2**30).toFixed(1)} / ${(gpu.capacity_bytes / 2**30).toFixed(0)} GiB` +
    ` (${Math.round(100 * gpu.used_bytes / gpu.capacity_bytes)}%)`;
  const hosted = r => ["openai_subscription", "anthropic", "claude_code"].includes(r.model.backend);
  const harness = r => r.harness.name === "claude_code" ? `Claude Code ${r.harness.version}` : `Pi ${r.harness.version}`;
  const scoreText = r => `${r.score_percent.toFixed(1)}%` + (r.interval_percent == null ? "" : ` ± ${r.interval_percent.toFixed(1)}`);
  const runsText = r => r.complete ? `${r.run_count} runs` :
    `Provisional · ${r.run_count}/${r.required_runs} runs` + (r.missing_seeds.length ? ` · missing seed ${r.missing_seeds.join(", ")}` : "");
  const thinking = r => ({unknown: "Not reported", on: "On (no level)", off: "Off",
    default: "Server/provider default", unsupported: "Not supported"})[r.settings.reasoning_effort] ||
    r.settings.reasoning_effort || "Not recorded";
  // The chart names the model and its thinking level only; the rest is in the details.
  const effort = r => ({minimal: "Minimal", low: "Low", medium: "Medium", high: "High", xhigh: "Extra", max: "Max",
    on: "Thinking", off: "No thinking"})[r.settings.reasoning_effort];
  const chartName = r => [r.model.name, r.model.quantization, effort(r)].filter(Boolean).join(" ");
  // Claude Code cannot enforce the declared generation budget, so going over it is flagged, not failed (ADR 0010).
  const overBudget = (r, c) => Number.isInteger(r.settings.max_tokens) && Number.isInteger(c?.generated_tokens) &&
    c.generated_tokens > r.settings.max_tokens;
  const budgetTag = (r, n, of) => {
    const tag = node("span", "budget-tag", `over ${Math.round(r.settings.max_tokens / 1000)}k` + (n > 1 ? ` ×${n}` : ""));
    tag.title = `Generated more than the declared ${fmt(r.settings.max_tokens)}-token budget ${of}. It is flagged, not failed.`;
    return tag;
  };
  const vram = r => r.resources ? (r.resources.peak_vram_bytes ?? r.resources.gpus.reduce((sum, gpu) => sum + gpu.used_bytes, 0)) : null;
  const context = r => r.settings.window_tokens ? `${fmt(r.settings.window_tokens)} context` : "API";
  const sum = (run, key) => run.cases.every(c => Number.isInteger(c[key])) ? run.cases.reduce((n, c) => n + c[key], 0) : null;
  const readable = value => value == null ? "Not recorded" : typeof value === "boolean" ? (value ? "Enabled" : "Disabled") :
    typeof value === "number" ? fmt(value) : value.replaceAll("_", " ");
  // Only a run's sampled peak is a measurement; a loaded-model snapshot is not a run's requirement.
  const required = r => r.resources?.kind === "run_samples" ? r.resources.peak_combined_bytes : null;
  const largest = records.reduce((max, r) => Math.max(max, (required(r) || 0) / 1e9), 0);
  const allValue = Math.max(100, Math.ceil(largest / 10) * 10) + 1;
  $("memory-limit").max = allValue;
  $("memory-limit").value = allValue;
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
      const row = node("tr"), count = r.case_passes[c.id], name = node("td", "case-id", c.id);
      const over = r.runs.filter(run => overBudget(r, run.cases.find(other => other.id === c.id))).length;
      if (over) name.append(budgetTag(r, over, `in ${over} of ${r.run_count} runs`));
      row.append(name,
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
      const over = run.cases.filter(c => overBudget(r, c)).length, tokenCell = node("td", "numeric", tokens == null ? "—" : fmt(tokens));
      if (over) tokenCell.append(budgetTag(r, over, `in ${over} of this run's ${run.cases.length} cases`));
      row.append(node("td", "case-id", `${run.created_at.slice(0, 10)} · ${run.run_id}`), node("td", "numeric", run.seed ?? "—"),
        node("td", "numeric", run.deployment?.parallel_attempts ?? 1),
        node("td", "numeric", `${run.cases.filter(c => c.passed).length}/${run.cases.length}`),
        tokenCell, node("td", "numeric", calls == null ? "—" : fmt(calls)));
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
        for (const [i, gpu] of p.gpus.entries()) memory.push([`GPU ${i + 1} · ${gpu.name} · peak`, card(gpu)]);
        conditions.append(definitionList(memory), node("p", "detail-note", "From the series run with the highest simultaneous RAM + VRAM peak. Service RAM includes charged page cache. Configured context is capacity; actual occupancy varies with the tasks."));
      } else {
      memory.push(["GPU memory · sampled", gb(vram(r))], ["Engine RAM · sampled RSS", gb(p.ram_rss_bytes)],
        ["Engine RAM · lifetime peak RSS", gb(p.ram_lifetime_peak_bytes)],
        ["Service RAM · sampled", gb(p.service_ram_bytes)], ["Service RAM · lifetime peak", gb(p.service_ram_lifetime_peak_bytes)],
        ["KV cache", p.kv_cache || "Not recorded"], ["Runtime", p.backend_version], ["CPU", p.cpu]);
      for (const [i, gpu] of p.gpus.entries()) memory.push([`GPU ${i + 1} · ${gpu.name}`, card(gpu)]);
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
  // Memory runs along the bottom in 64 GB steps, the sizes PCs and cards come in.
  const memoryMax = Math.max(64, Math.ceil(largest / 64) * 64);
  const casesText = r => `${fmt(Math.round(r.score_percent * r.total / 10) / 10)} of ${r.total} cases`;
  const memoryText = r => required(r) != null ? `${gb(required(r))} peak VRAM + RAM` : hosted(r) ? "API: no local memory" : "Memory not measured";
  // The series no cheaper series beats: each passes more cases than everything that used less memory.
  function frontier(measured) {
    const best = [];
    for (const r of [...measured].sort((a, b) => required(a) - required(b) || b.score_percent - a.score_percent)) {
      if (!best.length || r.score_percent > best.at(-1).score_percent) best.push(r);
    }
    return best;
  }
  function frontierLine(best) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", "frontier");
    svg.setAttribute("viewBox", "0 0 100 100");
    svg.setAttribute("preserveAspectRatio", "none");
    svg.setAttribute("aria-hidden", "true");
    const x = r => required(r) / 1e9 / memoryMax * 100, y = r => 100 - r.score_percent;
    let d = `M${x(best[0])},${y(best[0])}`;
    for (const r of best.slice(1)) d += ` H${x(r)} V${y(r)}`;
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("d", d + " H100");
    svg.append(path);
    return svg;
  }
  function legend(shown, withFrontier) {
    const list = node("div", "scatter-legend");
    const item = (mark, text) => { const entry = node("span", "legend-item"); entry.append(node("span", `legend-mark ${mark}`), text); list.append(entry); };
    if (shown.some(r => r.harness.name === "pi")) item("circle", "Pi");
    if (shown.some(r => r.harness.name === "claude_code")) item("diamond", "Claude Code");
    if (shown.some(r => !r.complete)) item("circle hollow", "Provisional (fewer than 3 runs)");
    if (withFrontier) item("line", "Most cases passed for its memory");
    return list;
  }
  function point(r, x, best, beyond, number) {
    const point = node("button", "scatter-point" + (r.harness.name === "claude_code" ? " diamond" : "") + (r.complete ? "" : " provisional") +
      (best ? " best" : "") + (beyond ? " beyond" : "") + (selected === r.series_id ? " selected" : ""));
    point.id = `point-${r.series_id}`;
    point.dataset.number = number;
    point.style.left = `${x * 100}%`;
    point.style.bottom = `${r.score_percent}%`;
    point.setAttribute("aria-label", `${chartName(r)}, ${harness(r)}, ${casesText(r)} (${scoreText(r)}), ${memoryText(r)}, ${runsText(r)}. Show details`);
    point.setAttribute("aria-expanded", String(selected === r.series_id));
    if (selected === r.series_id) point.setAttribute("aria-controls", "run-detail");
    if (r.interval_percent != null) {
      const low = Math.max(0, r.score_percent - r.interval_percent), high = Math.min(100, r.score_percent + r.interval_percent);
      const bar = node("span", "interval");
      // One score point is 1cqh of the plot; the bar is measured from the dot's centre.
      bar.style.bottom = `calc(50% + ${low - r.score_percent}cqh)`;
      bar.style.height = `${high - low}cqh`;
      point.append(bar);
    }
    const label = node("span", "point-label");
    label.append(node("span", "model-name", chartName(r)));
    if (records.filter(other => chartName(other) === chartName(r)).length > 1) {
      label.append(node("span", "point-meta", `${harness(r)} · Series ${r.series_id.slice(0, 8)}`));
    }
    point.append(node("span", "result-dot"), label, node("span", "point-number", number));
    point.addEventListener("click", () => {
      selected = selected === r.series_id ? null : r.series_id;
      render();
      document.getElementById(point.id)?.focus();
    });
    for (const show of ["pointerenter", "focus"]) point.addEventListener(show, () => tip(r, point));
    for (const hide of ["pointerleave", "blur"]) point.addEventListener(hide, () => tip(null));
    return point;
  }
  // One tooltip for the chart: the result first, then what it is.
  function tip(r, point) {
    const box = document.querySelector(".chart-tip");
    if (!box) return;
    if (!r) { box.hidden = true; return; }
    box.replaceChildren(node("strong", "", casesText(r) + (r.interval_percent == null ? "" : ` ± ${fmt(Math.round(r.interval_percent * r.total / 10) / 10)}`)),
      node("span", "", chartName(r)), node("span", "tip-muted", memoryText(r)), node("span", "tip-muted", `${harness(r)} · ${runsText(r)}`));
    box.hidden = false;
    const figure = box.parentElement.getBoundingClientRect(), at = point.getBoundingClientRect(), size = box.getBoundingClientRect();
    const left = Math.min(Math.max(at.left - figure.left + at.width / 2 - size.width / 2, 0), figure.width - size.width);
    const above = at.top - figure.top - size.height - 8;
    box.style.left = `${left}px`;
    box.style.top = `${above >= 0 ? above : at.bottom - figure.top + 8}px`;
  }
  function table(shown) {
    const view = node("details", "table-view");
    view.append(node("summary", "", "Table view"));
    const grid = node("table", "case-table"), head = node("thead"), row = node("tr");
    for (const title of ["Model", "Harness", "Cases passed", "Peak VRAM + RAM", "Runs"]) row.append(node("th", "", title));
    head.append(row); grid.append(head);
    const body = node("tbody");
    for (const r of shown) {
      const line = node("tr");
      line.append(node("td", "case-id", chartName(r)), node("td", "", harness(r)), node("td", "numeric", `${casesText(r)} (${scoreText(r)})`),
        node("td", "numeric", required(r) != null ? gb(required(r)) : hosted(r) ? "API" : "Not measured"), node("td", "", runsText(r)));
      body.append(line);
    }
    grid.append(body); view.append(grid);
    return view;
  }
  function scatter(shown, cap, all) {
    const figure = node("div", "scatter");
    const measured = shown.filter(r => required(r) != null), other = shown.filter(r => required(r) == null);
    const best = frontier(measured);
    figure.append(legend(shown, best.length > 1), node("div", "y-caption", "Cases passed (mean of runs)"));
    const body = node("div", "scatter-body");
    const area = node("div", "scatter-plot");
    for (const value of ticks(data.benchmark.case_count)) {
      const line = node("div", "grid-row");
      line.style.bottom = `${value / data.benchmark.case_count * 100}%`;
      line.append(node("span", "y-tick", value));
      area.append(line);
    }
    for (let size = 0; size <= memoryMax; size += 64) {
      const line = node("div", "grid-col");
      line.style.left = `${size / memoryMax * 100}%`;
      line.append(node("span", "x-tick" + (size === memoryMax ? " end" : ""), size ? `${size} GB` : "0"));
      area.append(line);
    }
    if (best.length > 1) area.append(frontierLine(best));
    if (!all) {
      const limit = node("div", "limit-line");
      limit.style.left = `${Math.min(cap / memoryMax, 1) * 100}%`;
      area.append(limit);
    }
    // Numbers follow the score order, so the key below reads from the top of the chart down.
    const number = r => shown.indexOf(r) + 1;
    for (const r of measured) area.append(point(r, required(r) / 1e9 / memoryMax, best.includes(r), !all && required(r) / 1e9 > cap, number(r)));
    body.append(area);
    if (other.length) {
      const strip = node("div", "api-strip");
      strip.append(node("span", "strip-title", other.every(hosted) ? "API" : "API or not measured"));
      // Spread across the strip: API models have no memory to place them by.
      other.forEach((r, i) => strip.append(point(r, (i + 1) / (other.length + 1), false, !all, number(r))));
      body.append(strip);
    }
    const tipBox = node("div", "chart-tip");
    tipBox.hidden = true;
    tipBox.setAttribute("role", "tooltip");
    figure.append(body, node("div", "axis-caption", "Peak VRAM + RAM in our runs"), node("ol", "point-key"), tipBox, table(shown));
    return figure;
  }
  const overlaps = (a, b) => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
  // Names go right, left, above or below their dot, whichever is free and inside the chart; frontier and
  // selected models are named first. A dot whose name has no room shows a number, named in the key below.
  function placeLabels() {
    const numbered = [];
    for (const zone of document.querySelectorAll(".scatter-plot, .api-strip")) {
      const bounds = (zone.classList.contains("api-strip") ? zone.parentElement : zone).getBoundingClientRect();
      const points = [...zone.querySelectorAll(".scatter-point")];
      const rank = p => (p.classList.contains("selected") ? 2 : 0) + (p.classList.contains("best") ? 1 : 0);
      points.sort((a, b) => rank(b) - rank(a));
      const taken = points.map(p => p.querySelector(".result-dot").getBoundingClientRect());
      for (const p of points) {
        const label = p.querySelector(".point-label");
        let placed = false;
        for (const side of ["right", "left", "above", "below"]) {
          label.className = `point-label place-${side}`;
          const box = label.getBoundingClientRect();
          const inside = box.left >= bounds.left && box.right <= bounds.right && box.top >= bounds.top - 12 && box.bottom <= bounds.bottom + 12;
          if (inside && !taken.some(t => overlaps(t, box))) { taken.push(box); placed = true; break; }
        }
        p.classList.toggle("numbered", !placed);
        if (!placed) { label.className = "point-label unplaced"; numbered.push(p); }
      }
    }
    const key = document.querySelector(".point-key");
    if (!key) return;
    key.replaceChildren(...numbered.sort((a, b) => a.dataset.number - b.dataset.number).map(p => {
      const item = node("li", "", p.querySelector(".model-name").textContent);
      item.value = Number(p.dataset.number);
      return item;
    }));
    key.hidden = numbered.length === 0;
  }
  function render() {
    const cap = Number($("memory-limit").value), all = cap === allValue;
    const shown = [...records].sort((a, b) => b.score_percent - a.score_percent || a.model.name.localeCompare(b.model.name) || b.run_count - a.run_count);
    $("memory-value").textContent = all ? "All" : `${cap} GB`;
    $("memory-limit").setAttribute("aria-valuetext", all ? "All models" : `Up to ${cap} GB of VRAM and RAM`);
    $("chart").replaceChildren(scatter(shown, cap, all));
    placeLabels();
    const active = shown.find(r => r.series_id === selected);
    if (active) $("chart").append(details(active)); else selected = null;
    const within = records.filter(r => required(r) != null && required(r) / 1e9 <= cap).length;
    $("result-status").textContent = all ? `${records.length} run series` : `${within} of ${records.length} run series within ${cap} GB`;
  }
  $("memory-limit").addEventListener("input", render);
  window.addEventListener("resize", placeLabels);
  render();
})();
