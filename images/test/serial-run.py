#!/usr/bin/env python3
"""Run one command in a root shell on a QEMU serial console (a unix socket) and
stream its output; for the long steps of the installer tests.

  serial-run.py <socket> <timeout-seconds> <command...>

Waits for a shell prompt first (the socket may have been idle for hours), prints
the command's output as it arrives and exits with the command's status (124 on
timeout). A QEMU serial socket server lets a client reconnect, so one VM can
serve many invocations.
"""
import re, socket, sys, time

path, timeout, cmd = sys.argv[1], float(sys.argv[2]), " ".join(sys.argv[3:])
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


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


def read(wait=0.3):
    global buf
    end = time.time() + wait
    got = ""
    while time.time() < end:
        try:
            d = sock.recv(65536)
        except BlockingIOError:
            time.sleep(0.05)
            continue
        if not d:
            break
        got += ANSI.sub("", d.decode(errors="replace")).replace("\r", "")
        end = time.time() + 0.05
    buf += got
    return got


# get a prompt
end = time.time() + 180
while True:
    sock.send(b"\n")
    read(1.5)
    if re.search(r"bash-[0-9.]+# $", buf):
        break
    if time.time() > end:
        print("no shell prompt:\n" + buf[-800:])
        sys.exit(125)
buf = ""
sock.send((cmd + '; echo "@@END$?@@"\n').encode())
rc, start = 124, time.time()
printed = 0
while time.time() - start < timeout:
    read(0.5)
    m = re.search(r"^@@END(\d+)@@$", buf, re.M)
    upto = m.start() if m else len(buf)
    # skip the echoed command line on the first output
    sys.stdout.write(buf[printed:upto]) if printed else None
    if not printed:
        nl = buf.find("\n")
        if nl >= 0:
            printed = nl + 1
            sys.stdout.write(buf[printed:upto])
    printed = max(printed, upto)
    sys.stdout.flush()
    if m:
        rc = int(m.group(1))
        break
else:
    print(f"\n[timeout after {timeout:.0f}s]")
sys.exit(rc)
