"""Localhost-only HTTP stub for tests.

POST *        -> 200, logs {"method","path","headers","body"} as a JSON line.
GET /yahoo-ok -> Yahoo-like chart JSON.
GET /stooq-ok -> Stooq-like CSV.
GET /html     -> HTML page.
GET /stooq-nd -> CSV with N/D.
GET other     -> 404.
POST /fail    -> 500.
Usage: python3 -I listener.py <portfile> <logfile>
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORTFILE, LOGFILE = sys.argv[1], sys.argv[2]

YAHOO = {"chart": {"result": [{"meta": {"symbol": "SPCX", "regularMarketPrice": 101.25,
                                         "regularMarketTime": 1763139600}}], "error": None}}
STOOQ = "Symbol,Date,Time,Open,High,Low,Close,Volume\r\nSPCX.US,2025-11-14,22:00:00,100,105,99,103.5,12345\r\n"
STOOQ_ND = "Symbol,Date,Time,Open,High,Low,Close,Volume\r\nSPCX.US,N/D,N/D,N/D,N/D,N/D,N/D,N/D\r\n"


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _log(self, body):
        with open(LOGFILE, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path,
                                "headers": dict(self.headers.items()), "body": body}) + "\n")

    def do_GET(self):
        self._log("")
        routes = {"/yahoo-ok": (json.dumps(YAHOO), "application/json"),
                  "/stooq-ok": (STOOQ, "text/csv"),
                  "/stooq-nd": (STOOQ_ND, "text/csv"),
                  "/html": ("<!DOCTYPE html><html><body>nope</body></html>", "text/html")}
        if self.path in routes:
            self._send(200, *routes[self.path])
        else:
            self._send(404, "not found", "text/plain")

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n).decode()
        self._log(body)
        if self.path == "/fail":
            self._send(500, '{"error":"boom"}', "application/json")
        else:
            self._send(200, '{"ok":true}', "application/json")


srv = HTTPServer(("127.0.0.1", 0), H)
with open(PORTFILE, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
