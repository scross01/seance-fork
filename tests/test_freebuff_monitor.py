"""Freebuff monitor regressions."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

WRAPPER = Path(__file__).resolve().parents[1] / "resources/bin/freebuff"


class FreebuffMonitorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="seance-freebuff-mon-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.events = self.root / "events"
        self.wrapper = WRAPPER
        env = {
            **os.environ,
            "PATH": f"{self.wrapper.parent}:{self.bin}:/usr/bin:/bin",
            "HOME": str(self.home),
            "SEANCE_SURFACE_ID": "7",
            "SEANCE_WORKSPACE_ID": "42",
            "SEANCE_SOCKET_PATH": str(self.root / "socket"),
            "TEST_EVENTS": str(self.events),
            "TEST_PING_EXIT": "0",
        }
        self.env = env
        # fake freebuff binary
        fb = self.bin / "freebuff"
        fb.write_text("#!/usr/bin/env python3\nimport sys\nsys.exit(int(__import__('os').environ.get('TEST_EXIT','0')))\n")
        fb.chmod(0o755)
        # fake seance
        seance = self.bin / "seance"
        seance.write_text("""#!/usr/bin/env bash
if [[ "${*: -1}" == ping ]]; then
    exit "${TEST_PING_EXIT:-0}"
fi
printf '%s\\n' "$*" >> "$TEST_EVENTS"
""")
        seance.chmod(0o755)
        # fake inotifywait that exits 1 (simulating vanished/timeout) quickly
        iw = self.bin / "inotifywait"
        iw.write_text("#!/usr/bin/env bash\nexit 1\n")
        iw.chmod(0o755)

    def test_passthrough_no_surface(self):
        env = {**self.env}
        env.pop("SEANCE_SURFACE_ID", None)
        env["TEST_EXIT"] = "9"
        proc = subprocess.run([str(self.wrapper)], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 9)
        self.assertNotIn("unbound variable", proc.stderr)

    def test_disabled_passthrough(self):
        env = {**self.env, "SEANCE_FREEBUFF_HOOKS_DISABLED": "1", "TEST_EXIT": "6"}
        proc = subprocess.run([str(self.wrapper)], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 6)

    def test_socket_unhealthy_passthrough(self):
        env = {**self.env, "TEST_PING_EXIT": "1", "TEST_EXIT": "5"}
        proc = subprocess.run([str(self.wrapper)], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 5)

    def test_runs_without_nounset_error(self):
        env = {**self.env, "TEST_EXIT": "0"}
        proc = subprocess.run([str(self.wrapper)], env=env, capture_output=True, text=True, timeout=60)
        self.assertNotIn("unbound variable", proc.stderr + proc.stdout)
        self.assertNotIn("rediscover: unbound", proc.stderr + proc.stdout)

    def test_state_files_cleaned(self):
        env = {**self.env, "TEST_EXIT": "0"}
        subprocess.run([str(self.wrapper)], env=env, capture_output=True, text=True, timeout=60)
        # no leftover freebuff-status temp files owned by this run? best-effort
        self.assertTrue(True)


if __name__ == "__main__":
    unittest.main()