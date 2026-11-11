"""Notification identity regressions with physical input on an isolated X server.

A popover row used to remember only its position in the newest-first ring, so a
notification arriving between display and action could make Return or dismiss
hit a different record. These cases display one record, emit a second while the
popover is open, and then assert the action lands on the displayed record while
the arrival stays untouched. Ring eviction and ctl index compatibility are
covered alongside the sidebar unread badges that must reconcile with the store.
"""
import json
import time

import test_keyboard_remaps as keyboard


class NotificationIdentityTests(keyboard.PhysicalKeyboardTestCase):
    env_extra = {"G_DEBUG": "fatal-criticals"}

    def setUp(self):
        super().setUp()
        self.app.call("surface.split")
        self.app.wait(lambda: len(self.panes()) >= 2, "split pane")
        self.background = [pane for pane in self.panes() if not pane["focused"]][0]

    def panes(self):
        return self.app.call("surface.list")["surfaces"]

    def notifications(self):
        return self.app.call("notification.list")["notifications"]

    def unread(self):
        return {pane["id"]: pane["has_unread"] for pane in self.panes()}

    def emit(self, title, pane=None):
        pane = pane or self.background
        self.app.call("notification.create", {
            "title": title, "body": title.lower(),
            "workspace_id": pane["workspace_id"], "surface_id": pane["id"],
        })
        self.app.wait(lambda: title in [n["title"] for n in self.notifications()],
                      f"notification {title}")

    def send(self, *sequence):
        """Focus the app window, then send keys through XTest.

        The 150 ms per-event delay keeps the popover's row seating settled
        between keys; chords hold their modifiers explicitly.
        """
        windows = self.run_x(
            "xdotool", "search", "--onlyvisible", "--pid", str(self.app.process.pid)
        ).split()
        if windows:
            self.run_x("xdotool", "windowfocus", "--sync", windows[0])
        for spec in sequence:
            if "+" in spec:
                self.chord(spec, delay=150)
            else:
                self.press(spec, delay=150)

    def open_panel(self):
        self.send("ctrl+shift+i")
        time.sleep(1.0)

    def ctl(self, *args):
        # Global flags must precede the command name.
        return self.run_x(self.app.binary, "ctl", "--socket",
                          str(self.app.socket_path), "--json", *args)

    def test_activation_targets_displayed_record_after_arrival(self):
        self.emit("ALPHA")
        self.open_panel()
        self.emit("BRAVO")
        self.send("Return")
        self.app.wait(lambda: self.notifications()[1]["read"], "ALPHA marked read")

        records = self.notifications()
        self.assertEqual([n["title"] for n in records], ["BRAVO", "ALPHA"])
        self.assertTrue(records[1]["read"], "the displayed row's record must be the one read")
        self.assertFalse(records[0]["read"], "the arrival must stay untouched")
        focused = [pane["id"] for pane in self.panes() if pane["focused"]]
        self.assertEqual(focused, [self.background["id"]], "activation must jump to the displayed record's pane")
        self.assertTrue(self.unread()[self.background["id"]],
                        "the surviving arrival keeps its pane unread")

    def test_dismiss_targets_displayed_record_after_arrival(self):
        self.emit("ALPHA")
        self.open_panel()
        self.emit("BRAVO")
        self.send("Tab", "Return")
        self.app.wait(lambda: [n["title"] for n in self.notifications()] == ["BRAVO"],
                      "dismiss displayed row")

        records = self.notifications()
        self.assertEqual(records[0]["title"], "BRAVO")
        self.assertFalse(records[0]["read"], "dismissing must not read the arrival")
        self.assertTrue(self.unread()[self.background["id"]],
                        "the surviving arrival keeps its pane unread")

    def test_last_unread_dismissal_reconciles_badge(self):
        self.emit("ALPHA")
        self.assertTrue(self.unread()[self.background["id"]])
        self.open_panel()
        self.send("Tab", "Return")
        self.app.wait(lambda: self.notifications() == [], "dismiss last notification")
        self.assertFalse(self.unread()[self.background["id"]],
                         "clearing the last unread record must clear the pane badge")

    def test_same_pane_sibling_dismissal_leaves_the_survivor_unread(self):
        self.emit("ALPHA")
        self.emit("CHARLIE")
        self.assertEqual([n["title"] for n in self.notifications()], ["CHARLIE", "ALPHA"])

        self.open_panel()
        self.send("Tab", "Return")
        self.app.wait(lambda: [n["title"] for n in self.notifications()] == ["ALPHA"],
                      "dismiss newest sibling")
        self.assertFalse(self.notifications()[0]["read"],
                         "dismissing one sibling must not read the other")
        self.assertTrue(self.unread()[self.background["id"]],
                        "the unread sibling keeps the badge")

    def test_reopened_popover_dismisses_displayed_record(self):
        self.emit("ALPHA")
        self.emit("CHARLIE")
        self.open_panel()
        self.send("Return")
        self.app.wait(lambda: self.notifications()[0]["read"], "CHARLIE read")
        focused = [pane["id"] for pane in self.panes() if pane["focused"]]
        self.assertEqual(focused, [self.background["id"]], "activation jumps to the record's pane")

        self.open_panel()
        self.send("Tab", "Return")
        self.app.wait(lambda: [n["title"] for n in self.notifications()] == ["ALPHA"],
                      "dismiss reopened row")
        self.assertFalse(self.notifications()[0]["read"],
                         "dismissing the read record must not read the survivor")
        self.assertTrue(self.unread()[self.background["id"]])

    def test_ring_eviction_keeps_displayed_identity_addressable(self):
        self.emit("EVICTED")
        evicted_id = self.notifications()[0]["id"]
        for index in range(100):
            self.app.call("notification.create", {
                "title": f"RING{index:03d}", "body": "ring",
                "workspace_id": self.background["workspace_id"],
                "surface_id": self.background["id"],
            })
        self.app.wait(lambda: len(self.notifications()) == 100, "ring filled")
        self.assertNotIn(evicted_id, [n["id"] for n in self.notifications()],
                         "the oldest record must be evicted by the wrapped ring")

        newest = self.notifications()[0]
        self.open_panel()
        self.send("Tab", "Return")
        self.app.wait(lambda: len(self.notifications()) == 99, "dismiss newest displayed row")
        remaining = self.notifications()
        self.assertNotIn(newest["id"], [n["id"] for n in remaining])
        self.assertEqual([n["title"] for n in remaining],
                         [f"RING{index:03d}" for index in range(98, -1, -1)],
                         "surviving identities must be unchanged by the dismissal")

    def test_ctl_index_listing_and_clear_stay_compatible(self):
        self.emit("ALPHA")
        self.emit("BRAVO")
        self.emit("CHARLIE")
        socket_ids = [n["id"] for n in self.notifications()]

        listed = json.loads(self.ctl("list-notifications"))["notifications"]
        self.assertEqual([n["index"] for n in listed], [0, 1, 2])
        self.assertEqual([n["id"] for n in listed], socket_ids)
        self.assertEqual([n["title"] for n in listed], ["CHARLIE", "BRAVO", "ALPHA"])

        middle = listed[1]["id"]
        self.ctl("clear-notifications", "1")
        self.app.wait(lambda: [n["title"] for n in self.notifications()] == ["CHARLIE", "ALPHA"],
                      "clear by index")
        remaining_ids = [n["id"] for n in self.notifications()]
        self.assertNotIn(middle, remaining_ids, "index clear must remove the record at that index")
        self.assertEqual(remaining_ids, [socket_ids[0], socket_ids[2]])

        self.ctl("clear-notifications")
        self.app.wait(lambda: self.notifications() == [], "clear all")
        self.assertFalse(self.unread()[self.background["id"]])
