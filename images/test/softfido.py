#!/usr/bin/env python3
"""Software FIDO2 authenticator for the token tests (images/test/token.sh). TEST USE ONLY.

Runs inside the VM and shows up as a hidraw FIDO device through /dev/uhid (modprobe
uhid first). It speaks CTAPHID/CTAP2: getInfo, makeCredential (packed self
attestation), getAssertion, the hmac-secret extension (what systemd-homed and
systemd-cryptenroll use) and clientPIN protocol 1 (setPIN, getPinToken). User
presence is granted automatically. Credentials are stateless (derived from a master
key in the state directory, like a real token), so they survive a restart.

  softfido.py STATE_DIR [--set-pin PIN] [--uv]

--set-pin stores a PIN in the state directory (it stays set on later runs); --uv
advertises built-in user verification. It is a deliberately small subset of CTAP
2.0: no resident keys, no PIN change, one credential per request, no U2F (CTAP1).
The PIN checks follow the spec, but there is no lockout beyond a retry counter that
resets on restart.
"""
import hashlib, hmac, os, select, struct, sys, time
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

AAGUID = bytes.fromhex("5ec0de5ec0de4000a000000000000001")


def log(*a):
    print("softfido:", *a, file=sys.stderr, flush=True)


# ---- minimal CBOR -----------------------------------------------------
def _head(m, n):
    if n < 24: return bytes([m << 5 | n])
    if n < 256: return bytes([m << 5 | 24, n])
    if n < 65536: return bytes([m << 5 | 25]) + struct.pack(">H", n)
    return bytes([m << 5 | 26]) + struct.pack(">I", n)


def cenc(o):
    if o is True: return b"\xf5"
    if o is False: return b"\xf4"
    if o is None: return b"\xf6"
    if isinstance(o, int): return _head(0, o) if o >= 0 else _head(1, -1 - o)
    if isinstance(o, (bytes, bytearray)): return _head(2, len(o)) + bytes(o)
    if isinstance(o, str):
        b = o.encode(); return _head(3, len(b)) + b
    if isinstance(o, list): return _head(4, len(o)) + b"".join(cenc(x) for x in o)
    if isinstance(o, dict):
        items = sorted(((cenc(k), cenc(v)) for k, v in o.items()), key=lambda kv: (len(kv[0]), kv[0]))
        return _head(5, len(items)) + b"".join(k + v for k, v in items)
    raise TypeError(o)


def cdec(b, i=0):
    ib = b[i]; m, a = ib >> 5, ib & 31; i += 1
    if m == 7:
        return {20: False, 21: True, 22: None}[a], i
    if a < 24: n = a
    elif a == 24: n = b[i]; i += 1
    elif a == 25: n = struct.unpack(">H", b[i:i + 2])[0]; i += 2
    elif a == 26: n = struct.unpack(">I", b[i:i + 4])[0]; i += 4
    else: raise ValueError("cbor length")
    if m == 0: return n, i
    if m == 1: return -1 - n, i
    if m == 2: return bytes(b[i:i + n]), i + n
    if m == 3: return bytes(b[i:i + n]).decode(), i + n
    if m == 4:
        out = []
        for _ in range(n):
            x, i = cdec(b, i); out.append(x)
        return out, i
    if m == 5:
        out = {}
        for _ in range(n):
            k, i = cdec(b, i); v, i = cdec(b, i); out[k] = v
        return out, i
    raise ValueError("cbor major")


# ---- crypto helpers ---------------------------------------------------
def aes(key, data, enc):
    c = Cipher(algorithms.AES(key), modes.CBC(b"\0" * 16))
    x = c.encryptor() if enc else c.decryptor()
    return x.update(data) + x.finalize()


def hm(key, *parts):
    return hmac.new(key, b"".join(parts), hashlib.sha256).digest()


def cose_pub(pub, alg):
    n = pub.public_numbers()
    return {1: 2, 3: alg, -1: 1, -2: n.x.to_bytes(32, "big"), -3: n.y.to_bytes(32, "big")}


