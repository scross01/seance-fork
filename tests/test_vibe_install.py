"""Vibe hook install lifecycle regressions. Run under Xvfb with SEANCE_TEST_BINARY set."""
import json
import os
import unittest

from test_ghostty_integration import GhosttyTestCase

USER_HOOKS = """[profile]
preferred-shell = "/bin/bash"

[[hooks]]
name = "user-early"
type = "pre_tool"
match = "*"
command = "/usr/bin/true"
"""

USER_LATE = """[[hooks]]
name = "user-late"
type = "post_tool"
match = "*"
command = "/usr/bin/false"
"""

# Version-2 era install layout: managed entries without ownership markers.
LEGACY_BLOCKS = """[[hooks]]
name = "seance-pre-tool"
type = "pre_tool"
match = "*"
command = "seance ctl vibe-hook pre-tool-use"
timeout = 5.0
description = "Séance: Track tool usage start"

[[hooks]]
name = "seance-post-tool"
type = "post_tool"
match = "*"
command = "seance ctl vibe-hook post-tool-use"
timeout = 5.0
description = "Séance: Track tool usage completion"

[[hooks]]
name = "seance-post-agent"
type = "post_agent"
command = "seance ctl vibe-hook stop"
timeout = 10.0
description = "Séance: Report idle state"
"""

BUNDLED_NAMES = {"seance-post-agent", "seance-pre-tool", "seance-post-tool"}


def managed_names_in(text):
    return {name for name in BUNDLED_NAMES if f'name = "{name}"' in text}


@unittest.skipUnless(os.environ.get("SEANCE_TEST_BINARY"), "set SEANCE_TEST_BINARY for GUI validation")
class VibeHooksTestCase(GhosttyTestCase):
    """Tests subclass with an `initial_fixture` so ~/.vibe/hooks.toml exists
    before GhosttyTestCase's automatic startup: the app installs during
    startup and never watches the file again."""

    config_extra = "vibe-hooks = true\n"
    initial_fixture = ""
    initial_mode = None

    def prepare(self):
        self.vibe = self.root / "home" / ".vibe"
        self.vibe.mkdir()
        self.hooks_path = self.vibe / "hooks.toml"
        self.backup_path = self.vibe / "hooks.toml.seance-original"
        self.marker_path = self.vibe / ".seance-version"
        if self.initial_fixture:
            self.hooks_path.write_text(self.initial_fixture)
        if self.initial_mode is not None:
            self.hooks_path.chmod(self.initial_mode)

    def read_hooks(self):
        return self.hooks_path.read_text()

    def rewrite_config(self, config_extra):
        """setUp wrote config.toml once, so a flipped flag needs a rewrite
        before the next start."""
        self.config_extra = config_extra
        config = self.root / "config" / "seance"
        (config / "config.toml").write_text(
            '[socket]\npath = ' + json.dumps(str(self.socket_path)) +
            '\n[behavior]\nconfirm-close-window = false\n' + self.config_extra)

    def restart(self, config_extra, tag):
        self.stop()
        self.rewrite_config(config_extra)
        self.log = (self.root / f"stderr-{tag}.log").open("w+")
        self.addCleanup(self.log.close)
        self.start()

    def assertUserIntact(self, text):
        self.assertIn("name = \"user-early\"", text)
        self.assertIn("name = \"user-late\"", text)

    def assertManagedPresent(self):
        self.assertEqual(BUNDLED_NAMES, managed_names_in(self.read_hooks()))

    def wait_for_install(self):
        self.wait(lambda: managed_names_in(self.read_hooks()), "vibe hooks install")


class FirstInstallPreservesUserHooks(VibeHooksTestCase):
    initial_fixture = USER_HOOKS + USER_LATE

    def test_first_install_preserves_user_hooks_and_backs_up(self):
        self.wait_for_install()
        text = self.read_hooks()
        self.assertManagedPresent()
        self.assertUserIntact(text)
        self.assertIn("# --- seance managed hooks: begin ---", text)
        self.assertIn("# --- seance managed hooks: end ---", text)
        self.assertEqual(USER_HOOKS + USER_LATE, self.backup_path.read_text())
        self.assertEqual("3", self.marker_path.read_text().strip())


class UpgradeFromLegacy(VibeHooksTestCase):
    initial_fixture = USER_HOOKS + LEGACY_BLOCKS + USER_LATE

    def test_upgrade_from_legacy_keeps_user_entries(self):
        self.wait_for_install()
        text = self.read_hooks()
        self.assertManagedPresent()
        self.assertUserIntact(text)
        self.assertEqual(USER_HOOKS + LEGACY_BLOCKS + USER_LATE,
                         self.backup_path.read_text())
        self.assertEqual("3", self.marker_path.read_text().strip())


class DisableThenReenable(VibeHooksTestCase):
    initial_fixture = USER_HOOKS + LEGACY_BLOCKS

    def test_disable_then_reenable_round_trips(self):
        self.wait_for_install()
        self.restart("vibe-hooks = false\n", "disable")
        self.wait(lambda: "name = \"seance-pre-tool\"" not in self.read_hooks(),
                  "vibe hooks disable")
        text = self.read_hooks()
        self.assertNotIn("name = \"seance-post-tool\"", text)
        self.assertNotIn("# --- seance managed hooks: begin ---", text)
        self.assertIn("name = \"user-early\"", text)
        self.assertFalse(self.marker_path.exists())
        self.assertEqual(USER_HOOKS + LEGACY_BLOCKS, self.backup_path.read_text())

        self.restart("vibe-hooks = true\n", "reenable")
        self.wait_for_install()
        self.assertManagedPresent()
        self.assertIn("name = \"user-early\"", self.read_hooks())
        self.assertEqual("3", self.marker_path.read_text().strip())
        self.assertEqual(USER_HOOKS + LEGACY_BLOCKS, self.backup_path.read_text())


class RepeatedStartup(VibeHooksTestCase):
    initial_fixture = USER_HOOKS

    def test_repeated_startup_does_not_rewrite(self):
        self.wait_for_install()
        stable = self.read_hooks()
        self.restart("vibe-hooks = true\n", "second")
        self.assertEqual(stable, self.read_hooks())


class PermissionsPreserved(VibeHooksTestCase):
    initial_fixture = USER_HOOKS
    initial_mode = 0o600

    def test_permissions_are_preserved(self):
        self.wait_for_install()
        self.assertEqual(0o600, self.hooks_path.stat().st_mode & 0o777)
        self.assertEqual(0o600, self.backup_path.stat().st_mode & 0o777)


if __name__ == "__main__":
    unittest.main()
