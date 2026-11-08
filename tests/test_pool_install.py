"""Pool installer lifecycle regressions. Run under Xvfb with SEANCE_TEST_BINARY set.

Covers first install (merge + original backup + mode), repeated install
idempotency, disable removing only seance-owned handlers, legacy marker
migration, and non-mutating refusal for unsupported, oversized and
backup-blocked settings. The install runs synchronously during startup, so
assertions can run as soon as setUp's start() returns.
"""
import json
import os
import unittest

from test_ghostty_integration import GhosttyTestCase

USER_SETTINGS = (
    "# my pool settings\n"
    "model: pool\n"
    "hooks:\n"
    "  SessionStart:\n"
    '    - matcher: "*"\n'
    '      command: "./user-start.sh"\n'
    "  Stop:\n"
    '    - matcher: "*"\n'
    '      command: "./user-stop.sh"\n'
    "other: true\n"
)

OWNED_EVENTS = (
    ("SessionStart", "session-start"),
    ("UserPromptSubmit", "prompt-submit"),
    ("PreToolUse", "pre-tool-use"),
    ("PostToolUse", "post-tool-use"),
    ("Stop", "stop"),
)

LEGACY_SETTINGS = (
    "hooks:\n"
    "# seance-pool-hooks-start\n"
    "  SessionStart:\n"
    '    - matcher: "*"\n'
    '      command: "seance ctl pool-hook session-start"\n'
    "      timeout: 10\n"
    "# seance-pool-hooks-end\n"
    "  Stop:\n"
    '    - matcher: "*"\n'
    '      command: "./user-stop.sh"\n'
)


@unittest.skipUnless(os.environ.get("SEANCE_TEST_BINARY"), "set SEANCE_TEST_BINARY for GUI validation")
class PoolInstallBase(GhosttyTestCase):
    config_extra = "pool-hooks = true\n"

    def prepare(self):
        self.pool_dir = self.root / "home" / ".config" / "poolside"
        self.pool_dir.mkdir(parents=True)
        self.settings = self.pool_dir / "settings.yaml"
        self.backup = self.pool_dir / "settings.yaml.bak"
        self.seed()

    def seed(self):
        """Write the pre-start Pool fixture for each scenario."""

    def temps(self):
        return [path for path in self.pool_dir.iterdir() if ".seance-" in path.name]

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


class FirstInstallTest(PoolInstallBase):
    def seed(self):
        self.settings.write_text(USER_SETTINGS)
        self.settings.chmod(0o600)

    def test_first_install_merges_handlers_backs_up_and_preserves_mode(self):
        installed = self.settings.read_text()
        for event, slug in OWNED_EVENTS:
            with self.subTest(event=event):
                self.assertEqual(1, installed.count(event + ":"))
                self.assertEqual(1, installed.count("pool-hook " + slug))
        # User handlers and unrelated keys survive.
        self.assertIn("./user-start.sh", installed)
        self.assertIn("./user-stop.sh", installed)
        self.assertIn("model: pool", installed)
        self.assertIn("other: true", installed)

        # The original is preserved byte-for-byte with its mode.
        self.assertEqual(USER_SETTINGS, self.backup.read_text())
        self.assertEqual(0o600, self.settings.stat().st_mode & 0o777)
        self.assertEqual(0o600, self.backup.stat().st_mode & 0o777)
        self.assertEqual([], self.temps())


class AbsentSettingsTest(PoolInstallBase):
    def test_first_install_creates_settings_without_a_backup(self):
        installed = self.settings.read_text()
        self.assertTrue(installed.startswith("hooks:\n"))
        for _, slug in OWNED_EVENTS:
            self.assertEqual(1, installed.count("pool-hook " + slug))
        self.assertFalse(self.backup.exists())


class RepeatedInstallTest(PoolInstallBase):
    def seed(self):
        self.settings.write_text(USER_SETTINGS)

    def test_restart_is_byte_idempotent_and_keeps_the_first_backup(self):
        first = self.settings.read_text()
        backup = self.backup.read_text()
        self.restart("pool-hooks = true\n", "again")
        self.assertEqual(first, self.settings.read_text())
        self.assertEqual(backup, self.backup.read_text())
        self.assertEqual([], self.temps())


class DisableTest(PoolInstallBase):
    def seed(self):
        self.settings.write_text(USER_SETTINGS)

    def test_disable_removes_only_owned_handlers(self):
        self.assertIn("pool-hook stop", self.settings.read_text())
        backup = self.backup.read_text()

        self.restart("pool-hooks = false\n", "disable")
        disabled = self.settings.read_text()
        for _, slug in OWNED_EVENTS:
            with self.subTest(slug=slug):
                self.assertNotIn("pool-hook " + slug, disabled)
        self.assertIn("./user-start.sh", disabled)
        self.assertIn("./user-stop.sh", disabled)
        self.assertIn("SessionStart:", disabled)
        self.assertIn("hooks:", disabled)
        # The original backup survives disable and is never overwritten.
        self.assertEqual(backup, self.backup.read_text())
        self.assertEqual([], self.temps())


class LegacyMarkerMigrationTest(PoolInstallBase):
    def seed(self):
        self.settings.write_text(LEGACY_SETTINGS)

    def test_marker_block_migrates_without_duplicates(self):
        migrated = self.settings.read_text()
        self.assertNotIn("seance-pool-hooks-start", migrated)
        self.assertEqual(1, migrated.count("pool-hook session-start"))
        self.assertEqual(1, migrated.count("SessionStart:"))
        self.assertIn("./user-stop.sh", migrated)
        self.assertEqual(LEGACY_SETTINGS, self.backup.read_text())


class UnsupportedSettingsTest(PoolInstallBase):
    def seed(self):
        self.settings.write_text("hooks: [SessionStart]\n")

    def test_unsupported_flow_mapping_is_left_byte_identical(self):
        self.assertEqual("hooks: [SessionStart]\n", self.settings.read_text())
        self.assertFalse(self.backup.exists())
        self.assertEqual([], self.temps())


class OversizedSettingsTest(PoolInstallBase):
    def seed(self):
        self.oversized = b"# " + b"a" * (1024 * 1024 + 16)
        self.settings.write_bytes(self.oversized)

    def test_oversized_settings_are_not_rewritten(self):
        self.assertEqual(self.oversized, self.settings.read_bytes())
        self.assertFalse(self.backup.exists())
        self.assertEqual([], self.temps())


class BlockedBackupTest(PoolInstallBase):
    def seed(self):
        self.settings.write_text(USER_SETTINGS)
        # A directory at the backup path blocks the transaction before any write.
        self.backup.mkdir()

    def test_blocked_backup_preserves_bytes_then_retry_succeeds(self):
        self.assertEqual(USER_SETTINGS, self.settings.read_text())
        self.assertEqual([], self.temps())

        self.backup.rmdir()
        self.restart("pool-hooks = true\n", "retry")
        installed = self.settings.read_text()
        self.assertEqual(1, installed.count("pool-hook stop"))
        self.assertEqual(USER_SETTINGS, self.backup.read_text())


if __name__ == "__main__":
    unittest.main()
