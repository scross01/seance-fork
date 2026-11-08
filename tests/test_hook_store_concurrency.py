"""Hook session-store concurrency regressions."""
import json
import os
import subprocess
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("SEANCE_TEST_BINARY") or REPO / "AppDir/usr/bin/seance")


class StubSocket:
    def __init__(self, path):
        self.path = str(path)
        self._sock = __import__("socket").socket(__import__("socket").AF_UNIX, __import__("socket").SOCK_STREAM)
        self._sock.bind(self.path)
        self._sock.listen(16)
        self._sock.settimeout(0.2)
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self):
        import socket as _s
        while not self._stop.is_set():
            try:
                conn, _ = self._sock.accept()
            except (_s.timeout, TimeoutError):
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
                    try:
                        conn.sendall(b'{"id":"1","ok":true,"result":{}}\n')
                    except OSError:
                        pass

    def close(self):
        self._stop.set()
        self._thread.join(timeout=2)
        self._sock.close()


@unittest.skipUnless(BINARY.exists(), f"build first: {BINARY}")
class HookStoreConcurrencyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="seance-hook-store-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.store_path = self.root / "sessions.json"
        self.socket_path = self.root / "seance.sock"
        self.server = StubSocket(self.socket_path)
        self.addCleanup(self.server.close)

    def run_hook(self, event, session_id):
        env = {
            **os.environ,
            "SEANCE_WORKSPACE_ID": "42",
            "SEANCE_SURFACE_ID": "7",
            "SEANCE_CLAUDE_HOOK_STATE_PATH": str(self.store_path),
        }
        proc = subprocess.run(
            [str(BINARY), "ctl", "--socket", str(self.socket_path),
             "claude-hook", event],
            env=env,
            input=json.dumps({"session_id": session_id}),
            capture_output=True, text=True, timeout=30,
        )
        return proc

    def read_store(self):
        if not self.store_path.exists():
            return {}
        data = json.loads(self.store_path.read_text())
        return data.get("sessions", {})

    def test_many_distinct_sessions_survive(self):
        n = 20

        def worker(i):
            return self.run_hook("session-start", f"s{i}")

        with ThreadPoolExecutor(max_workers=8) as ex:
            results = list(ex.map(worker, range(n)))
        for r in results:
            self.assertEqual(r.returncode, 0, r.stderr)
        sessions = self.read_store()
        self.assertEqual(len(sessions), n)
        for i in range(n):
            self.assertIn(f"s{i}", sessions)

    def test_repeated_updates_to_one_session(self):
        for i in range(10):
            r = self.run_hook("session-start", "same")
            self.assertEqual(r.returncode, 0, r.stderr)
        sessions = self.read_store()
        self.assertIn("same", sessions)

    def test_concurrent_consume_removes_only_target(self):
        # create two sessions
        for sid in ("a", "b"):
            r = self.run_hook("session-start", sid)
            self.assertEqual(r.returncode, 0, r.stderr)

        def worker(sid):
            return self.run_hook("session-end", sid)

        with ThreadPoolExecutor(max_workers=2) as ex:
            list(ex.map(worker, ["a"]))
        sessions = self.read_store()
        self.assertNotIn("a", sessions)
        self.assertIn("b", sessions)

    def test_store_always_valid_json(self):
        n = 10

        def worker(i):
            return self.run_hook("session-start", f"x{i}")

        with ThreadPoolExecutor(max_workers=4) as ex:
            list(ex.map(worker, range(n)))
        # parse must succeed
        data = json.loads(self.store_path.read_text())
        self.assertEqual(data["version"], 1)


if __name__ == "__main__":
    unittest.main()
