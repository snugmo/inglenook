#!/bin/sh
# nopw.sh USER: drop the password hash from a homed user's record, keeping the tokens
cd /var/tmp
python3 - "$1" <<PY
import json,sys,time
u=sys.argv[1]
r=json.load(open("/home/%s.homedir/.identity" % u))
r.pop("signature",None)
r["privileged"].pop("hashedPassword",None)
r["lastChangeUSec"]=int(time.time()*1e6)
json.dump(r,open("nopw-%s.json" % u,"w"))
PY
homectl update "$1" --identity="nopw-$1.json" </dev/null
