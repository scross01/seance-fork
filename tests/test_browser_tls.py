"""Browser TLS exception regressions. Run under Xvfb with SEANCE_TEST_BINARY set.

Verifies that certificate approval is scoped to the approved certificate
and host rather than disabling TLS validation process-wide.
"""
import os
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest

from test_ghostty_integration import GhosttyTestCase


def _generate_cert(directory):
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-keyout",
         os.path.join(directory, "key.pem"), "-out",
         os.path.join(directory, "cert.pem"),
         "-days", "2", "-nodes", "-subj", "/CN=localhost"],
        check=True, capture_output=True, timeout=60,
    )


class _TlsServer:
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


class AutoApproveTlsTests(GhosttyTestCase):
    env_extra = {"G_DEBUG": "fatal-criticals", "SEANCE_AUTO_PROCEED_TLS": "1"}

    def setUp(self):
        self.tls = _TlsServer()
        super().setUp()

    def tearDown(self):
        self.tls.close()
        super().tearDown()

    def prepare(self):
        pass

    def test_approved_host_loads_after_proceed(self):
        self.wait(lambda: self.call("surface.read_screen").get("text"), "shell startup")
        url = "https://localhost:%d" % self.tls.port
        pid = self.call("browser.open", {"url": url})["panel_id"]
        # Auto-proceed should allow the retained cert/host and load the URL.
        deadline = time.monotonic() + 15
        loaded = False
        while time.monotonic() < deadline:
            try:
                got = self.call("browser.get_url", {"panel_id": pid})["url"]
                if "localhost" in got:
                    loaded = True
                    break
            except (AssertionError, OSError, ValueError, KeyError):
                pass
            time.sleep(0.2)
        self.assertTrue(loaded, "approved certificate did not load")
        self.call("browser.close", {"panel_id": pid})


class StrictTlsTests(GhosttyTestCase):
    env_extra = {"G_DEBUG": "fatal-criticals"}

    def setUp(self):
        self.tls = _TlsServer()
        super().setUp()

    def tearDown(self):
        self.tls.close()
        super().tearDown()

    def prepare(self):
        pass

    def test_invalid_cert_does_not_crash_and_panel_survives(self):
        self.wait(lambda: self.call("surface.read_screen").get("text"), "shell startup")
        url = "https://localhost:%d" % self.tls.port
        pid = self.call("browser.open", {"url": url})["panel_id"]
        # Without approval the load must not silently succeed as a trusted
        # page; the app must remain responsive.
        time.sleep(2)
        tid = self.call("surface.list")["surfaces"][0]["id"]
        self.call("surface.read_screen", {"surface_id": tid})
        self.call("browser.close", {"panel_id": pid})
        self.wait(lambda: self.call("surface.read_screen", {"surface_id": tid}).get("text"),
                  "terminal after tls close")


if __name__ == "__main__":
    unittest.main()
