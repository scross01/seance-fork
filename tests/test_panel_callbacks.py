"""Panel callback lifetime regressions with physical input on isolated X servers.

Covers config reload racing a terminal close, browser first-load map →
close, a flashing browser → close with animations on and off, and closing
a browser panel while its TLS error dialog is outstanding. The
deterministic source/dialog ownership cases live in the native tests of
src/pane.zig and src/web_panel.zig; these cases drive the real GTK/WebKit
paths under fatal criticals.

Browser commands intentionally omit `panel_id`: the explicit-id lookup
resolves terminals and browser panels through one walk while their IDs
come from separate counters, so the focused-panel fallback is the reliable
form until id unification lands elsewhere.
"""
import os
import socket
import ssl
import subprocess
import tempfile
import threading
import time

import test_keyboard_remaps as keyboard


def _generate_cert(directory):
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-keyout",
         os.path.join(directory, "key.pem"), "-out",
         os.path.join(directory, "cert.pem"),
         "-days", "2", "-nodes", "-subj", "/CN=localhost"],
        check=True, capture_output=True, timeout=60,
    )


class _TlsServer:
    """Local HTTPS server with a self-signed certificate."""

    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="seance-tls-server-")
        _generate_cert(self.tmp.name)
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(os.path.join(self.tmp.name, "cert.pem"),
                                     os.path.join(self.tmp.name, "key.pem"))
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("127.0.0.1", 0))
        sock.listen(4)
        self.port = sock.getsockname()[1]
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._serve, args=(sock,), daemon=True)
        self._thread.start()

    def _serve(self, sock):
        sock.settimeout(0.2)
        while not self._stop.is_set():
            try:
                conn, _ = sock.accept()
            except (socket.timeout, TimeoutError):
                continue
            except OSError:
                break
            try:
                tls = self.context.wrap_socket(conn, server_side=True)
                try:
                    tls.recv(65536)
                finally:
                    tls.close()
            except (ssl.SSLError, OSError):
                try:
                    conn.close()
                except OSError:
                    pass
        sock.close()

    def close(self):
        self._stop.set()
        self._thread.join(timeout=3)
        self.tmp.cleanup()


class PanelCallbackTests(keyboard.PhysicalKeyboardTestCase):
    env_extra = {"G_DEBUG": "fatal-criticals"}

    def stop_clean(self):
        self.app.stop()
        self.assertEqual(self.app.process.returncode, 0)
        self.app.log.seek(0)
        log = self.app.log.read()
        self.assertNotIn("CRITICAL", log)

    def assert_terminal_usable(self, marker):
        self.app.call("surface.send_text", {
            "text": "printf '%s\\n' " % marker + "\n",
        })
        self.app.wait(lambda: marker in self.app.call("surface.read_screen")["text"],
                      "terminal input after close")
        self.stop_clean()

    def open_browser(self):
        self.app.call("browser.open", {"url": "about:blank"})


class ConfigReloadThenCloseTests(PanelCallbackTests):
    def test_config_reload_immediately_followed_by_terminal_close(self):
        # Reload queues a deferred redraw for every pane; closing right
        # after must cancel it before the pane is freed.
        self.run_x("xdotool", "key", "ctrl+shift+comma")
        self.run_x("xdotool", "key", "ctrl+shift+w")
        self.app.wait(lambda: self.app.call("surface.read_screen").get("text"),
                      "replacement shell after reload+close")
        self.assert_terminal_usable("AFTER_RELOAD_CLOSE")


class BrowserMapCloseTests(PanelCallbackTests):
    def test_browser_map_then_immediate_close(self):
        self.open_browser()
        # Close right after opening: the first-load idle queued on map
        # may still be pending when the panel is destroyed.
        self.app.call("browser.close", {})
        self.app.wait(lambda: self.app.call("surface.read_screen").get("text"),
                      "terminal after browser close")
        self.assert_terminal_usable("AFTER_BROWSER_MAP_CLOSE")


