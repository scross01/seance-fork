"""Codebuff monitor regressions: launch-owned discovery, isolation and cleanup.

The fake CLI writes a log carrying its own PID — the field production discovery
matches — and stays alive until released. A second launch shape spawns a child
that owns the log, like the npm launcher does. The fake inotifywait reports each
single-file watch and fails when that file is gone, like the real tool does.
"""
import json
import os
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

WRAPPER = Path(__file__).resolve().parents[1] / "resources/bin/codebuff"

FAKE_CODEBUFF = r'''#!/usr/bin/env python3
import json, os, subprocess, sys, time
from pathlib import Path

if "--monitor-child" not in sys.argv:
    Path(os.environ["TEST_ARGS"]).write_text(json.dumps(sys.argv[1:]))
    if os.environ.get("TEST_NESTED") == "1":
        child = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--monitor-child"],
                                 cwd=os.getcwd(), env=os.environ)
        sys.exit(child.wait())

def write_log():
    chats = Path(os.environ["HOME"]) / ".config" / "manicode" / "projects" / Path.cwd().name / "chats"
    launch = chats / os.environ.get("TEST_CHAT", "launch")
    launch.mkdir(parents=True, exist_ok=True)
    log = launch / "log.jsonl"
    log.write_text(json.dumps({"pid": os.getpid(), "msg": "launch"}, separators=(",", ":")) + "\n")
    Path(os.environ["TEST_LOGFILE"]).write_text(str(log))

if os.environ.get("TEST_NO_LOG") != "1":
    delay = float(os.environ.get("TEST_DELAY_LOG") or 0)
    if delay:
        time.sleep(delay)
    write_log()

release = Path(os.environ["TEST_RELEASE"])
while not release.exists():
    time.sleep(0.02)
code = release.read_text().strip()
sys.exit(int(code) if code else 0)
'''

FAKE_SEANCE = r'''#!/usr/bin/env python3
import json, os, sys
if sys.argv[-1] == "ping":
    sys.exit(int(os.environ.get("TEST_PING_EXIT", "0")))
event = {
    "argv": sys.argv[1:],
    "stdin": sys.stdin.read().strip(),
    "surface": os.environ.get("SEANCE_SURFACE_ID", ""),
}
with open(os.environ["TEST_EVENTS"], "a") as out:
    out.write(json.dumps(event) + "\n")
'''

FAKE_WATCHER = r'''#!/usr/bin/env python3
import os, sys, time
from pathlib import Path
logfile = sys.argv[-1]
with open(os.environ["TEST_WATCH_EVENTS"], "a") as out:
    out.write(logfile + "\n")
if not Path(logfile).exists():
    sys.exit(1)
time.sleep(float(os.environ.get("TEST_WATCH_SLEEP", "0.05")))
sys.exit(0)
'''


