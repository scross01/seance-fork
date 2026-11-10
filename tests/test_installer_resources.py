"""Installer resource ownership regressions. Run under Xvfb with SEANCE_TEST_BINARY set.

Integration switches are toggled through a preloaded GTK probe: the Settings
panel is an AdwDialog with no scriptable API, so the probe activates the real
switch rows exactly as a click would. Descriptor and owned-temp counts are
compared only at stable checkpoints after the cycles settle.
"""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest

from test_ghostty_integration import GhosttyTestCase

PROBE_SOURCE = r"""
#define GDK_DISABLE_DEPRECATION_WARNINGS
#include <adwaita.h>
#include <glib/gstdio.h>
#include <string.h>

static gboolean toggle_row(GtkWidget *widget, gpointer data) {
    if (ADW_IS_SWITCH_ROW(widget)) {
        const char *title = adw_preferences_row_get_title(ADW_PREFERENCES_ROW(widget));
        if (title && g_strcmp0(title, (const char *)data) == 0) {
            AdwSwitchRow *row = ADW_SWITCH_ROW(widget);
            adw_switch_row_set_active(row, !adw_switch_row_get_active(row));
            return TRUE;
        }
    }
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child;
         child = gtk_widget_get_next_sibling(child)) {
        if (toggle_row(child, data)) return TRUE;
    }
    return FALSE;
}

static gboolean toggle_any_window(const char *title) {
    GListModel *windows = gtk_window_get_toplevels();
    for (guint i = 0; i < g_list_model_get_n_items(windows); ++i) {
        GtkWindow *window = g_list_model_get_item(windows, i);
        gboolean found = toggle_row(GTK_WIDGET(window), (gpointer)title);
        g_object_unref(window);
        if (found) return TRUE;
    }
    return FALSE;
}

static gboolean open_settings(void) {
    GListModel *windows = gtk_window_get_toplevels();
    for (guint i = 0; i < g_list_model_get_n_items(windows); ++i) {
        GtkWindow *window = g_list_model_get_item(windows, i);
        GtkApplication *app = gtk_window_get_application(window);
        gboolean ok = app && g_action_group_has_action(G_ACTION_GROUP(app), "preferences");
        if (ok) g_action_group_activate_action(G_ACTION_GROUP(app), "preferences", NULL);
        g_object_unref(window);
        if (ok) return TRUE;
    }
    return FALSE;
}

static gboolean poll(gpointer data) {
    (void)data;
    const char *control = g_getenv("SEANCE_TEST_GTK_CONTROL");
    if (!control) return G_SOURCE_CONTINUE;
    char *contents = NULL;
    if (!g_file_get_contents(control, &contents, NULL, NULL)) return G_SOURCE_CONTINUE;
    g_strstrip(contents);
    char *newline = strchr(contents, '\n');
    char *title = "";
    if (newline) {
        *newline = 0;
        title = newline + 1;
        g_strstrip(title);
    }
    gboolean ok = FALSE;
    if (g_strcmp0(contents, "open-settings") == 0) ok = open_settings();
    else if (g_strcmp0(contents, "toggle") == 0) ok = toggle_any_window(title);
    g_remove(control);
    char *result = g_strconcat(control, ".result", NULL);
    g_file_set_contents(result, ok ? "ok" : "missing", -1, NULL);
    g_free(result);
    g_free(contents);
    return G_SOURCE_CONTINUE;
}

__attribute__((constructor)) static void probe_init(void) {
    if (g_getenv("SEANCE_TEST_GTK_CONTROL")) g_timeout_add(25, poll, NULL);
}
"""

INTEGRATIONS = (
    ("OpenCode integration", "opencode"),
    ("Kilo Code integration", "kilo"),
    ("MiMo Code integration", "mimocode"),
    ("Mistral Vibe integration", "vibe"),
    ("Hermes Agent integration", "hermes"),
)

# Installed path relative to HOME and the bundled asset it should match.
PLUGIN_FILES = {
    "opencode": (".config/opencode/plugins/seance-opencode.ts", "opencode-plugin.ts"),
    "kilo": (".config/kilo/plugins/seance-kilo.ts", "kilo-plugin.ts"),
    "mimocode": (".config/mimocode/plugins/seance-mimocode.ts", "mimocode-plugin.ts"),
    "vibe": (".vibe/hooks.toml", "vibe-hooks.toml"),
    "hermes": (".hermes/plugins/seance/__init__.py", None),
}


