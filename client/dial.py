#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dial.py -- dial-home client: the generalized school-ssh.bat.

Every machine you can reach is an entry in MACHINES below: a list of ssh-config
aliases (anchors) tried in order, plus the shell to open there. The bat's tricks
are all kept:

  * anchors with automatic failover (alias down -> try the next one)
  * one-shot commands are piped over stdin into the guest's login bash, which
    sidesteps cmd/ssh/bash quote nesting (Windows guests use their own shell)
  * rc=255 prints an ordered triage checklist instead of a bare failure

Usage:
    python dial.py                 interactive: pick a machine, open a shell
    python dial.py status          probe every anchor of every machine
    python dial.py <name>          open an interactive shell on <name>
    python dial.py <name> <cmd>    run <cmd> there and print the output

Only the stdlib is used. Edit MACHINES to add a machine; anchors are aliases in
~/.ssh/config (the relay/node scripts in this repo create the far side).
"""
import os
import re
import socket
import subprocess
import sys
import time

SSH = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "System32", "OpenSSH", "ssh.exe")

# ---- machine registry -------------------------------------------------------
# anchors: ssh-config aliases, tried in order. shell: what an interactive login
# opens there ("bash" = MSYS2/git-bash login shell via stdin trick, "cmd"/"ps" =
# Windows shells). local_port: an optional anchor that is a port on THIS laptop.
MACHINES = {
    "school": {
        "aliases": ["school-guest", "school-guest-pc2"],
        "shell": "bash",
        "bash": "D:/yzd/MSYS2/usr/bin/bash.exe",
        "local_port": 13401,
        "note": "Win11-HV1, 校机",
    },
    "win2": {
        "aliases": ["winbox"],
        "shell": "cmd",
        "local_port": None,  # the anchor lives on the relay, not on this laptop
        "note": "DESKTOP-67S90N6, 经 relay 102 (enroll.sh)",
    },
}
# -----------------------------------------------------------------------------


def ssh_args(extra=()):
    return [SSH, "-o", "BatchMode=yes", "-o", "ConnectTimeout=6"] + list(extra)


def port_listening(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(2)
    try:
        return s.connect_ex(("127.0.0.1", int(port))) == 0
    finally:
        s.close()


def alias_alive(alias):
    r = subprocess.run(ssh_args([alias, "hostname"]),
                       capture_output=True, text=True, timeout=25)
    return r.returncode == 0, (r.stdout or r.stderr).strip()


def pick_anchor(machine):
    """Return the first anchor that answers, with the reason the others did not."""
    tried = []
    for alias in machine["aliases"]:
        local = machine.get("local_port")
        if local and not port_listening(local):
            tried.append((alias, "local anchor port %s not listening" % local))
            continue
        ok, out = alias_alive(alias)
        if ok:
            return alias, tried, out
        tried.append((alias, out.splitlines()[-1] if out else "no answer"))
    return None, tried, ""


def status():
    for name, m in MACHINES.items():
        print("== %s  (%s)" % (name, m.get("note", "")))
        anchor, tried, host = pick_anchor(m)
        for alias, why in tried:
            print("   %-18s down: %s" % (alias, why))
        if anchor:
            print("   %-18s UP   (%s)" % (anchor, host or "alive"))
        else:
            print("   ALL ANCHORS DOWN")
    print("")


def dial(name, command=None):
    m = MACHINES.get(name)
    if not m:
        print("unknown machine: %s (known: %s)" % (name, ", ".join(sorted(MACHINES))))
        return 2
    anchor, tried, _ = pick_anchor(m)
    for alias, why in tried:
        print("[i] %s down: %s" % (alias, why))
    if not anchor:
        print("no anchor up for %s. check, in order:" % name)
        print("  1. aliases exist in ~/.ssh/config")
        print("  2. local anchor port listening (netstat -ano | findstr %s)"
              % m.get("local_port", "-"))
        print("  3. the machine itself is on and someone is logged in")
        return 1
    print("[i] using anchor %s" % anchor)
    if command:
        if m["shell"] == "bash":
            # stdin trick from school-ssh.bat: no quote nesting to lose
            p = subprocess.run([SSH, "-T", anchor, m["bash"] + " --login -s"],
                               input=command, text=True)
        else:
            p = subprocess.run([SSH, "-t", anchor, command])
        return p.returncode
    if m["shell"] == "bash":
        p = subprocess.run([SSH, "-t", anchor, m["bash"] + " --login -i"])
    elif m["shell"] == "ps":
        p = subprocess.run([SSH, "-t", anchor, "powershell -NoLogo"])
    else:
        p = subprocess.run([SSH, "-t", anchor])
    if p.returncode == 255:
        print("connection failed on %s. check ~/.ssh/config, the anchor ports, "
              "and whether the machine is logged in." % anchor)
    return p.returncode


def menu():
    names = sorted(MACHINES)
    while True:
        print("")
        for i, n in enumerate(names, 1):
            print("  %d) %s  %s" % (i, n, MACHINES[n].get("note", "")))
        print("  s) status of all")
        print("  q) quit")
        choice = input("dial which? [1-%d/s/q] " % len(names)).strip().lower()
        if choice == "q":
            return 0
        if choice == "s":
            status()
            continue
        if choice.isdigit() and 1 <= int(choice) <= len(names):
            rc = dial(names[int(choice) - 1])
            if os.name == "nt":
                input("[enter to go back]")
        else:
            print("?")


def main():
    argv = sys.argv[1:]
    if not argv:
        try:
            return menu()
        except KeyboardInterrupt:
            return 0
    if argv[0] == "status":
        status()
        return 0
    if argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    return dial(argv[0], " ".join(argv[1:]) or None)


if __name__ == "__main__":
    sys.exit(main() or 0)