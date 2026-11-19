"""Count how the agents used python, perl, node and sed in their bash calls, per saved run.

Usage:  python3 count_tools.py verification/runs counts.json   (from the repository root)

A program counts as run when it stands where the shell runs a command (a line start, or after ; & | ( then do,
optionally behind sudo, env or timeout), outside comment lines. "probe" counts which / command -v / type / whereis
naming python. A call counts as missing when its output says "<name>: command not found" (or env: no such file), or,
for python, when the call hid the error with 2>/dev/null (python is in none of the case images). "after_python" is
what the next bash call ran. Reads verification/runs/run-*/<case>/logs/pi-events.jsonl."""
import glob, json, re, sys, collections

RUNS = sys.argv[1]
POS = r"(?:^|[;&|(]\s*|\bthen\s+|\bdo\s+)(?:sudo\s+|env\s+|timeout\s+\d+[sm]?\s+)?"
RUN = {k: re.compile(POS + rx + r"(?=\s|$)", re.M) for k, rx in {
    "python": r"python[23]?(?:\.\d+)?", "perl": r"perl", "node": r"(?:node|npm|npx)", "sed": r"sed"}.items()}
PROBE = re.compile(r"\b(?:which|command -v|type|whereis)\b[^\n;&|]*\bpython", re.M)
NOTFOUND = {
    "python": re.compile(r"python[23]?(?:\.\d+)?: (?:command )?not found|env: ['\"]?python[23]?['\"]?: No such file"),
    "perl": re.compile(r"perl: (?:command )?not found"), "node": re.compile(r"(?:node|npm|npx): (?:command )?not found"),
    "sed": re.compile(r"sed: (?:command )?not found")}
HIDDEN = re.compile(r"python[23]?\b[^\n]*2>\s*/dev/null")

def strip_comments(cmd):
    return "\n".join(l for l in cmd.split("\n") if not l.lstrip().startswith("#"))

def out_of(e):
    r = e.get("result")
    if not isinstance(r, dict): return str(r or "")
    sc = r.get("structuredContent")
    if isinstance(sc, dict) and sc.get("output") is not None: return sc["output"]
    return "".join(c.get("text", "") for c in r.get("content") or [] if isinstance(c, dict))

res = []
for run in sorted(glob.glob(f"{RUNS}/run-*")):
    model = None; cases = 0
    c = {k: collections.Counter() for k in ("python", "perl", "node", "sed")}
    case_sets = {k: set() for k in ("python_run", "python_probe", "perl", "perl_missing", "node", "sed")}
    after = collections.Counter(); multi = 0; py_calls_per_case = collections.Counter()
    for f in sorted(glob.glob(f"{run}/*/logs/pi-events.jsonl")):
        cases += 1; case = f.split("/")[-3]; cmds = {}; names = {}; seq = []
        for line in open(f, errors="replace"):
            try: e = json.loads(line)
            except Exception: continue
            t = e.get("type")
            if t == "message_end" and (e.get("message") or {}).get("role") == "assistant":
                model = e["message"].get("model") or model
            elif t == "tool_execution_start":
                cmds[e.get("toolCallId")] = (e.get("args") or {}).get("command") or ""
                names[e.get("toolCallId")] = e.get("toolName")
            elif t == "tool_execution_end":
                raw = cmds.get(e.get("toolCallId"), ""); cmd = strip_comments(raw); out = out_of(e)
                uses = {k for k, rx in RUN.items() if rx.search(cmd)}
                if PROBE.search(cmd):
                    c["python"]["probe"] += 1; case_sets["python_probe"].add(case)
                for k in uses:
                    c[k]["calls"] += 1
                    missing = NOTFOUND[k].search(out) or (k == "python" and HIDDEN.search(cmd))
                    c[k]["missing" if missing else "ran"] += 1
                    if k == "python":
                        case_sets["python_run"].add(case); py_calls_per_case[case] += 1
                        if not NOTFOUND[k].search(out): c[k]["hidden"] += 1
                    elif k == "perl":
                        case_sets["perl"].add(case)
                        if missing: case_sets["perl_missing"].add(case)
                    else:
                        case_sets[k].add(case)
                seq.append((names.get(e.get("toolCallId")), uses, cmd))
        for i, (tool, u, _) in enumerate(seq):
            if "python" in u:
                if i + 1 >= len(seq):
                    after["case ended"] += 1; continue
                tool2, u2, cmd2 = seq[i + 1]
                after["python again" if "python" in u2 else "perl" if "perl" in u2 else "sed" if "sed" in u2 else
                      "bash: cat > file heredoc" if tool2 == "bash" and re.search(r"cat\s*>+\s*\S+\s*<<", cmd2) else
                      "bash: mix / elixir" if tool2 == "bash" and re.search(r"\b(mix|elixir)\b", cmd2) else
                      "bash: other" if tool2 == "bash" else f"{tool2} tool"] += 1
    multi = sum(1 for v in py_calls_per_case.values() if v > 1)
    res.append({"run": run.split("/")[-1], "model": model, "cases": cases,
                "python": dict(c["python"]), "perl": dict(c["perl"]), "node": dict(c["node"]), "sed": dict(c["sed"]),
                "cases_python_run": len(case_sets["python_run"]), "cases_python_probe": len(case_sets["python_probe"]),
                "cases_python_run_more_than_once": multi,
                "cases_perl": len(case_sets["perl"]), "cases_perl_missing": sorted(case_sets["perl_missing"]),
                "cases_node": sorted(case_sets["node"]), "cases_sed": len(case_sets["sed"]), "after_python": dict(after)})
json.dump(res, open(sys.argv[2], "w"), indent=1)
tot = collections.Counter()
for r in res:
    p = r["python"]
    print(f'{r["run"][4:19]} {r["model"][:36]:36s} cases {r["cases"]:2d} | py-run cases {r["cases_python_run"]:2d} calls {p.get("calls",0):3d} missing {p.get("missing",0):3d} ran {p.get("ran",0)} hidden {p.get("hidden",0)} | probes {p.get("probe",0)} in {r["cases_python_probe"]} cases | >1 in {r["cases_python_run_more_than_once"]} | perl cases {r["cases_perl"]:2d} calls {r["perl"].get("calls",0):3d} missing {r["perl"].get("missing",0)} {r["cases_perl_missing"]} | node {r["node"]} {r["cases_node"]} | sed cases {r["cases_sed"]} calls {r["sed"].get("calls",0)} | after {r["after_python"]}')
    tot["cases"] += r["cases"]; tot["py_cases"] += r["cases_python_run"]; tot["py_calls"] += p.get("calls", 0); tot["py_missing"] += p.get("missing", 0); tot["py_hidden"] += p.get("hidden", 0); tot["probes"] += p.get("probe", 0)
    tot["perl_cases"] += r["cases_perl"]; tot["perl_calls"] += r["perl"].get("calls", 0); tot["perl_missing"] += r["perl"].get("missing", 0); tot["sed_calls"] += r["sed"].get("calls", 0); tot["multi"] += r["cases_python_run_more_than_once"]
    for k, v in r["after_python"].items(): tot["after:" + k] += v
print(dict(tot))
