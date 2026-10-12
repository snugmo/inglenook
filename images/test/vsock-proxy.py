#!/usr/bin/env python3
"""ssh ProxyCommand for vhost-device-vsock: vsock-proxy.py <uds-path> <port>"""
import os, select, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall(f"CONNECT {sys.argv[2]}\n".encode())
line = b""
while not line.endswith(b"\n"):
    c = s.recv(1)
    if not c: sys.exit("vsock: connection closed during handshake")
    line += c
if not line.startswith(b"OK"): sys.exit(f"vsock: {line!r}")
i, o = sys.stdin.fileno(), sys.stdout.fileno()
while True:
    r, _, _ = select.select([i, s], [], [])
    if i in r:
        d = os.read(i, 65536)
        if not d: break
        s.sendall(d)
    if s in r:
        d = s.recv(65536)
        if not d: break
        os.write(o, d)
