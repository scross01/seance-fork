"""Browser eval regressions. Run under Xvfb with SEANCE_TEST_BINARY set.

Requests are answered asynchronously: the acceptor hands the connection to a
deferred reply, so this suite keeps several sockets outstanding at once and
checks that each answer matches its own request. The five-second server
deadline is not observable from here — WebKit answers a Promise-returning
script with an immediate error instead of awaiting it — so the deadline itself
is pinned by the native state-machine tests in src/socket_server.zig. Client
timeouts are deliberately longer than that deadline so a deadline reply is
never mistaken for a dead socket.
"""
import json
import socket
import time
import unittest

from test_ghostty_integration import GhosttyTestCase

# Server reply deadline is 5 s; stay well clear of it.
CLIENT_TIMEOUT = 10


class BrowserEvalTests(GhosttyTestCase):
    def _send(self, request):
        conn = socket.socket(socket.AF_UNIX)
        self.addCleanup(conn.close)
        conn.settimeout(CLIENT_TIMEOUT)
        conn.connect(str(self.socket_path))
        conn.sendall((json.dumps(request) + "\n").encode())
        return conn

    def _recv(self, conn):
        reply = b""
        while b"\n" not in reply:
            part = conn.recv(65536)
            self.assertTrue(part, "application closed the socket without a reply")
            reply += part
        return json.loads(reply)

    def request(self, request):
        return self._recv(self._send(request))

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

    def test_eval_overlapping_requests_correlate_by_id(self):
        pid = self._open_panel()
        # Both requests are outstanding before either reply is read: the
        # acceptor transfers each connection to its own deferred reply.
        first = self._send({"id": "first", "method": "browser.eval",
                            "params": {"panel_id": pid, "script": "1 + 1"}})
        second = self._send({"id": "second", "method": "browser.eval",
                             "params": {"panel_id": pid, "script": "'two'"}})
        replies = {}
        for conn in (first, second):
            reply = self._recv(conn)
            self.assertTrue(reply["ok"], reply)
            replies[reply["id"]] = reply["result"]
        self.assertEqual(replies, {"first": 2, "second": "two"})
        self.call("browser.close", {"panel_id": pid})

    def test_eval_promise_is_not_awaited_and_never_reported_as_timeout(self):
        pid = self._open_panel()
        # WebKit reports the Promise as an evaluation error immediately; it
        # does not await it. Keeping this bounded documents that the deadline
        # must be proven natively rather than inferred from a Promise.
        start = time.monotonic()
        reply = self.request({"id": "p", "method": "browser.eval",
                              "params": {"panel_id": pid,
                                         "script": "new Promise(r => setTimeout(() => r(1), 6000))"}})
        self.assertLess(time.monotonic() - start, 5)
        self.assertFalse(reply["ok"], reply)
        self.assertEqual(reply["error"]["code"], "eval_error")
        self.call("browser.close", {"panel_id": pid})

    def test_eval_rejections_leave_the_server_healthy(self):
        pid = self._open_panel()
        # Each rejected request answers, closes its connection and frees its
        # request exactly once; repeating them must not corrupt later work.
        for _ in range(2):
            missing = self.request({"id": "m", "method": "browser.eval",
                                    "params": {"panel_id": pid}})
            self.assertFalse(missing["ok"], missing)
            self.assertEqual(missing["error"]["code"], "invalid_params")
            absent = self.request({"id": "n", "method": "browser.eval",
                                   "params": {"panel_id": 999999, "script": "1"}})
            self.assertFalse(absent["ok"], absent)
            self.assertEqual(absent["error"]["code"], "not_found")
        reply = self.request({"id": "ok", "method": "browser.eval",
                              "params": {"panel_id": pid, "script": "6 * 7"}})
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(reply["result"], 42)
        self.call("browser.close", {"panel_id": pid})

    def test_eval_close_during_eval_then_next_request_works(self):
        closing = self._open_panel()
        surviving = self._open_panel()
        pending = self._send({"id": "closing", "method": "browser.eval",
                              "params": {"panel_id": closing, "script": "'late'"}})
        self.call("browser.close", {"panel_id": closing})
        # Whatever the retained webview reports (result or error), the request
        # must still be answered rather than abandoned with its socket open.
        reply = self._recv(pending)
        self.assertEqual(reply["id"], "closing")
        self.assertIn("ok", reply)
        healthy = self.request({"id": "next", "method": "browser.eval",
                                "params": {"panel_id": surviving, "script": "9"}})
        self.assertTrue(healthy["ok"], healthy)
        self.assertEqual(healthy["result"], 9)
        self.call("browser.close", {"panel_id": surviving})


if __name__ == "__main__":
    unittest.main()
