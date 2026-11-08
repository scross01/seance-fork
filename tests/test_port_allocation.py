"""Workspace port-block regressions. Run under Xvfb with SEANCE_TEST_BINARY set.

Each case starts the installed binary, then has the shell print only the
SEANCE_PORT* variables of the terminal under test. Valid allocations must be a
whole block inside 1..65535; an exhausted or unallocated workspace (and an
invalid configured pair) must export none of the three variables while the
workspace itself keeps working.
"""
import json
import os
import unittest

from test_ghostty_integration import GhosttyTestCase

MAX_U32 = 2**32 - 1


def seeded_session(port_ordinal):
    """Session with one workspace at a chosen port ordinal."""
    return {
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
                "port_ordinal": port_ordinal,
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


@unittest.skipUnless(os.environ.get("SEANCE_TEST_BINARY"), "set SEANCE_TEST_BINARY for GUI validation")
class PortTestCase(GhosttyTestCase):
    def prepare(self):
        if getattr(self, "seed_ordinal", None) is not None:
            path = self.root / "home" / ".config" / "seance" / "session.json"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(seeded_session(self.seed_ordinal)))

    def setUp(self):
        super().setUp()
        # The first terminal is created after startup; ctl reports it as
        # destroyed until its shell has produced output.
        self.wait(lambda: self.call("surface.read_screen").get("text"), "shell startup")

    def focused_surface(self):
        for surface in self.call("surface.list")["surfaces"]:
            if surface["focused"]:
                return surface["id"]
        surfaces = self.call("surface.list")["surfaces"]
        self.assertTrue(surfaces, "no terminal surface")
        return surfaces[0]["id"]

    def ports(self, surface=None):
        """SEANCE_PORT* variables exported to one terminal, as a dict."""
        surface = surface or self.focused_surface()
        begin = "PORTS_BEGIN_%d" % surface
        end = "PORTS_END_%d" % surface
        # The delimiters are assembled by printf so the shell's echo of this
        # command line cannot be mistaken for the command's output.
        self.call("surface.send_text", {
            "surface_id": surface,
            "text": ("clear; printf 'PORTS%s\\n' '_BEGIN_" + str(surface) + "'; "
                     "env | grep '^SEANCE_PORT' | sort; "
                     "printf 'PORTS%s\\n' '_END_" + str(surface) + "'\n"),
        })
        self.wait(lambda: end in self.call("surface.read_screen", {"surface_id": surface}).get("text", ""),
                  "port environment output")
        text = self.call("surface.read_screen", {"surface_id": surface})["text"]
        values = {}
        for line in text.split(begin, 1)[1].split(end, 1)[0].splitlines():
            line = line.strip()
            if line.startswith("SEANCE_PORT"):
                key, _, value = line.partition("=")
                values[key] = value
        return values

    def new_workspace(self):
        before = {surface["id"] for surface in self.call("surface.list")["surfaces"]}
        self.call("workspace.create")
        self.wait(lambda: {surface["id"] for surface in
                           self.call("surface.list")["surfaces"]} - before,
                  "new workspace terminal")
        created = ({surface["id"] for surface in
                    self.call("surface.list")["surfaces"]} - before).pop()
        self.wait(lambda: self.call("surface.read_screen", {"surface_id": created}).get("text"),
                  "new workspace shell startup")
        return created

    def assert_usable(self, surface=None):
        surface = surface or self.focused_surface()
        self.assertIsNone(self.process.poll(), "application exited")
        self.call("surface.send_text", {"surface_id": surface, "text": "echo USABLE_OK\n"})
        self.wait(lambda: "USABLE_OK" in self.call(
            "surface.read_screen", {"surface_id": surface}).get("text", ""),
            "terminal usable")
        self.stop()
        self.assertEqual(self.process.returncode, 0)

    def assert_ports(self, expected, surface=None):
        self.assertEqual(expected, self.ports(surface))


class DefaultPortsTest(PortTestCase):
    def test_defaults_export_ten_port_blocks(self):
        self.assert_ports({
            "SEANCE_PORT": "9100",
            "SEANCE_PORT_END": "9109",
            "SEANCE_PORT_RANGE": "10",
        })
        self.assert_usable()


class InvalidPairTest(PortTestCase):
    config_extra = "[socket]\nport-base = 65535\nport-range = 100\n"

    def test_invalid_pair_falls_back_to_defaults(self):
        self.assert_ports({
            "SEANCE_PORT": "9100",
            "SEANCE_PORT_END": "9109",
            "SEANCE_PORT_RANGE": "10",
        })
        self.assert_usable()


class LastBlockTest(PortTestCase):
    config_extra = "[socket]\nport-base = 65000\nport-range = 536\n"

    def test_last_block_ends_at_the_top_of_the_port_space(self):
        self.assert_ports({
            "SEANCE_PORT": "65000",
            "SEANCE_PORT_END": "65535",
            "SEANCE_PORT_RANGE": "536",
        })
        self.assert_usable()


class ExhaustedOrdinalTest(PortTestCase):
    config_extra = "[socket]\nport-base = 65000\nport-range = 536\n"

    def test_exhausted_workspace_exports_no_ports_and_still_works(self):
        self.assert_ports({
            "SEANCE_PORT": "65000",
            "SEANCE_PORT_END": "65535",
            "SEANCE_PORT_RANGE": "536",
        })
        second = self.new_workspace()
        # Ordinal 1 would start at 65536: the workspace gets no block at all.
        self.assertEqual({}, self.ports(second))
        self.assert_usable(second)


class RestoredMaxOrdinalTest(PortTestCase):
    seed_ordinal = MAX_U32 - 1

    def test_maximum_restored_ordinal_allocates_nothing(self):
        self.assertEqual({}, self.ports())
        # The counter saturates at the sentinel: the next workspace also gets
        # no block, and creating it must not overflow.
        created = self.new_workspace()
        self.assertEqual({}, self.ports(created))
        self.assert_usable(created)


class RestoredSentinelOrdinalTest(PortTestCase):
    seed_ordinal = MAX_U32

    def test_sentinel_ordinal_allocates_nothing(self):
        self.assertEqual({}, self.ports())
        created = self.new_workspace()
        self.assertEqual({}, self.ports(created))
        self.assert_usable(created)


if __name__ == "__main__":
    unittest.main()
