"""Browser TLS exception regressions, each case on its own isolated X server.

Verifies that certificate approval is scoped to the approved certificate and
host rather than disabling TLS validation process-wide.

Success is asserted from content delivered by a real HTTP response: each
fixture serves a marker and a title over loopback and counts delivered
responses, so an approval that merely leaves the requested URL in the toolbar
cannot pass. ``browser.get_url`` is never used as evidence because it falls
back to the requested URL while nothing has loaded.

Approval goes through the actual in-window dialog using a physical keyboard
harness: the dialog's default response is Cancel, so Shift+Tab reaches
"Proceed anyway" and Return activates it. The harness only types once the app
logs that the dialog was presented (``SEANCE_TLS_DIALOG_LOG``), so a keystroke
can never land on the dialog before it is interactive. Rejection cases never
send approval keys; they observe the fixture staying untouched, then dismiss
the dialog with Escape and wait for the logged cancel response.
"""
import json
import os
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest

import test_keyboard_remaps as keyboard
from test_ghostty_integration import GhosttyTestCase

_counter = 0
DIALOG_PRESENTED = "tls dialog presented"
DIALOG_CANCELED = "tls dialog response cancel"


def _generate_cert(cert_path, key_path):
    """Self-signed localhost certificate; a fresh key pair per call."""
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-keyout", key_path,
         "-out", cert_path, "-days", "2", "-nodes", "-subj", "/CN=localhost",
         "-addext", "subjectAltName=DNS:localhost"],
        check=True, capture_output=True, timeout=60,
    )


class _Page:
    """Loopback fixture serving one marker page, optionally over TLS.

    ``accepts`` counts TCP connections, ``handshakes`` completed TLS
    handshakes, and ``delivered`` complete HTTP responses. Only ``delivered``
    proves the protected content reached the browser.
    """

    def __init__(self, tls, host_marker=None):
        global _counter
        _counter += 1
        self.marker = host_marker or "SEANCE_TLS_%d" % _counter
        self.title = "tls-page-%d" % _counter
        self.tmp = tempfile.TemporaryDirectory(prefix="seance-tls-fixture-")
        self.context = None
        if tls:
            cert = os.path.join(self.tmp.name, "cert.pem")
            key = os.path.join(self.tmp.name, "key.pem")
            _generate_cert(cert, key)
            self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            self.context.load_cert_chain(cert, key)
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("127.0.0.1", 0))
        sock.listen(8)
        self.port = sock.getsockname()[1]
        self.accepts = 0
        self.handshakes = 0
        self.delivered = 0
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
            self.accepts += 1
            try:
                stream = self.context.wrap_socket(conn, server_side=True) if self.context else conn
                if self.context:
                    self.handshakes += 1
                request = b""
                while b"\r\n\r\n" not in request and len(request) < 65536:
                    part = stream.recv(4096)
                    if not part:
                        break
                    request += part
                body = ("<!doctype html><html><head><title>%s</title></head>"
                        "<body><h1>%s</h1></body></html>" % (self.title, self.marker))
                stream.sendall(("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n"
                                "Content-Length: %d\r\nConnection: close\r\n\r\n%s"
                                % (len(body), body)).encode())
                self.delivered += 1
                stream.close()
            except (ssl.SSLError, OSError):
                try:
                    conn.close()
                except OSError:
                    pass
        sock.close()

    def url(self, host):
        scheme = "https" if self.context else "http"
        return "%s://%s:%d/" % (scheme, host, self.port)

    def close(self):
        self._stop.set()
        self._thread.join(timeout=3)
        self.tmp.cleanup()


