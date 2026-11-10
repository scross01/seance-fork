"""Freebuff monitor regressions: published state, transitions and owned cleanup.

The fake CLI writes a launch-owned log carrying its own PID (the same field
production discovery matches), stays alive until released, and lets the test
append markers at controlled moments. The fake inotifywait reports wakes and
fails when the watched log is gone, like the real tool does.
"""
import json
import os
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

WRAPPER = Path(__file__).resolve().parents[1] / "resources/bin/freebuff"

FAKE_FREEBUFF = """#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path

Path(os.environ["TEST_ARGS"]).write_text(json.dumps(sys.argv[1:]))
if os.environ.get("TEST_NO_LOG") != "1":
    project = Path(os.environ["HOME"]) / ".config" / "manicode" / "projects" / Path.cwd().name / "chats"
    launch = project / os.environ.get("TEST_CHAT", "launch")
    launch.mkdir(parents=True, exist_ok=True)
    log = launch / "log.jsonl"
    log.write_text(json.dumps({"pid": os.getpid(), "msg": "launch"}, separators=(",", ":")) + "\\n")
    Path(os.environ["TEST_LOGFILE"]).write_text(str(log))

release = Path(os.environ["TEST_RELEASE"])
while not release.exists():
    time.sleep(0.02)
code = release.read_text().strip()
sys.exit(int(code) if code else 0)
"""

FAKE_SEANCE = """#!/usr/bin/env python3
import json, os, sys
if sys.argv[-1] == "ping":
    sys.exit(int(os.environ.get("TEST_PING_EXIT", "0")))
event = {
    "argv": sys.argv[1:],
    "stdin": sys.stdin.read().strip(),
    "surface": os.environ.get("SEANCE_SURFACE_ID", ""),
}
with open(os.environ["TEST_EVENTS"], "a") as out:
    out.write(json.dumps(event) + "\\n")
"""

FAKE_WATCHER = """#!/usr/bin/env python3
import os, sys, time
from pathlib import Path
logfile = sys.argv[-1]
with open(os.environ["TEST_WATCH_EVENTS"], "a") as out:
    out.write(logfile + "\\n")
if not Path(logfile).exists():
    sys.exit(1)
time.sleep(float(os.environ.get("TEST_WATCH_SLEEP", "0.05")))
sys.exit(0)
"""


class FreebuffMonitorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="seance-freebuff-mon-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.tmpdir = self.root / "tmp"
        self.tmpdir.mkdir(mode=0o700)
        self.events_file = self.root / "events"
        self.watch_events_file = self.root / "watch-events"
        self.logfile_file = self.root / "logfile"
        self.release_file = self.root / "release"
        self.args_file = self.root / "args.json"
        self.wrapper = WRAPPER
        env = {
            **os.environ,
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.home),
            "TMPDIR": str(self.tmpdir),
            "SEANCE_SURFACE_ID": "7",
            "SEANCE_WORKSPACE_ID": "42",
            "SEANCE_SOCKET_PATH": str(self.root / "socket"),
            "TEST_EVENTS": str(self.events_file),
            "TEST_WATCH_EVENTS": str(self.watch_events_file),
            "TEST_LOGFILE": str(self.logfile_file),
            "TEST_RELEASE": str(self.release_file),
            "TEST_ARGS": str(self.args_file),
            "TEST_PING_EXIT": "0",
        }
        env.pop("MANICODE_DIR", None)
        self.env = env
        self.script(self.bin / "freebuff", FAKE_FREEBUFF)
        self.script(self.bin / "seance", FAKE_SEANCE)
        self.script(self.bin / "inotifywait", FAKE_WATCHER)
        self.proc = None

    @staticmethod
    def script(path, content):
        path.write_text(content)
        path.chmod(0o755)

    def start(self, extra_env=None, args=None):
        env = {**self.env, **(extra_env or {})}
        # A seance pane is its own process group; teardown signals the group.
        self.proc = subprocess.Popen([str(self.wrapper), *(args or [])], cwd=str(self.root), env=env,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
                                     start_new_session=True)
        self.addCleanup(self.reap)
        return self.proc

    def reap(self):
        if self.proc is not None and self.proc.poll() is None:
            self.release(0)
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()

    def release(self, code):
        self.release_file.write_text(str(code))

    def events(self):
        try:
            text = self.events_file.read_text()
        except FileNotFoundError:
            return []
        parsed = []
        for line in text.splitlines():
            try:
                parsed.append(json.loads(line))
            except json.JSONDecodeError:
                continue  # a line still being appended
        return parsed

    def watch_events(self):
        try:
            return self.watch_events_file.read_text().splitlines()
        except FileNotFoundError:
            return []

    def statuses(self):
        result = []
        for event in self.events():
            if event["argv"][-1:] != ["prompt-submit"]:
                continue
            try:
                result.append(json.loads(event["stdin"] or "{}").get("status", "Running"))
            except json.JSONDecodeError:
                result.append("<unparsable>")
        return result

    def state_files(self):
        return sorted(self.tmpdir.glob("freebuff-status-*"))

    def logfile(self):
        return Path(self.logfile_file.read_text().strip())

    def append(self, logfile, line):
        with logfile.open("a") as out:
            out.write(line + "\n")

    def leftovers(self):
        output = subprocess.run(["ps", "-eo", "pid=,args="], capture_output=True,
                                text=True, timeout=10).stdout
        return [line for line in output.splitlines() if str(self.root) in line]

    def wait_for(self, check, description, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                if check():
                    return
            except (OSError, ValueError, json.JSONDecodeError):
                pass
            time.sleep(0.05)
        self.fail("%s timed out\nstatuses: %r\nevents: %r\nwatched: %r\nstate: %r"
                  % (description, self.statuses(), self.events(), self.watch_events(),
                     self.state_files()))

    def wait_watching(self, timeout=15):
        self.wait_for(lambda: bool(self.watch_events()), "monitor watch phase", timeout)

    def assert_session_end(self):
        self.wait_for(lambda: any(e["argv"][-1:] == ["session-end"] for e in self.events()),
                      "session-end", 5)

    def assert_cleanup(self, release=None):
        if release is not None:
            self.release(release)
        if self.proc is not None and self.proc.poll() is None:
            self.proc.wait(timeout=10)
        self.wait_for(lambda: not self.state_files(), "owned state file removal", 5)
        watched = len(self.watch_events())
        time.sleep(0.4)
        self.assertEqual(watched, len(self.watch_events()), "monitor watcher survived cleanup")
        deadline = time.monotonic() + 5
        leftovers = self.leftovers()
        while leftovers and time.monotonic() < deadline:
            time.sleep(0.05)
            leftovers = self.leftovers()
        self.assertEqual([], leftovers, "processes outlived the session")
        self.assert_session_end()

    # ── Pass-through behavior ──────────────────────────────────────────

    def test_passthrough_no_surface(self):
        env = dict(self.env)
        env.pop("SEANCE_SURFACE_ID", None)
        self.env = env
        self.start()
        self.release(9)
        self.assertEqual(9, self.proc.wait(timeout=10))
        self.assertEqual([], self.events())

    def test_disabled_passthrough(self):
        self.start({"SEANCE_FREEBUFF_HOOKS_DISABLED": "1"})
        self.release(6)
        self.assertEqual(6, self.proc.wait(timeout=10))
        self.assertEqual([], self.events())
        self.assertEqual([], self.state_files())

    def test_socket_unhealthy_passthrough(self):
        self.start({"TEST_PING_EXIT": "1"})
        self.release(5)
        self.assertEqual(5, self.proc.wait(timeout=10))
        self.assertEqual([], self.events())
        self.assertEqual([], self.state_files())

    # ── State reconciliation ───────────────────────────────────────────

    def test_silent_session_reconciles_running_to_idle(self):
        self.start()
        self.wait_for(lambda: self.statuses() == ["Running"], "published Running")
        self.wait_watching()
        self.wait_for(lambda: "Idle" in self.statuses(), "reconciled Idle", 15)
        self.assertEqual(["Running", "Idle"], self.statuses())
        self.assertEqual(1, len(self.state_files()), "monitor owns one state file")
        # A silent repeat must not duplicate the idle transition.
        time.sleep(1.0)
        self.assertEqual(["Running", "Idle"], self.statuses())
        self.release(0)
        self.assertEqual(0, self.proc.wait(timeout=10))
        self.assert_cleanup()

    def test_completion_as_first_marker_reconciles_idle(self):
        self.start()
        self.wait_for(lambda: self.statuses() == ["Running"], "published Running")
        self.wait_watching()
        self.append(self.logfile(), "[chat-runtime] Freebuff session over")
        self.wait_for(lambda: self.statuses() == ["Running", "Idle"], "idle completion", 10)

    def test_reconciled_idle_reports_running_after_activity_then_completion(self):
        self.start()
        self.wait_for(lambda: self.statuses() == ["Running"], "published Running")
        self.wait_watching()
        self.wait_for(lambda: "Idle" in self.statuses(), "reconciled Idle", 15)
        logfile = self.logfile()
        self.append(logfile, "Start agent main")
        self.wait_for(lambda: self.statuses()[-1:] == ["Running"], "activity Running", 5)
        self.append(logfile, "[chat-runtime] Freebuff session over")
        self.wait_for(lambda: self.statuses() == ["Running", "Idle", "Running", "Idle"],
                      "activity then completion", 5)

    def test_unrelated_debug_writes_do_not_report_activity(self):
        self.start()
        self.wait_for(lambda: self.statuses() == ["Running"], "published Running")
        self.wait_watching()
        self.append(self.logfile(), "debug: telemetry heartbeat")
        time.sleep(1.0)
        self.assertEqual(["Running"], self.statuses(),
                         "non-marker writes are not agent activity")

    def test_vanished_log_rediscovers_once(self):
        self.start()
        self.wait_for(lambda: self.statuses() == ["Running"], "published Running")
        self.wait_watching()
        first = self.logfile()
        pid = json.loads(first.read_text().splitlines()[0])["pid"]
        second = first.parent.parent / "second" / "log.jsonl"
        second.parent.mkdir()
        second.write_text(json.dumps({"pid": pid, "msg": "relaunch"}, separators=(",", ":")) + "\n")
        first.unlink()
        self.wait_for(lambda: str(second) in self.watch_events(), "rediscovered log", 10)
        self.append(second, "[chat-runtime] Freebuff session over")
        self.wait_for(lambda: "Idle" in self.statuses(), "idle after rediscovery", 10)

    def test_failed_discovery_reports_idle_once(self):
        self.start({"TEST_NO_LOG": "1"})
        self.wait_for(lambda: self.statuses() == ["Running"], "published Running")
        self.wait_for(lambda: self.statuses() == ["Running", "Idle"], "discovery idle", 40)
        self.assertEqual([], self.watch_events(), "no watch phase without a log")
        self.wait_for(lambda: not self.state_files(), "state file removal", 5)
        self.release(0)
        self.assertEqual(0, self.proc.wait(timeout=10))
        self.assert_cleanup()

    # ── Exit and teardown cleanup ──────────────────────────────────────

    def test_arguments_forwarded_to_cli(self):
        self.start(args=["arg1", "two words"])
        self.wait_for(lambda: self.statuses() == ["Running"], "published Running")
        self.wait_for(self.args_file.exists, "fake CLI launch")
        self.assertEqual(["arg1", "two words"], json.loads(self.args_file.read_text()))
        self.release(0)
        self.assertEqual(0, self.proc.wait(timeout=10))
        self.assert_cleanup()

    def test_normal_exit_preserves_code_and_cleans(self):
        self.start()
        self.wait_for(lambda: self.statuses() == ["Running"], "published Running")
        self.wait_watching()
        self.release(0)
        self.assertEqual(0, self.proc.wait(timeout=10))
        self.assert_cleanup()

    def test_nonzero_exit_preserves_code_and_cleans(self):
        self.start()
        self.wait_for(lambda: self.statuses() == ["Running"], "published Running")
        self.wait_watching()
        self.release(7)
        self.assertEqual(7, self.proc.wait(timeout=10))
        self.assert_cleanup()

    def test_hup_cleans_monitor_and_state(self):
        self.start()
        self.wait_for(lambda: self.statuses() == ["Running"], "published Running")
        self.wait_watching()
        self.assertEqual(1, len(self.state_files()), "monitor owns one state file")
        # Pane teardown HUP reaches the wrapper and its CLI together.
        os.killpg(os.getpgid(self.proc.pid), signal.SIGHUP)
        self.assertEqual(129, self.proc.wait(timeout=10))
        self.assert_cleanup()


if __name__ == "__main__":
    unittest.main()
