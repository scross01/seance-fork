"""Scrollback config regressions. Run under Xvfb with SEANCE_TEST_BINARY set.

Verifies that `[terminal] scrollback-lines` is honored as a *line* count
rather than being mis-applied as bytes.
"""
import json
import os
import unittest

from test_session_restore import SessionRestoreBase, iter_scrollbacks


class SmallScrollbackCapTests(SessionRestoreBase):
    config_extra = "[terminal]\nscrollback-lines = 300\n"

    def test_small_line_cap_is_enforced(self):
        self.wait(lambda: self.call("surface.read_screen").get("text"), "shell startup")
        self.call("surface.send_text", {
            "text": "seq 1 5499; printf 'EARLY_%s\\n' MARKER_5500; seq 5501 6000; printf 'DONE_%s\\n' TAIL_OK\n"
        })
        self.wait(lambda: "DONE_TAIL_OK" in self.call("surface.read_screen")["text"],
                  "large output")
        self.stop()
        self.assertEqual(self.process.returncode, 0)

        scrollbacks = list(iter_scrollbacks(self.read_session()))
        self.assertTrue(scrollbacks)
        for sb in scrollbacks:
            self.assertLessEqual(len(sb.splitlines()), 400,
                                "scrollback exceeds cap")
        self.assertFalse(any("EARLY_MARKER_5500" in sb for sb in scrollbacks))


class LargeScrollbackCapTests(SessionRestoreBase):
    config_extra = "[terminal]\nscrollback-lines = 40000\n"

    def test_large_line_cap_takes_effect(self):
        self.wait(lambda: self.call("surface.read_screen").get("text"), "shell startup")
        self.call("surface.send_text", {
            "text": "seq 1 60000; printf 'DONE_%s\\n' TAIL_OK\n"
        })
        self.wait(lambda: "DONE_TAIL_OK" in self.call("surface.read_screen")["text"],
                  "large output")
        self.stop()
        self.assertEqual(self.process.returncode, 0)

        scrollbacks = list(iter_scrollbacks(self.read_session()))
        self.assertTrue(scrollbacks)
        max_lines = max(len(sb.splitlines()) for sb in scrollbacks)
        self.assertGreaterEqual(max_lines, 3800)


if __name__ == "__main__":
    unittest.main()
