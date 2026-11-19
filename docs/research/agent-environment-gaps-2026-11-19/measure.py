"""Count what the case containers lacked that the agents reached for, from every saved attempt log.

Usage (from the repository root):
    python3 docs/research/agent-environment-gaps-2026-11-19/measure.py verification counts.json

Reads the Pi runs in verification/v6-archive-2026-11-19/runs/run-*/<case>/logs/pi-events.jsonl (they were in
verification/runs/ until v6 was started again that day) and the Claude Code transcripts in the opus-validation-*,
sonnet-series-* and haiku-series-* folders, and image-inventory.json next to this file (which programs each case
image had then, written from probe.sh output). Later runs are left out: their containers have the programs.

Rules:
- A bash call "runs" a program when shparse.py finds it where the shell runs a command. Heredoc bodies and quoted text
  are not commands. A program is "missing" when image-inventory.json says that case's image lacks it.
- A Python call is "visible" when its output says python was not found, "hidden" when the call sent the error to
  /dev/null. It "writes a file" when its script calls write_text/.write/open(..., 'w').
- "Recovered" (Pi runs): the next successful change to a file the failed script named, by any other means.
- An edit, read or write call failed when the tool reported an error.
- Environment-caused test failures are recognised by the test module names in SIGNATURES, each reproduced on the
  untouched case image with baseline.sh.
"""
import collections, glob, json, os, re, statistics, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from shparse import programs, strip_heredocs, BUILTINS  # noqa: E402

ROOT, OUT = sys.argv[1], sys.argv[2]
INVENTORY = json.load(open(os.path.join(HERE, "image-inventory.json")))["programs"]
PY = re.compile(r"^python[23]?(\.\d+)?$")
PY_NOT_FOUND = re.compile(r"python[23]?(\.\d+)?: (command )?not found|['‘]python[23]?['’]: No such file")
SIGNATURES = {
    "accent-pr-183": r"AccentTest\.WebappController|AccentTest\.GraphQL\.Resolvers\.Language\)",
    "beacon-pr-687": r"embed displays youtube video",
    "livebook-pr-3076": r"python code evaluation end-to-end",
    "operately-pr-1069": r"CreateBlobTest",
    "operately-pr-1205": r"CreateBlobTest",
    "pinchflat-pr-610": r"UserScripts\.CommandRunnerTest",
}


def has(case, program):
    where = INVENTORY.get(program)
    return where is None or where == "all" or (where != "none" and case in where)


def text_of(result):
    if not isinstance(result, dict):
        return str(result or "")
    sc = result.get("structuredContent")
    if isinstance(sc, dict) and sc.get("output") is not None:
        return sc["output"]
    return "".join(c.get("text", "") for c in (result.get("content") or []) if isinstance(c, dict))


def pi_attempts():
    for run in sorted(glob.glob(f"{ROOT}/v6-archive-2026-11-19/runs/run-*")):
        ident = json.load(open(f"{run}/run-summary.json"))["model"].get("identity") or {}
        model = f'{ident.get("name")} {ident.get("quantization") or ""}'.strip()
        for f in sorted(glob.glob(f"{run}/*/logs/pi-events.jsonl")):
            case = f.split("/")[-3]
            grade = json.load(open(f"{run}/{case}/grade-summary.json"))
            seq, starts = [], {}
            for line in open(f, errors="replace"):
                if line.startswith('{"messages"'):
                    continue
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                kind = e.get("type")
                if kind == "message_end" and (e.get("message") or {}).get("role") == "assistant":
                    seq.append({"reply": True, "tokens": (e["message"].get("usage") or {}).get("output") or 0})
                elif kind == "tool_execution_start":
                    starts[e.get("toolCallId")] = e
                elif kind == "tool_execution_end":
                    s = starts.pop(e.get("toolCallId"), {})
                    seq.append({"tool": e.get("toolName"), "args": s.get("args") or {}, "error": bool(e.get("isError")),
                                "out": text_of(e.get("result"))})
            yield {"harness": "pi", "model": model, "case": case, "run": os.path.basename(run), "seq": seq,
                   "passed": grade.get("passed"), "generated": grade.get("generated_tokens") or 0}