def pub_from_cose(c):
    x = int.from_bytes(c[-2], "big"); y = int.from_bytes(c[-3], "big")
    return ec.EllipticCurvePublicNumbers(x, y, ec.SECP256R1()).public_key()


class Token:
    def __init__(self, state, uv=False):
        os.makedirs(state, exist_ok=True)
        self.state = state
        self.uv = uv
        mk = os.path.join(state, "master")
        if not os.path.exists(mk):
            with open(mk, "wb") as f: f.write(os.urandom(32))
        self.master = open(mk, "rb").read()
        self.pinfile = os.path.join(state, "pin")
        self.ka = ec.generate_private_key(ec.SECP256R1())
        self.pin_token = os.urandom(32)
        self.retries = 8
        self.counter = int(time.time())

    # PIN state: the 16-byte left half of SHA-256(pin), or None
    @property
    def pin_hash(self):
        return open(self.pinfile, "rb").read() if os.path.exists(self.pinfile) else None

    def shared(self, peer_cose):
        z = self.ka.exchange(ec.ECDH(), pub_from_cose(peer_cose))
        return hashlib.sha256(z).digest()

    # ---- credentials
    def cred_new(self, rp_hash):
        nonce = os.urandom(32)
        return nonce + hm(self.master, b"tag", nonce, rp_hash)[:16]

    def cred_ok(self, cid, rp_hash):
        return len(cid) == 48 and hmac.compare_digest(cid[32:], hm(self.master, b"tag", cid[:32], rp_hash)[:16])

    def cred_key(self, cid):
        d = HKDF(hashes.SHA256(), 32, None, b"sign" + cid[:32]).derive(self.master)
        return ec.derive_private_key(int.from_bytes(d, "big") % (2**255) + 1, ec.SECP256R1())

    def cred_random(self, cid, uv):
        return hm(self.master, b"hmac-uv" if uv else b"hmac-nouv", cid[:32])

    # ---- user verification via PIN token
    def verify_uv(self, p, cdh, pk, pk_auth, need_pin=True):
        """Return (ok, uv_flag, error). Only makeCredential requires the PIN to be present; an
        assertion without pinUvAuthParam is allowed (user presence only), like on real tokens."""
        if pk_auth is None:
            if need_pin and self.pin_hash is not None and not self.uv:
                return False, False, 0x36
            return True, bool(self.uv), 0
        if pk != 1: return False, False, 0x33
        if not hmac.compare_digest(pk_auth, hm(self.pin_token, cdh)[:16]):
            return False, False, 0x33
        return True, True, 0

    # ---- CTAP2 commands
    def get_info(self):
        opts = {"rk": False, "up": True, "plat": False, "clientPin": self.pin_hash is not None}
        if self.uv: opts["uv"] = True
        return b"\0" + cenc({1: ["FIDO_2_0"], 2: ["hmac-secret"], 3: AAGUID, 4: opts, 5: 1200, 6: [1]})

    def client_pin(self, p):
        sub = p[2]
        if sub == 1:
            return b"\0" + cenc({3: self.retries})
        if sub == 2:
            return b"\0" + cenc({1: cose_pub(self.ka.public_key(), -25)})
        sh = self.shared(p[3]) if 3 in p else None
        if sub == 3:  # setPIN
            if self.pin_hash is not None: return b"\x34"
            if not hmac.compare_digest(p[4], hm(sh, p[5])[:16]): return b"\x33"
            pin = aes(sh, p[5], False).rstrip(b"\0")
            if len(pin) < 4: return b"\x37"
            open(self.pinfile, "wb").write(hashlib.sha256(pin).digest()[:16])
            log("PIN set")
            return b"\0"
        if sub == 5:  # getPinToken
            if self.pin_hash is None: return b"\x35"
            if self.retries == 0: return b"\x32"
            if not hmac.compare_digest(aes(sh, p[6], False), self.pin_hash):
                self.retries -= 1
                self.ka = ec.generate_private_key(ec.SECP256R1())
                log("wrong PIN, retries left", self.retries)
                return b"\x31"
            self.retries = 8
            self.pin_token = os.urandom(32)
            return b"\0" + cenc({2: aes(sh, self.pin_token, True)})
        return b"\x3e"

    def make_credential(self, p):
        cdh, rp = p[1], p[2]
        if not any(c.get("alg") == -7 for c in p.get(4, [])): return b"\x26"
        ok, uvf, err = self.verify_uv(p, cdh, p.get(9), p.get(8))
        if not ok: return bytes([err])
        rp_hash = hashlib.sha256(rp["id"].encode()).digest()
        exts = p.get(6, {})
        hs = bool(exts.get("hmac-secret"))
        cid = self.cred_new(rp_hash)
        pub = self.cred_key(cid).public_key()
        flags = 0x01 | (0x04 if uvf else 0) | 0x40 | (0x80 if hs else 0)
        ad = rp_hash + bytes([flags]) + struct.pack(">I", self._count()) + AAGUID \
            + struct.pack(">H", len(cid)) + cid + cenc(cose_pub(pub, -7))
        if hs: ad += cenc({"hmac-secret": True})
        log("makeCredential rp=%s uv=%s hmac-secret=%s" % (rp["id"], uvf, hs))
        sig = self.cred_key(cid).sign(ad + cdh, ec.ECDSA(hashes.SHA256()))
        return b"\0" + cenc({1: "packed", 2: ad, 3: {"alg": -7, "sig": sig}})

    def get_assertion(self, p):
        rp_id, cdh = p[1], p[2]
        rp_hash = hashlib.sha256(rp_id.encode()).digest()
        cid = next((c["id"] for c in p.get(3, []) if self.cred_ok(c["id"], rp_hash)), None)
        if cid is None: return b"\x2e"
        ok, uvf, err = self.verify_uv(p, cdh, p.get(7), p.get(6), need_pin=False)
        if not ok: return bytes([err])
        silent = p.get(5, {}).get("up") is False  # pre-flight probe: no user presence
        flags = (0 if silent else 0x01) | (0x04 if uvf else 0)
        ext = b""
        hs = p.get(4, {}).get("hmac-secret")
        if hs:
            sh = self.shared(hs[1])
            if not hmac.compare_digest(hs[3], hm(sh, hs[2])[:16]): return b"\x33"
            salts = aes(sh, hs[2], False)
            cr = self.cred_random(cid, uvf)
            out = b"".join(hm(cr, salts[i:i + 32]) for i in range(0, len(salts), 32))
            ext = cenc({"hmac-secret": aes(sh, out, True)})
            flags |= 0x80
        ad = rp_hash + bytes([flags]) + struct.pack(">I", self._count()) + ext
        sig = self.cred_key(cid).sign(ad + cdh, ec.ECDSA(hashes.SHA256()))
        log("getAssertion rp=%s uv=%s hmac-secret=%s" % (rp_id, uvf, bool(hs)))
        return b"\0" + cenc({1: {"id": cid, "type": "public-key"}, 2: ad, 3: sig})

    def _count(self):
        self.counter += 1
        return self.counter

    def ctap2(self, data):
        r = self.ctap2_(data)
        log("ctap2 cmd=0x%02x -> status 0x%02x len=%d" % (data[0], r[0], len(r)))
        return r

    def ctap2_(self, data):
        cmd = data[0]
        p = cdec(data, 1)[0] if len(data) > 1 else {}
        try:
            if cmd == 4: return self.get_info()
            if cmd == 6: return self.client_pin(p)
            if cmd == 1: return self.make_credential(p)
            if cmd == 2: return self.get_assertion(p)
            if cmd == 7:
                if os.path.exists(self.pinfile): os.unlink(self.pinfile)
                return b"\0"
        except Exception as e:  # malformed requests
            log("error", repr(e))
            return b"\x02"
        return b"\x01"