class FlashBrowserCloseBase(PanelCallbackTests):
    def flash_and_close(self):
        self.open_browser()
        # flash_focused (ctrl+shift+H) arms the flash chain on the active
        # (browser) panel; close while its timeout sources are pending.
        self.run_x("xdotool", "key", "ctrl+shift+H")
        self.app.call("browser.close", {})
        self.app.wait(lambda: self.app.call("surface.read_screen")["text"],
                      "terminal after flashing browser close")
        self.assert_terminal_usable("AFTER_FLASH_CLOSE")


class FlashBrowserCloseAnimationsOnTests(FlashBrowserCloseBase):
    def test_flashing_browser_close_with_animations_on(self):
        self.flash_and_close()


class FlashBrowserCloseAnimationsOffTests(FlashBrowserCloseBase):
    def setUp(self):
        super().setUp()
        # Reduced-motion path: static 400ms highlight instead of the pulse.
        gdir = self.app.root / "config" / "gtk-4.0"
        gdir.mkdir(exist_ok=True)
        (gdir / "settings.ini").write_text("[Settings]\ngtk-enable-animations=false\n")
        self.app.stop()
        self.app.start()
        window = self.run_x("xdotool", "search", "--onlyvisible", "--pid",
                            str(self.app.process.pid)).strip().splitlines()[0]
        self.run_x("xdotool", "windowfocus", "--sync", window)
        self.app.wait(lambda: self.app.call("surface.read_screen").get("text"),
                      "shell startup after animation settings change")

    def test_flashing_browser_close_with_animations_off(self):
        self.flash_and_close()


class TlsDialogCloseTests(PanelCallbackTests):
    def setUp(self):
        super().setUp()
        self.tls = _TlsServer()
        self.addCleanup(self.tls.close)

    def test_tls_dialog_outstanding_then_panel_close(self):
        self.app.call("browser.open", {"url": "https://localhost:%d" % self.tls.port})
        # Wait for the load attempt to start and settle; the resulting
        # self-signed error presents an AdwAlertDialog whose context is
        # owned until its response fires.
        deadline = time.monotonic() + 15
        saw_loading = False
        while time.monotonic() < deadline:
            try:
                loading = self.app.call("browser.is_loading")["loading"]
            except (AssertionError, OSError, ValueError):
                break
            if loading:
                saw_loading = True
            elif saw_loading:
                break
            time.sleep(0.05)

        # Close the panel while the dialog is (or was) outstanding: the
        # response must become a harmless cancellation, never a UAF.
        try:
            self.app.call("browser.close", {})
        except (AssertionError, OSError, ValueError):
            pass  # panel may already be gone with its dialog
        self.app.wait(lambda: self.app.call("surface.read_screen").get("text"),
                      "terminal after tls dialog close")
        self.assert_terminal_usable("AFTER_TLS_DIALOG_CLOSE")


class ExplicitPanelIdTests(PanelCallbackTests):
    def test_explicit_panel_ids_are_unique_and_addressable(self):
        pid = self.app.call("browser.open", {"url": "about:blank"})["panel_id"]
        terminal_ids = {s["id"] for s in self.app.call("surface.list")["surfaces"]}
        # surface.list only reports terminal panels, so this is exactly the
        # collision the two-counter scheme guarantees on first browser open.
        self.assertNotIn(pid, terminal_ids,
                         "browser panel id collides with a terminal id")
        # Mirror direction: a surface.send_text targeted at a known terminal
        # id still succeeds while a browser panel is open.
        tid = next(iter(terminal_ids))
        self.app.call("surface.send_text", {"surface_id": tid, "text": "echo MIRROR_OK\n"})
        # Explicit-id close must address the browser panel directly.
        self.app.call("browser.close", {"panel_id": pid})
        self.app.wait(lambda: self.app.call("surface.read_screen").get("text"),
                      "terminal after explicit-id browser close")
        self.assert_terminal_usable("AFTER_EXPLICIT_ID_CLOSE")


if __name__ == "__main__":
    import unittest
    unittest.main()
