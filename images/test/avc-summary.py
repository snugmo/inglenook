#!/usr/bin/env python3
"""Summarize SELinux AVC denials from audit/journal text on stdin.

One line per distinct denial: "<perms> | <source type> -> <target type> : <class>",
sorted and unique. The process-transition permissions (siginh, rlimitinh,
noatsecure) are dropped: they are noise that appears once dontaudit rules are
disabled (see the Containerfile) and is harmless.
"""
import re
import sys

NOISE = {"siginh", "rlimitinh", "noatsecure"}
AVC = re.compile(r"avc:\s+denied\s+\{ ([^}]*) \}")

def ctx_type(line, key):
    m = re.search(key + r"=(?:[^:\s]*:){2}([A-Za-z0-9_]+)", line)
    return m.group(1) if m else "?"

out = set()
for line in sys.stdin:
    m = AVC.search(line)
    if not m:
        continue
    perms = sorted(m.group(1).split())
    if set(perms) <= NOISE:
        continue
    cls = re.search(r"tclass=(\S+)", line)
    out.add(f"{' '.join(perms)} | {ctx_type(line, 'scontext')} -> "
            f"{ctx_type(line, 'tcontext')} : {cls.group(1) if cls else '?'}")
print("\n".join(sorted(out)))
