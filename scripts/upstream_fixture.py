#!/usr/bin/env python3
"""Trivial upstream fixture for slanginx M1 proxy acceptance.

Usage: upstream_fixture.py <port> <marker>

Endpoints:
  /hello      200, body "hello from upstream <marker>\n"
  /echo       200, echoes method / path / selected headers / body
  /status404  404, body "upstream <marker> says missing\n"

Everything else behaves like /echo. HTTP/1.1 with explicit
Content-Length on every response; HEAD sends the /hello headers
with no body, as a real upstream would.
"""
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
MARKER = sys.argv[2]


def hello_body():
    return ("hello from upstream %s\n" % MARKER).encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n > 0 else b""

    def _send(self, code, body, ctype="text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _echo(self, body):
        lines = [
            "method %s" % self.command,
            "path %s" % self.path,
            "x-forwarded-for %s" % (self.headers.get("X-Forwarded-For") or "-"),
            "x-real-ip %s" % (self.headers.get("X-Real-Ip") or "-"),
            "user-agent %s" % (self.headers.get("User-Agent") or "-"),
            "accept-language %s" % (self.headers.get("Accept-Language") or "-"),
            "content-type %s" % (self.headers.get("Content-Type") or "-"),
            "body-begin",
        ]
        head = ("\n".join(lines) + "\n").encode()
        return head + body + b"\nbody-end\n"

    def _handle(self):
        body = self._read_body()
        # The proxy forwards the full path (route prefix kept),
        # so endpoints are matched on the path tail.
        path_only = self.path.split("?", 1)[0]
        if path_only.endswith("/hello"):
            self._send(200, hello_body())
        elif path_only.endswith("/status404"):
            self._send(404, ("upstream %s says missing\n" % MARKER).encode())
        else:
            self._send(200, self._echo(body))

    do_GET = _handle
    do_POST = _handle
    do_PUT = _handle
    do_DELETE = _handle
    do_HEAD = _handle


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    print("fixture %s on %d" % (MARKER, PORT), flush=True)
    server.serve_forever()
