"""Hermes plugin host-process isolation and emission behavior.

Run with: python3 -B -m unittest discover -s tests -p 'test_hermes_plugin.py' -v

The bundled plugin is loaded by file location inside a child interpreter so
its import-time behavior can never mutate this test runner. A fake `seance`
executable early on PATH records argv/stdin so payloads, ordering, reaping
and bounding can be asserted without model calls.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
PLUGIN_PATH = REPO / "resources" / "hermes-plugin" / "__init__.py"

FAKE_SEANCE = r'''#!/usr/bin/env python3
import json, os, sys, time
event = sys.argv[3] if len(sys.argv) > 3 else ""
mode = os.environ.get("FAKE_SEANCE_MODE", "record")
log = os.environ["FAKE_SEANCE_LOG"]
if mode == "exit-fast":
    with open(log, "a") as f:
        f.write(json.dumps({"event": event, "payload": None,
                            "pid": os.getpid(), "mode": "exit-fast"}) + "\n")
    sys.exit(0)
payload = sys.stdin.read()
rec = {"event": event, "pid": os.getpid(),
       "payload": json.loads(payload) if payload else None}
with open(log, "a") as f:
    f.write(json.dumps(rec) + "\n")
slow_events = [s for s in os.environ.get("FAKE_SEANCE_SLOW_EVENTS", "").split(",") if s]
if mode == "slow" or event in slow_events:
    time.sleep(float(os.environ.get("FAKE_SEANCE_SLEEP", "30")))
sys.exit(int(os.environ.get("FAKE_SEANCE_EXIT", "0")))
'''

# Runs inside the child interpreter: imports the plugin by path, then
# reports signal-handler identity, an unrelated child's exit code and the
# requested emission case as JSON on stdout.
DRIVER = r'''
import importlib.util, json, os, signal, subprocess, sys, time

PLUGIN = os.environ["SEANCE_PLUGIN_PATH"]
LOG = os.environ["FAKE_SEANCE_LOG"]
CASE = os.environ["HERMES_CASE"]


def custom_handler(signum, frame):
    pass


signal.signal(signal.SIGCHLD, custom_handler)
before = signal.getsignal(signal.SIGCHLD)

spec = importlib.util.spec_from_file_location("seance_hermes_plugin", PLUGIN)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

results = {"handler_preserved": signal.getsignal(signal.SIGCHLD) is before}

# An unrelated child must keep its real exit status after the import.
try:
    r = subprocess.run([sys.executable, "-c", "import sys; sys.exit(7)"],
                       capture_output=True, timeout=10)
    results["exit7"] = r.returncode
except Exception as exc:
    results["exit7"] = "raised:%s" % type(exc).__name__


class Ctx:
    def __init__(self):
        self.hooks = {}

    def register_hook(self, name, fn):
        self.hooks[name] = fn


ctx = Ctx()
mod.register(ctx)


def records():
    if not os.path.exists(LOG):
        return []
    out = []
    with open(LOG) as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def flush(timeout):
    fn = getattr(mod, "_flush", None)
    if fn is not None:
        fn(timeout)
    else:
        # Old plugin: payload writes are synchronous on the caller thread.
        time.sleep(1.0)


def reaped(pid):
    try:
        os.waitpid(pid, os.WNOHANG)
        return False  # still running, or a zombie only we just reaped
    except ChildProcessError:
        return True  # already waited by the plugin's owner


if CASE == "signal":
    flush(2.0)
elif CASE == "signal-disabled":
    ctx.hooks["on_session_start"](session_id="ignored")
    ctx.hooks["pre_llm_call"](session_id="ignored")
    flush(2.0)
    results["records"] = records()
elif CASE == "payload":
    ctx.hooks["on_session_start"](session_id="sess-1")
    flush(5.0)
    results["records"] = records()
elif CASE == "order":
    for i in range(5):
        ctx.hooks["on_session_start"](session_id="sess-%d" % i)
    flush(5.0)
    results["records"] = records()
elif CASE == "slow":
    mod._CHILD_TIMEOUT = 0.5
    start = time.monotonic()
    ctx.hooks["on_session_start"](session_id="slow")
    flush(10.0)
    results["elapsed"] = time.monotonic() - start
    recs = records()
    results["records"] = recs
    results["reaped"] = [reaped(r["pid"]) for r in recs]
elif CASE == "oversized":
    ctx.hooks["post_llm_call"](session_id="big",
                               assistant_response="x" * (2 * 1024 * 1024))
    flush(3.0)
    results["records"] = records()
elif CASE == "broken-pipe":
    ctx.hooks["on_session_start"](session_id="gone")
    flush(5.0)
    results["records"] = records()
elif CASE == "bounded-queue":
    mod._CHILD_TIMEOUT = 10.0
    ctx.hooks["on_session_start"](session_id="first")
    time.sleep(0.4)  # worker is now blocked inside the slow child
    for i in range(200):
        ctx.hooks["pre_llm_call"](session_id="flood-%d" % i)
    flush(30.0)
    results["records"] = records()
else:
    raise SystemExit("unknown case %r" % CASE)

print(json.dumps(results))
'''


class HermesPluginTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="seance-hermes-plugin-")
        cls.root = Path(cls.tmp.name)
        cls.fake_bin = cls.root / "bin"
        cls.fake_bin.mkdir()
        fake = cls.fake_bin / "seance"
        fake.write_text(FAKE_SEANCE)
        fake.chmod(0o755)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_case(self, case, env_extra=None, timeout=40):
        log = self.root / ("log-%s-%d.txt" % (case, id(self)))
        if log.exists():
            log.unlink()
        env = dict(os.environ)
        env.update({
            "PATH": str(self.fake_bin) + os.pathsep + env.get("PATH", ""),
            "SEANCE_PLUGIN_PATH": str(PLUGIN_PATH),
            "FAKE_SEANCE_LOG": str(log),
            "HERMES_CASE": case,
            "SEANCE_SURFACE_ID": "7",
            "SEANCE_WORKSPACE_ID": "42",
        })
        env.pop("SEANCE_HERMES_HOOKS_DISABLED", None)
        if env_extra:
            env.update(env_extra)
        proc = subprocess.run([sys.executable, "-B", "-c", DRIVER],
                              env=env, capture_output=True, text=True,
                              timeout=timeout)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return json.loads(proc.stdout)

    # --- host signal isolation (characterization) ---

    def test_import_preserves_custom_sigchld_handler(self):
        for extra in (None, {"SEANCE_HERMES_HOOKS_DISABLED": "1"}):
            with self.subTest(disabled=bool(extra)):
                results = self.run_case("signal", extra)
                self.assertTrue(results["handler_preserved"],
                                "plugin replaced the host SIGCHLD handler")

    def test_unrelated_child_exit_code_preserved(self):
        for extra in (None, {"SEANCE_HERMES_HOOKS_DISABLED": "1"}):
            with self.subTest(disabled=bool(extra)):
                results = self.run_case("signal", extra)
                self.assertEqual(results["exit7"], 7,
                                 "unrelated child exit status changed")

    # --- emission behavior ---

    def test_payload_reaches_bridge_with_ids(self):
        results = self.run_case("payload")
        recs = results["records"]
        self.assertEqual(len(recs), 1, recs)
        self.assertEqual(recs[0]["event"], "session-start")
        payload = recs[0]["payload"]
        self.assertEqual(payload["session_id"], "sess-1")
        self.assertEqual(payload["workspace_id"], 42)
        self.assertEqual(payload["surface_id"], 7)

    def test_repeated_emissions_preserve_order(self):
        results = self.run_case("order")
        recs = results["records"]
        self.assertEqual([r["payload"]["session_id"] for r in recs],
                         ["sess-%d" % i for i in range(5)], recs)
        self.assertTrue(all(r["event"] == "session-start" for r in recs))

    def test_disabled_integration_is_inert(self):
        results = self.run_case("signal-disabled",
                                {"SEANCE_HERMES_HOOKS_DISABLED": "1"})
        self.assertTrue(results["handler_preserved"])
        self.assertEqual(results["records"], [])

    def test_slow_bridge_is_bounded_and_child_reaped(self):
        results = self.run_case("slow",
                                {"FAKE_SEANCE_MODE": "slow",
                                 "FAKE_SEANCE_SLEEP": "30"})
        self.assertLess(results["elapsed"], 8.0,
                        "slow bridge blocked longer than the bound")
        self.assertEqual(len(results["records"]), 1, results["records"])
        self.assertEqual(results["reaped"], [True],
                         "owned child was not reaped after the timeout")

    def test_oversized_payload_is_dropped(self):
        results = self.run_case("oversized")
        self.assertEqual(results["records"], [],
                         "oversized payload should not reach the bridge")

    def test_broken_pipe_is_swallowed(self):
        results = self.run_case("broken-pipe",
                                {"FAKE_SEANCE_MODE": "exit-fast"})
        # The bridge recorded its invocation; the plugin must survive the
        # EPIPE from writing to an exited child.
        self.assertEqual(len(results["records"]), 1, results["records"])

    def test_queue_is_bounded_under_flood(self):
        results = self.run_case(
            "bounded-queue",
            {"FAKE_SEANCE_SLOW_EVENTS": "session-start",
             "FAKE_SEANCE_SLEEP": "2"})
        recs = results["records"]
        first = [r for r in recs if r["event"] == "session-start"]
        flood = [r for r in recs if r["event"] == "prompt-submit"]
        self.assertEqual(len(first), 1, "head-of-line emission lost")
        self.assertGreater(len(flood), 0, "queue never drained")
        self.assertLessEqual(len(flood), 64,
                             "queue bound exceeded: %d" % len(flood))
        # Lifecycle order: the queued head came before every flood item.
        self.assertLess(recs.index(first[0]), recs.index(flood[0]))


if __name__ == "__main__":
    unittest.main()
