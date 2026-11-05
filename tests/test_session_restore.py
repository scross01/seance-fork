"""Session snapshot save/restore regressions. Run under Xvfb with SEANCE_TEST_BINARY set.

The base harness removes SEANCE_DISABLE_SESSION_RESTORE, so restore is
enabled for every case here; the seeded fixture writes
~/.config/seance/session.json before the automatic startup in setUp.
"""
import json
import os
import unittest

from test_ghostty_integration import GhosttyTestCase

# Minimal SESSION_VERSION=1 document matching what the serializer emits;
# restore must accept a file it did not write itself.
SEED_SESSION = {
    "version": 1,
    "created_at": 0,
    "windows": [{
        "sidebar_visible": True,
        "active_workspace": 0,
        "width": 1200,
        "height": 800,
        "workspaces": [{
            "title": "seeded",
            "custom_title": None,
            "custom_color": None,
            "is_pinned": False,
            "port_ordinal": 0,
            "camera": 0.0,
            "layout": {
                "type": "columns",
                "focused_column": 0,
                "columns": [{
                    "width": 1.0,
                    "groups": [{
                        "active_panel": 0,
                        "panels": [{
                            "type": "terminal",
                            "cwd": None,
                            "custom_title": None,
                            "height_weight": 1.0,
                            "scrollback": None,
                        }],
                    }],
                }],
            },
        }],
    }],
}


def iter_scrollbacks(session):
    for win in session.get("windows", []):
        for ws in win.get("workspaces", []):
            layout = ws.get("layout") or {}
            for col in layout.get("columns", []):
                for grp in col.get("groups", []):
                    for panel in grp.get("panels", []):
                        scrollback = panel.get("scrollback")
                        if isinstance(scrollback, str) and scrollback:
                            yield scrollback


class SessionRestoreBase(GhosttyTestCase):
    seed_session = None

    def prepare(self):
        assert "SEANCE_DISABLE_SESSION_RESTORE" not in self.env, \
            "session restore must stay enabled for these fixtures"
        self.session_path = self.root / "home" / ".config" / "seance" / "session.json"
        self.session_path.parent.mkdir(parents=True, exist_ok=True)
        if self.seed_session is not None:
            self.session_path.write_text(json.dumps(self.seed_session))

    def read_session(self):
        return json.loads(self.session_path.read_text())


@unittest.skipUnless(os.environ.get("SEANCE_TEST_BINARY"), "set SEANCE_TEST_BINARY for GUI validation")
class SessionSaveRestoreTestCase(SessionRestoreBase):
    def test_shutdown_save_is_bounded_parseable_and_restored(self):
        self.wait(lambda: self.call("surface.read_screen").get("text"), "shell startup")
        self.print_marker("SHUTDOWN_SAVE")
        self.stop()
        self.assertEqual(self.process.returncode, 0)

        raw = self.session_path.read_text()
        self.assertLessEqual(len(raw.encode()), 10 * 1024 * 1024)
        session = json.loads(raw)
        self.assertEqual(1, session["version"])
        self.assertGreaterEqual(len(session["windows"]), 1)
        # Atomic commit: owner-only mode and no leftover temp files.
        self.assertEqual(0o600, self.session_path.stat().st_mode & 0o777)
        self.assertEqual([], list(self.session_path.parent.glob("session.json.seance-*")))

        self.start()
        self.wait(lambda: "SHUTDOWN_SAVE" in self.call("surface.read_screen")["text"],
                  "restored marker")

    def test_large_history_restores_the_newest_tail(self):
        self.wait(lambda: self.call("surface.read_screen").get("text"), "shell startup")
        # Markers are assembled by printf so the echoed command never
        # contains the full literal; the tail marker only appears once
        # seq finishes, making the wait below a completion signal.
        self.call("surface.send_text", {
            "text": "printf 'OLDEST_%s\\n' HEAD_MARKER; seq 1 200000; printf 'NEWEST_%s\\n' TAIL_MARKER\n"
        })
        self.wait(lambda: "NEWEST_TAIL_MARKER" in self.call("surface.read_screen")["text"],
                  "large output")
        self.stop()

        scrollbacks = list(iter_scrollbacks(self.read_session()))
        self.assertTrue(scrollbacks)
        self.assertTrue(any("NEWEST_TAIL_MARKER" in sb for sb in scrollbacks))
        self.assertFalse(any("OLDEST_HEAD_MARKER" in sb for sb in scrollbacks))
        for scrollback in scrollbacks:
            self.assertLessEqual(len(scrollback), 400_000)

        self.start()
        self.wait(lambda: "NEWEST_TAIL_MARKER" in self.call("surface.read_screen")["text"],
                  "restored tail")

    def test_many_panes_round_trip_with_layout_counts(self):
        self.wait(lambda: self.call("surface.read_screen").get("text"), "shell startup")
        for i in range(5):
            self.call("workspace.create", {"title": "keep-%d" % i})
        # Splits become extra columns; restore recreates them.
        self.call("surface.split")
        self.call("surface.split")

        windows = self.call("window.list")["windows"]
        workspaces = self.call("workspace.list")["workspaces"]
        surfaces = self.call("surface.list")["surfaces"]
        self.assertEqual(1, len(windows))
        self.assertEqual(6, len(workspaces))
        self.assertGreaterEqual(len(surfaces), 8)

        self.stop()
        session = self.read_session()
        self.assertEqual(6, len(session["windows"][0]["workspaces"]))

        self.start()
        self.wait(lambda: len(self.call("workspace.list")["workspaces"]) == 6,
                  "restored workspaces")
        self.assertEqual(6, self.call("window.list")["windows"][0]["workspace_count"])
        titles = {ws["title"] for ws in self.call("workspace.list")["workspaces"]}
        self.assertTrue({"keep-0", "keep-1", "keep-2", "keep-3", "keep-4"} <= titles)
        restored = self.call("surface.list")["surfaces"]
        self.assertEqual(len(surfaces), len(restored))


@unittest.skipUnless(os.environ.get("SEANCE_TEST_BINARY"), "set SEANCE_TEST_BINARY for GUI validation")
class SeededSessionTestCase(SessionRestoreBase):
    seed_session = SEED_SESSION

    def test_preexisting_session_json_is_readable(self):
        # The seed was written in prepare(), before the app's first startup.
        self.wait(lambda: len(self.call("window.list")["windows"]) == 1,
                  "seeded window restored")
        self.assertEqual(1, len(self.call("workspace.list")["workspaces"]))
        titles = {ws["title"] for ws in self.call("workspace.list")["workspaces"]}
        self.assertIn("seeded", titles)
        # The surface is created on GL realize after the window maps — wait
        # for the shell prompt before interacting with it.
        self.wait(lambda: self.call("surface.read_screen").get("text"),
                  "seeded shell startup")
        self.print_marker("SEEDED_OK")


if __name__ == "__main__":
    unittest.main()