class Session:
    """One wrapper launch with its own surface, TMPDIR and captured events."""

    def __init__(self, case, name, surface="7", chat="launch", home=None):
        self.case = case
        self.base = case.root / name
        self.base.mkdir()
        self.home = home if home is not None else self.base / "home"
        if home is None:
            self.home.mkdir()
        self.tmpdir = self.base / "tmp"
        self.tmpdir.mkdir(mode=0o700)
        self.events_file = self.base / "events"
        self.watch_events_file = self.base / "watch-events"
        self.logfile_file = self.base / "logfile"
        self.release_file = self.base / "release"
        self.args_file = self.base / "args.json"
        self.env = {
            **os.environ,
            "PATH": f"{case.bin}:/usr/bin:/bin",
            "HOME": str(self.home),
            "TMPDIR": str(self.tmpdir),
            "SEANCE_SURFACE_ID": surface,
            "SEANCE_WORKSPACE_ID": "42",
            "SEANCE_SOCKET_PATH": str(self.base / "socket"),
            "TEST_EVENTS": str(self.events_file),
            "TEST_WATCH_EVENTS": str(self.watch_events_file),
            "TEST_LOGFILE": str(self.logfile_file),
            "TEST_RELEASE": str(self.release_file),
            "TEST_ARGS": str(self.args_file),
            "TEST_CHAT": chat,
            "TEST_PING_EXIT": "0",
        }
        self.proc = None
        case.addCleanup(self.reap)

    def start(self, extra_env=None, args=None):
        self.env = {**self.env, **(extra_env or {})}
        # A seance pane is its own process group; teardown signals the group.
        self.proc = subprocess.Popen([str(WRAPPER), *(args or [])], cwd=str(self.case.root),
                                     env=self.env, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.PIPE, text=True, start_new_session=True)
        return self.proc

    def reap(self):
        if self.proc is not None and self.proc.poll() is None:
            self.release(0)
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.close_stderr()

    def close_stderr(self):
        if self.proc is not None and self.proc.stderr is not None and not self.proc.stderr.closed:
            self.proc.stderr.close()

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
        return sorted(self.tmpdir.glob("codebuff-status-*"))

    def logfile(self):
        return Path(self.logfile_file.read_text().strip())

    def append(self, logfile, line):
        with logfile.open("a") as out:
            out.write(line + "\n")

    def leftovers(self):
        output = subprocess.run(["ps", "-eo", "pid=,args="], capture_output=True,
                                text=True, timeout=10).stdout
        return [line for line in output.splitlines() if str(self.base) in line]

    def wait_for(self, check, description, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                if check():
                    return
            except (OSError, ValueError, json.JSONDecodeError):
                pass
            time.sleep(0.05)
        self.case.fail("%s timed out\nstatuses: %r\nevents: %r\nwatched: %r\nstate: %r"
                       % (description, self.statuses(), self.events(), self.watch_events(),
                          self.state_files()))

    def wait_watching(self, timeout=15):
        self.wait_for(lambda: bool(self.watch_events()), "monitor watch phase", timeout)

    def expect_exit(self, code):
        if self.proc.poll() is None:
            self.proc.wait(timeout=10)
        self.case.assertEqual(code, self.proc.returncode, self.proc.stderr.read())
        self.close_stderr()

    def assert_cleanup(self, release=None):
        if release is not None:
            self.release(release)
        if self.proc is not None and self.proc.poll() is None:
            self.proc.wait(timeout=10)
        self.wait_for(lambda: not self.state_files(), "owned state file removal", 5)
        watched = len(self.watch_events())
        time.sleep(0.4)
        self.case.assertEqual(watched, len(self.watch_events()), "monitor watcher survived cleanup")
        deadline = time.monotonic() + 5
        leftovers = self.leftovers()
        while leftovers and time.monotonic() < deadline:
            time.sleep(0.05)
            leftovers = self.leftovers()
        self.case.assertEqual([], leftovers, "processes outlived the session")
        self.wait_for(lambda: any(e["argv"][-1:] == ["session-end"] for e in self.events()),
                      "session-end", 5)


class CodebuffMonitorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="seance-codebuff-mon-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, content in (("codebuff", FAKE_CODEBUFF), ("seance", FAKE_SEANCE),
                              ("inotifywait", FAKE_WATCHER)):
            path = self.bin / name
            path.write_text(content)
            path.chmod(0o755)

    def session(self, name, **kwargs):
        return Session(self, name, **kwargs)

    def foreign_log(self, session, chat, pid):
        """A log another process would own: same project tree, other pid."""
        chats = session.home / ".config" / "manicode" / "projects" / self.root.name / "chats"
        launch = chats / chat
        launch.mkdir(parents=True, exist_ok=True)
        log = launch / "log.jsonl"
        log.write_text(json.dumps({"pid": pid, "msg": "other"}, separators=(",", ":")) + "\n")
        return log

    # ── Pass-through behavior ──────────────────────────────────────────

    def test_passthrough_without_surface(self):
        s = self.session("no-surface")
        env = dict(s.env)
        env.pop("SEANCE_SURFACE_ID")
        s.env = env
        s.start()
        s.release(9)
        s.expect_exit(9)
        self.assertEqual([], s.events())

    def test_disabled_passthrough(self):
        s = self.session("disabled")
        s.start({"SEANCE_CODEBUFF_HOOKS_DISABLED": "1"})
        s.release(6)
        s.expect_exit(6)
        self.assertEqual([], s.events())
        self.assertEqual([], s.state_files())

    def test_socket_unhealthy_passthrough(self):
        s = self.session("unhealthy")
        s.start({"TEST_PING_EXIT": "1"})
        s.release(5)
        s.expect_exit(5)
        self.assertEqual([], s.events())
        self.assertEqual([], s.state_files())

    # ── Launch-owned discovery ─────────────────────────────────────────

    def test_arguments_forwarded_to_cli(self):
        s = self.session("args")
        s.start(args=["arg1", "two words"])
        s.wait_for(lambda: s.statuses() == ["Running"], "published Running")
        s.wait_for(s.args_file.exists, "fake CLI launch")
        self.assertEqual(["arg1", "two words"], json.loads(s.args_file.read_text()))
        s.release(0)
        s.expect_exit(0)
        s.assert_cleanup()

    def test_watches_only_the_launch_owned_log(self):
        s = self.session("owned")
        foreign = self.foreign_log(s, "other-session", pid=999999)
        s.start()
        s.wait_watching()
        watched = set(s.watch_events())
        self.assertEqual({str(s.logfile())}, watched)
        self.assertNotIn(str(foreign), watched)
        self.assertNotEqual(999999, json.loads(s.logfile().read_text().splitlines()[0])["pid"])

    def test_nested_launch_discovers_child_log(self):
        s = self.session("nested")
        s.start({"TEST_NESTED": "1"})
        s.wait_watching()
        owned = json.loads(s.logfile().read_text().splitlines()[0])
        self.assertNotIn(owned["pid"], (0,), "log must record a real pid")
        self.assertEqual({str(s.logfile())}, set(s.watch_events()))
        s.release(0)
        s.expect_exit(0)
        s.assert_cleanup()

    def test_delayed_log_is_discovered(self):
        s = self.session("delayed")
        s.start({"TEST_DELAY_LOG": "2"})
        s.wait_watching()
        self.assertEqual({str(s.logfile())}, set(s.watch_events()))
        s.release(0)
        s.expect_exit(0)
        s.assert_cleanup()

    def test_vanished_log_rediscovers_once(self):
        s = self.session("rediscover")
        s.start()
        s.wait_watching()
        first = s.logfile()
        pid = json.loads(first.read_text().splitlines()[0])["pid"]
        second = first.parent.parent / "second" / "log.jsonl"
        second.parent.mkdir()
        second.write_text(json.dumps({"pid": pid, "msg": "relaunch"}, separators=(",", ":")) + "\n")
        first.unlink()
        s.wait_for(lambda: str(second) in s.watch_events(), "rediscovered log", 10)
        s.release(0)
        s.expect_exit(0)
        s.assert_cleanup()

    def test_missing_ownership_signal_falls_back_without_watching(self):
        s = self.session("no-owner")
        foreign = self.foreign_log(s, "someone-else", pid=999998)
        s.start({"TEST_NO_LOG": "1"})
        s.wait_for(lambda: s.statuses() == ["Running"], "published Running")
        s.wait_for(lambda: s.statuses() == ["Running", "Idle"], "fallback Idle", 40)
        self.assertEqual([], s.watch_events(), "no ownership signal means no attribution")
        self.assertTrue(foreign.exists(), "the newest foreign log is not adopted")
        s.wait_for(lambda: not s.state_files(), "state file removal", 5)
        s.release(0)
        s.expect_exit(0)
        s.assert_cleanup()

    # ── Status transitions ─────────────────────────────────────────────

    def test_silent_session_reconciles_running_to_idle(self):
        s = self.session("silent")
        s.start()
        s.wait_for(lambda: s.statuses() == ["Running"], "published Running")
        s.wait_watching()
        s.wait_for(lambda: "Idle" in s.statuses(), "reconciled Idle", 15)
        self.assertEqual(["Running", "Idle"], s.statuses())
        self.assertEqual(1, len(s.state_files()), "monitor owns one state file")
        time.sleep(1.0)
        self.assertEqual(["Running", "Idle"], s.statuses())
        s.release(0)
        s.expect_exit(0)
        s.assert_cleanup()

    def test_owned_log_write_reports_running(self):
        s = self.session("activity")
        s.start()
        s.wait_for(lambda: s.statuses() == ["Running"], "published Running")
        s.wait_watching()
        s.wait_for(lambda: "Idle" in s.statuses(), "reconciled Idle", 15)
        s.append(s.logfile(), json.dumps({"msg": "agent step"}))
        s.wait_for(lambda: s.statuses()[-1:] == ["Running"], "activity Running", 5)
        self.assertEqual(["Running", "Idle", "Running"], s.statuses())

    def test_unrelated_session_write_is_ignored(self):
        s = self.session("isolated")
        foreign = self.foreign_log(s, "another-session", pid=999997)
        s.start()
        s.wait_for(lambda: s.statuses() == ["Running"], "published Running")
        s.wait_watching()
        s.wait_for(lambda: "Idle" in s.statuses(), "reconciled Idle", 15)
        s.append(foreign, json.dumps({"msg": "their work"}))
        time.sleep(1.0)
        self.assertEqual(["Running", "Idle"], s.statuses(),
                         "another session's log must not mark this pane Running")

    def test_concurrent_sessions_same_project_stay_isolated(self):
        home = self.root / "shared-home"
        home.mkdir()
        a = self.session("session-a", surface="11", chat="chat-a", home=home)
        b = self.session("session-b", surface="12", chat="chat-b", home=home)
        a.start()
        b.start()
        a.wait_watching()
        b.wait_watching()
        third = self.foreign_log(a, "chat-third", pid=999996)
        self.assertNotEqual(a.logfile(), b.logfile())
        a.wait_for(lambda: "Idle" in a.statuses(), "a reconciled Idle", 15)
        b.wait_for(lambda: "Idle" in b.statuses(), "b reconciled Idle", 15)

        a.append(a.logfile(), json.dumps({"msg": "a step"}))
        a.wait_for(lambda: a.statuses()[-1:] == ["Running"], "a Running", 5)
        time.sleep(0.6)
        self.assertEqual(["Running", "Idle"], b.statuses(), "b saw a's activity")

        a.append(third, json.dumps({"msg": "third-party step"}))
        time.sleep(0.6)
        self.assertEqual(["Running", "Idle", "Running"], a.statuses())
        self.assertEqual(["Running", "Idle"], b.statuses())

        b.append(b.logfile(), json.dumps({"msg": "b step"}))
        b.wait_for(lambda: b.statuses()[-1:] == ["Running"], "b Running", 5)
        self.assertEqual(["Running", "Idle", "Running"], a.statuses())

        for s in (a, b):
            s.release(0)
            s.expect_exit(0)
            s.assert_cleanup()

    # ── Exit and teardown cleanup ──────────────────────────────────────

    def test_nonzero_exit_preserves_code_and_cleans(self):
        s = self.session("exit-7")
        s.start()
        s.wait_for(lambda: s.statuses() == ["Running"], "published Running")
        s.wait_watching()
        s.release(7)
        s.expect_exit(7)
        s.assert_cleanup()

    def test_hup_cleans_monitor_and_state(self):
        s = self.session("hup")
        s.start()
        s.wait_for(lambda: s.statuses() == ["Running"], "published Running")
        s.wait_watching()
        self.assertEqual(1, len(s.state_files()), "monitor owns one state file")
        # Pane teardown HUP reaches the wrapper and its CLI together.
        os.killpg(os.getpgid(s.proc.pid), signal.SIGHUP)
        s.expect_exit(129)
        s.assert_cleanup()


if __name__ == "__main__":
    unittest.main()
