#!/usr/bin/env python3
"""Lightweight mock TAS endpoint server for brownfield testing."""

import json
from http.server import HTTPServer, BaseHTTPRequestHandler

ROUTES = {
    "/fulcio/healthz": (200, "ok"),
    "/rekor/api/v1/log": (200, json.dumps({"treeSize": 0, "rootHash": "", "signedTreeHead": ""})),
    "/api/v1/timestamp/certchain": (200, json.dumps(["mock-tsa-root-cert"])),
    "/tuf/root.json": (200, json.dumps({"signed": {"_type": "root", "version": 1}})),
    "/tuf/1.root.json": (200, json.dumps({"signed": {"_type": "root", "version": 1}})),
    "/oidc/.well-known/openid-configuration": (200, json.dumps({
        "issuer": "http://localhost:8090/oidc",
        "authorization_endpoint": "http://localhost:8090/oidc/auth",
        "token_endpoint": "http://localhost:8090/oidc/token",
        "jwks_uri": "http://localhost:8090/oidc/certs",
    })),
}


class MockHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ROUTES:
            status, body = ROUTES[self.path]
            self.send_response(status)
            content_type = "application/json" if self.path != "/fulcio/healthz" else "text/plain"
            self.send_header("Content-Type", content_type)
            self.end_headers()
            self.wfile.write(body.encode())
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 8090), MockHandler)
    print("Mock TAS server listening on :8090")
    server.serve_forever()
