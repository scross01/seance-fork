"""UTF-8 boundary regressions for bounded titles and notification fields.

Fixed byte buffers used to be filled with raw `@min(len, cap)` copies, so a
title or notification ending near the capacity was cut inside a multibyte
codepoint. That produced invalid UTF-8 for GTK and for the session document.
These cases drive the socket/ctl paths with synthetic multibyte text and assert
the stored, persisted and re-saved text is the longest complete-character
prefix, under fatal GTK criticals and strict decoding.
"""
import copy
import json
import os
from pathlib import Path
import unittest

from test_ghostty_integration import GhosttyTestCase
from test_session_restore import SEED_SESSION

EMOJI = "\U0001f600"  # 4 bytes
EURO = "\u20ac"  # 3 bytes
BAD_LOG_MARKERS = ("Invalid UTF-8", "invalid utf8", "not valid UTF-8", "\ufffd")


class UnicodeAssertions:
    def session_file(self):
        return self.root / "home" / ".config" / "seance" / "session.json"

    def assert_clean_log(self):
        text = self.session_log_text()
        for marker in BAD_LOG_MARKERS:
            self.assertNotIn(marker, text, "app log reported broken UTF-8")

    def session_log_text(self):
        return Path(self.log.name).read_text(errors="replace")


@unittest.skipUnless(os.environ.get("SEANCE_TEST_BINARY"), "set SEANCE_TEST_BINARY for GUI validation")
class UnicodeFieldTests(UnicodeAssertions, GhosttyTestCase):
    env_extra = {"G_DEBUG": "fatal-criticals"}

    def setUp(self):
        super().setUp()
        # The window is still creating its first workspace when ping answers.
        self.wait(lambda: len(self.call("workspace.list").get("workspaces", [])) == 1,
                  "workspace ready")

    def workspaces(self):
        return self.call("workspace.list")["workspaces"]

    def workspace_title(self, workspace_id):
        return next(w["title"] for w in self.workspaces() if w["id"] == workspace_id)

    def notifications(self):
        return self.call("notification.list")["notifications"]

    def test_workspace_title_keeps_complete_characters(self):
        workspace = self.workspaces()[0]
        split = "W" * 125 + EMOJI  # 129 bytes: the 128-byte cap lands inside the emoji
        self.call("workspace.rename", {"workspace_id": workspace["id"], "title": split})
        title = self.workspace_title(workspace["id"])
        self.assertEqual("W" * 125, title)
        title.encode("utf-8").decode("utf-8")

        exact = "E" * 124 + EMOJI  # exactly 128 bytes: retained whole
        self.assertEqual(128, len(exact.encode("utf-8")))
        self.call("workspace.rename", {"workspace_id": workspace["id"], "title": exact})
        self.assertEqual(exact, self.workspace_title(workspace["id"]))
        self.assert_clean_log()

    def test_workspace_title_survives_save_and_restore(self):
        workspace = self.workspaces()[0]
        exact = "E" * 124 + EMOJI
        self.call("workspace.rename", {"workspace_id": workspace["id"], "title": exact})
        self.assertEqual(exact, self.workspace_title(workspace["id"]))

        self.stop()
        raw = self.session_file().read_bytes()
        session = json.loads(raw.decode("utf-8"))  # strict decode on purpose
        saved = session["windows"][0]["workspaces"][0]["custom_title"]
        self.assertEqual(exact, saved)

        self.start()
        self.wait(lambda: self.workspace_title(workspace["id"]) == exact,
                  "restored workspace title")
        self.assert_clean_log()

    def test_notification_fields_keep_complete_characters(self):
        self.call("surface.split")
        self.wait(lambda: len(self.call("surface.list")["surfaces"]) >= 2, "split pane")
        background = [p for p in self.call("surface.list")["surfaces"] if not p["focused"]][0]

        title = "T" * 253 + EMOJI  # 257 bytes -> 253 kept
        subtitle = "S" * 254 + EURO  # 257 bytes -> 254 kept
        body = "B" * 509 + EMOJI  # 513 bytes -> 509 kept
        self.call("notification.create", {
            "title": title, "subtitle": subtitle, "body": body,
            "workspace_id": background["workspace_id"], "surface_id": background["id"],
        })
        expected = ("T" * 253, "S" * 254, "B" * 509)
        self.wait(lambda: [n["title"] for n in self.notifications()] == [expected[0]],
                  "bounded notification")
        record = self.notifications()[0]
        self.assertEqual(expected[0], record["title"])
        self.assertEqual(expected[1], record["subtitle"])
        self.assertEqual(expected[2], record["body"])
        for field in ("title", "subtitle", "body"):
            record[field].encode("utf-8").decode("utf-8")
            self.assertNotIn("\ufffd", record[field])
        self.assert_clean_log()


def seeded_session():
    session = copy.deepcopy(SEED_SESSION)
    workspace = session["windows"][0]["workspaces"][0]
    workspace["custom_title"] = "W" * 125 + EMOJI  # 129 bytes -> 125 kept
    panel = workspace["layout"]["columns"][0]["groups"][0]["panels"][0]
    # 67 bytes: the 64-byte tab-title cap lands inside the emoji, while the
    # 256-byte pane field keeps the whole string.
    panel["custom_title"] = "P" * 63 + EMOJI
    return session


@unittest.skipUnless(os.environ.get("SEANCE_TEST_BINARY"), "set SEANCE_TEST_BINARY for GUI validation")
class SeededUnicodeRestoreTests(UnicodeAssertions, GhosttyTestCase):
    env_extra = {"G_DEBUG": "fatal-criticals"}
    seed_session = seeded_session()

    def prepare(self):
        path = self.session_file()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(self.seed_session))

    def test_seeded_multibyte_titles_restore_without_splitting(self):
        self.wait(lambda: len(self.call("workspace.list")["workspaces"]) == 1,
                  "seeded workspace restored")
        titles = [w["title"] for w in self.call("workspace.list")["workspaces"]]
        self.assertEqual(["W" * 125], titles)
        self.assert_clean_log()

        self.stop()
        session = json.loads(self.session_file().read_bytes().decode("utf-8"))
        workspace = session["windows"][0]["workspaces"][0]
        self.assertEqual("W" * 125, workspace["custom_title"])
        panel = workspace["layout"]["columns"][0]["groups"][0]["panels"][0]
        self.assertEqual("P" * 63 + EMOJI, panel["custom_title"])


if __name__ == "__main__":
    unittest.main()
