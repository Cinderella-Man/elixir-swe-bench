# Tests for the solver kit's hook uploader. Run: python3 -I test/claude_code/hook_test.py
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Importing the hook must not leave bytecode in the kit source, which is hashed.
sys.dont_write_bytecode = True
HOOK = pathlib.Path(__file__).resolve().parents[2] / "priv/claude_code/kit/.claude/eab/hook.py"
spec = importlib.util.spec_from_file_location("eab_hook", HOOK)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)


def record(kind, content, **extra):
    return dict({"type": kind, "message": {"role": kind, "content": content}}, **extra)


PROMPT = record("user", "Frozen prompt\n")
TOOL = record("assistant", [{"type": "tool_use", "id": "t1", "name": "mcp__eab_workspace__bash"}])
RESULT = record("user", [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}])
REQUEST = {"type": "api-request", "params": {"model": "claude-opus-5-5"}}
HANDBACK = record("assistant", [{"type": "tool_use", "id": "hb", "name": "SubagentHandback",
                                 "input": {"message": "Final report."}}])
DELIVERED = record("user", [{"type": "tool_result", "tool_use_id": "hb", "content": [
    {"type": "text", "text": json.dumps({"success": True, "message": "Report delivered to your caller."})}]}])


def lines(*records):
    return "".join(json.dumps(r) + "\n" for r in records)


class Controller:
    def __init__(self, *replies):
        self.bodies = []
        received = self.bodies
        replies = list(replies)

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                received.append(json.loads(self.rfile.read(int(self.headers["content-length"]))))
                reply = replies.pop(0) if replies else b"{}"
                self.send_response(200)
                self.send_header("content-length", str(len(reply)))
                self.end_headers()
                self.wfile.write(reply)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]

    def close(self):
        self.server.shutdown()


class UploaderTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = pathlib.Path(self.dir.name) / "agent-a1.jsonl"
        self.controller = Controller()
        hook.CONTROLLER = self.controller.url
        hook.COMPLETE_WAIT_SECONDS, hook.STABLE_SECONDS, hook.POLL_SECONDS = 10, 0.3, 0.05

    def tearDown(self):
        self.controller.close()
        self.dir.cleanup()

    def upload(self):
        body = {"event": {"hook_event_name": "SubagentStop", "agent_transcript_path": str(self.path)}}
        thread = threading.Thread(target=hook.upload, args=(body,))
        thread.start()
        return thread

    def test_waits_for_records_written_after_meta_says_finished(self):
        # The race seen in Opus validation run 1: finished, but the file ends on an api-request.
        self.path.with_suffix(".meta.json").write_text(json.dumps({"finished": True}))
        self.path.write_text(lines(PROMPT, TOOL, RESULT, REQUEST))
        thread = self.upload()
        time.sleep(0.8)
        self.assertEqual(self.controller.bodies, [])
        with self.path.open("a") as handle:
            handle.write(lines(HANDBACK))
            handle.flush()
            time.sleep(0.1)
            handle.write(lines(DELIVERED))
        thread.join(10)
        [body] = self.controller.bodies
        self.assertEqual(body["transcript"], lines(PROMPT, TOOL, RESULT, REQUEST, HANDBACK, DELIVERED))
        self.assertNotIn("transcript_error", body)

    def test_an_assistant_message_ending_the_turn_uploads_once_the_file_is_stable(self):
        final = record("assistant", [{"type": "text", "text": "Done."}])
        self.path.write_text(lines(PROMPT, TOOL, RESULT, final))
        self.upload().join(10)
        self.assertEqual(self.controller.bodies[0]["transcript"], lines(PROMPT, TOOL, RESULT, final))

    def test_a_truncated_transcript_is_uploaded_after_the_bound(self):
        hook.COMPLETE_WAIT_SECONDS = 1
        self.path.write_text(lines(PROMPT, TOOL, RESULT, REQUEST))
        started = time.monotonic()
        self.upload().join(10)
        self.assertGreaterEqual(time.monotonic() - started, 1)
        self.assertEqual(self.controller.bodies[0]["transcript"], lines(PROMPT, TOOL, RESULT, REQUEST))

    def test_completion_rules(self):
        failed = record("user", [{"type": "tool_result", "tool_use_id": "hb", "is_error": True, "content": "x"}])
        refused = record("user", [{"type": "tool_result", "tool_use_id": "hb",
                                   "content": json.dumps({"success": False})}])
        self.assertTrue(hook.complete(lines(PROMPT, HANDBACK, DELIVERED)))
        self.assertTrue(hook.complete(lines(PROMPT, record("assistant", [{"type": "text", "text": "x"}]),
                                            {"type": "attachment", "attachment": {"type": "hook_success"}})))
        self.assertFalse(hook.complete(lines(PROMPT, HANDBACK)))
        self.assertFalse(hook.complete(lines(PROMPT, HANDBACK, failed)))
        self.assertFalse(hook.complete(lines(PROMPT, HANDBACK, refused)))
        self.assertFalse(hook.complete(lines(PROMPT, TOOL, RESULT)))
        self.assertFalse(hook.complete(lines(PROMPT, HANDBACK, DELIVERED)[:-5]))
        self.assertFalse(hook.complete(lines(PROMPT)))