class BrowserTlsTestCase(keyboard.XServerTestCase, GhosttyTestCase):
    env_extra = {"G_DEBUG": "fatal-criticals", "SEANCE_TLS_DIALOG_LOG": "1"}
    required_commands = ("Xvfb", "xdotool")

    def setUp(self):
        # A bare X server, not the developer's session: with a window manager
        # in the way the mounted dialog never receives the keyboard, so the
        # approval keys land in the terminal.
        keyboard.XServerTestCase.setUp(self)
        self.env_extra = dict(type(self).env_extra, DISPLAY=self.display_name)
        GhosttyTestCase.setUp(self)

    def prepare(self):
        pass

    def tearDown(self):
        # WebKit's helper processes can outlive the app briefly and still write
        # into the temporary XDG tree; give them a moment before the harness
        # removes it.
        self.stop()
        time.sleep(0.5)

    def page(self, tls=True):
        fixture = _Page(tls)
        self.addCleanup(fixture.close)
        return fixture

    def request(self, method, params=None, timeout=15):
        """Like GhosttyTestCase.call, with room for browser.open's first paint."""
        with socket.socket(socket.AF_UNIX) as conn:
            conn.settimeout(timeout)
            conn.connect(str(self.socket_path))
            conn.sendall((json.dumps({"id": "test", "method": method,
                                      "params": params}) + "\n").encode())
            data = b""
            while b"\n" not in data:
                part = conn.recv(65536)
                if not part:
                    break
                data += part
        reply = json.loads(data)
        self.assertTrue(reply["ok"], reply)
        return reply.get("result")

    def open(self, url):
        return self.request("browser.open", {"url": url})["panel_id"]

    def text(self, panel_id):
        """Read the document text, retrying a connection the app reset.

        A panel whose TLS dialog is still outstanding can have its eval
        connection reset before the request is served; the app stays healthy,
        so retry briefly rather than turning that into a test failure.
        """
        for attempt in range(3):
            try:
                return str(self.request("browser.eval", {
                    "panel_id": panel_id, "script": "document.body.textContent"}))
            except (BrokenPipeError, ConnectionResetError, TimeoutError) as exc:
                if self.process.poll() is not None:
                    self.fail("application exited while reading panel content: %r" % (exc,))
                if attempt == 2:
                    raise
                time.sleep(0.2)

    def log_text(self):
        # Read through a separate handle: seeking the shared stderr file would
        # move the offset the app writes at.
        self.log.flush()
        with open(self.log.name, "r", errors="replace") as handle:
            return handle.read()

    def dialogs_presented(self):
        return self.log_text().count(DIALOG_PRESENTED)

    def dialogs_canceled(self):
        return self.log_text().count(DIALOG_CANCELED)

    def wait_dialog(self, previous):
        self.wait(lambda: self.dialogs_presented() > previous, "TLS dialog presentation")

    def wait_loaded(self, panel_id, page, timeout=45):
        # A TLS-approved page has to clear the certificate decision, load the
        # document and render it before the marker is readable. On a loaded CI
        # runner that sequence routinely exceeds the 15 s default, so allow
        # more headroom here; the assertion itself is unchanged.
        self.wait(lambda: page.marker in self.text(panel_id),
                  "fixture content for %s" % page.marker, timeout=timeout)

    def assert_not_delivered(self, panel_id, page, baseline, seconds=3.0):
        """Observe a bounded window in which the fixture must stay untouched.

        The delivered-response count is the authoritative assertion: it proves
        the protected body never left the fixture. The document check is
        supplementary and skipped while the panel has no readable document.
        """
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.assertEqual(baseline, page.delivered,
                             "fixture delivered protected content without approval")
            try:
                self.assertNotIn(page.marker, self.text(panel_id))
            except (BrokenPipeError, ConnectionResetError, TimeoutError):
                pass
            time.sleep(0.2)

    def x(self, *args, check=False):
        """Run an X tool against this case's own server."""
        return subprocess.run(args, env=self.env, check=check, capture_output=True,
                              text=True, timeout=10)

    def _focus_app_window(self):
        """Focus the app's largest visible toplevel.

        The app owns more than one toplevel, and without a window manager X
        input focus can land on one that never sees the dialog. Picking the
        largest visible window and focusing it explicitly keeps the keyboard
        harness deterministic.
        """
        windows = self.x("xdotool", "search", "--onlyvisible", "--pid",
                         str(self.process.pid)).stdout.split()
        best, best_area = None, -1
        for window in windows:
            geometry = self.x("xdotool", "getwindowgeometry", "--shell", window).stdout
            fields = dict(line.split("=", 1) for line in geometry.splitlines() if "=" in line)
            area = int(fields.get("WIDTH", 0)) * int(fields.get("HEIGHT", 0))
            if area > best_area:
                best, best_area = window, area
        if best:
            self.x("xdotool", "windowfocus", "--sync", best)

    def send_keys(self, *keys):
        self._focus_app_window()
        self.x("xdotool", "key", "--delay", "150", *keys, check=True)

    def approve_dialog(self, page, panel_id, presented):
        """Approve exactly one dialog: the one raised by `page`'s failing host.

        `presented` is the presentation count captured before the load that
        triggered this dialog, so the harness types only at this dialog.
        """
        self.wait(lambda: page.accepts > 0, "TLS handshake attempt")
        self.wait_dialog(presented)
        self.send_keys("shift+Tab", "Return")
        self.wait_loaded(panel_id, page)

    def dismiss_dialog(self):
        canceled = self.dialogs_canceled()
        self.send_keys("Escape")
        self.wait(lambda: self.dialogs_canceled() > canceled, "dialog cancellation")

    def assert_healthy(self):
        self.assertTrue(self.call("system.ping"))
        surface = self.call("surface.list")["surfaces"][0]["id"]
        self.call("surface.read_screen", {"surface_id": surface})