def claude_attempts():
    folders = ("opus-validation-*", "sonnet-series-*", "haiku-series-*")
    for f in sorted(p for d in folders for p in glob.glob(f"{ROOT}/{d}/run-*/*/logs/claude-transcript.jsonl")):
        case, run = f.split("/")[-3], f.split("/")[-4]
        gpath = os.path.join(os.path.dirname(os.path.dirname(f)), "grade-summary.json")
        grade = json.load(open(gpath)) if os.path.exists(gpath) else {}
        uses, seq, model = {}, [], None
        for line in open(f, errors="replace"):
            try:
                e = json.loads(line)
            except Exception:
                continue
            m = e.get("message") or {}
            if e.get("type") == "assistant" and m.get("model") and m["model"] != "<synthetic>":
                model = m["model"]
            for b in m.get("content") if isinstance(m.get("content"), list) else []:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_use":
                    uses.setdefault(b["id"], b)
                elif b.get("type") == "tool_result" and b.get("tool_use_id") in uses and not uses[b["tool_use_id"]].get("done"):
                    u = uses[b["tool_use_id"]]
                    u["done"] = True
                    c = b.get("content")
                    out = c if isinstance(c, str) else "".join(x.get("text", "") for x in (c or []) if isinstance(x, dict))
                    seq.append({"tool": u["name"].replace("mcp__eab_workspace__", ""), "args": u.get("input") or {},
                                "error": bool(b.get("is_error")), "out": out})
        if model:
            yield {"harness": "claude_code", "model": model, "case": case, "run": run, "seq": seq,
                   "passed": grade.get("passed"), "generated": grade.get("generated_tokens") or 0}


def norm(path):
    return (path or "").replace("/workspace/", "").lstrip("./")


def script_targets(text):
    found = set(re.findall(r"""(?:open|Path|read_text|write_text)\(\s*[rf]?['"]([^'"\n]+\.\w{1,5})['"]""", text))
    found |= set(re.findall(r"""(?m)^\s*(?:p|path|fn|f|file|filename|fname|target)\s*=\s*[rf]?['"]([^'"\n]+\.\w{1,5})['"]""", text))
    return {norm(p) for p in found}


def changes(call, targets):
    """Does this later call change one of the files, by a means other than python?"""
    if call["tool"] in ("edit", "write"):
        return not call["error"] and norm(call["args"].get("path")) in targets
    if call["tool"] != "bash":
        return False
    cmd = call["args"].get("command") or ""
    if any(PY.match(os.path.basename(p)) for p, _ in programs(cmd)[0]):
        return False
    return any(t in cmd for t in targets) and bool(re.search(
        r"sed\s+(-[a-zA-Z]*i|--in-place)|perl\s+[^\n]*-[a-zA-Z0-9]*i|cat\s*>+|tee\s|>\s*\S|elixir\s|mv\s|cp\s|git (checkout|apply|restore)|patch\s|awk\s", cmd))


models = collections.defaultdict(lambda: collections.Counter())
missing = collections.Counter()
missing_attempts = collections.defaultdict(set)
python_calls = []
baseline = collections.defaultdict(lambda: collections.Counter())

for a in list(pi_attempts()) + list(claude_attempts()):
    key = (a["run"], a["case"])
    m = models[(a["harness"], a["model"])]
    m["attempts"] += 1
    m["passed"] += bool(a["passed"])
    m["generated_tokens"] += a["generated"]
    flags = set()
    calls = [x for x in a["seq"] if "tool" in x]
    saw_baseline = None
    for i, x in enumerate(a["seq"]):
        if "tool" not in x:
            continue
        m["tool_calls"] += 1
        if x["tool"] in ("edit", "read", "write"):
            m[x["tool"]] += 1
            m[x["tool"] + "_failed"] += x["error"]
            continue
        if x["tool"] != "bash":
            # SubagentHandback is the Claude Code harness's own hand-back call; anything else was never offered.
            m["calls_to_tools_that_do_not_exist"] += x["tool"] != "SubagentHandback"
            continue
        m["bash"] += 1
        cmd = x["args"].get("command") or ""
        progs, bodies = programs(cmd)
        names = {os.path.basename(p) if "/" in p else p for p, _ in progs} - BUILTINS
        absent = {n for n in names if not has(a["case"], n)}
        for n in absent:
            label = "python" if PY.match(n) else n
            missing[label] += 1
            missing_attempts[label].add(key)
            m["missing:" + label] += 1
            flags.add(label)
        # /tmp is mounted noexec: running a file in /tmp by its path fails.
        if re.search(r"(?m)^(?:/bin/)?(?:ba)?sh: (?:line \d+: )?/tmp/\S+: Permission denied", x["out"]):
            m["tmp_noexec_calls"] += 1
            flags.add("tmp_noexec")
        # The bash tool's timeout is in seconds; values of 100000 and more are millisecond-style.
        t = x["args"].get("timeout")
        if isinstance(t, (int, float)) and t >= 100000:
            m["timeout_ms_style"] += 1
            m["timeout_rejected"] += "Invalid timeout" in x["out"]
        if a["harness"] == "claude_code" and re.search(r"/tmp/claude-[^\n]*No such file or directory", x["out"]):
            m["host_scratchpad_missing_calls"] += 1
            flags.add("host_scratchpad")
        sig = SIGNATURES.get(a["case"])
        if sig and saw_baseline is None and re.search(sig, x["out"]):
            saw_baseline = i
        if any(PY.match(n) for n in names) and not has(a["case"], "python3"):
            script = "\n".join(b for _, b, opener in bodies if "python" in opener or re.search(r"cat\s*>+\s*\S+\.py", opener)) or cmd
            targets = script_targets(script) | script_targets(cmd)
            writes = bool(re.search(r"write_text|\.write\(|open\([^)]*['\"]w", script))
            reply = next((a["seq"][j]["tokens"] for j in range(i, -1, -1) if a["seq"][j].get("reply")), None)
            later = [y for y in a["seq"][i + 1:] if "tool" in y]
            recovered_after = next((n + 1 for n, y in enumerate(later) if changes(y, targets)), None) if writes and targets else None
            python_calls.append({"harness": a["harness"], "model": a["model"], "run": a["run"], "case": a["case"], "writes": writes,
                                 "visible": bool(PY_NOT_FOUND.search(x["out"])),
                                 "hidden": bool(re.search(r"python[23]?\b[^\n]*2>\s*/dev/null", cmd)),
                                 "script_chars": len(script), "reply_tokens": reply, "has_target": bool(writes and targets),
                                 "recovered_after_calls": recovered_after, "last_call": not later, "targets": sorted(targets),
                                 "next_tool": later[0]["tool"] if later else None})
    for f in flags:
        m["attempts_with:" + f] += 1
    m["attempts_with_any_missing_program"] += bool(flags - {"tmp_noexec", "host_scratchpad"})
    if a["case"] in SIGNATURES:
        b = baseline[a["case"]]
        b["attempts"] += 1
        b["saw_failing_tests"] += saw_baseline is not None

