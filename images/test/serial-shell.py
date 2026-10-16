#!/usr/bin/env python3
"""Drive a root shell on a QEMU serial console (a unix socket) for the tests.

  serial-shell.py <socket> <boot-timeout> <prompt-regex> < script

Each stdin line is "description<TAB>command<TAB>expected-regex" (a regex that
must match the command's output). The first line waits for the shell prompt.
The command "@console" matches the regex against everything the console
printed before the first prompt (the boot log and any banner).
Prints "ok   ..." / "FAIL ..." per line; exit 1 if any failed.
"""
import re, socket, sys, time

path, boot_timeout, prompt = sys.argv[1], float(sys.argv[2]), sys.argv[3]


def connect():
    end = time.time() + 30
    while True:
        s = socket.socket(socket.AF_UNIX)
        try:
            s.connect(path)
            s.setblocking(False)
            return s
        except OSError:
            s.close()
            if time.time() > end:
                raise
            time.sleep(0.3)


sock = connect()
buf = ""


def pump(timeout):
    global buf
    end = time.time() + timeout
    while time.time() < end:
        try:
            data = sock.recv(65536)
        except BlockingIOError:
            time.sleep(0.05)
            continue
        if not data:
            break
        buf += re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", data.decode(errors="replace")).replace("\r", "")
        return True
    return False


def expect(rx, timeout):
    global buf
    end = time.time() + timeout
    while True:
        m = re.search(rx, buf, re.M)
        if m:
            out, buf = buf[: m.start()], buf[m.end():]
            return out
        if time.time() > end:
            return None
        pump(0.5)


fail = 0
first = True
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    desc, cmd, want = line.split("\t")
    if first:
        # Nudge the (idle) shell once it is up: the prompt may have been printed before we connected.
        ok = False
        boot_text = ""
        end = time.time() + boot_timeout
        while time.time() < end:
            sock.send(b"\n")
            before = expect(prompt, 3)
            if before is not None:
                boot_text += before
                ok = True
                break
        if not ok:
            print(f"FAIL boot: no shell prompt within {boot_timeout:.0f}s; the console ended with:\n{buf[-1500:]}")
            sys.exit(1)
        first = False
        # Kernel messages would land in the middle of command output.
        sock.send(b"dmesg -n 1\n")
        expect(prompt, 5)
    if cmd == "@console":
        if re.search(want, boot_text, re.M):
            print(f"ok   {desc}")
        else:
            print(f"FAIL {desc}: want /{want}/ in the console output before the prompt, got {boot_text[-400:]!r}")
            fail = 1
        continue
    buf = ""
    sock.send((cmd + '; echo "@@END$?@@"\n').encode())
    out = expect(r"^@@END\d+@@$", 60)
    if out is None:
        print(f"FAIL {desc}: no output; got {buf[-300:]!r}")
        fail = 1
        continue
    # drop the echoed command line
    out = out.split("\n", 1)[1] if "\n" in out else out
    if re.search(want, out, re.M):
        print(f"ok   {desc}")
    else:
        print(f"FAIL {desc}: want /{want}/, got {out.strip()[:400]!r}")
        fail = 1
sys.exit(fail)
