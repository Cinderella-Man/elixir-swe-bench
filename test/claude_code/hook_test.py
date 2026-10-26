# Tests for the solver kit's hook uploader. Run: python3 -I test/claude_code/hook_test.py
import importlib.util
import json
import pathlib
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
    def __init__(self):
        self.bodies = []
        received = self.bodies

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                received.append(json.loads(self.rfile.read(int(self.headers["content-length"]))))
                self.send_response(200)
                self.send_header("content-length", "2")
                self.end_headers()
                self.wfile.write(b"{}")

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


if __name__ == "__main__":
    unittest.main(verbosity=1)
