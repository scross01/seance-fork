"""Runtime socket ownership regressions. Run under Xvfb with SEANCE_TEST_BINARY set."""
import json
import os
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

from test_ghostty_integration import GhosttyTestCase

BINARY = os.environ.get("SEANCE_TEST_BINARY")


class RuntimeSocketOwnershipTests(GhosttyTestCase):
    def test_graceful_stop_removes_owned_socket(self):
        path = Path(self.socket_path)
        self.assertTrue(path.exists(), "startup must create the socket")
        self.assertEqual(0o600, stat.S_IMODE(os.lstat(path).st_mode),
                         "socket must stay owner-only")
        self.assertEqual(0o700, stat.S_IMODE(os.lstat(path.parent).st_mode),
                         "runtime directory must stay owner-only")
        self.assertEqual({"pong": True}, self.call("system.ping"))

        self.stop()

        self.assertEqual(0, self.process.returncode)
        self.assertFalse(path.exists(), "graceful stop must remove the socket it bound")

    def test_replacement_at_socket_path_survives_shutdown(self):
        path = Path(self.socket_path)
        self.assertTrue(path.exists())
        path.unlink()
        path.write_text("test-owned replacement")

        self.stop()

        self.assertEqual(0, self.process.returncode)
        self.assertEqual("test-owned replacement", path.read_text(),
                         "cleanup removed a path this instance no longer owns")

    def test_second_instance_leaves_live_endpoint_intact(self):
        path = Path(self.socket_path)
        before = os.lstat(path)
        second = subprocess.Popen([self.binary], env=self.env, cwd=self.root,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(1.5)
            after = os.lstat(path)
            self.assertEqual((before.st_dev, before.st_ino), (after.st_dev, after.st_ino),
                             "a second startup replaced the live socket pathname")
            self.assertEqual({"pong": True}, self.call("system.ping"),
                             "the original owner must keep serving its endpoint")
        finally:
            if second.poll() is None:
                second.terminate()
                try:
                    second.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    second.kill()
                    second.wait()


@unittest.skipUnless(BINARY, "set SEANCE_TEST_BINARY for GUI validation")
class OverlongSocketPathTests(unittest.TestCase):
    def test_overlong_socket_path_is_rejected_without_a_truncated_endpoint(self):
        with tempfile.TemporaryDirectory(prefix="seance-long-socket-") as tmp:
            root = Path(tmp)
            for name in ("home", "config", "cache", "run"):
                (root / name).mkdir(mode=0o700)
            long_path = root / ("s" * 160)
            self.assertGreater(len(str(long_path)), 108)

            config = root / "config" / "seance"
            config.mkdir()
            (config / "config.toml").write_text(
                "[socket]\npath = " + json.dumps(str(long_path)) +
                "\n[behavior]\nconfirm-close-window = false\n")
            ghostty = root / "config" / "ghostty"
            ghostty.mkdir()
            (ghostty / "config").write_text("command = /bin/bash --noprofile --norc\n")

            env = os.environ.copy()
            env.update(HOME=str(root / "home"), XDG_CONFIG_HOME=str(root / "config"),
                       XDG_CACHE_HOME=str(root / "cache"), XDG_RUNTIME_DIR=str(root / "run"),
                       GDK_BACKEND="x11", DBUS_SESSION_BUS_ADDRESS="disabled:",
                       LIBGL_ALWAYS_SOFTWARE="1", NO_AT_BRIDGE="1", SHELL="/bin/bash")
            env.pop("SEANCE_DISABLE_SESSION_RESTORE", None)

            process = subprocess.Popen([str(Path(BINARY).resolve())], env=env, cwd=root,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                time.sleep(2)
                self.assertFalse(long_path.exists(), "bound an unreachable full-length path")
                self.assertFalse(Path(str(long_path)[:107]).exists(),
                                 "bound a truncated socket endpoint")
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


if __name__ == "__main__":
    unittest.main()
