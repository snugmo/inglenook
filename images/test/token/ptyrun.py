#!/usr/bin/env python3
"""ptyrun.py REPLY[,REPLY...] CMD... - run CMD on a pty, answering each ': ' prompt with the next reply."""
import os, pty, select, sys, time
replies = sys.argv[1].split(",") if sys.argv[1] else []
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[2], sys.argv[2:])
buf = b""
deadline = time.time() + 60
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 1)
    if not r:
        if buf.rstrip().endswith((b":", b"?")) and replies:
            time.sleep(0.3)
            os.write(fd, replies.pop(0).encode() + b"\n")
            buf = b""
        continue
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d:
        break
    sys.stdout.buffer.write(d); sys.stdout.flush()
    buf += d
_, st = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(st))
