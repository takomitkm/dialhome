#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bootstrap-server.py -- the ONE public port that onboards any new machine.

    GET /healthz                 -> "ok" (no token)
    GET /i?n=<name>&t=<token>    -> the personalized installer for that machine

Security model:
  * the token IS the capability: without it the port answers nothing useful
  * the token travels over plain HTTP, so rotate it (delete bootstrap-token and
    restart) after onboarding sessions, and treat campus HTTP as sniffable
  * every request is logged to bootstrap.log (ip, name, bytes)
  * rate limited per IP; enroll output is generated per request by enroll.sh, so
    each connection mints exactly one node identity (key + a fresh port pair)

Run (systemd, as user): see dialhome-bootstrap.service in this directory.
"""
import hmac
import http.server
import os
import socketserver
import subprocess
import sys
import time
import urllib.parse

BASE = os.path.expanduser("~/.magpie-connector")
TOKEN_FILE = os.path.join(BASE, "bootstrap-token")
LOG_FILE = os.path.join(BASE, "bootstrap.log")
NAMES_FILE = os.path.join(BASE, "bootstrap-names.json")
ENROLL = os.path.join(BASE, "enroll.sh")
RATE_MAX = 6          # requests per IP per minute
RATE_WINDOW = 60.0

window = {}           # ip -> [timestamps]


def name_for_ip(ip):
    """Stable node name per client IP: first request allocates, later ones reuse.
    Two machines that share one IP (heavy NAT) would share a slot -- pass ?n=<name>
    from the client to override in that case."""
    import json
    names = {}
    if os.path.exists(NAMES_FILE):
        with open(NAMES_FILE, encoding="utf-8") as f:
            try:
                names = json.load(f)
            except ValueError:
                names = {}
    if ip not in names:
        import secrets
        suffix = secrets.token_hex(2)
        names[ip] = f"n-{ip.replace('.', '-')}-{suffix}"
        with open(NAMES_FILE, "w", encoding="utf-8") as f:
            json.dump(names, f, indent=1)
    return names[ip]


def read_token():
    with open(TOKEN_FILE, encoding="utf-8") as f:
        return f.read().strip()


def log(msg):
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%dT%H:%M:%S ") + msg + "\n")
    except OSError:
        pass


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "dialhome-bootstrap/1"
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # silence default stderr logging
        pass

    def _text(self, code, body):
        body = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        ip = self.client_address[0]
        now = time.time()
        w = [t for t in window.get(ip, []) if now - t < RATE_WINDOW]
        if len(w) >= RATE_MAX:
            log(f"RATE ip={ip}")
            return self._text(429, "slow down\n")
        w.append(now)
        window[ip] = w

        if u.path == "/healthz":
            return self._text(200, "ok\n")
        if u.path != "/i":
            return self._text(404, "not found\n")

        q = urllib.parse.parse_qs(u.query)
        given = (q.get("t") or [""])[0]
        if not given or not hmac.compare_digest(given, read_token()):
            log(f"DENY ip={ip} bad-token")
            return self._text(403, "bad token\n")

        if q.get("n"):
            raw = (q.get("n") or ["node"])[0]
            name = "".join(c for c in raw.lower() if c.isalnum() or c == "-")[:40] or "node"
        else:
            # no name given: allocate/reuse a stable per-IP identity, so the client
            # one-liner stays as short as `iex(curl.exe -s '<url>?t=<token>')`
            name = name_for_ip(ip)

        try:
            r = subprocess.run(["bash", ENROLL, name], capture_output=True,
                               text=True, timeout=60)
        except subprocess.TimeoutExpired:
            log(f"TIMEOUT name={name} ip={ip}")
            return self._text(504, "enroll timeout\n")

        out = r.stdout or ""
        if len(out) < 2000 or "FromBase64String" not in out:
            log(f"FAIL name={name} ip={ip} err={r.stderr[-200:]!r}")
            return self._text(500, "enroll failed: " + (r.stderr or "")[-300:] + "\n")

        log(f"OK name={name} ip={ip} bytes={len(out)}")
        self._text(200, out)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18443
    bind = sys.argv[2] if len(sys.argv) > 2 else "0.0.0.0"
    if not os.path.exists(TOKEN_FILE):
        import secrets
        with open(TOKEN_FILE, "w", encoding="utf-8") as f:
            f.write(secrets.token_hex(16))
        os.chmod(TOKEN_FILE, 0o600)
        log("token generated")
    log(f"listening on {bind}:{port}")
    print(f"dialhome bootstrap on {bind}:{port} (token: {TOKEN_FILE})")
    Server((bind, port), Handler).serve_forever()


if __name__ == "__main__":
    main()