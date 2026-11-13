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
  if (!data || data.schema_version !== 7) {
    $("chart").append(node("p", "empty", "Results could not be loaded. Please reload."));
    return;
  }
  const records = data.results;
  if (records.length === 0) {
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
  // Who made the quantization comes before it, as in "Unsloth UD-Q5_K_XL": the same name can come from several makers.
  const quant = r => [r.model.quantized_by, r.model.quantization].filter(Boolean).join(" ");
  const chartName = r => [r.model.name, quant(r), effort(r)].filter(Boolean).join(" ");
  // Claude Code cannot enforce the declared generation budget, so going over it is flagged, not failed (ADR 0010).
  const overBudget = (r, c) => Number.isInteger(r.settings.max_tokens) && Number.isInteger(c?.generated_tokens) &&
    c.generated_tokens > r.settings.max_tokens;
  const budgetTag = (r, n, of) => {
    const tag = node("span", "budget-tag", `over ${Math.round(r.settings.max_tokens / 1000)}k` + (n > 1 ? ` ×${n}` : ""));
    tag.title = `Generated more than the declared ${fmt(r.settings.max_tokens)}-token budget ${of}. It is flagged, not failed.`;
    return tag;
  };
  // A budget can end an attempt before the agent finishes. The patch at that point is graded, and may still pass.
  const thousands = tokens => `${Math.floor(tokens / 1000)}k`;
  const cutoffs = {
    generation_budget: {
      label: r => `stopped at ${thousands(r.settings.max_tokens)}`,
      text: r => `the attempt used its whole ${fmt(r.settings.max_tokens)}-token generation budget`,
    },
    context_budget: {
      label: () => "context full",
      text: r => r.settings.window_tokens ?
        `the next prompt would not fit the ${fmt(r.settings.window_tokens)}-token context limit with ${fmt(r.settings.response_tokens)} tokens kept for the reply` :
        "the conversation reached the model's context limit",
    },
    response_budget: {
      label: r => r.settings.response_tokens ? `reply cut at ${thousands(r.settings.response_tokens)}` : "reply cut off",
      text: r => `one reply reached the ${r.settings.response_tokens ? `${fmt(r.settings.response_tokens)}-token ` : ""}` +
        "response limit before the agent had finished, which ended the attempt",
    },
  };
  const cutoffTag = (r, kind, n, where) => {
    const tag = node("span", "cutoff-tag", cutoffs[kind].label(r) + (n > 1 ? ` ×${n}` : ""));
    tag.title = `${where}, ${cutoffs[kind].text(r)}. The patch at that point was graded.`;
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
    heading.append(node("h2", "", `${r.model.name}${quant(r) ? ` · ${quant(r)}` : ""} · ${harness(r)} · Thinking: ${thinking(r)}`));
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
    const attempts = r.runs.flatMap(run => run.cases), cut = attempts.filter(c => c.cutoff).length;
    if (cut) outcomes.append(node("p", "detail-note", `${cut} of ${attempts.length} attempts ran out of a budget before the agent had finished. ` +
      "Their patches at that point were graded; the tags say which limit."));
    const table = node("table", "case-table");
    const head = node("thead"), hr = node("tr");
    for (const title of ["Case", "Runs passed"]) hr.append(node("th", "", title));
    head.append(hr); table.append(head);
    const tbody = node("tbody");
    for (const c of r.runs[0].cases) {
      const row = node("tr"), count = r.case_passes[c.id], name = node("td", "case-id", c.id);
      const tries = r.runs.map(run => run.cases.find(other => other.id === c.id));
      const over = tries.filter(t => overBudget(r, t)).length;
      if (over) name.append(budgetTag(r, over, `in ${over} of ${r.run_count} runs`));
      for (const kind of Object.keys(cutoffs)) {
        const n = tries.filter(t => t.cutoff === kind).length;
        if (n) name.append(cutoffTag(r, kind, n, r.run_count === 1 ? "In this run" : `In ${n} of ${r.run_count} runs`));
      }
      row.append(name,
        node("td", count === r.run_count ? "passed" : count === 0 ? "failed" : "numeric", `${count}/${r.run_count}`));
      tbody.append(row);
    }
    table.append(tbody); outcomes.append(table);
    outcomes.append(node("h3", "settings-heading", "Runs"));
    const runs = node("table", "case-table");
    const runHead = node("thead"), runRow = node("tr");
    for (const title of ["Run", "Seed", "Parallel attempts", "Passed", "Cut off", "Output tokens", "Model calls"]) runRow.append(node("th", "", title));
    runHead.append(runRow); runs.append(runHead);
    const runBody = node("tbody");
    for (const run of r.runs) {
      const row = node("tr"), tokens = sum(run, "generated_tokens"), calls = sum(run, "model_calls");
      const over = run.cases.filter(c => overBudget(r, c)).length, tokenCell = node("td", "numeric", tokens == null ? "—" : fmt(tokens));
      if (over) tokenCell.append(budgetTag(r, over, `in ${over} of this run's ${run.cases.length} cases`));
      const kinds = Object.keys(cutoffs).map(kind => [kind, run.cases.filter(c => c.cutoff === kind).length]).filter(([, n]) => n);
      const cutCell = node("td", "numeric", `${run.cases.filter(c => c.cutoff).length}/${run.cases.length}`);
      if (kinds.length) cutCell.title = kinds.map(([kind, n]) => `${cutoffs[kind].label(r)}: ${n}`).join(" · ");
      row.append(node("td", "case-id", `${run.created_at.slice(0, 10)} · ${run.run_id}`), node("td", "numeric", run.seed ?? "—"),
        node("td", "numeric", run.deployment?.parallel_attempts ?? 1),
        node("td", "numeric", `${run.cases.filter(c => c.passed).length}/${run.cases.length}`),
        cutCell, tokenCell, node("td", "numeric", calls == null ? "—" : fmt(calls)));
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
    const maker = {artifact_files: "named in the model file", owner_supplied: "given by the publisher"}[r.model.quantized_by_source];
    const memory = [["Quantized by", r.model.quantized_by ? `${r.model.quantized_by} · ${maker}` : hosted(r) ? "Hosted API" : "Not recorded"],
      ["Model weights", gb(r.model.size_bytes)], ["Context limit", context(r)]];
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
  // Until series record their family, it is the model's name without a quantizer's mark. A Coder variant is
  // another model, so it keeps its own family: "...-GSQ-RCO-Coder" belongs to "...-Coder".
  const family = r => r.model.family || r.model.name.replace(/-(GSQ-RCO|Gyro-[A-Z]+)(?=-|$)/, "");
  const memberName = r => [quant(r), effort(r)].filter(Boolean).join(" ") || chartName(r);
  // These five hues pass every pairwise colour check on white (the dataviz validator with --pairs all). In this fixed
  // order they go to the families with more than one series, best family first; every other family is grey. Colours
  // are decided once from all results, so the filter below never repaints a family.
  const HUES = ["#2a78d6", "#1baf7a", "#eda100", "#008300", "#e34948"], GREY = "#8a8494";
  const families = (() => {
    const groups = new Map();
    for (const r of records) groups.set(family(r), [...(groups.get(family(r)) || []), r]);
    const top = members => Math.max(...members.map(r => r.score_percent));
    let slot = 0;
    return new Map([...groups].sort(([an, a], [bn, b]) => top(b) - top(a) || an.localeCompare(bn))
      .map(([name, members]) => [name, {name, members, color: members.length > 1 && slot < HUES.length ? HUES[slot++] : GREY}]));
  })();
  // A family's best series carries its name on the chart: most cases passed, then least memory.
  const anchors = new Set([...families.values()].map(f => [...f.members].sort((a, b) =>
    b.score_percent - a.score_percent || (required(a) ?? Infinity) - (required(b) ?? Infinity))[0]));
  const chosen = new Set();
  let tableOpen = false, sortBy = "cases", sortDown = true;
  const faded = r => chosen.size > 0 && !chosen.has(family(r));
  // The series no cheaper series beats: each passes more cases than everything that used less memory.
  function frontier(measured) {
    const best = [];
    for (const r of [...measured].sort((a, b) => required(a) - required(b) || b.score_percent - a.score_percent)) {
      if (!best.length || r.score_percent > best.at(-1).score_percent) best.push(r);
    }
    return best;
  }
  const svg = (tag, attributes) => {
    const e = document.createElementNS("http://www.w3.org/2000/svg", tag);
    for (const [key, value] of Object.entries(attributes)) e.setAttribute(key, value);
    return e;
  };
  const xOf = r => required(r) / 1e9 / memoryMax * 100, yOf = r => 100 - r.score_percent;
  // Lines in the plot's own coordinates: each maker's quants of a family in memory order, then the frontier's steps.
  function lines(measured, best) {
    const layer = svg("svg", {class: "plot-lines", viewBox: "0 0 100 100", preserveAspectRatio: "none", "aria-hidden": "true"});
    for (const f of families.values()) {
      const makers = new Map();
      for (const r of measured.filter(r => family(r) === f.name)) {
        makers.set(r.model.quantized_by, [...(makers.get(r.model.quantized_by) || []), r]);
      }
      for (const members of makers.values()) {
        if (members.length < 2) continue;
        members.sort((a, b) => required(a) - required(b));
        layer.append(svg("polyline", {class: "family-line" + (faded(members[0]) ? " faded" : ""), stroke: f.color,
          points: members.map(r => `${xOf(r)},${yOf(r)}`).join(" ")}));
      }
    }
    if (best.length > 1) {
      let d = `M${xOf(best[0])},${yOf(best[0])}`;
      for (const r of best.slice(1)) d += ` H${xOf(r)} V${yOf(r)}`;
      layer.append(svg("path", {class: "frontier", d: d + " H100"}));
    }
    return layer;
  }
  // The family buttons are the colour legend and the filter: pick families to bring them forward.
  function chips() {
    const row = node("div", "family-chips");
    row.setAttribute("role", "group");
    row.setAttribute("aria-label", "Families: choose to highlight");
    const all = [...families.values()];
    for (const f of [...all.filter(f => f.color !== GREY), ...all.filter(f => f.color === GREY)]) {
      const chip = node("button", "chip" + (chosen.has(f.name) ? " on" : ""));
      chip.setAttribute("aria-pressed", String(chosen.has(f.name)));
      const swatch = node("span", "chip-swatch");
      swatch.style.background = f.color;
      chip.append(swatch, node("span", "", f.name), node("span", "chip-count", f.members.length));
      chip.addEventListener("click", () => { chosen.has(f.name) ? chosen.delete(f.name) : chosen.add(f.name); render(); });
      row.append(chip);
    }
    if (chosen.size) {
      const clear = node("button", "chip clear", "Show all");
      clear.addEventListener("click", () => { chosen.clear(); render(); });
      row.append(clear);
    }
    return row;
  }
  function legend(shown, withFrontier) {
    const list = node("div", "scatter-legend");
    const item = (mark, text) => { const entry = node("span", "legend-item"); entry.append(node("span", `legend-mark ${mark}`), text); list.append(entry); };
    if (shown.some(r => r.harness.name === "pi")) item("circle", "Pi");
    if (shown.some(r => r.harness.name === "claude_code")) item("diamond", "Claude Code");
    if (shown.some(r => !r.complete)) item("circle hollow", "Provisional (fewer than 3 runs)");
    if ([...families.values()].some(f => f.members.length > 1)) item("ladder", "One maker's quants of a family");
    if (withFrontier) item("line", "Most cases passed for its memory");
    return list;
  }
  function point(r, x, best, number, nudge) {
    const lead = anchors.has(r), alone = families.get(family(r)).members.length === 1;
    const point = node("button", "scatter-point" + (r.harness.name === "claude_code" ? " diamond" : "") + (r.complete ? "" : " provisional") +
      (best ? " best" : "") + (lead ? " anchor" : "") + (faded(r) ? " faded" : "") + (selected === r.series_id ? " selected" : ""));
    point.id = `point-${r.series_id}`;
    point.dataset.number = number;
    point.style.left = `${x * 100}%`;
    point.style.bottom = `${r.score_percent}%`;
    point.style.setProperty("--dot", families.get(family(r)).color);
    if (nudge) point.style.setProperty("--nudge", `${nudge}px`);
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
    // A family's best series names the family; its other quants name only their quantization and thinking.
    const label = node("span", "point-label");
    if (alone) label.append(node("span", "model-name", chartName(r)));
    else if (lead) label.append(node("span", "model-name", family(r)), node("span", "point-meta", memberName(r)));
    else label.append(node("span", "member-name", memberName(r)));
    if (records.filter(other => chartName(other) === chartName(r)).length > 1) {
      label.append(node("span", "point-meta", `${harness(r)} · Series ${r.series_id.slice(0, 8)}`));
    }
    label.append(node("span", "label-number", number));
    point.append(node("span", "result-dot"), label);
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
  const columns = [
    ["model", "Model", r => chartName(r), r => chartName(r)],
    ["family", "Family", r => family(r), r => family(r)],
    ["maker", "Quantized by", r => r.model.quantized_by || "", r => r.model.quantized_by || (hosted(r) ? "API" : "—")],
    ["harness", "Harness", r => harness(r), r => harness(r)],
    ["cases", "Cases passed", r => r.score_percent, r => `${casesText(r)} (${scoreText(r)})`],
    ["memory", "Peak VRAM + RAM", r => required(r) ?? Infinity, r => required(r) != null ? gb(required(r)) : hosted(r) ? "API" : "Not measured"],
    ["runs", "Runs", r => r.run_count, r => runsText(r)],
  ];
  function table(shown) {
    const view = node("details", "table-view");
    view.open = tableOpen;
    view.addEventListener("toggle", () => { tableOpen = view.open; });
    view.append(node("summary", "", "Table view"));
    const grid = node("table", "case-table sortable"), head = node("thead"), row = node("tr");
    for (const [key, title] of columns) {
      const th = node("th");
      th.setAttribute("aria-sort", sortBy === key ? (sortDown ? "descending" : "ascending") : "none");
      const button = node("button", "sort", title + (sortBy === key ? (sortDown ? " ↓" : " ↑") : ""));
      button.addEventListener("click", () => { sortDown = sortBy === key ? !sortDown : key === "cases"; sortBy = key; render(); });
      th.append(button); row.append(th);
    }
    head.append(row); grid.append(head);
    const [, , value] = columns.find(([key]) => key === sortBy);
    const order = (a, b) => (value(a) < value(b) ? -1 : value(a) > value(b) ? 1 : 0) * (sortDown ? -1 : 1);
    const body = node("tbody");
    for (const r of [...shown].sort(order)) {
      const line = node("tr", faded(r) ? "faded" : "");
      for (const [key, , , text] of columns) line.append(node("td", ["model", "family", "maker"].includes(key) ? "case-id" : "numeric", text(r)));
      body.append(line);
    }
    grid.append(body); view.append(grid);
    return view;
  }
  function scatter(shown) {
    const figure = node("div", "scatter");
    const measured = shown.filter(r => required(r) != null), other = shown.filter(r => required(r) == null);
    const best = frontier(measured);
    figure.append(chips(), legend(shown, best.length > 1), node("div", "y-caption", "Cases passed (mean of runs)"));
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
    area.append(lines(measured, best));
    // Numbers follow the score order, so the key below reads from the top of the chart down.
    const number = r => shown.indexOf(r) + 1;
    // Series at the same score and nearly the same memory are spread sideways so none hides another.
    const spots = new Map();
    for (const r of measured) {
      const spot = `${Math.round(xOf(r))}:${r.score_percent}`;
      spots.set(spot, [...(spots.get(spot) || []), r]);
    }
    for (const r of measured) {
      const twins = spots.get(`${Math.round(xOf(r))}:${r.score_percent}`);
      area.append(point(r, required(r) / 1e9 / memoryMax, best.includes(r), number(r), (twins.indexOf(r) - (twins.length - 1) / 2) * 9));
    }
    body.append(area);
    if (other.length) {
      const strip = node("div", "api-strip");
      strip.append(node("span", "strip-title", other.every(hosted) ? "API" : "API or not measured"));
      // Spread across the strip: API models have no memory to place them by.
      other.forEach((r, i) => strip.append(point(r, (i + 1) / (other.length + 1), false, number(r), 0)));
      body.append(strip);
    }
    const tipBox = node("div", "chart-tip");
    tipBox.hidden = true;
    tipBox.setAttribute("role", "tooltip");
    figure.append(body, node("div", "axis-caption", "Peak VRAM + RAM in our runs"), node("ol", "point-key"), tipBox, table(shown));
    return figure;
  }
  const overlaps = (a, b) => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
  // Names go right, left, above or below their dot, whichever is free and inside the chart. The selected series and
  // each family's best are placed first, then the frontier, then the other quants. A family name with no room is
  // shown as its number, named in the key below; another quant with no room is left to the tooltip and the table.
  // Faded families give up their room.
  function placeLabels() {
    const numbered = [];
    for (const zone of document.querySelectorAll(".scatter-plot, .api-strip")) {
      const bounds = (zone.classList.contains("api-strip") ? zone.parentElement : zone).getBoundingClientRect();
      const points = [...zone.querySelectorAll(".scatter-point")];
      const rank = p => (p.classList.contains("faded") ? -9 : 0) + (p.classList.contains("selected") ? 4 : 0) +
        (p.classList.contains("anchor") ? 2 : 0) + (p.classList.contains("best") ? 1 : 0);
      points.sort((a, b) => rank(b) - rank(a));
      const taken = points.filter(p => !p.classList.contains("faded")).map(p => p.querySelector(".result-dot").getBoundingClientRect());
      const fit = (label, form) => {
        for (const side of ["right", "left", "above", "below"]) {
          label.className = `point-label${form} place-${side}`;
          const box = label.getBoundingClientRect();
          const inside = box.left >= bounds.left && box.right <= bounds.right && box.top >= bounds.top - 12 && box.bottom <= bounds.bottom + 12;
          if (inside && !taken.some(t => overlaps(t, box))) { taken.push(box); return true; }
        }
        return false;
      };
      for (const p of points) {
        const label = p.querySelector(".point-label");
        if (p.classList.contains("faded")) { label.className = "point-label unplaced"; continue; }
        if (fit(label, "")) continue;
        // A family keeps its number even where it overlaps: it is the family's only name on the chart.
        if (p.classList.contains("anchor")) {
          if (!fit(label, " as-number")) label.className = "point-label as-number place-right";
          numbered.push(p);
        } else label.className = "point-label unplaced";
      }
    }
    const key = document.querySelector(".point-key");
    if (!key) return;
    key.replaceChildren(...numbered.sort((a, b) => a.dataset.number - b.dataset.number).map(p => {
      const names = [...p.querySelector(".point-label").children].filter(e => !e.classList.contains("label-number"));
      const item = node("li", "", names.map(e => e.textContent).join(" · "));
      item.value = Number(p.dataset.number);
      return item;
    }));
    key.hidden = numbered.length === 0;
  }
  function render() {
    const shown = [...records].sort((a, b) => b.score_percent - a.score_percent || a.model.name.localeCompare(b.model.name) || b.run_count - a.run_count);
    $("chart").replaceChildren(scatter(shown));
    placeLabels();
    const active = shown.find(r => r.series_id === selected);
    if (active) $("chart").append(details(active)); else selected = null;
    $("result-status").textContent = `${records.length} run series in ${families.size} families` +
      (chosen.size ? ` · showing ${[...chosen].join(", ")}` : "");
  }
  window.addEventListener("resize", placeLabels);
  render();
})();
