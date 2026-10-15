#!/bin/sh
# nopw.sh USER: drop the password hash from a homed user's record, keeping the tokens.
# Works for directory homes (record in the home) and LUKS homes (record in /var/lib/systemd/home).
cd /var/tmp
python3 - "$1" <<PY
import json,os,sys,time
u=sys.argv[1]
p="/var/lib/systemd/home/%s.identity" % u
if not os.path.exists(p): p="/home/%s.homedir/.identity" % u
r=json.load(open(p))
for k in ("signature","binding","status"):
    r.pop(k,None)
r["privileged"].pop("hashedPassword",None)
r["lastChangeUSec"]=int(time.time()*1e6)
json.dump(r,open("nopw-%s.json" % u,"w"))
PY
homectl update "$1" --identity="nopw-$1.json" </dev/null
