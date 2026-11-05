"""Hermes installer lifecycle regressions. Run under Xvfb with SEANCE_TEST_BINARY set.

Covers first install (backup + marker + enable), retry after a failed
backup transaction, and disabling without losing the original backup.
The install runs synchronously during startup, so assertions can run as
soon as setUp's start() returns.
"""
import os
import unittest

from test_ghostty_integration import GhosttyTestCase

ORIGINAL_CONFIG = "plugins:\n  enabled: []\n"
ENABLED_CONFIG = "plugins:\n  enabled: [seance]\n"
BLOCKED_BACKUP_CONTENT = "not the original\n"


@unittest.skipUnless(os.environ.get("SEANCE_TEST_BINARY"), "set SEANCE_TEST_BINARY for GUI validation")
class HermesInstallBase(GhosttyTestCase):
    config_extra = "hermes-hooks = true\n"

    def prepare(self):
        self.hermes = self.root / "home" / ".hermes"
        self.hermes.mkdir()
        self.config_path = self.hermes / "config.yaml"
        self.backup_path = self.hermes / "config.yaml.bak"
        self.marker_path = self.hermes / ".seance-version"
        self.plugin_dir = self.hermes / "plugins" / "seance"
        self.seed()

    def seed(self):
        """Write the pre-start ~/.hermes fixture for each scenario."""

    def rewrite_config(self, config_extra):
        import json
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


class FirstInstallTest(HermesInstallBase):
    def seed(self):
        self.config_path.write_text(ORIGINAL_CONFIG)
        self.config_path.chmod(0o600)

    def test_first_install_backs_up_stamps_and_enables(self):
        self.assertEqual(ENABLED_CONFIG, self.config_path.read_text())
        self.assertEqual(0o600, self.config_path.stat().st_mode & 0o777)
        # First-install backup holds the original bytes and mode.
        self.assertEqual(ORIGINAL_CONFIG, self.backup_path.read_text())
        self.assertEqual(0o600, self.backup_path.stat().st_mode & 0o777)
        self.assertEqual("2", self.marker_path.read_text().strip())
        self.assertTrue((self.plugin_dir / "__init__.py").exists())
        self.assertTrue((self.plugin_dir / "plugin.yaml").exists())


class FailedBackupRetryTest(HermesInstallBase):
    def seed(self):
        self.config_path.write_text(ORIGINAL_CONFIG)
        # A directory at the backup path makes the backup transaction fail.
        self.backup_path.mkdir()

    def test_failed_backup_never_mutates_or_stamps_then_retry_succeeds(self):
        # Transaction failed: config untouched, no marker, retryable.
        self.assertEqual(ORIGINAL_CONFIG, self.config_path.read_text())
        self.assertFalse(self.marker_path.exists())

        # Clear the obstruction; the next launch must complete the install.
        self.backup_path.rmdir()
        self.restart("hermes-hooks = true\n", "retry")
        self.assertEqual(ENABLED_CONFIG, self.config_path.read_text())
        self.assertEqual("2", self.marker_path.read_text().strip())
        self.assertEqual(ORIGINAL_CONFIG, self.backup_path.read_text())
        self.assertTrue((self.plugin_dir / "__init__.py").exists())


class DisablePreservesBackupTest(HermesInstallBase):
    def seed(self):
        self.config_path.write_text(ENABLED_CONFIG)
        self.backup_path.write_text(BLOCKED_BACKUP_CONTENT)

    def test_disable_strips_entry_but_keeps_original_backup(self):
        # Startup with an existing backup: never overwritten.
        self.assertEqual("2", self.marker_path.read_text().strip())
        self.assertEqual(BLOCKED_BACKUP_CONTENT, self.backup_path.read_text())
        self.assertTrue((self.plugin_dir / "__init__.py").exists())

        self.restart("hermes-hooks = false\n", "disable")
        self.assertEqual(ORIGINAL_CONFIG, self.config_path.read_text())
        # The original backup survives disable, files and marker are gone.
        self.assertEqual(BLOCKED_BACKUP_CONTENT, self.backup_path.read_text())
        self.assertFalse(self.marker_path.exists())
        self.assertFalse(self.plugin_dir.exists())


if __name__ == "__main__":
    unittest.main()
