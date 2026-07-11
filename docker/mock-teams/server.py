#!/usr/bin/env python3
"""Mock Microsoft Teams incoming-webhook receiver (Issue 08).

The POC has no real Teams tenant, so this stands in for the two
severity-routed channels. It honors the Teams incoming-webhook contract
(accept a JSON card POST, answer 200 with body "1") and keeps everything it
receives, so the verify script can assert an alert actually arrived with its
runbook link. Production swaps the webhook URLs for real Teams ones; nothing
else changes.

    POST /critical | /warning   <- Alertmanager msteams_configs + Airflow
                                   failure callbacks
    GET  /messages              -> {"critical": [...], "warning": [...]}
    DELETE /messages            -> clear (verify scripts isolate runs)
"""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

MESSAGES = {"critical": [], "warning": []}


class Handler(BaseHTTPRequestHandler):
    def _respond(self, code: int, body: bytes, content_type="text/plain") -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        channel = self.path.strip("/")
        if channel not in MESSAGES:
            return self._respond(404, b"unknown channel")
        length = int(self.headers.get("Content-Length", 0))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return self._respond(400, b"invalid json")
        MESSAGES[channel].append(payload)
        print(f"[mock-teams] {channel}: {json.dumps(payload)[:300]}", flush=True)
        # Teams incoming webhooks answer literal "1" on success.
        self._respond(200, b"1")

    def do_GET(self):
        if self.path.startswith("/messages"):
            return self._respond(200, json.dumps(MESSAGES).encode(), "application/json")
        self._respond(200, b"mock-teams up")

    def do_DELETE(self):
        if self.path.startswith("/messages"):
            for channel in MESSAGES:
                MESSAGES[channel].clear()
            return self._respond(200, b"cleared")
        self._respond(404, b"not found")

    def log_message(self, *args):  # quieter default access log
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