@unittest.skipUnless(os.environ.get("SEANCE_TEST_BINARY"), "set SEANCE_TEST_BINARY for GUI validation")
class InstallerResourceBase(GhosttyTestCase):
    @classmethod
    def setUpClass(cls):
        for command in ("cc", "pkg-config"):
            if not shutil.which(command):
                raise unittest.SkipTest(f"installer resource tests require {command}")
        cls.probe_dir = tempfile.TemporaryDirectory(prefix="seance-installer-probe-")
        cls.addClassCleanup(cls.probe_dir.cleanup)
        cls.probe = str(Path(cls.probe_dir.name) / "gtk-probe.so")
        source = Path(cls.probe_dir.name) / "probe.c"
        source.write_text(PROBE_SOURCE)
        subprocess.run(
            ["cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror", str(source),
             "-o", cls.probe, *cls.adwaita_flags()],
            check=True,
        )

    @staticmethod
    def adwaita_flags():
        # The Homebrew pkg-config shadowing system packages lacks gtk4.pc.
        for binary in ("/usr/bin/pkg-config", "pkg-config"):
            try:
                flags = subprocess.check_output(
                    [binary, "--cflags", "--libs", "libadwaita-1"],
                    text=True, stderr=subprocess.DEVNULL)
            except (OSError, subprocess.CalledProcessError):
                continue
            return shlex.split(flags)
        raise unittest.SkipTest("libadwaita-1 development files are required")

    def prepare(self):
        home = self.root / "home"
        for relative in (".config/opencode", ".config/kilo", ".config/mimocode", ".vibe"):
            (home / relative).mkdir(parents=True, exist_ok=True)
        hermes = home / ".hermes"
        hermes.mkdir(parents=True, exist_ok=True)
        (hermes / "config.yaml").write_text("plugins:\n  enabled: []\n")

        # Deterministic OpenCode major detection: shadow any real install.
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        opencode = fake_bin / "opencode"
        opencode.write_text("#!/bin/sh\necho 1.0.0\n")
        opencode.chmod(0o755)
        self.env["PATH"] = str(fake_bin) + ":/usr/bin:/bin"

        self.home = home
        self.bundled = Path(self.binary).resolve().parent.parent / "share" / "seance"
        self.control = self.root / "gtk-control"
        self.env["LD_PRELOAD"] = self.probe
        self.env["SEANCE_TEST_GTK_CONTROL"] = str(self.control)
        self.seed()

    def seed(self):
        """Write the pre-start fixture for each scenario."""

    def probe_call(self, line):
        result = Path(str(self.control) + ".result")
        result.unlink(missing_ok=True)
        scratch = Path(str(self.control) + ".write")
        scratch.write_text(line)
        os.replace(scratch, self.control)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if result.exists():
                status = result.read_text().strip()
                result.unlink()
                return status
            time.sleep(0.02)
        self.fail("GTK probe timed out waiting for %r" % line)

    def open_settings(self):
        self.assertEqual("ok", self.probe_call("open-settings"))

    def toggle(self, title):
        self.assertEqual("ok", self.probe_call("toggle\n" + title), title)

    def plugin_path(self, agent):
        return self.home / PLUGIN_FILES[agent][0]

    def plugin_present(self, agent):
        path = self.plugin_path(agent)
        if agent == "vibe":
            # Disable keeps the file's unmanaged header comments.
            return path.exists() and "seance managed hooks: begin" in path.read_text()
        return path.exists()

    def wait_installed(self, agent, expected=True):
        self.wait(lambda: self.plugin_present(agent) == expected,
                  "%s installed=%s" % (agent, expected))

    def owned_temps(self):
        return [path for path in self.home.rglob("*.tmp") if ".seance-" in path.name]

    def fd_count(self):
        return len(os.listdir("/proc/%d/fd" % self.process.pid))

    def settle(self):
        for _ in range(4):
            self.call("system.ping")
            time.sleep(0.1)

    def cycle(self):
        for title, _ in INTEGRATIONS:
            self.toggle(title)
        for _, agent in INTEGRATIONS:
            self.wait_installed(agent, expected=False)
        for title, _ in INTEGRATIONS:
            self.toggle(title)
        for _, agent in INTEGRATIONS:
            self.wait_installed(agent, expected=True)


class RepeatedToggleTest(InstallerResourceBase):
    def test_repeated_cycles_keep_descriptors_and_temps_bounded(self):
        for _, agent in INTEGRATIONS:
            self.wait_installed(agent, expected=True)
        self.open_settings()
        # Warm up lazily created GTK resources before comparing counts.
        self.cycle()
        self.settle()
        baseline = self.fd_count()

        counts = []
        for _ in range(4):
            self.cycle()
            self.settle()
            counts.append(self.fd_count())

        self.assertLessEqual(
            counts[-1] - baseline, 1,
            "integration cycles leaked descriptors: baseline %d, counts %r" % (baseline, counts))
        self.assertEqual([], self.owned_temps())
        for agent in ("opencode", "kilo", "mimocode"):
            relative, bundled = PLUGIN_FILES[agent]
            self.assertEqual((self.bundled / bundled).read_bytes(),
                             (self.home / relative).read_bytes(), agent)


class BlockedReplaceTest(InstallerResourceBase):
    def seed(self):
        plugins = self.home / ".config" / "opencode" / "plugins"
        plugins.mkdir()
        # A directory at the destination makes the rename fail after the temp write.
        self.blocked = plugins / "seance-opencode.ts"
        self.blocked.mkdir()
        # Legacy fixed temp name that belongs to another writer.
        self.foreign_tmp = plugins / "seance-opencode.ts.tmp"
        self.foreign_tmp.write_text("foreign\n")

    def test_blocked_replace_cleans_up_owned_temp_and_retries(self):
        self.assertTrue(self.blocked.is_dir())
        self.assertEqual([], self.owned_temps())
        self.assertEqual("foreign\n", self.foreign_tmp.read_text())

        self.blocked.rmdir()
        self.open_settings()
        self.toggle("OpenCode integration")  # disable
        self.wait_installed("opencode", expected=False)
        self.toggle("OpenCode integration")  # retry install
        self.wait_installed("opencode", expected=True)

        self.assertEqual((self.bundled / "opencode-plugin.ts").read_bytes(),
                         self.plugin_path("opencode").read_bytes())
        self.assertEqual("foreign\n", self.foreign_tmp.read_text())
        self.assertEqual([], self.owned_temps())


class SymlinkDestinationTest(InstallerResourceBase):
    def seed(self):
        plugins = self.home / ".config" / "opencode" / "plugins"
        plugins.mkdir()
        self.target = self.home / "outside.ts"
        self.target.write_text("outside\n")
        self.link = plugins / "seance-opencode.ts"
        self.link.symlink_to(self.target)

    def test_symlink_destination_is_refused_and_target_untouched(self):
        # Startup install must not write through the user's link.
        self.assertEqual("outside\n", self.target.read_text())
        self.assertTrue(self.link.is_symlink())
        self.assertEqual([], self.owned_temps())


if __name__ == "__main__":
    unittest.main()
