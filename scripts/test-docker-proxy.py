#!/usr/bin/env python3
"""Exercise the built proxy process and its signal-driven socket cleanup."""

import pathlib
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest


BINARY = pathlib.Path(sys.argv.pop(1)).resolve(strict=True)


class DockerProxyProcessTests(unittest.TestCase):
    def test_help(self):
        result = subprocess.run(
            [str(BINARY), "--help"], capture_output=True, text=True, timeout=10
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--socket <absolute-path>", result.stdout)
        self.assertEqual(result.stderr, "")

    def wait_until_ready(self, process, endpoint):
        deadline = time.monotonic() + 10
        while True:
            self.assertIsNone(process.poll(), "Proxy exited before becoming ready")
            self.assertLess(time.monotonic(), deadline, "Proxy did not start")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(2)
                try:
                    connection.connect(str(endpoint))
                except (FileNotFoundError, ConnectionRefusedError):
                    time.sleep(0.02)
                    continue
                connection.sendall(b"GET /_ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                response = bytearray()
                while chunk := connection.recv(4096):
                    response.extend(chunk)
                    self.assertLessEqual(len(response), 16384)
                    self.assertLess(time.monotonic(), deadline, "Readiness response timed out")
                self.assertTrue(response.startswith(b"HTTP/1.1 200 "), response)
                self.assertEqual(response.partition(b"\r\n\r\n")[2], b"OK")
                return

    def check_shutdown(self, shutdown_signal, partial_request):
        with tempfile.TemporaryDirectory(prefix="hw-proxy-", dir="/private/tmp") as temporary:
            root = pathlib.Path(temporary)
            endpoint = root / "proxy.sock"
            process = subprocess.Popen(
                [str(BINARY), "--socket", str(endpoint), "--control-socket", str(root / "control.sock")],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            connection = None
            try:
                self.wait_until_ready(process, endpoint)
                self.assertTrue(stat.S_ISSOCK(endpoint.stat().st_mode))
                self.assertEqual(stat.S_IMODE(endpoint.stat().st_mode), 0o600)
                if partial_request:
                    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    connection.settimeout(5)
                    connection.connect(str(endpoint))
                    connection.sendall(b"GET /_ping HTTP/1.1\r\nHost: localhost\r\n")
                    # Keep the request open while the foreground read waits for headers.
                    time.sleep(0.25)
                process.send_signal(shutdown_signal)
                stdout, stderr = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertEqual(stdout, "")
                self.assertEqual(stderr, "")
                self.assertFalse(endpoint.exists(), "Owned socket was not removed")
                self.assertEqual(list(root.iterdir()), [], "Proxy left resources behind")
            finally:
                if connection is not None:
                    connection.close()
                if process.poll() is None:
                    process.kill()
                process.communicate(timeout=5)

    def test_idle_sigterm(self):
        self.check_shutdown(signal.SIGTERM, False)

    def test_idle_sigint(self):
        self.check_shutdown(signal.SIGINT, False)

    def test_partial_request_sigterm(self):
        self.check_shutdown(signal.SIGTERM, True)

    def test_partial_request_sigint(self):
        self.check_shutdown(signal.SIGINT, True)


if __name__ == "__main__":
    unittest.main()
