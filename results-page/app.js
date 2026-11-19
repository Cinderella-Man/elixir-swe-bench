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
  // Dark or light: theme.js set it before the page was drawn, the button in the corner changes it and keeps the
  // choice. Every colour on the page is a variable of the theme, so nothing is drawn again.
  const toggle = $("theme-toggle");
  if (toggle) {
    const show = theme => {
      document.documentElement.dataset.theme = theme;
      toggle.textContent = theme === "dark" ? "\u2600\uFE0E Light" : "\u263E\uFE0E Dark";
      toggle.setAttribute("aria-label", theme === "dark" ? "Switch to light mode" : "Switch to dark mode");
    };
    show(document.documentElement.dataset.theme === "light" ? "light" : "dark");
    toggle.hidden = false;
    toggle.addEventListener("click", () => {
      const next = document.documentElement.dataset.theme === "light" ? "dark" : "light";
      try { localStorage.setItem("theme", next); } catch { /* no storage: the choice lasts for this visit */ }
      show(next);
    });
  }
  // An older controller's payload (schema 8 or 9) simply has no timing or machines; before 11, no patch verdicts;
  // before 12, no context sizes.
  if (!data || ![8, 9, 10, 11, 12].includes(data.schema_version) || !Array.isArray(data.releases) || data.releases.length === 0) {
    $("chart").append(node("p", "empty", "Results could not be loaded. Please reload."));
    return;
  }
  // One benchmark release is shown at a time: the primary one, or the one named in ?release=.
  const wanted = new URLSearchParams(location.search).get("release");
  const primary = data.releases.find(r => r.benchmark.id === data.primary) || data.releases.at(-1);
  const release = data.releases.find(r => wanted && (r.label === wanted || r.benchmark.id === wanted)) || primary;
  if (data.releases.length > 1) {
    const bar = $("releases");
    bar.append(node("span", "release-title", "Release"));
    for (const r of data.releases) {
      const link = node("a", "chip" + (r === release ? " on" : ""), r.label);
      link.href = r === primary ? location.pathname : `?release=${encodeURIComponent(r.label)}`;
      if (r === release) link.setAttribute("aria-current", "page");
      const role = r === primary ? "main results" : r.current ? "new runs" : "earlier";
      link.append(node("span", "chip-count", role));
      link.title = `${r.benchmark.id}: ${r.results.length} run series`;
      bar.append(link);
    }
    if (release.note) bar.append(node("span", "release-note", release.note));
  }
  // A context size narrows a score to the attempts that fit inside it (ADR 0022). A case then counts only if the
  // agent finished on its own, its whole attempt stayed inside that many tokens of context, and its patch passes.
  // One run at the largest window gives the score at every smaller size: nothing is run or graded again. A series
  // whose runs did not record each attempt's peak context has no score at a size.
  const sizes = release.context_sizes || [];
  const sized = release.results.filter(r => r.by_context);
  const tokensText = tokens => tokens.toLocaleString("en-US");
  const inside = (c, tokens) => c.passed && !c.cutoff && Number.isInteger(c.peak_context_tokens) && c.peak_context_tokens <= tokens;
  const records = release.results;
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
  // A release label the operator declared follows it ("Unsloth UD-Q6_K_L v3.1"): makers re-upload files under the same name.
  const quant = r => [r.model.quantized_by, r.model.quantization, r.model.source?.release_label].filter(Boolean).join(" ");
  const chartName = r => [r.model.name, quant(r), effort(r)].filter(Boolean).join(" ");
  // A release with token allowances gives each case one: the most its attempt may generate. A case then passes
  // only if the agent finished on its own inside it (ADR 0021). Series of earlier releases have none.
  const allowance = (r, id) => r.setup?.allowance?.tokens?.[id] ?? null;
  const allowed = r => Boolean(r.setup?.allowance);
  // The patch passed every check, but the attempt did not finish inside its allowance, so the case failed.
  const outside = c => c && c.passed === false && c.patch_passed === true;
  const outsideTag = (n, where) => {
    const tag = node("span", "budget-tag", "patch passed" + (n > 1 ? ` ×${n}` : ""));
    tag.title = `${where} the patch passed every check, but the agent did not finish inside the token allowance, so the case counts as failed.`;
    return tag;
  };
  // Claude Code cannot enforce the declared generation budget, so going over it is flagged, not failed (ADR 0010).
  // Under a token allowance, going over fails the case instead.
  const overBudget = (r, c) => !allowed(r) && Number.isInteger(r.settings.max_tokens) && Number.isInteger(c?.generated_tokens) &&
    c.generated_tokens > r.settings.max_tokens;
  const budgetTag = (r, n, of) => {
    const tag = node("span", "budget-tag", `over ${Math.round(r.settings.max_tokens / 1000)}k` + (n > 1 ? ` ×${n}` : ""));
    tag.title = `Generated more than the declared ${fmt(r.settings.max_tokens)}-token budget ${of}. It is flagged, not failed.`;
    return tag;
  };
  // A budget can end an attempt before the agent finishes. The patch at that point is graded, and may still pass
  // unless the series has token allowances: then an attempt that did not finish fails whatever its patch.
  const thousands = tokens => `${Math.floor(tokens / 1000)}k`;
  const cutoffs = {
    generation_budget: {
      label: r => allowed(r) ? "stopped at allowance" : `stopped at ${thousands(r.settings.max_tokens)}`,
      text: (r, id) => allowance(r, id) ? `the attempt used its whole allowance of ${fmt(allowance(r, id))} generated tokens` :
        allowed(r) ? "the attempt used its whole token allowance" :
        `the attempt used its whole ${fmt(r.settings.max_tokens)}-token generation budget`,
    },
    context_budget: {
      label: () => "context full",
      // Series without a per-reply cap let a reply use the room left in the window (ADR 0015).
      text: r => !r.settings.window_tokens ? "the conversation reached the model's context limit" :
        r.settings.response_tokens ?
          `the next prompt would not fit the ${fmt(r.settings.window_tokens)}-token context limit with ${fmt(r.settings.response_tokens)} tokens kept for the reply` :
          `the conversation filled the ${fmt(r.settings.window_tokens)}-token context limit`,
    },
    response_budget: {
      label: r => r.settings.response_tokens ? `reply cut at ${thousands(r.settings.response_tokens)}` : "reply cut off",
      text: r => `one reply reached the ${r.settings.response_tokens ? `${fmt(r.settings.response_tokens)}-token ` : ""}` +
        "response limit before the agent had finished, which ended the attempt",
    },
  };
  // Each case name links to its summary page in the repository, when the page was built with one.
  const repository = document.querySelector('nav[aria-label="Links"] a')?.getAttribute("href") || "";
  const caseName = id => {
    if (!repository.startsWith("https://github.com/")) return id;
    const link = node("a", "", id);
    link.href = `${repository}/blob/main/docs/cases/${encodeURIComponent(id)}.md`;
    link.target = "_blank"; link.rel = "noopener";
    link.title = "What this case asks for, its ticket and its files";
    return link;
  };
  const cutoffTag = (r, kind, n, where, id) => {
    const tag = node("span", "cutoff-tag", cutoffs[kind].label(r) + (n > 1 ? ` ×${n}` : ""));
    tag.title = `${where}, ${cutoffs[kind].text(r, id)}. ` +
      (allowed(r) ? "The case counts as failed; the patch at that point was still graded." : "The patch at that point was graded.");
    return tag;
  };
  const vram = r => r.resources ? (r.resources.peak_vram_bytes ?? r.resources.gpus.reduce((sum, gpu) => sum + gpu.used_bytes, 0)) : null;
  const context = r => r.settings.window_tokens ? `${fmt(r.settings.window_tokens)} context` : "API";
  const sum = (run, key) => run.cases.every(c => Number.isInteger(c[key])) ? run.cases.reduce((n, c) => n + c[key], 0) : null;
  // Case time and model speed, recorded only when a run worked on one case at a time (ADR 0019).
  // Series published before schema 9 carry none.
  const timed = r => r.runs.some(run => run.timing);
  // No-break spaces keep one duration on one line; several runs' durations may still wrap between them.
  const duration = ms => {
    if (ms < 60000) return `${Math.round(ms / 1000)} s`;
    const minutes = Math.round(ms / 60000);
    return minutes < 60 ? `${minutes} min` : `${Math.floor(minutes / 60)} h ${minutes % 60} min`;
  };
  const seconds = ms => `${fmt(Math.round(ms / 1000))} s`;
  const rate = (tokens, ms) => ms > 0 && tokens > 0 ? (tokens * 1000 / ms).toFixed(1) : null;
  const speedSource = {server_reported: "reported by the model server, network excluded",
    controller_timed: "timed by the benchmark, network included", mixed: "from mixed sources"};
  const speedText = s => !s ? "No model speed recorded" : [
    rate(s.generated_tokens, s.generation_ms) && `generation ${rate(s.generated_tokens, s.generation_ms)} tok/s`,
    rate(s.prompt_tokens, s.prompt_ms) && `prompt ${rate(s.prompt_tokens, s.prompt_ms)} tok/s`,
    s.draft_tokens ? `${Math.round(100 * s.draft_accepted / s.draft_tokens)}% of draft tokens accepted` : null,
    `${fmt(s.calls)} model call${s.calls === 1 ? "" : "s"}, ${speedSource[s.source]}`,
  ].filter(Boolean).join(" · ");
  const runName = run => `${run.created_at.slice(0, 10)} · ${run.run_id}`;
  const untimed = run => (run.deployment?.parallel_attempts ?? 1) > 1 ?
    `Not recorded: the run worked on ${run.deployment.parallel_attempts} cases at once` : "Not recorded";
  // A local run without a per-reply cap records none (ADR 0015); API runs leave it to the provider.
  // Local series cap neither a reply (ADR 0015) nor an attempt's generated tokens (ADR 0016).
  // Under token allowances the budget is each case's own, whatever the run declared.
  const settingValue = (r, key, value) =>
    key === "max_tokens" && allowed(r) ? "Each case's token allowance" :
    ["response_tokens", "max_tokens"].includes(key) && value == null && r.settings.window_tokens ? "No cap" : readable(value);
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
  // The model's files: where they came from, which upload that was and the bytes served (ADR 0018).
  const ggufLabels = {
    "general.version": "Version in file", "general.name": "Name in file", "general.basename": "Base name in file",
    "general.finetune": "Finetune", "general.size_label": "Size label", "general.organization": "Organization",
    "general.architecture": "Architecture", "general.license": "License", "general.url": "URL in file",
    "general.repo_url": "Repository in file", "general.source.url": "Original model",
    "general.source.huggingface.repository": "Original repository", "general.base_model.count": "Base models",
    "general.base_model.0.name": "Base model", "general.base_model.0.organization": "Base model organization",
    "general.base_model.0.version": "Base model version", "general.base_model.0.repo_url": "Base model repository",
    "general.file_type": "GGUF file type", "general.quantization_version": "Quantization version",
    "quantize.imatrix.file": "Imatrix file", "quantize.imatrix.dataset": "Imatrix dataset",
    "quantize.imatrix.entries_count": "Imatrix entries", "quantize.imatrix.chunks_count": "Imatrix chunks",
  };
  const short = commit => commit ? commit.slice(0, 7) : "";
  const day = date => date ? date.slice(0, 10) : "";
  function modelFiles(r) {
    const m = r.model, s = m.source, list = node("dl", "setting-list");
    const add = (label, value) => { list.append(node("dt", "", label)); const dd = node("dd"); dd.append(value); list.append(dd); };
    if (s) {
      const link = node("a", "", s.repository ? `${s.repository} · ${s.file}` : s.url);
      link.href = s.repository && s.commit ? `https://huggingface.co/${s.repository}/blob/${s.commit}/${s.path.split("/").map(encodeURIComponent).join("/")}` : s.url;
      link.target = "_blank"; link.rel = "noopener";
      add("Source", link);
      if (s.author) add("Hugging Face author", s.author);
      if (s.release_label) add("Release", s.release_label);
      if (s.revision) add("Declared revision", s.revision);
      if (s.commit) add(s.verification === "verified" ? "Uploaded in commit" : "Commit looked up", `${short(s.commit)}${s.commit_date ? ` · ${day(s.commit_date)}` : ""}`);
      const check = {verified: "The served files' sha256 match this upload", differs: "The served files' sha256 differ from this source",
        not_checked: "Not compared with the source"}[s.verification];
      add("Check", [check, s.verification_note].filter(Boolean).join(". "));
      add("Declared by", s.declared_by === "publisher" ? "the publisher" : "the operator, before the run");
    } else {
      add("Source", hosted(r) ? "Hosted API" : "Not declared");
    }
    for (const [i, file] of (m.weight_files || []).entries()) {
      const code = node("code", "sha", file.sha256);
      code.title = `${file.name} · ${fmt(file.size_bytes)} bytes`;
      add(m.weight_files.length > 1 ? `sha256 · shard ${i + 1}` : "sha256", code);
    }
    if (!m.weight_files && !hosted(r)) add("sha256", "Not recorded");
    for (const [key, value] of Object.entries(m.gguf || {})) add(ggufLabels[key] || key, typeof value === "number" ? fmt(value) : value);
    return list;
  }
  function definitionList(entries) {
    const list = node("dl", "setting-list");
    for (const [label, value] of entries) list.append(node("dt", "", label), node("dd", "", value));
    return list;
  }
  // Where a run's model was served (ADR 0020). Runs published before schema 10 name their GPUs, CPU and server only
  // through their memory record, without system RAM or server flags.
  const machineOf = run => run.machine || (run.resources ? {
    gpus: run.resources.gpus.map(g => ({name: g.name, memory_bytes: g.capacity_bytes})), cpu: run.resources.cpu,
    ram_bytes: null, server: run.resources.backend, server_build: run.resources.backend_version,
    kv_cache: run.resources.kv_cache, flags: null} : null);
  const gpusText = m => {
    if (!m.gpus.length) return "No GPU";
    const groups = new Map();
    for (const g of m.gpus) {
      const key = `${g.name.replace(/^NVIDIA (GeForce )?/, "")} ${Math.round(g.memory_bytes / 2**30)} GB`;
      groups.set(key, (groups.get(key) || 0) + 1);
    }
    return [...groups].map(([key, n]) => (n > 1 ? `${n}× ` : "") + key).join(" + ");
  };
  const cpuText = m => m.cpu && m.cpu.replace(/\((R|TM)\)/g, "").replace(/\s+\d+-Core Processor$/, "").trim();
  const machineText = m => [gpusText(m), cpuText(m), m.ram_bytes && `${Math.round(m.ram_bytes / 2**30)} GB RAM`].filter(Boolean).join(" · ");
  const serverText = m => {
    const name = {llama_cpp: "llama.cpp", strata: "Strata", maya: "Project Maya"}[m.server] || m.server;
    const build = !m.server_build ? name : m.server_build.startsWith(name) ? m.server_build : `${name} ${m.server_build}`;
    return [build, m.kv_cache && `KV cache ${m.kv_cache}`]
      .filter(Boolean).join(" · ");
  };
  const flagsText = m => m.flags == null ? null :
    Object.entries(m.flags).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => v === true ? k : `${k} ${v}`).join(" ");
  // Model speed summed over cases, as a run's timing sums it.
  const speedSum = cases => cases.map(c => c.timing?.model_speed).filter(Boolean).reduce((a, s) => !a ? {...s} : {
    source: a.source === s.source ? a.source : "mixed", calls: a.calls + s.calls,
    prompt_tokens: a.prompt_tokens + s.prompt_tokens, prompt_ms: a.prompt_ms + s.prompt_ms,
    generated_tokens: a.generated_tokens + s.generated_tokens, generation_ms: a.generation_ms + s.generation_ms,
    draft_tokens: (a.draft_tokens ?? 0) + (s.draft_tokens ?? 0) || null,
    draft_accepted: (a.draft_accepted ?? 0) + (s.draft_accepted ?? 0) || null}, null);
  const generation = s => (s && rate(s.generated_tokens, s.generation_ms)) || "—";
  const prompt = s => (s && rate(s.prompt_tokens, s.prompt_ms)) || "—";
  // Speed on the speed cases (ADR 0020): every full run timed on all of them, and every speed run. All rows cover the
  // same cases, so they compare across quantizations and machines; how fast a model generates depends on how long its
  // conversations get, so a run's total over other cases would not.
  const speedCases = release.speed_cases || [];
  let speedRowsCache = null;
  function allSpeedRows() {
    if (speedRowsCache) return speedRowsCache;
    const rows = [];
    const add = (r, run, cases, kind) => {
      const machine = machineOf(run);
      rows.push({r, run, kind, cases, machine, speed: speedSum(cases), family: family(r),
        time: cases.reduce((n, c) => n + c.timing.time_ms, 0), passed: cases.filter(c => c.passed).length,
        hardware: machine ? gpusText(machine) : "Not recorded"});
    };
    if (speedCases.length) {
      for (const r of records) for (const run of r.runs) {
        const picked = speedCases.map(id => run.cases.find(c => c.id === id));
        if (picked.every(c => c?.timing)) add(r, run, picked, "run");
      }
      for (const s of release.speed_runs || []) add(s, s.run, s.run.cases, "speed");
    }
    const tokens = row => row.speed ? row.speed.generated_tokens / row.speed.generation_ms : 0;
    return speedRowsCache = rows.sort((a, b) => tokens(b) - tokens(a));
  }
  const speedNote = () => `Tokens per second on the same ${speedCases.length} speed cases (${speedCases.join(", ")}), so every row ` +
    "covers the same work: a full run counts its times on these cases, and a speed run runs only these, one at a time. " +
    "llama.cpp and Project Maya report their own timings, network excluded; Strata is timed by the benchmark, network included. " +
    "Pass counts show whether a setup still solves the cases; speed is never scored. Hover a server for its flags.";
  function speedTable(rows, {showModel} = {}) {
    const table = node("table", "case-table speed-table"), head = node("thead"), headRow = node("tr");
    for (const title of [...(showModel ? ["Model"] : []), "Quantization", "Machine", "Server", "Generation tok/s", "Prompt tok/s", "Passed", "Run"])
      headRow.append(node("th", "", title));
    head.append(headRow); table.append(head);
    const body = node("tbody");
    for (const row of rows) {
      const tr = node("tr");
      if (showModel) tr.append(node("td", "case-id", row.r.model.name));
      tr.append(node("td", "case-id", memberName(row.r)));
      tr.append(node("td", "case-id", row.machine ? machineText(row.machine) : "Not recorded"));
      const server = node("td", "case-id", row.machine ? serverText(row.machine) : "—");
      if (row.machine) server.title = flagsText(row.machine) || "No server flags recorded";
      const gen = node("td", "numeric", generation(row.speed)), pp = node("td", "numeric", prompt(row.speed));
      gen.title = pp.title = `${speedText(row.speed)} · ${duration(row.time)} over the speed cases`;
      const run = node("td", "case-id", `${row.kind === "speed" ? "Speed run" : "Full run"} · ${row.run.created_at.slice(0, 10)}`);
      run.title = row.run.run_id;
      tr.append(server, gen, pp, node("td", "numeric", `${row.passed}/${row.cases.length}`), run);
      body.append(tr);
    }
    table.append(body);
    // Wide on a phone: the table scrolls in its own box rather than the page.
    const scroll = node("div", "table-scroll");
    scroll.append(table);
    return scroll;
  }
  // The speed of every model on every machine, filtered by machine and by the family buttons.
  let speedOpen = false, speedMachine = "";
  function speedView() {
    const rows = allSpeedRows();
    if (!rows.length) return null;
    const view = node("details", "table-view");
    view.open = speedOpen;
    view.addEventListener("toggle", () => { speedOpen = view.open; });
    view.append(node("summary", "", `Speed by machine · ${rows.length} measured setups`));
    const filter = node("label", "speed-filter", "GPUs ");
    const select = node("select");
    select.append(new Option("All machines", ""), ...[...new Set(rows.map(row => row.hardware))].sort().map(h => new Option(h, h)));
    select.value = speedMachine;
    select.addEventListener("change", () => { speedMachine = select.value; render(); });
    filter.append(select);
    const shown = rows.filter(row => (!speedMachine || row.hardware === speedMachine) && (!chosen.size || chosen.has(row.family)));
    view.append(filter, speedTable(shown, {showModel: true}), node("p", "detail-note", speedNote()));
    return view;
  }
  // One block per run: its outcomes, the machine and server its model ran on, and how fast, together.
  function runBlocks(r) {
    const blocks = node("div", "run-blocks");
    for (const [i, run] of r.runs.entries()) {
      const block = node("div", "run-block"), list = node("dl", "setting-list");
      const add = (label, value, className) => {
        list.append(node("dt", "", label));
        const dd = node("dd", className || ""); dd.append(value); list.append(dd);
      };
      const tokens = sum(run, "generated_tokens"), calls = sum(run, "model_calls");
      const over = run.cases.filter(c => overBudget(r, c)).length, cut = run.cases.filter(c => c.cutoff);
      const late = run.cases.filter(outside).length;
      block.append(node("div", "run-block-head", `Run ${i + 1} · ${runName(run)}` + (run.seed != null ? ` · seed ${run.seed}` : "")));
      const outcome = node("span", "", `${run.cases.filter(c => c.passed).length}/${run.cases.length} passed · ${cut.length} cut off · ` +
        (allowed(r) ? `${late} with a passing patch outside the allowance · ` : "") +
        `${tokens == null ? "—" : fmt(tokens)} output tokens · ${calls == null ? "—" : fmt(calls)} model calls`);
      if (cut.length) outcome.title = Object.keys(cutoffs).map(kind => [kind, cut.filter(c => c.cutoff === kind).length])
        .filter(([, n]) => n).map(([kind, n]) => `${cutoffs[kind].label(r)}: ${n}`).join(" · ");
      if (over) outcome.append(budgetTag(r, over, `in ${over} of this run's ${run.cases.length} cases`));
      add("Outcome", outcome);
      const m = machineOf(run);
      add("Machine", m ? machineText(m) : hosted(r) ? "Hosted API" : "Not recorded");
      if (m) {
        add("Server", serverText(m));
        // Each flag keeps its value on one line; lines break between flags.
        const code = node("code", "flags");
        if (m.flags && Object.keys(m.flags).length)
          for (const [i, [k, v]] of Object.entries(m.flags).sort(([a], [b]) => a.localeCompare(b)).entries())
            code.append(...(i ? [" "] : []), node("span", "flag", v === true ? k : `${k} ${v}`));
        else code.textContent = m.flags ? "None of the listed speed flags" : m.server === "strata" ? "Strata reports none" : "Not recorded";
        add("Server flags", code);
      }
      const t = run.timing, s = t?.model_speed;
      add("Speed", s ? speedText(s) : t ? "No model speed recorded" : untimed(run));
      if (t) add("Case time", `${duration(t.time_ms)} over ${t.measured_cases}/${run.cases.length} cases, one at a time`);
      const picked = speedCases.map(id => run.cases.find(c => c.id === id));
      if (speedCases.length && picked.every(c => c?.timing)) {
        const speed = speedSum(picked);
        add("Speed cases", `generation ${generation(speed)} tok/s · prompt ${prompt(speed)} tok/s on the ${speedCases.length} speed cases`);
      }
      if (run.resources?.peak_combined_bytes) add("Memory peak", `${gb(run.resources.peak_combined_bytes)} VRAM + RAM`);
      block.append(list); blocks.append(block);
    }
    return blocks;
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
    if (allowed(r)) {
      const rule = r.setup.allowance, late = attempts.filter(outside).length;
      outcomes.append(node("p", "detail-note", `Each case has a token allowance: ${rule.multiple} times the median that ${rule.validator} generated on it, ` +
        `and at least ${fmt(rule.minimum_tokens)}. A case passes only if the agent finishes on its own inside it. ` +
        `${late} of ${attempts.length} attempts had a passing patch but did not, and count as failed.`));
    } else if (cut) outcomes.append(node("p", "detail-note", `${cut} of ${attempts.length} attempts ran out of a budget before the agent had finished. ` +
      "Their patches at that point were graded; the tags say which limit."));
    const table = node("table", "case-table");
    const head = node("thead"), hr = node("tr");
    // Each attempt's peak context, where the series recorded it: the largest prompt and reply any model call held.
    const peaks = Boolean(r.by_context);
    for (const title of ["Case", "Runs passed", ...(peaks ? ["Peak context"] : []),
      ...(allowed(r) ? ["Output tokens", "Allowance"] : []),
      ...(timed(r) ? ["Time", "Generation tok/s"] : [])]) hr.append(node("th", "", title));
    head.append(hr); table.append(head);
    const tbody = node("tbody");
    for (const c of r.runs[0].cases) {
      const row = node("tr"), count = r.case_passes[c.id], name = node("td", "case-id");
      name.append(caseName(c.id));
      const tries = r.runs.map(run => run.cases.find(other => other.id === c.id));
      const over = tries.filter(t => overBudget(r, t)).length;
      if (over) name.append(budgetTag(r, over, `in ${over} of ${r.run_count} runs`));
      for (const kind of Object.keys(cutoffs)) {
        const n = tries.filter(t => t.cutoff === kind).length;
        if (n) name.append(cutoffTag(r, kind, n, r.run_count === 1 ? "In this run" : `In ${n} of ${r.run_count} runs`, c.id));
      }
      const late = tries.filter(outside).length;
      if (late) name.append(outsideTag(late, r.run_count === 1 ? "In this run" : `In ${late} of ${r.run_count} runs`));
      row.append(name,
        node("td", count === r.run_count ? "passed" : count === 0 ? "failed" : "numeric", `${count}/${r.run_count}`));
      if (peaks) {
        // One value per run, in run order.
        const peak = node("td", "numeric", tries.map(t => thousands(t.peak_context_tokens)).join(" · "));
        peak.title = r.runs.map((run, i) => `${runName(run)}: ${fmt(tries[i].peak_context_tokens)} tokens` +
          (tries[i].cutoff ? ", cut off before the agent finished" : tries[i].passed ? "" : ", patch did not pass")).join("\n");
        row.append(peak);
      }
      if (allowed(r)) {
        // One value per run, in run order, beside what the case allows.
        const used = node("td", "numeric", tries.map(t => Number.isInteger(t.generated_tokens) ? thousands(t.generated_tokens) : "—").join(" · "));
        used.title = r.runs.map((run, i) => `${runName(run)}: ` +
          (Number.isInteger(tries[i].generated_tokens) ? `${fmt(tries[i].generated_tokens)} output tokens` : "Not recorded")).join("\n");
        const limit = node("td", "numeric", allowance(r, c.id) == null ? "—" : thousands(allowance(r, c.id)));
        if (allowance(r, c.id) != null) limit.title = `${fmt(allowance(r, c.id))} generated tokens`;
        row.append(used, limit);
      }
      if (timed(r)) {
        // One value per run, in run order.
        const time = node("td", "numeric", tries.map(t => t.timing ? duration(t.timing.time_ms) : "—").join(" · "));
        const speed = node("td", "numeric", tries.map(t => {
          const s = t.timing?.model_speed;
          return (s && rate(s.generated_tokens, s.generation_ms)) || "—";
        }).join(" · "));
        time.title = speed.title = r.runs.map((run, i) => `${runName(run)}: ` + (tries[i].timing ?
          `${seconds(tries[i].timing.time_ms)} · ${speedText(tries[i].timing.model_speed)}` : untimed(run))).join("\n");
        row.append(time, speed);
      }
      tbody.append(row);
    }
    table.append(tbody); outcomes.append(table);
    outcomes.append(node("h3", "settings-heading", "Runs"), runBlocks(r));
    // Only this series' own setup: its runs and the speed runs of the same files, quantization and settings, on
    // whatever machines measured them. Other quantizations of the model are compared under Speed by machine.
    const ownRows = allSpeedRows().filter(row => row.r.series_id === r.series_id);
    if (ownRows.length > 1) outcomes.append(node("h3", "settings-heading", "Speed of this setup on the speed cases"),
      speedTable(ownRows), node("p", "detail-note", speedNote() + " Other quantizations and settings of this model are under Speed by machine."));
    if (!r.complete) {
      outcomes.append(node("h3", "settings-heading", "Required setup for the missing runs"));
      outcomes.append(definitionList(Object.entries(r.setup).map(([key, value]) =>
        [readable(key), typeof value === "object" && value !== null ? JSON.stringify(value) : readable(value)])));
    }
    const conditions = node("div");
    conditions.append(node("h3", "", "Model files"), modelFiles(r));
    conditions.append(node("h3", "settings-heading", "Memory & deployment"));
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
      Object.entries(r.settings).map(([key, value]) => [settings[key] || readable(key), settingValue(r, key, value)])));
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
  // Five family colours, each theme's own (styles.css): on white all five pass every pairwise colour check (the
  // dataviz validator with --pairs all), on the dark background the first four do. In this fixed order they go to
  // the families with more than one series, best family first; every other family is grey. The chart of cases
  // against context colours each series instead (lineStyles). Colours are decided once from all results, so the
  // filter below never repaints a family.
  const HUES = [1, 2, 3, 4, 5].map(n => `var(--f${n})`), GREY = "var(--grey)";
  const grouped = list => {
    const groups = new Map();
    for (const r of list) groups.set(family(r), [...(groups.get(family(r)) || []), r]);
    const top = members => Math.max(...members.map(r => r.score_percent));
    return [...groups].sort(([an, a], [bn, b]) => top(b) - top(a) || an.localeCompare(bn));
  };
  const familyColors = (() => {
    let slot = 0;
    return new Map(grouped(release.results).map(([name, members]) =>
      [name, members.length > 1 && slot < HUES.length ? HUES[slot++] : GREY]));
  })();
  const families = new Map(grouped(records).map(([name, members]) => [name, {name, members, color: familyColors.get(name)}]));
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
    // A theme colour is a variable, which a style can hold and an attribute cannot.
    for (const [key, value] of Object.entries(attributes)) {
      if ((key === "stroke" || key === "fill") && String(value).startsWith("var(")) e.style[key] = value;
      else e.setAttribute(key, value);
    }
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
  // `view` overrides what the point shows (its score, interval and a tooltip line) where one series has two
  // points; `kind` then keeps their ids apart.
  function point(r, x, best, number, nudge, view = null, kind = "") {
    const v = view ? {...r, ...view} : r;
    const lead = anchors.has(r), alone = families.get(family(r)).members.length === 1;
    const point = node("button", "scatter-point" + (r.harness.name === "claude_code" ? " diamond" : "") + (r.complete ? "" : " provisional") +
      (best ? " best" : "") + (lead ? " anchor" : "") + (faded(r) ? " faded" : "") + (selected === r.series_id ? " selected" : ""));
    point.id = `point-${r.series_id}${kind}`;
    point.dataset.number = number;
    point.style.left = `${x * 100}%`;
    point.style.bottom = `${v.score_percent}%`;
    point.style.setProperty("--dot", families.get(family(r)).color);
    if (nudge) point.style.setProperty("--nudge", `${nudge}px`);
    point.setAttribute("aria-label", `${chartName(r)}, ${harness(r)}, ${casesText(v)} (${scoreText(v)})` +
      (v.tip_note ? ` ${v.tip_note}` : "") + `, ${memoryText(r)}, ${runsText(r)}. Show details`);
    point.setAttribute("aria-expanded", String(selected === r.series_id));
    if (selected === r.series_id) point.setAttribute("aria-controls", "run-detail");
    if (v.interval_percent != null) {
      const low = Math.max(0, v.score_percent - v.interval_percent), high = Math.min(100, v.score_percent + v.interval_percent);
      const bar = node("span", "interval");
      // One score point is 1cqh of the plot; the bar is measured from the dot's centre.
      bar.style.bottom = `calc(50% + ${low - v.score_percent}cqh)`;
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
    for (const show of ["pointerenter", "focus"]) point.addEventListener(show, () => tip(v, point));
    for (const hide of ["pointerleave", "blur"]) point.addEventListener(hide, () => tip(null));
    return point;
  }
  // One tooltip for the chart: the result first, then what it is.
  function tip(r, point) {
    const box = document.querySelector(".chart-tip");
    if (!box) return;
    if (!r) { box.hidden = true; return; }
    box.replaceChildren(node("strong", "", casesText(r) + (r.interval_percent == null ? "" : ` ± ${fmt(Math.round(r.interval_percent * r.total / 10) / 10)}`) +
        (r.tip_note ? ` ${r.tip_note}` : "")),
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
    // Where the release recorded peak context: the cases solved with the whole attempt inside each size, as a count.
    ...(sized.length ? sizes.map(tokens => [`inside-${tokens}`, `In ${tokensText(tokens)}`,
      r => r.by_context ? r.by_context[tokens].score_percent : -1,
      r => r.by_context ? fmt(Math.round(r.by_context[tokens].score_percent * r.total / 10) / 10) : "—",
      `Cases solved with the whole attempt inside ${tokensText(tokens)} tokens of context`]) : []),
    ["memory", "Peak VRAM + RAM", r => required(r) ?? Infinity, r => required(r) != null ? gb(required(r)) : hosted(r) ? "API" : "Not measured"],
    ["runs", "Runs", r => r.run_count, r => runsText(r)],
  ];
  function table(shown) {
    const view = node("details", "table-view");
    view.open = tableOpen;
    view.addEventListener("toggle", () => { tableOpen = view.open; });
    view.append(node("summary", "", "Table view"));
    const grid = node("table", "case-table sortable"), head = node("thead"), row = node("tr");
    for (const [key, title, , , hint] of columns) {
      const th = node("th");
      if (hint) th.title = hint;
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
    for (const value of ticks(release.benchmark.case_count)) {
      const line = node("div", "grid-row");
      line.style.bottom = `${value / release.benchmark.case_count * 100}%`;
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
    const speed = speedView();
    if (speed) figure.append(speed);
    return figure;
  }
  const largestSize = sizes.at(-1);
  // A line is read every 16,384 tokens, from 32,768 up: each of the five context sizes is one of those readings, so
  // a dot there shows the number the table gives.
  const stepSize = largestSize / 16, firstSize = stepSize * 2;
  const readings = Array.from({length: (largestSize - firstSize) / stepSize + 1}, (_, i) => firstSize + i * stepSize);
  const across = tokens => (tokens - firstSize) / (largestSize - firstSize) * 100;
  // Cases a series solves with the whole attempt inside `tokens` of context, as the mean of its runs.
  const solvedInside = (r, tokens) => {
    let solved = 0;
    for (const run of r.runs) for (const c of run.cases) if (inside(c, tokens)) solved += 1;
    return solved / r.runs.length;
  };
  const countText = cases => fmt(Math.round(cases * 10) / 10);
  // Each line has its own colour and its own dashes. Eight colours cannot all be told from each other at a glance,
  // so the dashes are dealt in fours: the colours that are near each other (blue and violet, aqua and green, orange
  // and red) never share a stroke. Colour and stroke follow the series, in the order the series were first run, so
  // neither changes when scores do or when a series is added. A ninth series and later are grey.
  const DASHES = ["", "7 4", "2 4", "11 4 2 4"], LINE_HUES = 8;
  const lineStyles = (() => {
    const first = r => r.runs.map(run => run.created_at).sort()[0];
    const ordered = release.results.filter(r => r.by_context)
      .sort((a, b) => first(a).localeCompare(first(b)) || a.series_id.localeCompare(b.series_id));
    return new Map(ordered.map((r, i) => [r.series_id, {color: i < LINE_HUES ? `var(--s${i + 1})` : GREY, dash: DASHES[i % DASHES.length]}]));
  })();
  const lineKey = style => {
    const key = svg("svg", {class: "line-key", viewBox: "0 0 30 12", "aria-hidden": "true"});
    key.append(svg("line", {x1: 1, y1: 6, x2: 29, y2: 6, stroke: style.color, "stroke-width": 2, "stroke-dasharray": style.dash}),
      svg("circle", {cx: 15, cy: 6, r: 3.5, fill: style.color}));
    return key;
  };
  // Lights one series up and dims the rest, wherever the pointer met it: its line, its dots or its name.
  function focusSeries(id) {
    const figure = document.querySelector(".scatter.curves");
    if (!figure) return;
    figure.classList.toggle("has-focus", Boolean(id));
    for (const mark of figure.querySelectorAll("[data-series]")) mark.classList.toggle("focus", mark.dataset.series === id);
  }
  // A line's name in the legend: its key, the model, what tells this series from the model's others, and what it
  // solves inside the largest size.
  function legendEntry(r) {
    const style = lineStyles.get(r.series_id), end = r.by_context?.[largestSize], entry = node("li");
    const button = node("button", "legend-series" + (selected === r.series_id ? " selected" : ""));
    button.id = `legend-${r.series_id}`;
    button.dataset.series = r.series_id;
    const alone = families.get(family(r)).members.length === 1 && hosted(r);
    if (style) button.append(lineKey(style));
    button.append(node("span", "series-name", alone ? chartName(r) : family(r)));
    if (!alone) button.append(node("span", "series-meta", memberName(r)));
    if (records.filter(other => chartName(other) === chartName(r)).length > 1) button.append(node("span", "series-meta", `${harness(r)} · Series ${r.series_id.slice(0, 8)}`));
    button.append(node("span", "series-value", end ? countText(end.score_percent * r.total / 100) : "no context recorded"));
    button.title = end ? `${countText(end.score_percent * r.total / 100)} of ${r.total} cases solved inside ${tokensText(largestSize)} tokens of context` : "No line: its runs did not record context";
    button.setAttribute("aria-label", `${chartName(r)}, ${harness(r)}, ` + (end ? `${countText(end.score_percent * r.total / 100)} of ${r.total} cases inside ` +
      `${tokensText(largestSize)} tokens of context` : "no context recorded") + `, ${runsText(r)}. Show details`);
    button.setAttribute("aria-expanded", String(selected === r.series_id));
    if (selected === r.series_id) button.setAttribute("aria-controls", "run-detail");
    button.addEventListener("click", () => {
      selected = selected === r.series_id ? null : r.series_id;
      render();
      document.getElementById(button.id)?.focus();
    });
    for (const show of ["pointerenter", "focus"]) button.addEventListener(show, () => focusSeries(r.series_id));
    for (const hide of ["pointerleave", "blur"]) button.addEventListener(hide, () => focusSeries(null));
    entry.append(button);
    return entry;
  }
  // The chart of a release whose series recorded their attempts' peak context (ADR 0022): cases solved against the
  // context the whole attempt must fit in. Each series is one line with a dot at every reading, averaged over its
  // runs. A legend above the plot names the lines, most cases first; pointing at the plot reads every series at the
  // nearest reading. A series without recorded peaks has no line, only its name.
  function curves(shown) {
    const figure = node("div", "scatter curves");
    const endOf = r => r.by_context[largestSize].score_percent;
    const lined = shown.filter(r => r.by_context).sort((a, b) => endOf(b) - endOf(a) || chartName(a).localeCompare(chartName(b)));
    const names = node("ol", "series-legend");
    names.setAttribute("aria-label", `Run series, by cases solved inside ${tokensText(largestSize)} tokens of context`);
    for (const r of [...lined, ...shown.filter(r => !r.by_context)]) names.append(legendEntry(r));
    const list = node("div", "scatter-legend");
    const item = (mark, text) => { const entry = node("span", "legend-item"); entry.append(node("span", `legend-mark ${mark}`), text); list.append(entry); };
    if (shown.some(r => r.harness.name === "pi")) item("circle", "Pi");
    if (shown.some(r => r.harness.name === "claude_code")) item("diamond", "Claude Code");
    if (shown.some(r => !r.complete)) item("circle hollow", "Provisional (fewer than 3 runs)");
    figure.append(names, list, node("div", "y-caption", "Cases solved (mean of runs)"));
    const body = node("div", "scatter-body"), area = node("div", "scatter-plot");
    for (const value of ticks(release.benchmark.case_count)) {
      const line = node("div", "grid-row");
      line.style.bottom = `${value / release.benchmark.case_count * 100}%`;
      line.append(node("span", "y-tick", value));
      area.append(line);
    }
    for (const tokens of [firstSize, ...sizes]) {
      const line = node("div", "grid-col");
      line.style.left = `${across(tokens)}%`;
      line.append(node("span", "x-tick" + (tokens === largestSize ? " end" : tokens === firstSize ? " start" : ""), tokensText(tokens)));
      area.append(line);
    }
    const layer = svg("svg", {class: "plot-lines", viewBox: "0 0 100 100", preserveAspectRatio: "none", "aria-hidden": "true"});
    const heights = new Map(lined.map(r => [r.series_id, readings.map(tokens => solvedInside(r, tokens) / r.total * 100)]));
    for (const r of lined) {
      const style = lineStyles.get(r.series_id), state = (faded(r) ? " faded" : "") + (selected === r.series_id ? " selected" : "");
      const path = svg("path", {class: "context-line" + state, stroke: style.color, "stroke-dasharray": style.dash,
        d: heights.get(r.series_id).map((height, i) => `${i ? "L" : "M"}${across(readings[i])},${100 - height}`).join(" ")});
      path.dataset.series = r.series_id;
      layer.append(path);
    }
    const hair = node("div", "crosshair");
    hair.hidden = true;
    area.append(layer, hair);
    for (const r of lined) {
      const style = lineStyles.get(r.series_id);
      // The last reading is the series' end: its dot there opens its details and shows the harness and whether it is provisional.
      heights.get(r.series_id).slice(0, -1).forEach((height, i) => {
        const dot = node("span", "sample-dot" + (faded(r) ? " faded" : ""));
        dot.dataset.series = r.series_id;
        dot.style.left = `${across(readings[i])}%`;
        dot.style.bottom = `${height}%`;
        dot.style.setProperty("--dot", style.color);
        area.append(dot);
      });
      const end = r.by_context[largestSize];
      const last = point(r, 1, false, 0, 0, {score_percent: end.score_percent, interval_percent: end.interval_percent,
        tip_note: `inside ${tokensText(largestSize)} tokens of context`}, "-end");
      last.querySelector(".point-label").remove();
      last.dataset.series = r.series_id;
      last.style.setProperty("--dot", style.color);
      for (const show of ["pointerenter", "focus"]) last.addEventListener(show, () => focusSeries(r.series_id));
      for (const hide of ["pointerleave", "blur"]) last.addEventListener(hide, () => focusSeries(null));
      area.append(last);
    }
    const tipBox = node("div", "chart-tip");
    tipBox.hidden = true;
    tipBox.setAttribute("role", "tooltip");
    // One readout for the whole plot: every series at the reading nearest the pointer, most cases first. The line
    // nearest the pointer is lit, so a line can be asked its name.
    const readout = event => {
      if (event.target.closest(".scatter-point")) return;
      const box = area.getBoundingClientRect();
      const at = Math.min(Math.max(Math.round((event.clientX - box.left) / box.width * (readings.length - 1)), 0), readings.length - 1);
      const rows = lined.filter(r => !faded(r)).map(r => ({r, height: heights.get(r.series_id)[at]}))
        .sort((a, b) => b.height - a.height || endOf(b.r) - endOf(a.r));
      if (!rows.length) return;
      const y = row => box.bottom - row.height / 100 * box.height;
      const near = rows.reduce((best, row) => Math.abs(y(row) - event.clientY) < Math.abs(y(best) - event.clientY) ? row : best);
      const lit = Math.abs(y(near) - event.clientY) <= 14 ? near.r.series_id : null;
      focusSeries(lit);
      hair.hidden = false;
      hair.style.left = `${across(readings[at])}%`;
      const entries = rows.map(({r, height}) => {
        const entry = node("span", "tip-row" + (r.series_id === lit ? " lit" : ""));
        entry.append(lineKey(lineStyles.get(r.series_id)), node("strong", "", countText(height * r.total / 100)), node("span", "", chartName(r)));
        return entry;
      });
      tipBox.replaceChildren(node("span", "tip-muted", `Inside ${tokensText(readings[at])} tokens of context`), ...entries);
      tipBox.hidden = false;
      const frame = figure.getBoundingClientRect(), size = tipBox.getBoundingClientRect();
      const right = event.clientX - frame.left + 16;
      tipBox.style.left = `${right + size.width <= frame.width ? right : Math.max(event.clientX - frame.left - 16 - size.width, 0)}px`;
      tipBox.style.top = `${Math.min(Math.max(event.clientY - frame.top - size.height / 2, 0), frame.height - size.height)}px`;
    };
    area.addEventListener("pointermove", readout);
    area.addEventListener("pointerleave", () => { hair.hidden = true; tipBox.hidden = true; focusSeries(null); });
    body.append(area);
    figure.append(body, node("div", "axis-caption", "Context the whole attempt must fit in (tokens)"), tipBox, table(shown));
    const speed = speedView();
    if (speed) figure.append(speed);
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
      // The ends of the context lines carry no name: theirs are beside the plot.
      const points = [...zone.querySelectorAll(".scatter-point")].filter(p => p.querySelector(".point-label"));
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
    $("chart").replaceChildren(sized.length ? curves(shown) : scatter(shown));
    if (sized.length) {
      $("chart").setAttribute("aria-label", "Cases solved against the context the whole attempt must fit in, by model");
      $("chart-help").textContent = "One line per run series: each dot is how many cases the model solves when the whole attempt must fit in " +
        "that much context (the mean of its runs), read every 16,384 tokens. The number after a name is what it solves inside " +
        `${tokensText(largestSize)}. Point at the chart to read every model at one context size. Models reached through an API were not held ` +
        "to a context window: what each solved with no limit is in the table view. Hollow dots are provisional. Compare models within one " +
        "harness. Click a name for details.";
    }
    placeLabels();
    const active = shown.find(r => r.series_id === selected);
    if (active) $("chart").append(details(active)); else selected = null;
    $("result-status").textContent = `${records.length} run series in ${families.size} families` +
      (chosen.size ? ` · showing ${[...chosen].join(", ")}` : "");
  }
  window.addEventListener("resize", placeLabels);
  render();
})();
