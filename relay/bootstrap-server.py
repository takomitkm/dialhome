#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bootstrap-server.py -- the ONE public port that onboards any new machine.

    GET /healthz                 -> "ok"
    GET /i[?f=<fp>][?n=<name>]   -> the personalized installer for that machine

Security model (owner's call: OPEN enrollment -- no token):
  * anyone who can reach the port can mint a node identity; that is intentional
  * the hard ceiling is the port pool itself (enroll.sh refuses when the pairs
    run out), plus a per-IP rate limit and full request logging
  * node keys stay unprivileged (own loopback ports only, no -L, no shell), so a
    rogue enrollment costs resources, not access
  * reconcile-machines.sh audits what got enrolled and auto-merges duplicate
    hardware identities

Run (systemd, as user): see dialhome-bootstrap.service in this directory.
"""
import http.server
import json
import os
import socketserver
import subprocess
import sys
import threading
import time
import urllib.parse

BASE = os.path.expanduser("~/.magpie-connector")
LOG_FILE = os.path.join(BASE, "bootstrap.log")
MACHINES_FILE = os.path.join(BASE, "machines.json")
NAMES_FILE = os.path.join(BASE, "bootstrap-names.json")
ENROLL = os.path.join(BASE, "enroll.sh")
RATE_MAX = 6          # requests per IP per minute
RATE_WINDOW = 60.0
FLOCK = threading.Lock()

window = {}           # ip -> [timestamps]


def machines_read():
    if os.path.exists(MACHINES_FILE):
        with open(MACHINES_FILE, encoding="utf-8") as f:
            try:
                return json.load(f)
            except ValueError:
                return {}
    return {}


def machines_write(m):
    tmp = MACHINES_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(m, f, indent=1)
    os.replace(tmp, MACHINES_FILE)


def name_for_fingerprint(fp, ip):
    """Hardware-fingerprint identity: same fp -> same slot, regardless of IP/DHCP.
    Two machines behind one NAT IP stay separate because fp comes from their
    hardware (Win32_ComputerSystemProduct.UUID, MACs), not from the network."""
    with FLOCK:
        m = machines_read()
        for name, rec in m.items():
            if rec.get("fp") == fp:
                rec["last_seen"] = time.strftime("%Y-%m-%dT%H:%M:%S")
                rec["last_ip"] = ip
                machines_write(m)
                return name, True
        name = "n-" + fp[:12]
        m[name] = {"fp": fp, "first_ip": ip, "first_seen": time.strftime("%Y-%m-%dT%H:%M:%S"),
                   "last_seen": time.strftime("%Y-%m-%dT%H:%M:%S"), "uuid": None, "macs": None}
        machines_write(m)
        return name, False


def name_for_ip(ip):
    """Legacy fallback: identity keyed by source IP (used when the client sent no fp)."""
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

    def _pserr(self, code, msg):
        """Errors come back as VALID PowerShell: the client does iex(curl ...), so a
        plain-text error would explode as 'command not found'. A comment + a
        Write-Host hint degrades to one readable yellow line instead."""
        body = "# dialhome bootstrap: %s\nWrite-Host '[dialhome] %s' -ForegroundColor Yellow\n" % (msg, msg)
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body.encode("utf-8"))))
        self.end_headers()
        self.wfile.write(body.encode("utf-8"))

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        ip = self.client_address[0]
        now = time.time()
        w = [t for t in window.get(ip, []) if now - t < RATE_WINDOW]
        if len(w) >= RATE_MAX:
            log(f"RATE ip={ip}")
            return self._pserr(429, "slow down, try again in a minute")
        w.append(now)
        window[ip] = w

        if u.path == "/healthz":
            return self._text(200, "ok\n")
        if u.path != "/i":
            return self._pserr(404, "unknown path (use /i)")

        q = urllib.parse.parse_qs(u.query)
        if q.get("f"):
            # hardware fingerprint (client-side SHA256 of UUID/MACs, 16 hex): identity
            # follows the MACHINE, not the network -- DHCP re-addressing and random
            # MACs on other adapters do not create a new slot. The fingerprint is client-claimed, so reconcile-machines.sh re-checks
            # it through the encrypted channel once the node is reachable.
            fp = (q.get("f") or [""])[0]
            if not fp.isalnum() or len(fp) > 32:
                return self._pserr(400, "bad fingerprint parameter")
            name, reused = name_for_fingerprint(fp.lower(), ip)
            log(f"{'REUSE' if reused else 'NEW'} fp={fp} name={name} ip={ip}")
        elif q.get("n"):
            raw = (q.get("n") or ["node"])[0]
            name = "".join(c for c in raw.lower() if c.isalnum() or c == "-")[:40] or "node"
            log(f"EXPLICIT name={name} ip={ip}")
        else:
            # legacy fallback: no fingerprint sent -- key the identity on source IP
            name = name_for_ip(ip)
            log(f"IPNAME name={name} ip={ip}")

        try:
            r = subprocess.run(["bash", ENROLL, name], capture_output=True,
                               text=True, timeout=60)
        except subprocess.TimeoutExpired:
            log(f"TIMEOUT name={name} ip={ip}")
            return self._pserr(504, "enroll timed out on the relay, try again")

        out = r.stdout or ""
        if len(out) < 2000 or "FromBase64String" not in out:
            log(f"FAIL name={name} ip={ip} err={r.stderr[-200:]!r}")
            return self._pserr(500, "enroll failed on the relay: " + ((r.stderr or "")[-160:].replace(chr(10), " ")))

        log(f"OK name={name} ip={ip} bytes={len(out)}")
        self._text(200, out)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18443
    bind = sys.argv[2] if len(sys.argv) > 2 else "0.0.0.0"
    log(f"listening on {bind}:{port}")
    print(f"dialhome bootstrap on {bind}:{port} (open enrollment -- no token)")
    Server((bind, port), Handler).serve_forever()


if __name__ == "__main__":
    main()