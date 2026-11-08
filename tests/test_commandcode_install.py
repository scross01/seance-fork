"""Command Code installer lifecycle regressions. Run under Xvfb with SEANCE_TEST_BINARY set.

Covers first install (merge + original backup + mode), idempotency, disable
removing only seance-owned handlers, and fail-closed behavior for every input
we cannot preserve: oversized, invalid JSON, a non-object root, an unsupported
hooks shape and a blocked backup path. The install runs synchronously during
startup, so assertions can run as soon as setUp's start() returns.
"""
import json
import os
import unittest

from test_ghostty_integration import GhosttyTestCase

EVENTS = ("SessionStart", "PreToolUse", "PostToolUse", "Stop")
SLUGS = {
    "SessionStart": "session-start",
    "PreToolUse": "pre-tool-use",
    "PostToolUse": "post-tool-use",
    "Stop": "stop",
}

OWNED_POSTTOOL = (
    'test -n "$SEANCE_SURFACE_ID" && seance ctl commandcode-hook post-tool-use || exit 0'
)

USER_SETTINGS = {
    "model": "user-model",
    "hooks": {
        "PreToolUse": [
            {
                "matcher": "SHELL",
                "hooks": [{"type": "command", "command": "./user-pretool.sh"}],
            }
        ],
        # A definition that mixes a user handler with an owned one: install
        # must leave it alone, disable must keep just the user handler.
        "PostToolUse": [
            {
                "matcher": "WRITE",
                "hooks": [
                    {"type": "command", "command": "./user-posttool.sh"},
                    {"type": "command", "command": OWNED_POSTTOOL},
                ],
            }
        ],
    },
    "theme": "dark",
}

ONLY_OWNED = {
    "hooks": {
        "Stop": [
            {
                "hooks": [
                    {
                        "type": "command",
                        "command": 'test -n "$SEANCE_SURFACE_ID" && seance ctl '
                        "commandcode-hook stop || exit 0",
                    }
                ]
            }
        ]
    }
}


def dump(value):
    return json.dumps(value, indent=2) + "\n"


def owned_commands(value):
    """Every handler command in a settings object that seance owns."""
    found = []
    hooks = value.get("hooks")
    if isinstance(hooks, dict):
        for definitions in hooks.values():
            if not isinstance(definitions, list):
                continue
            for definition in definitions:
                if not isinstance(definition, dict):
                    continue
                for handler in definition.get("hooks") or []:
                    if not isinstance(handler, dict):
                        continue
                    command = handler.get("command")
                    if isinstance(command, str) and "seance ctl commandcode-hook" in command:
                        found.append(command)
    return found


@unittest.skipUnless(os.environ.get("SEANCE_TEST_BINARY"), "set SEANCE_TEST_BINARY for GUI validation")
class CommandCodeInstallBase(GhosttyTestCase):
    config_extra = "commandcode-hooks = true\n"

    def prepare(self):
        self.cc_dir = self.root / "home" / ".commandcode"
        self.cc_dir.mkdir(parents=True)
        self.settings = self.cc_dir / "settings.json"
        self.backup = self.cc_dir / "settings.json.seance-backup"
        self.seed()

    def seed(self):
        """Write the pre-start ~/.commandcode fixture for each scenario."""

    def temps(self):
        return [path for path in self.cc_dir.iterdir() if path.name.endswith(".tmp")]

    def versioned_backups(self):
        return [
            path for path in self.cc_dir.iterdir()
            if path.name.startswith("settings.json.seance-backup-")
        ]

    def rewrite_config(self, config_extra):
        self.config_extra = config_extra
        config = self.root / "config" / "seance"
        (config / "config.toml").write_text(
            '[socket]\npath = ' + json.dumps(str(self.socket_path)) +
            '\n[behavior]\nconfirm-close-window = false\n' + self.config_extra)

    def restart(self, config_extra, tag):
        self.stop()
        self.rewrite_config(config_extra)
        self.log = (self.root / ("stderr-%s.log" % tag)).open("w+")
        self.addCleanup(self.log.close)
        self.start()

    def assert_installed(self, value):
        hooks = value.get("hooks")
        self.assertIsInstance(hooks, dict)
        for event, slug in SLUGS.items():
            self.assertIn(event, hooks)
            commands = owned_commands({"hooks": {event: hooks[event]}})
            self.assertEqual(1, len(commands), (event, hooks[event]))
            self.assertIn("commandcode-hook " + slug, commands[0])


class FirstInstallTest(CommandCodeInstallBase):
    def seed(self):
        self.settings.write_text(dump(USER_SETTINGS))
        self.settings.chmod(0o600)

    def test_first_install_merges_hooks_and_keeps_user_configuration(self):
        installed = json.loads(self.settings.read_text())
        self.assert_installed(installed)
        # Unrelated keys and the user's own handlers survive.
        self.assertEqual("user-model", installed["model"])
        self.assertEqual("dark", installed["theme"])
        self.assertIn("./user-pretool.sh", self.settings.read_text())
        self.assertIn("./user-posttool.sh", self.settings.read_text())
        # The shared PostToolUse definition was not duplicated: the user's one
        # definition there already carried an owned handler.
        self.assertEqual(1, len(installed["hooks"]["PostToolUse"]))
        self.assertEqual(
            1, self.settings.read_text().count("commandcode-hook post-tool-use"))

        # The original bytes are preserved with their mode, before the change.
        self.assertEqual(dump(USER_SETTINGS), self.backup.read_text())
        self.assertEqual(0o600, self.backup.stat().st_mode & 0o777)
        self.assertEqual(0o600, self.settings.stat().st_mode & 0o777)
        self.assertEqual([], self.temps())
        self.assertEqual([], self.versioned_backups())


