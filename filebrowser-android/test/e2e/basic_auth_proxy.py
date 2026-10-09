#!/usr/bin/env python3
"""Reverse proxy that demands HTTP basic auth, like a hardened deployment.

Usage: basic_auth_proxy.py LISTEN_PORT UPSTREAM_URL USER PASSWORD

It forwards every request (including tus PATCH/HEAD) to UPSTREAM_URL and
strips the Authorization header, so File Browser only sees its own X-Auth.
"""
import base64
import http.client
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

PORT, UPSTREAM, USER, PASSWORD = int(sys.argv[1]), urlsplit(sys.argv[2]), sys.argv[3], sys.argv[4]
EXPECTED = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()
HOP = {"connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade", "authorization", "host"}


class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _forward(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        if self.headers.get("Authorization") != EXPECTED:
            reply = b"proxy authentication required"
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="e2e"')
            self.send_header("Content-Length", str(len(reply)))
            self.end_headers()
            self.wfile.write(reply)
            return
        conn = http.client.HTTPConnection(UPSTREAM.hostname, UPSTREAM.port, timeout=120)
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        conn.request(self.command, self.path, body=body, headers=headers)
        res = conn.getresponse()
        data = res.read()
        self.send_response(res.status)
        for k, v in res.getheaders():
            if k.lower() not in HOP and k.lower() != "content-length":
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)
        conn.close()

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = _forward

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", PORT), Proxy).serve_forever()
