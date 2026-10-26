# Elixir Agent Benchmark solver hook. Forwards Claude Code's PreToolUse(Agent) and
# SubagentStop events to the benchmark controller and prints its reply as hook output.
# It also reports the installed kit's file hashes, so the controller can refuse a
# drifted kit, and uploads the finished solver's transcript. Standard library only.
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

CONTROLLER = "__EAB_CONTROLLER_URL__"
INSTRUCTIONS = ("CLAUDE.md", "CLAUDE.local.md", "AGENTS.md", ".claude/CLAUDE.md")
# Claude Code writes the solver's final message after SubagentStop hooks start, and
# marks the subagent finished in its .meta.json once the transcript is complete.
FINISH_WAIT_SECONDS = 300


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


def post(body, timeout):
    request = urllib.request.Request(
        CONTROLLER + "/claude-code/hook",
        data=json.dumps(body).encode("utf-8"),
        headers={"content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8")


def detail(error):
    return getattr(error, "read", lambda: b"")().decode("utf-8", "replace") or str(error)


def upload(body):
    """Detached: wait until the subagent is finished, then send its whole transcript."""
    path = pathlib.Path(body["event"]["agent_transcript_path"])
    meta = path.with_suffix(".meta.json")
    deadline = time.monotonic() + FINISH_WAIT_SECONDS
    while time.monotonic() < deadline:
        try:
            if json.loads(meta.read_text(encoding="utf-8")).get("finished") is True:
                break
        except (OSError, ValueError):
            pass
        time.sleep(0.5)
    else:
        body["transcript_error"] = "the subagent was not marked finished within %d seconds" % FINISH_WAIT_SECONDS
    try:
        body["transcript"] = path.read_text(encoding="utf-8")
    except OSError as error:
        body["transcript_error"] = str(error)
    for attempt in range(5):
        try:
            post(body, 170)
            return
        except (urllib.error.URLError, OSError) as error:
            failure = detail(error)
            time.sleep(2 ** attempt)
    log = pathlib.Path(tempfile.gettempdir()) / "eab-solver-hook.log"
    with log.open("a", encoding="utf-8") as handle:
        handle.write("Transcript upload failed for %s: %s\n" % (path, failure[:500]))


def main():
    if sys.argv[1:] == ["--upload"]:
        upload(json.load(sys.stdin))
        return
    event = json.load(sys.stdin)
    name = event.get("hook_event_name")
    root = pathlib.Path(os.environ.get("CLAUDE_PROJECT_DIR") or pathlib.Path(__file__).resolve().parents[2])
    body = {"event": event, "kit": kit(root)}
    if name == "SubagentStop":
        if event.get("agent_transcript_path"):
            # Return at once; a detached uploader sends the transcript when it is complete.
            child = subprocess.Popen(
                [sys.executable, "-I", os.path.abspath(__file__), "--upload"],
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            child.stdin.write(json.dumps(body).encode("utf-8"))
            child.stdin.close()
        # Never exit 2 here: that would keep the solver running.
        return
    try:
        sys.stdout.write(post(body, 590))
    except (urllib.error.URLError, OSError) as error:
        # Fail closed: without the controller no attempt may start.
        reason = "The benchmark controller did not accept this call: " + detail(error)[:500] + \
            " Tell the user and stop."
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }}))


main()