class AbsentSettingsTest(CommandCodeInstallBase):
    def test_first_install_creates_settings_without_a_backup(self):
        installed = json.loads(self.settings.read_text())
        self.assert_installed(installed)
        self.assertFalse(self.backup.exists())
        self.assertEqual([], self.temps())


class RepeatedInstallTest(CommandCodeInstallBase):
    def seed(self):
        self.settings.write_text(dump(USER_SETTINGS))

    def test_restart_is_byte_idempotent_and_keeps_the_first_backup(self):
        first = self.settings.read_text()
        backup = self.backup.read_text()
        self.restart("commandcode-hooks = true\n", "again")
        self.assertEqual(first, self.settings.read_text())
        self.assertEqual(backup, self.backup.read_text())
        self.assertEqual([], self.temps())


class DisableTest(CommandCodeInstallBase):
    def seed(self):
        self.settings.write_text(dump(USER_SETTINGS))

    def test_disable_removes_only_owned_handlers(self):
        self.assertTrue(owned_commands(json.loads(self.settings.read_text())))
        backup = self.backup.read_text()

        self.restart("commandcode-hooks = false\n", "disable")
        disabled = json.loads(self.settings.read_text())
        self.assertEqual([], owned_commands(disabled))
        self.assertIn("./user-pretool.sh", self.settings.read_text())
        self.assertIn("./user-posttool.sh", self.settings.read_text())
        self.assertEqual("user-model", disabled["model"])
        # The original backup survives disable and is never overwritten.
        self.assertEqual(backup, self.backup.read_text())
        self.assertEqual([], self.temps())


class DisableEmptySettingsTest(CommandCodeInstallBase):
    def seed(self):
        self.settings.write_text(dump(ONLY_OWNED))

    def test_disable_removes_the_file_when_only_owned_hooks_remained(self):
        self.restart("commandcode-hooks = false\n", "disable")
        self.assertFalse(self.settings.exists())
        self.assertEqual(dump(ONLY_OWNED), self.backup.read_text())


class OversizedSettingsTest(CommandCodeInstallBase):
    def seed(self):
        self.oversized = b'{"model": "' + b"a" * (1024 * 1024 + 16) + b'"}'
        self.settings.write_bytes(self.oversized)

    def test_oversized_settings_are_not_rewritten(self):
        self.assertEqual(self.oversized, self.settings.read_bytes())
        self.assertFalse(self.backup.exists())
        self.assertEqual([], self.temps())


class InvalidJsonTest(CommandCodeInstallBase):
    def seed(self):
        self.raw = b'{"model": "user-model", "hooks": {'
        self.settings.write_bytes(self.raw)

    def test_invalid_json_is_left_byte_identical(self):
        self.assertEqual(self.raw, self.settings.read_bytes())
        self.assertFalse(self.backup.exists())
        self.assertEqual([], self.temps())


class NonObjectRootTest(CommandCodeInstallBase):
    def seed(self):
        self.raw = b'["not", "an", "object"]\n'
        self.settings.write_bytes(self.raw)

    def test_non_object_root_is_left_byte_identical(self):
        self.assertEqual(self.raw, self.settings.read_bytes())
        self.assertFalse(self.backup.exists())


class UnsupportedHooksTest(CommandCodeInstallBase):
    def seed(self):
        self.raw = b'{"hooks": ["SessionStart"], "model": "m"}\n'
        self.settings.write_bytes(self.raw)

    def test_unsupported_hooks_value_is_left_byte_identical(self):
        self.assertEqual(self.raw, self.settings.read_bytes())
        self.assertFalse(self.backup.exists())
        self.assertEqual([], self.temps())


class BlockedBackupTest(CommandCodeInstallBase):
    def seed(self):
        self.settings.write_text(dump(USER_SETTINGS))
        # A directory at the backup path blocks the transaction before any write.
        self.backup.mkdir()

    def test_blocked_backup_preserves_bytes_then_retry_succeeds(self):
        self.assertEqual(dump(USER_SETTINGS), self.settings.read_text())
        self.assertEqual([], self.temps())

        self.backup.rmdir()
        self.restart("commandcode-hooks = true\n", "retry")
        installed = json.loads(self.settings.read_text())
        self.assert_installed(installed)
        self.assertEqual(dump(USER_SETTINGS), self.backup.read_text())


class StaleBackupTest(CommandCodeInstallBase):
    def seed(self):
        # The first backup holds an older generation; the live file has since
        # moved on, so those bytes are not recoverable from it.
        self.first_generation = dump(ONLY_OWNED)
        self.settings.write_text(dump(USER_SETTINGS))
        self.backup.write_text(self.first_generation)
        self.backup.chmod(0o600)

    def test_a_stale_first_backup_does_not_replace_the_current_generation_backup(self):
        self.assert_installed(json.loads(self.settings.read_text()))
        # The original first backup is untouched.
        self.assertEqual(self.first_generation, self.backup.read_text())
        # The generation that was actually replaced is preserved beside it.
        versions = self.versioned_backups()
        self.assertEqual(1, len(versions), versions)
        self.assertEqual(dump(USER_SETTINGS), versions[0].read_text())
        # A versioned backup mirrors the live file's permission bits.
        self.assertEqual(
            self.settings.stat().st_mode & 0o777,
            versions[0].stat().st_mode & 0o777)
        self.assertEqual([], self.temps())


if __name__ == "__main__":
    unittest.main()