class RoutingTest(unittest.TestCase):
    """Parallel solvers: each workspace tool call names the subagent that made it."""

    def run_hook(self, event):
        result = subprocess.run([sys.executable, "-I", str(HOOK)], input=json.dumps(event),
                                capture_output=True, text=True, timeout=30,
                                env=dict(os.environ, CLAUDE_PROJECT_DIR=str(HOOK.parents[2])))
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)["hookSpecificOutput"]

    def test_workspace_calls_carry_the_real_subagent_id(self):
        output = self.run_hook({"hook_event_name": "PreToolUse", "tool_name": "mcp__eab_workspace__bash",
                                "agent_id": "a1", "agent_type": "eab-opus-5-5-xhigh",
                                "tool_input": {"command": "ls", "eab_agent_id": "forged"}})
        self.assertEqual(output["permissionDecision"], "allow")
        self.assertEqual(output["updatedInput"], {"command": "ls", "eab_agent_id": "a1"})

    def test_workspace_calls_outside_a_solver_are_refused(self):
        output = self.run_hook({"hook_event_name": "PreToolUse", "tool_name": "mcp__eab_workspace__read",
                                "tool_input": {"path": "x"}})
        self.assertEqual(output["permissionDecision"], "deny")
        self.assertNotIn("updatedInput", output)

    def test_launch_reports_reach_the_controller_with_the_kit(self):
        controller = Controller()
        hook.CONTROLLER = controller.url
        event = {"hook_event_name": "PostToolUse", "tool_name": "Agent", "tool_use_id": "toolu_1",
                 "tool_response": {"status": "async_launched", "agentId": "a1"}}
        old = sys.stdin, sys.stdout, os.environ.get("CLAUDE_PROJECT_DIR")
        sys.stdin, sys.stdout = io.StringIO(json.dumps(event)), io.StringIO()
        os.environ["CLAUDE_PROJECT_DIR"] = str(HOOK.parents[2])
        try:
            hook.main()
            printed = sys.stdout.getvalue()
        finally:
            sys.stdin, sys.stdout = old[0], old[1]
            if old[2] is None:
                os.environ.pop("CLAUDE_PROJECT_DIR")
            else:
                os.environ["CLAUDE_PROJECT_DIR"] = old[2]
            controller.close()
        self.assertEqual(printed, "")
        [body] = controller.bodies
        self.assertEqual(body["event"], event)
        self.assertIn(".claude/eab/hook.py", body["kit"]["files"])

    def test_a_stopped_solver_is_reported_before_its_transcript(self):
        controller = Controller()
        hook.CONTROLLER = controller.url
        event = {"hook_event_name": "SubagentStop", "agent_id": "a1", "agent_type": "eab-opus-5-5-xhigh"}
        old = sys.stdin, sys.stdout, os.environ.get("CLAUDE_PROJECT_DIR")
        sys.stdin, sys.stdout = io.StringIO(json.dumps(event)), io.StringIO()
        os.environ["CLAUDE_PROJECT_DIR"] = str(HOOK.parents[2])
        try:
            hook.main()
            printed = sys.stdout.getvalue()
        finally:
            sys.stdin, sys.stdout = old[0], old[1]
            if old[2] is None:
                os.environ.pop("CLAUDE_PROJECT_DIR")
            else:
                os.environ["CLAUDE_PROJECT_DIR"] = old[2]
            controller.close()
        # Never exit 2 or print a decision here: that would keep the solver running.
        self.assertEqual(printed, "")
        [body] = controller.bodies
        self.assertEqual(body["event"], event)
        self.assertIs(body["stopping"], True)
        self.assertNotIn("transcript", body)

    def test_finished_solvers_come_from_claude_codes_subagent_records(self):
        with tempfile.TemporaryDirectory() as root:
            session = pathlib.Path(root) / "session.jsonl"
            agents = pathlib.Path(root) / "session" / "subagents"
            agents.mkdir(parents=True)
            (agents / "agent-a1.meta.json").write_text(json.dumps(
                {"agentType": "eab-opus-5-5-xhigh", "toolUseId": "toolu_1", "finished": True}))
            (agents / "agent-a2.meta.json").write_text(json.dumps({"agentType": "eab-opus-5-5-xhigh"}))
            (agents / "agent-a3.meta.json").write_text("{not json")
            self.assertEqual(hook.finished_solvers({"transcript_path": str(session)}), [
                {"agent_id": "a1", "agent_type": "eab-opus-5-5-xhigh",
                 "agent_transcript_path": str(agents / "agent-a1.jsonl")}])
            self.assertEqual(hook.finished_solvers({}), [])

    def test_an_agent_call_first_recovers_finished_solvers_then_claims(self):
        decision = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                           "permissionDecisionReason": "busy"}}
        solver = {"agent_id": "a1", "agent_type": "eab-opus-5-5-xhigh",
                  "agent_transcript_path": "/t/agent-a1.jsonl"}
        controller = Controller(json.dumps({"eab_upload": [solver]}).encode(), json.dumps(decision).encode())
        session = tempfile.TemporaryDirectory()
        agents = pathlib.Path(session.name) / "s" / "subagents"
        agents.mkdir(parents=True)
        (agents / "agent-a1.meta.json").write_text(json.dumps({"agentType": "eab-opus-5-5-xhigh", "finished": True}))
        hook.CONTROLLER = controller.url
        uploads = []
        original = hook.spawn_upload
        hook.spawn_upload = uploads.append
        event = {"hook_event_name": "PreToolUse", "tool_name": "Agent", "tool_use_id": "toolu_2",
                 "transcript_path": str(pathlib.Path(session.name) / "s.jsonl"),
                 "tool_input": {"subagent_type": "eab-opus-5-5-xhigh"}}
        old = sys.stdin, sys.stdout, os.environ.get("CLAUDE_PROJECT_DIR")
        sys.stdin, sys.stdout = io.StringIO(json.dumps(event)), io.StringIO()
        os.environ["CLAUDE_PROJECT_DIR"] = str(HOOK.parents[2])
        try:
            hook.main()
            printed = sys.stdout.getvalue()
        finally:
            hook.spawn_upload = original
            sys.stdin, sys.stdout = old[0], old[1]
            if old[2] is None:
                os.environ.pop("CLAUDE_PROJECT_DIR")
            else:
                os.environ["CLAUDE_PROJECT_DIR"] = old[2]
            controller.close()
            session.cleanup()
        # A quick recovery request, then the claim; Claude Code sees only the decision.
        recover, claim = controller.bodies
        self.assertEqual([s["agent_id"] for s in recover["recover"]], ["a1"])
        self.assertNotIn("recover", claim)
        self.assertEqual(json.loads(printed), decision)
        [upload] = uploads
        self.assertEqual(upload["event"], dict(solver, hook_event_name="SubagentStop", recovered=True))


if __name__ == "__main__":
    unittest.main(verbosity=1)
