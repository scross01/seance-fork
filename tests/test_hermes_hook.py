"""Hermes process-exit status handling.

Run with: python3 -m unittest tests.test_hermes_hook -v

Drives the real `seance ctl` binary against a stub control socket so the
hook's request can be asserted without a running GUI. Hermes fires
`session-end` between turns (from its on_session_end hook), so that event must
leave status alone; the wrapper's `process-exit` event is what clears it.
"""

import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest


REPO = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("SEANCE_TEST_BINARY") or REPO / "AppDir/usr/bin/seance")


class StubSocket:
    """Unix-socket server that records control requests and acks them."""

    def __init__(self, path):
        self.path = str(path)
        self.requests = []
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.bind(self.path)
        self._sock.listen(8)
        self._sock.settimeout(0.2)
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self):
        while not self._stop.is_set():
            try:
                conn, _ = self._sock.accept()
            except (socket.timeout, TimeoutError):
                continue
            except OSError:
                return
            with conn:
                conn.settimeout(2)
                data = b""
                try:
                    while b"\n" not in data:
                        part = conn.recv(65536)
                        if not part:
                            break
                        data += part
                except OSError:
                    pass
                if b"\n" in data:
                    self.requests.append(json.loads(data.split(b"\n", 1)[0]))
                    try:
                        conn.sendall(b'{"id":"1","ok":true,"result":{}}\n')
                    except OSError:
                        pass

    def close(self):
        self._stop.set()
        self._thread.join(timeout=2)
        self._sock.close()


@unittest.skipUnless(BINARY.exists(), f"build first: {BINARY}")
class HermesHookTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="seance-hermes-hook-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.socket_path = self.root / "seance.sock"
        self.server = StubSocket(self.socket_path)
        self.addCleanup(self.server.close)

    def hook(self, *args, **env_overrides):
        env = {**os.environ, "SEANCE_WORKSPACE_ID": "42",
               "SEANCE_SURFACE_ID": "7", **env_overrides}
        return subprocess.run(
            [str(BINARY), "ctl", "--socket", str(self.socket_path), *args],
            env=env, input="", capture_output=True, text=True, timeout=10,
        )

    def test_process_exit_clears_hermes_surface_status(self):
        result = self.hook("hermes-hook", "process-exit")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.server.requests), 1, self.server.requests)
        request = self.server.requests[0]
        self.assertEqual(request["method"], "workspace.clear_status")
        self.assertEqual(request["params"], {"workspace_id": 42, "key": "hermes-7"})

    def test_session_end_leaves_hermes_status_intact(self):
        result = self.hook("hermes-hook", "session-end")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.requests, [])

    def test_process_exit_falls_back_to_prefix_without_surface(self):
        result = self.hook("hermes-hook", "process-exit", SEANCE_SURFACE_ID="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.requests[0]["params"],
                         {"workspace_id": 42, "key": "hermes"})

    def test_session_end_still_clears_for_other_agents(self):
        # Contrast: agents that do not fire session-end per turn clear on it.
        result = self.hook("kilo-hook", "session-end")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.requests[0]["method"], "workspace.clear_status")
        self.assertEqual(self.server.requests[0]["params"],
                         {"workspace_id": 42, "key": "kilo-7"})


if __name__ == "__main__":
    unittest.main()
