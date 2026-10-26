# Elixir Agent Benchmark solver hook. Forwards Claude Code's PreToolUse(Agent) and
# SubagentStop events to the benchmark controller and prints its reply as hook output.
# It also reports the installed kit's file hashes, so the controller can refuse a
# drifted kit, and uploads the finished solver's transcript. Standard library only.
import hashlib
import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

CONTROLLER = "__EAB_CONTROLLER_URL__"
INSTRUCTIONS = ("CLAUDE.md", "CLAUDE.local.md", "AGENTS.md", ".claude/CLAUDE.md")


def kit(root):
    files = {}
    for path in sorted((root / ".claude").rglob("*")):
        if path.is_file() and "__pycache__" not in path.parts:
            files[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    if (root / ".mcp.json").is_file():
        files[".mcp.json"] = hashlib.sha256((root / ".mcp.json").read_bytes()).hexdigest()
    folders = [root, *root.parents]
    return {
        "files": files,
        "repository": [str(d) for d in folders if (d / ".git").exists()],
        "instructions": [str(d / n) for d in folders for n in INSTRUCTIONS if (d / n).is_file()],
    }


def main():
    event = json.load(sys.stdin)
    name = event.get("hook_event_name")
    root = pathlib.Path(os.environ.get("CLAUDE_PROJECT_DIR") or pathlib.Path(__file__).resolve().parents[2])
    body = {"event": event, "kit": kit(root)}
    path = event.get("agent_transcript_path")
    if name == "SubagentStop" and path:
        try:
            body["transcript"] = pathlib.Path(path).read_text(encoding="utf-8")
        except OSError as error:
            body["transcript_error"] = str(error)
    request = urllib.request.Request(
        CONTROLLER + "/claude-code/hook",
        data=json.dumps(body).encode("utf-8"),
        headers={"content-type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=590 if name == "PreToolUse" else 170) as response:
            sys.stdout.write(response.read().decode("utf-8"))
    except (urllib.error.URLError, OSError) as error:
        detail = getattr(error, "read", lambda: b"")().decode("utf-8", "replace") or str(error)
        if name == "PreToolUse":
            # Fail closed: without the controller no attempt may start.
            reason = "The benchmark controller did not accept this call: " + detail[:500] + \
                " Tell the user and stop."
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }}))
        else:
            # Never exit 2 here: that would keep the solver running.
            sys.stderr.write("Benchmark controller did not receive the solver transcript: " + detail[:500] + "\n")
            sys.exit(1)


main()