class TlsApprovalScopeTests(BrowserTlsTestCase):
    def test_plain_http_control_serves_expected_content(self):
        """Content/eval readiness control: no certificate involved."""
        page = self.page(tls=False)
        panel = self.open(page.url("127.0.0.1"))
        self.wait_loaded(panel, page)
        self.assertEqual(page.title, self.call("browser.eval",
                                               {"panel_id": panel,
                                                "script": "document.title"}))
        self.assertEqual(1, page.delivered)

    def test_approved_pair_loads_content_and_reload_does_not_reprompt(self):
        page = self.page()
        dialogs = self.dialogs_presented()
        panel = self.open(page.url("localhost"))

        # Strict by default: the self-signed certificate is not trusted, so
        # neither the marker nor the HTTP response may appear.
        self.wait_dialog(dialogs)
        self.assert_not_delivered(panel, page, baseline=0)
        self.assertEqual(0, page.delivered)

        self.approve_dialog(page, panel, dialogs)
        self.assertEqual(page.title, self.call("browser.eval",
                                               {"panel_id": panel,
                                                "script": "document.title"}))
        self.assertEqual(1, page.delivered)

        # The approved certificate+host pair is remembered for the session:
        # reloading delivers the page again without another dialog.
        dialogs = self.dialogs_presented()
        self.call("browser.reload", {"panel_id": panel})
        self.wait(lambda: page.delivered >= 2, "reload of the approved pair")
        self.wait_loaded(panel, page)
        self.assertEqual(dialogs, self.dialogs_presented(),
                         "reload must reuse the approved certificate and host")

    def test_same_certificate_other_host_requires_its_own_approval(self):
        page = self.page()
        dialogs = self.dialogs_presented()
        panel = self.open(page.url("localhost"))
        self.wait_dialog(dialogs)
        self.approve_dialog(page, panel, dialogs)
        self.assertEqual(1, page.delivered)

        # Same certificate, different host: the hostname is not in the
        # approved pair, so a new panel must stay unapproved in the same
        # network session and ask again.
        dialogs = self.dialogs_presented()
        other = self.open(page.url("127.0.0.1"))
        self.wait_dialog(dialogs)
        self.assert_not_delivered(other, page, baseline=1)
        self.dismiss_dialog()
        self.assert_healthy()

    def test_other_certificate_on_approved_host_requires_its_own_approval(self):
        approved = self.page()
        unapproved = self.page()
        dialogs = self.dialogs_presented()
        panel = self.open(approved.url("localhost"))
        self.wait_dialog(dialogs)
        self.approve_dialog(approved, panel, dialogs)
        self.assertEqual(1, approved.delivered)

        # Same host, different certificate: approval is keyed by the retained
        # certificate, not by host alone.
        dialogs = self.dialogs_presented()
        other = self.open(unapproved.url("localhost"))
        self.wait_dialog(dialogs)
        self.assert_not_delivered(other, unapproved, baseline=0)
        self.dismiss_dialog()
        self.assert_healthy()

    def test_fresh_session_rejects_unapproved_certificate(self):
        page = self.page()
        dialogs = self.dialogs_presented()
        panel = self.open(page.url("localhost"))
        self.wait_dialog(dialogs)
        self.assert_not_delivered(panel, page, baseline=0, seconds=4.0)
        self.dismiss_dialog()
        self.assert_healthy()
        self.call("browser.close", {"panel_id": panel})
        self.assert_healthy()

    def test_closing_panel_with_tls_dialog_outstanding_is_safe(self):
        page = self.page()
        dialogs = self.dialogs_presented()
        panel = self.open(page.url("localhost"))
        self.wait_dialog(dialogs)

        # The dialog's context outlives the panel; teardown must invalidate it
        # rather than leave a dangling panel pointer (G_DEBUG makes a critical
        # fatal for this process).
        self.call("browser.close", {"panel_id": panel})
        self.assert_healthy()
        self.assertEqual(0, page.delivered)


class BlanketApprovalMutationTests(BrowserTlsTestCase):
    """Mutation evidence for the scoping assertions above.

    With blanket auto-proceed the cross-host case from
    ``test_same_certificate_other_host_requires_its_own_approval`` delivers the
    protected marker, which is exactly what that test asserts must not happen.
    Production policy is untouched; only this disposable fixture session sets
    the documented test seam.
    """

    env_extra = {"G_DEBUG": "fatal-criticals", "SEANCE_AUTO_PROCEED_TLS": "1"}

    def test_blanket_approval_would_deliver_cross_host_content(self):
        page = self.page()
        first = self.open(page.url("localhost"))
        self.wait_loaded(first, page)
        self.assertEqual(1, page.delivered)

        other_host = self.open(page.url("127.0.0.1"))
        self.wait(lambda: page.delivered >= 2, "blanket approval of a second host")
        self.wait_loaded(other_host, page)


if __name__ == "__main__":
    unittest.main()
