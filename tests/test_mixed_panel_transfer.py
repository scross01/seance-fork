"""Mixed terminal/browser panel transfer across stacked and tabbed columns.

Expelling a panel and switching a column's layout mode have no ctl command, so
each case drives a real application on its own isolated X server and sends
physical key events. Every column starts stacked (startup, split and
browser.open alike) and one toggle flips the focused column to tabbed, so each
case states which endpoints it toggles.

Every case asserts the application survives the transfer, the panel id is still
listed by browser.list (which walks the live column/group panel lists), the
transferred panel became the active panel of the target group, and it can still
run script.
"""

import json
import os
import select
import shutil
import socket
import subprocess
import unittest
from unittest.mock import patch

import test_ghostty_integration as integration

EVAL_TIMEOUT = 10


class MixedPanelTransferTest(unittest.TestCase):
    def setUp(self):
        for command in ("Xvfb", "xdotool"):
            if not shutil.which(command):
                self.skipTest(f"mixed transfer tests require {command}")
        server = subprocess.Popen(
            ["Xvfb", "-displayfd", "1", "-screen", "0", "1280x800x24",
             "-nolisten", "tcp", "-noreset"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        self.addCleanup(self.stop_server, server)
        self.assertTrue(select.select([server.stdout], [], [], 10)[0],
                        "Xvfb startup timed out")
        display = ":" + server.stdout.readline().decode().strip()
        self.assertNotEqual(display, ":", "Xvfb failed to start")
        self.app = integration.GhosttyTestCase()
        self.addCleanup(self.app.doCleanups)
        with patch.dict(os.environ, {"DISPLAY": display}):
            self.app.setUp()
        self.app.wait(lambda: self.app.call("surface.read_screen").get("text"),
                      "shell startup")
        # A bare X server has no window manager, so focus the toplevel directly.
        window = self.run_x("xdotool", "search", "--onlyvisible", "--pid",
                            str(self.app.process.pid)).strip().splitlines()[0]
        self.run_x("xdotool", "windowfocus", "--sync", window)

    @staticmethod
    def stop_server(server):
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
        server.stdout.close()

    # ── helpers ─────────────────────────────────────────────────────────

    def run_x(self, *args):
        return subprocess.run(args, env=self.app.env, check=True,
                              capture_output=True, text=True,
                              timeout=10).stdout

    def assert_running(self, note):
        if self.app.process.poll() is None:
            return
        self.app.log.flush()
        self.app.log.seek(0)
        self.fail(f"{note}: application exited with status "
                  f"{self.app.process.returncode}\n{self.app.log.read()[-4000:]}")

    def key(self, chord, until):
        """Press chord, wait for it to take effect, then for a settled layout.

        Expel and layout transitions animate over frame ticks, so the state a
        later key depends on (row seating, AdwTabView membership, removal of an
        emptied column) is only final once system.tree reports the workspace
        settled.
        """
        self.run_x("xdotool", "key", "--clearmodifiers", chord)
        self.app.wait(until, f"{chord} takes effect")
        self.app.wait(self.settled, f"layout settles after {chord}")
        self.assert_running(f"after {chord}")

    def active_workspace(self):
        tree = self.app.call("system.tree")
        windows = [w for w in tree["windows"] if w["active"]]
        self.assertEqual(len(windows), 1, tree)
        workspaces = [w for w in windows[0]["workspaces"] if w["active"]]
        self.assertEqual(len(workspaces), 1, windows)
        return workspaces[0]

    def groups(self):
        return self.active_workspace()["pane_groups"]

    def settled(self):
        return self.active_workspace()["settled"]

    def group(self, group_id):
        matched = [g for g in self.groups() if g["id"] == group_id]
        self.assertEqual(len(matched), 1, self.groups())
        return matched[0]

    def focused_group(self):
        matched = [g for g in self.groups() if g["focused"]]
        self.assertEqual(len(matched), 1, self.groups())
        return matched[0]

    def browser_ids(self):
        return [p["id"] for p in self.app.call("browser.list")["panels"]]

    def eval_js(self, panel_id, script):
        with socket.socket(socket.AF_UNIX) as conn:
            conn.settimeout(EVAL_TIMEOUT)
            conn.connect(str(self.app.socket_path))
            conn.sendall((json.dumps({"id": "eval", "method": "browser.eval",
                                      "params": {"panel_id": panel_id,
                                                 "script": script}}) + "\n").encode())
            data = b""
            while b"\n" not in data:
                part = conn.recv(65536)
                if not part:
                    break
                data += part
        reply = json.loads(data)
        self.assertTrue(reply["ok"], reply)
        return reply["result"]

    def assert_browser_usable(self, panel_id):
        self.assertIn(panel_id, self.browser_ids(),
                      "transferred panel left the live group lists")
        self.app.call("browser.get_url", {"panel_id": panel_id})
        self.app.call("browser.get_title", {"panel_id": panel_id})
        self.assertEqual(self.eval_js(panel_id, "21 * 2"), 42,
                         "transferred panel cannot run script")

    def split_terminal(self):
        self.app.call("surface.split")
        self.app.wait(lambda: len(self.groups()) == 2, "split terminal")

    def browser_tab(self):
        """Add a browser panel to the focused column as another panel."""
        before = self.browser_ids()
        self.key("ctrl+alt+e", lambda: len(self.browser_ids()) == len(before) + 1)
        created = [pid for pid in self.browser_ids() if pid not in before]
        self.assertEqual(len(created), 1, created)
        return created[0]

    def toggle_layout(self):
        """Flip the focused column between stacked and tabbed."""
        mode = self.focused_group()["layout_mode"]
        self.key("ctrl+shift+l",
                 lambda: self.focused_group()["layout_mode"] != mode)

    def focus_column(self, side):
        target = self.groups()[0 if side == "Left" else -1]["id"]
        self.key("ctrl+shift+" + side,
                 lambda: self.focused_group()["id"] == target)

    def transfer(self, side="Left"):
        before = self.groups()
        self.key("ctrl+alt+" + side, lambda: self.groups() != before)

    def wait_groups(self, count, description):
        """Wait for a column count: emptied columns close on a later frame."""
        self.app.wait(lambda: len(self.groups()) == count, description)

    def assert_browser_is_active(self, group_id):
        group = self.group(group_id)
        self.assertTrue(group["focused"], group)
        # The browser is the group's active panel, so no terminal claims selection.
        self.assertFalse(any(s["selected"] for s in group["surfaces"]), group)

    def transfer_browser_between_columns(self, *, source_tabbed, target_tabbed):
        """Split, add a browser tab, set both endpoint modes and expel left."""
        self.split_terminal()
        panel_id = self.browser_tab()
        target = self.groups()[0]["id"]
        if source_tabbed:
            self.toggle_layout()
        if target_tabbed:
            self.focus_column("Left")
            self.toggle_layout()
            self.focus_column("Right")

        self.transfer()

        self.assert_running("after expelling a browser panel")
        self.assertEqual(len(self.groups()), 2, self.groups())
        self.assert_browser_is_active(target)
        self.assert_browser_usable(panel_id)
        return panel_id

    # ── endpoint matrix ─────────────────────────────────────────────────

    def test_stacked_to_stacked_transfer(self):
        self.transfer_browser_between_columns(source_tabbed=False,
                                              target_tabbed=False)

    def test_stacked_to_tabbed_transfer(self):
        self.transfer_browser_between_columns(source_tabbed=False,
                                              target_tabbed=True)

    def test_tabbed_to_stacked_transfer(self):
        self.transfer_browser_between_columns(source_tabbed=True,
                                              target_tabbed=False)

    def test_tabbed_to_tabbed_transfer(self):
        self.transfer_browser_between_columns(source_tabbed=True,
                                              target_tabbed=True)

    # ── column edges and ownership ──────────────────────────────────────

    def test_browser_without_target_creates_a_column(self):
        panel_id = self.browser_tab()
        self.assertEqual(len(self.groups()), 1, self.groups())

        self.transfer()

        self.assert_running("after creating a column for a browser")
        groups = self.groups()
        self.assertEqual(len(groups), 2, groups)
        self.assertEqual(self.focused_group()["surfaces"], [], groups)
        self.assert_browser_usable(panel_id)

    def test_browser_leaving_its_column_closes_it(self):
        terminal = self.app.call("surface.list")["surfaces"][0]["id"]
        panel_id = self.app.call("browser.open", {"url": "about:blank"})["panel_id"]
        self.app.wait(lambda: panel_id in self.browser_ids(), "browser column")
        target = self.groups()[0]["id"]
        self.assertEqual(len(self.groups()), 2, self.groups())

        self.transfer()

        self.assert_running("after emptying a browser column")
        self.assertEqual(len(self.groups()), 1, self.groups())
        self.assert_browser_is_active(target)
        self.assert_browser_usable(panel_id)
        self.app.call("surface.send_text", {"surface_id": terminal,
                                            "text": "echo SURVIVED\n"})
        self.app.wait(lambda: "SURVIVED" in self.app.call(
            "surface.read_screen", {"surface_id": terminal})["text"],
            "terminal after browser transfer")

    def test_browser_round_trip_keeps_ownership(self):
        terminal = self.app.call("surface.list")["surfaces"][0]["id"]
        panel_id = self.app.call("browser.open", {"url": "about:blank"})["panel_id"]
        self.app.wait(lambda: panel_id in self.browser_ids(), "browser column")
        self.assertEqual(len(self.groups()), 2, self.groups())

        self.transfer()
        self.assert_running("after first transfer")
        self.assertEqual(len(self.groups()), 1, self.groups())
        self.assert_browser_usable(panel_id)

        self.transfer("Right")
        self.assert_running("after transferring back")
        groups = self.groups()
        self.assertEqual(len(groups), 2, groups)
        self.assert_browser_is_active(self.focused_group()["id"])
        self.assert_browser_usable(panel_id)

        self.app.call("browser.close", {"panel_id": panel_id})
        self.app.wait(lambda: panel_id not in self.browser_ids(), "browser close")
        self.wait_groups(1, "closed browser column closes")
        self.app.call("surface.send_text", {"surface_id": terminal,
                                            "text": "echo ROUND_TRIP_HOME\n"})
        self.app.wait(lambda: "ROUND_TRIP_HOME" in (
            self.app.call("surface.read_screen",
                          {"surface_id": terminal}).get("text") or ""),
                      "terminal after browser close")

    def test_terminal_slow_path_still_transfers(self):
        self.split_terminal()
        # Second terminal, so the source column survives the expel.
        self.key("ctrl+shift+t",
                 lambda: len(self.app.call("surface.list")["surfaces"]) == 3)
        moved = [s["id"] for s in self.app.call("surface.list")["surfaces"]
                 if s["focused"]][0]
        target = self.groups()[0]["id"]

        self.transfer()

        self.assert_running("after expelling a terminal")
        self.assertEqual(len(self.groups()), 2, self.groups())
        group = self.group(target)
        self.assertTrue(group["focused"], group)
        selected = [s["id"] for s in group["surfaces"] if s["selected"]]
        self.assertEqual(selected, [moved], group)
        self.app.call("surface.send_text", {"surface_id": moved,
                                            "text": "echo MOVED_OK\n"})
        self.app.wait(lambda: "MOVED_OK" in self.app.call(
            "surface.read_screen", {"surface_id": moved})["text"],
            "moved terminal input")


if __name__ == "__main__":
    unittest.main()
