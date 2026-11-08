"""Browser eval regressions. Run under Xvfb with SEANCE_TEST_BINARY set."""
import json
import socket
import time
import unittest

from test_ghostty_integration import GhosttyTestCase


class BrowserEvalTests(GhosttyTestCase):
    def request(self, request):
        with socket.socket(socket.AF_UNIX) as conn:
            conn.settimeout(5)
            conn.connect(str(self.socket_path))
            conn.sendall((json.dumps(request) + "\n").encode())
            reply = b""
            while b"\n" not in reply:
                part = conn.recv(65536)
                self.assertTrue(part, "application closed the socket without a reply")
                reply += part
        return json.loads(reply)

    def setUp(self):
        super().setUp()
        self.wait(lambda: self.call("surface.read_screen").get("text"), "shell startup")

    def _open_panel(self):
        return self.call("browser.open", {"url": "about:blank"})["panel_id"]

    def test_eval_returns_native_json_types(self):
        pid = self._open_panel()
        cases = [
            ('"hello"', "hello"),
            ('42', 42),
            ('1.5', 1.5),
            ('true', True),
            ('null', None),
            ('[1, 2, 3]', [1, 2, 3]),
            ('({a: 1, b: "x"})', {"a": 1, "b": "x"}),
        ]
        for script, expected in cases:
            with self.subTest(script=script):
                reply = self.request({"id": "e", "method": "browser.eval",
                                      "params": {"panel_id": pid, "script": script}})
                self.assertTrue(reply["ok"], reply)
                self.assertEqual(reply["result"], expected)
        self.call("browser.close", {"panel_id": pid})

    def test_eval_string_escaping(self):
        pid = self._open_panel()
        reply = self.request({"id": "e", "method": "browser.eval",
                              "params": {"panel_id": pid,
                                         "script": 'JSON.stringify("a\\nb\\\\c")'}})
        # script returns a JSON string containing newline/backslash
        self.assertTrue(reply["ok"], reply)
        self.call("browser.close", {"panel_id": pid})

    def test_eval_undefined(self):
        pid = self._open_panel()
        reply = self.request({"id": "e", "method": "browser.eval",
                              "params": {"panel_id": pid, "script": "undefined"}})
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(reply["result"], "undefined")
        self.call("browser.close", {"panel_id": pid})

    def test_eval_thrown_exception(self):
        pid = self._open_panel()
        reply = self.request({"id": "e", "method": "browser.eval",
                              "params": {"panel_id": pid, "script": "throw new Error('boom')"}})
        self.assertFalse(reply["ok"], reply)
        self.assertEqual(reply["error"]["code"], "eval_error")
        self.call("browser.close", {"panel_id": pid})

    def test_eval_missing_panel(self):
        reply = self.request({"id": "e", "method": "browser.eval",
                              "params": {"panel_id": 999999, "script": "1"}})
        self.assertFalse(reply["ok"], reply)
        self.assertEqual(reply["error"]["code"], "not_found")

    def test_eval_timeout_does_not_poison_next(self):
        pid = self._open_panel()
        # A delayed completion via setTimeout; first request should time out.
        self.request({"id": "t", "method": "browser.eval",
                      "params": {"panel_id": pid, "script": "new Promise(r=>setTimeout(()=>r(1),6000))"}})
        # Next eval should succeed.
        reply = self.request({"id": "e2", "method": "browser.eval",
                              "params": {"panel_id": pid, "script": "7"}})
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(reply["result"], 7)
        self.call("browser.close", {"panel_id": pid})

    def test_eval_concurrent_requests_serialize(self):
        pid = self._open_panel()
        r1 = self.request({"id": "a", "method": "browser.eval",
                           "params": {"panel_id": pid, "script": "1"}})
        r2 = self.request({"id": "b", "method": "browser.eval",
                           "params": {"panel_id": pid, "script": "2"}})
        self.assertTrue(r1["ok"] and r2["ok"])
        self.assertEqual(r1["result"], 1)
        self.assertEqual(r2["result"], 2)
        self.call("browser.close", {"panel_id": pid})


if __name__ == "__main__":
    unittest.main()
