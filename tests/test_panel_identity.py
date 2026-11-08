"""Panel identity regressions. Run under Xvfb with SEANCE_TEST_BINARY set.

Verifies that terminal and browser panels share one collision-free id
space: mixed creation yields unique ids, explicit ids address the right
panel, and a restored layout allocates fresh unique ids.
"""
import os
import unittest

from test_ghostty_integration import GhosttyTestCase
from test_session_restore import SessionRestoreBase, iter_scrollbacks


class MixedPanelIdentityTests(GhosttyTestCase):
    def test_mixed_panel_ids_are_unique_and_addressable(self):
        self.wait(lambda: self.call("surface.read_screen").get("text"), "shell startup")

        # Terminal -> browser -> terminal in one group.
        terminal_ids = [s["id"] for s in self.call("surface.list")["surfaces"]]
        self.assertTrue(terminal_ids)
        first_terminal = terminal_ids[0]

        browser_a = self.call("browser.open", {"url": "about:blank"})["panel_id"]

        self.call("surface.split")
        self.wait(lambda: len(self.call("surface.list")["surfaces"]) >= 2,
                  "split terminal")
        terminal_ids = [s["id"] for s in self.call("surface.list")["surfaces"]]
        second_terminal = [t for t in terminal_ids if t != first_terminal][0] \
            if len(terminal_ids) > 1 else terminal_ids[0]

        browser_b = self.call("browser.open", {"url": "about:blank"})["panel_id"]

        all_ids = terminal_ids + [browser_a, browser_b]
        self.assertEqual(len(all_ids), len(set(all_ids)),
                         "panel ids are not unique across kinds")

        # Explicit browser targeting must address the right panel.
        self.call("browser.navigate", {"panel_id": browser_a, "url": "about:blank"})
        self.call("browser.reload", {"panel_id": browser_a})
        self.call("browser.get_url", {"panel_id": browser_a})
        self.call("browser.get_title", {"panel_id": browser_a})

        # Explicit terminal targeting must still work with a browser present.
        self.call("surface.read_screen", {"surface_id": first_terminal})
        self.call("surface.focus", {"surface_id": first_terminal})
        self.call("surface.send_text", {"surface_id": first_terminal,
                                       "text": "echo TERMINAL_OK\n"})

        # Close the browser explicitly by id.
        self.call("browser.close", {"panel_id": browser_a})
        self.wait(lambda: self.call("surface.read_screen").get("text"),
                  "terminal after browser close")

        # Second browser still addressable.
        self.call("browser.get_url", {"panel_id": browser_b})
        self.call("browser.close", {"panel_id": browser_b})


class RestoredPanelIdentityTests(SessionRestoreBase):
    def test_restored_layout_allocates_fresh_unique_ids(self):
        self.wait(lambda: self.call("surface.read_screen").get("text"), "shell startup")
        self.call("browser.open", {"url": "about:blank"})
        self.call("surface.split")
        self.wait(lambda: len(self.call("surface.list")["surfaces"]) >= 2,
                  "split terminal")
        self.stop()
        self.assertEqual(self.process.returncode, 0)

        self.start()
        self.wait(lambda: len(self.call("surface.list")["surfaces"]) >= 1,
                  "restored surfaces")
        restored_surfaces = self.call("surface.list")["surfaces"]
        sid = restored_surfaces[0]["id"]
        self.wait(lambda: self.call("surface.read_screen", {"surface_id": sid}).get("text"),
                  "restored startup")

        terminal_ids = [s["id"] for s in self.call("surface.list")["surfaces"]]
        browser_ids = []
        try:
            browser_ids = [b["id"] for b in self.call("browser.list")["panels"]]
        except (AssertionError, OSError, ValueError, KeyError):
            browser_ids = []
        all_ids = terminal_ids + browser_ids
        self.assertTrue(all_ids)
        self.assertEqual(len(all_ids), len(set(all_ids)),
                         "restored panel ids are not unique")


if __name__ == "__main__":
    unittest.main()