print(f'{"harness / model":44s} {"att":>4s} {"pass":>4s} | {"python att/calls":>16s} | other missing programs (attempts)')
for (harness, model), m in sorted(models.items()):
    other = ", ".join(f'{k[14:]} {v}' for k, v in sorted(m.items(), key=lambda kv: -kv[1])
                      if k.startswith("attempts_with:") and k[14:] not in ("python", "tmp_noexec", "host_scratchpad"))
    print(f'{harness + " / " + model:44s} {m["attempts"]:4d} {m["passed"]:4d} | {m["attempts_with:python"]:7d} / {m["missing:python"]:<6d} | {other}')

print("\nprograms run but absent from that case's image (calls / attempts):")
print("  " + ", ".join(f"{p} {c}/{len(missing_attempts[p])}" for p, c in missing.most_common()))

for harness in ("pi", "claude_code"):
    pc = [p for p in python_calls if p["harness"] == harness]
    known = [p for p in pc if p["has_target"]]
    rec = [p["recovered_after_calls"] for p in known if p["recovered_after_calls"]]
    line = (f'\n{harness}: {len(pc)} python calls in {len({(p["run"], p["case"]) for p in pc})} attempts; {sum(p["writes"] for p in pc)} wrote a file; '
            f'{sum(p["visible"] for p in pc)} showed the error, {sum(p["hidden"] and not p["visible"] for p in pc)} hid it; '
            f'{sum(p["last_call"] for p in pc)} were the last tool call; edit scripts naming a file: {len(known)}, '
            f'changed another way later: {len(rec)}, after a median of {statistics.median(rec) if rec else "-"} calls (mean {statistics.mean(rec):.1f})')
    if harness == "pi":
        tokens = [p["reply_tokens"] for p in pc if p["reply_tokens"] is not None]
        total = sum(m["generated_tokens"] for (h, _), m in models.items() if h == "pi")
        line += f'; tokens of the replies that made the calls: median {statistics.median(tokens)}, sum {sum(tokens)} = {100 * sum(tokens) / total:.2f}% of all generated tokens'
    else:
        line += f'; median script length {statistics.median(p["script_chars"] for p in pc)} characters'
    print(line)

print(f'\n{"harness / model":44s} {"edits":>6s} {"failed":>6s} {"%":>4s} | /tmp noexec | ms-style timeout (rejected) | host scratchpad missing | tools that do not exist')
for (harness, model), m in sorted(models.items()):
    print(f'{harness + " / " + model:44s} {m["edit"]:6d} {m["edit_failed"]:6d} {100 * m["edit_failed"] / max(1, m["edit"]):4.0f} | {m["tmp_noexec_calls"]:11d} | '
          f'{m["timeout_ms_style"]:8d} ({m["timeout_rejected"]}) | {m["host_scratchpad_missing_calls"]:23d} | {m["calls_to_tools_that_do_not_exist"]}')

print("\nattempts that saw tests failing for environment reasons (saw / attempts):")
print("  " + ", ".join(f'{c} {b["saw_failing_tests"]}/{b["attempts"]}' for c, b in sorted(baseline.items())))

json.dump({"models": {f"{h} / {mo}": dict(m) for (h, mo), m in models.items()}, "missing_programs": dict(missing),
           "missing_program_attempts": {k: len(v) for k, v in missing_attempts.items()}, "python_calls": python_calls,
           "environment_failing_tests": {c: dict(b) for c, b in baseline.items()}}, open(OUT, "w"), indent=1)