# ---- CTAPHID over uhid ----------------------------------------------
RDESC = bytes.fromhex(
    "06d0f10901a1010920150026ff007508954081020921150026ff00750895409102c0")
UHID_START, UHID_OPEN, UHID_CLOSE, UHID_OUTPUT, UHID_GET_REPORT, UHID_GET_REPORT_REPLY, \
    UHID_CREATE2, UHID_INPUT2, UHID_SET_REPORT, UHID_SET_REPORT_REPLY = 2, 4, 5, 6, 9, 10, 11, 12, 13, 14


class Hid:
    def __init__(self, tok):
        self.tok = tok
        self.fd = os.open("/dev/uhid", os.O_RDWR)
        self.pending = {}
        self.next_cid = 1
        ev = struct.pack("<I128s64s64sHHIIII", UHID_CREATE2, b"softfido", b"", b"softfido-0",
                         len(RDESC), 3, 0x1209, 0xF1D0, 1, 0) + RDESC.ljust(4096, b"\0")
        os.write(self.fd, ev)

    def send(self, cid, cmd, data):
        pk = cid + bytes([0x80 | cmd]) + struct.pack(">H", len(data)) + data[:57]
        self.raw(pk)
        data, seq = data[57:], 0
        while data:
            self.raw(cid + bytes([seq]) + data[:59]); data = data[59:]; seq += 1

    def raw(self, pk):
        pk = pk.ljust(64, b"\0")
        os.write(self.fd, struct.pack("<IH", UHID_INPUT2, 64) + pk)

    def packet(self, p):
        cid, b4 = p[0:4], p[4]
        if b4 & 0x80:
            cmd, n = b4 & 0x7F, (p[5] << 8) | p[6]
            d = bytearray(p[7:7 + min(n, 57)])
            if n > len(d):
                self.pending[cid] = [cmd, n, d]; return
            self.dispatch(cid, cmd, bytes(d))
        else:
            st = self.pending.get(cid)
            if not st: return
            st[2] += p[5:5 + min(st[1] - len(st[2]), 59)]
            if len(st[2]) >= st[1]:
                del self.pending[cid]; self.dispatch(cid, st[0], bytes(st[2]))

    def dispatch(self, cid, cmd, data):
        if cmd == 0x06:  # INIT
            new = cid
            if cid == b"\xff\xff\xff\xff":
                new = struct.pack(">I", self.next_cid); self.next_cid += 1
            self.send(cid, 0x06, data[:8] + new + bytes([2, 0, 0, 0, 0x04 | 0x08]))
        elif cmd == 0x01:
            self.send(cid, 0x01, data)
        elif cmd == 0x10:
            self.send(cid, 0x10, self.tok.ctap2(data))
        else:
            self.send(cid, 0x3F, b"\x01")

    def run(self):
        while True:
            select.select([self.fd], [], [])
            ev = os.read(self.fd, 8192)
            t = struct.unpack_from("<I", ev)[0]
            if t == UHID_OUTPUT:
                size = struct.unpack_from("<H", ev, 4 + 4096)[0]
                d = ev[4:4 + size]
                if size == 65: d = d[1:]
                self.packet(d[:64])
            elif t == UHID_GET_REPORT:
                i = struct.unpack_from("<I", ev, 4)[0]
                os.write(self.fd, struct.pack("<IIHH", UHID_GET_REPORT_REPLY, i, 5, 0))
            elif t == UHID_SET_REPORT:
                i = struct.unpack_from("<I", ev, 4)[0]
                os.write(self.fd, struct.pack("<IIH", UHID_SET_REPORT_REPLY, i, 5))
            elif t == UHID_START:
                log("started")


if __name__ == "__main__":
    tok = Token(sys.argv[1], uv="--uv" in sys.argv)
    if "--set-pin" in sys.argv:
        pin = sys.argv[sys.argv.index("--set-pin") + 1].encode()
        open(tok.pinfile, "wb").write(hashlib.sha256(pin).digest()[:16])
    Hid(tok).run()
