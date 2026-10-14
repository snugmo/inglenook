#!/usr/bin/env python3
"""pamtest.py SERVICE USER [REPLY...] - run pam_authenticate + pam_acct_mgmt, print the conversation.
Prompts that ask for input are answered from REPLY (in order, empty when exhausted)."""
import ctypes, ctypes.util, sys

libpam = ctypes.CDLL(ctypes.util.find_library("pam") or "libpam.so.0")
libc = ctypes.CDLL(None)
libc.calloc.restype = ctypes.c_void_p
libc.calloc.argtypes = [ctypes.c_size_t, ctypes.c_size_t]
libc.strdup.restype = ctypes.c_void_p


class Msg(ctypes.Structure):
    _fields_ = [("style", ctypes.c_int), ("msg", ctypes.c_char_p)]


class Resp(ctypes.Structure):
    _fields_ = [("resp", ctypes.c_void_p), ("rc", ctypes.c_int)]


CONV = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.POINTER(Msg)),
                        ctypes.POINTER(ctypes.POINTER(Resp)), ctypes.c_void_p)


class Conv(ctypes.Structure):
    _fields_ = [("conv", CONV), ("data", ctypes.c_void_p)]


service, user, replies = sys.argv[1], sys.argv[2], sys.argv[3:]
names = {1: "PROMPT_ECHO_OFF", 2: "PROMPT_ECHO_ON", 3: "ERROR_MSG", 4: "TEXT_INFO"}


def conv(n, msgs, resp, _):
    arr = libc.calloc(n, ctypes.sizeof(Resp))
    resp[0] = ctypes.cast(arr, ctypes.POINTER(Resp))
    for i in range(n):
        m = msgs[i][0]
        text = m.msg.decode() if m.msg else ""
        print("  [%s] %s" % (names.get(m.style, m.style), text), flush=True)
        if m.style in (1, 2):
            ans = replies.pop(0) if replies else ""
            print("  -> reply: %r" % ("*" * len(ans) if m.style == 1 else ans), flush=True)
            resp[0][i].resp = libc.strdup(ans.encode())
    return 0


cb = CONV(conv)
c = Conv(cb, None)
h = ctypes.c_void_p()
libpam.pam_start.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(Conv), ctypes.POINTER(ctypes.c_void_p)]
rc = libpam.pam_start(service.encode(), user.encode(), ctypes.byref(c), ctypes.byref(h))
libpam.pam_strerror.restype = ctypes.c_char_p
libpam.pam_strerror.argtypes = [ctypes.c_void_p, ctypes.c_int]
for name in ("pam_authenticate", "pam_acct_mgmt"):
    f = getattr(libpam, name)
    f.argtypes = [ctypes.c_void_p, ctypes.c_int]
    rc = f(h, 0)
    print("%s: %d %s" % (name, rc, libpam.pam_strerror(h, rc).decode()), flush=True)
    if rc:
        break
libpam.pam_end(h, rc)
sys.exit(1 if rc else 0)
