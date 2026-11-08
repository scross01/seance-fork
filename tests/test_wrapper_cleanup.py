"""Wrapper cleanup regressions."""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

WRAPPERS = {
    "kilo": ("resources/bin/kilo", "kilo", "KILO", "kilo-hook"),
    "mimo": ("resources/bin/mimo", "mimo", "MIMOCODE", "mimocode-hook"),
    "vibe": ("resources/bin/vibe", "vibe", "VIBE", "vibe-hook"),
    "pi": ("resources/bin/pi", "pi", "PI", "pi-hook"),
}


class WrapperCleanupTests(unittest.TestCase):
    def make_env(self, name, wrapper_rel, binary, prefix, hook):
        self.tmp = tempfile.TemporaryDirectory(prefix=f"seance-{name}-wrap-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.events = self.root / "events"
        self.capture = self.root / "capture.json"
        wrapper = (Path(__file__).resolve().parents[1] / wrapper_rel).resolve()
        env = {
            **os.environ,
            "PATH": f"{wrapper.parent}:{self.bin}:/usr/bin:/bin",
            "HOME": str(self.home),
            "SEANCE_SURFACE_ID": "7",
            "SEANCE_WORKSPACE_ID": "42",
            "SEANCE_SOCKET_PATH": str(self.root / "socket"),
            "TEST_CAPTURE": str(self.capture),
            "TEST_EVENTS": str(self.events),
            "TEST_PING_EXIT": "0",
        }
        hook_env = f"SEANCE_{prefix}_HOOKS_DISABLED"
        env.pop(hook_env, None)
        # fake agent binary
        self.script(self.bin / binary, f"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path(os.environ['TEST_CAPTURE']).write_text(json.dumps({{'args': sys.argv[1:]}}))
sys.exit(int(os.environ.get('TEST_EXIT', '0')))
""")
        # fake seance
        seance = self.bin / "seance"
        seance.write_text("""#!/usr/bin/env bash
if [[ "${*: -1}" == ping ]]; then
    exit "${TEST_PING_EXIT:-0}"
fi
printf '%s\\n' "$*" >> "$TEST_EVENTS"
""")
        seance.chmod(0o755)
        return env, wrapper, hook

    def script(self, path, content):
        path.write_text(content)
        path.chmod(0o755)

    def run_case(self, name, exit_code, extra_env=None):
        wrapper_rel, binary, prefix, hook = WRAPPERS[name]
        env, wrapper, hookname = self.make_env(name, wrapper_rel, binary, prefix, hook)
        env["TEST_EXIT"] = str(exit_code)
        if extra_env:
            env.update(extra_env)
        # pi session dir cleanup test: precreate marker
        inp = "" 
        proc = subprocess.run([str(wrapper), "arg1", "arg two"],
                              env=env, input=inp, capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, exit_code, (proc.stdout, proc.stderr))
        events = self.events.read_text() if self.events.exists() else ""
        self.assertIn("session-end", events, (name, events))

    def test_nonzero_exit_still_cleans(self):
        for name in WRAPPERS:
            with self.subTest(name=name):
                self.run_case(name, 7)

    def test_zero_exit_cleans(self):
        for name in WRAPPERS:
            with self.subTest(name=name):
                self.run_case(name, 0)

    def test_passthrough_no_surface(self):
        for name in WRAPPERS:
            wrapper_rel, binary, prefix, hook = WRAPPERS[name]
            env, wrapper, hookname = self.make_env(name, wrapper_rel, binary, prefix, hook)
            env.pop("SEANCE_SURFACE_ID", None)
            env["TEST_EXIT"] = "3"
            proc = subprocess.run([str(wrapper)], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(proc.returncode, 3)
            self.assertFalse(self.events.exists() and "session-end" in self.events.read_text())

    def test_disabled_hooks_passthrough(self):
        for name in WRAPPERS:
            wrapper_rel, binary, prefix, hook = WRAPPERS[name]
            env, wrapper, hookname = self.make_env(name, wrapper_rel, binary, prefix, hook)
            env[f"SEANCE_{prefix}_HOOKS_DISABLED"] = "1"
            env["TEST_EXIT"] = "4"
            proc = subprocess.run([str(wrapper)], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(proc.returncode, 4)
            self.assertFalse(self.events.exists() and "session-end" in self.events.read_text())

    def test_socket_unhealthy_passthrough(self):
        for name in WRAPPERS:
            wrapper_rel, binary, prefix, hook = WRAPPERS[name]
            env, wrapper, hookname = self.make_env(name, wrapper_rel, binary, prefix, hook)
            env["TEST_PING_EXIT"] = "1"
            env["TEST_EXIT"] = "5"
            proc = subprocess.run([str(wrapper)], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(proc.returncode, 5)
            self.assertFalse(self.events.exists() and "session-end" in self.events.read_text())

    def test_pi_removes_own_session_dir(self):
        name = "pi"
        wrapper_rel, binary, prefix, hook = WRAPPERS[name]
        env, wrapper, hookname = self.make_env(name, wrapper_rel, binary, prefix, hook)
        env["TEST_EXIT"] = "0"
        # precreate session dir
        sd = Path(env["HOME"]) / ".cache" / "seance-pi" / "7"
        sd.mkdir(parents=True, exist_ok=True)
        (sd / "marker").write_text("x")
        proc = subprocess.run([str(wrapper)], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 0)
        self.assertFalse(sd.exists())


if __name__ == "__main__":
    unittest.main()