#!/usr/bin/env python3
"""Assemble the installer overlay: the /usr of the mkosi package tree minus
everything the boot initrd already has, plus the hand-written rootfs/ tree.

  overlay.py <mkosi-tree> <boot-initrd-dir> <rootfs-dir> <out-dir>

Both initrds are unpacked over each other at boot, so a file present in both
must be identical; one that differs (a different library build, say) would
silently replace the boot initrd's copy, so it is an error here. Docs, man
pages, locales, debug links, gdb helpers, shell completions and the rpm database are left out.
"""
import filecmp, os, shutil, sys

tree, initrd, rootfs, out = sys.argv[1:5]
SKIP = ("usr/share/doc", "usr/share/man", "usr/share/info", "usr/share/licenses", "usr/share/locale",
        "usr/lib/locale", "usr/lib/sysimage", "usr/lib/rpm", "usr/lib/.build-id",
        "usr/share/gcc", "usr/share/gdb", "usr/share/bash-completion", "usr/share/zsh")  # prefixes
conflicts, added = [], 0


def target(link):
    """A symlink's target. Links into /etc/alternatives (dig, host, ...) would
    dangle, because only /usr is taken from the tree; point them at what the
    alternatives link in the tree points to."""
    t = os.readlink(link)
    if t.startswith("/etc/alternatives/") and link.startswith(tree):
        alt = tree + t
        if os.path.islink(alt):
            return os.readlink(alt)
    return t


def same(a, b):
    if os.path.islink(a) or os.path.islink(b):
        if not (os.path.islink(a) and os.path.islink(b)):
            return False
        # the boot initrd keeps its alternatives links as they are (it has /etc/alternatives)
        return os.readlink(a) == os.readlink(b) or target(a) == target(b)
    return filecmp.cmp(a, b, shallow=False)


def put(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.islink(src):
        os.symlink(target(src), dst)
    else:
        shutil.copy2(src, dst)


for root, dirs, files in os.walk(os.path.join(tree, "usr")):
    rel = os.path.relpath(root, tree)
    dirs[:] = [d for d in dirs if not os.path.join(rel, d).startswith(SKIP)]
    # a symlinked directory is an entry like a file
    for name in files + [d for d in dirs if os.path.islink(os.path.join(root, d))]:
        r = os.path.join(rel, name)
        src, have = os.path.join(root, name), os.path.join(initrd, r)
        if os.path.lexists(have):
            if os.path.isdir(have) and not os.path.islink(have):
                conflicts.append(f"{r}: a directory in the boot initrd")
            elif not same(src, have):
                conflicts.append(f"{r}: differs from the boot initrd's copy")
            continue
        put(src, os.path.join(out, r))
        added += 1

if conflicts:
    print("overlay conflicts with the boot initrd (build both from the same Fedora snapshot):", file=sys.stderr)
    print("\n".join("  " + c for c in conflicts), file=sys.stderr)
    sys.exit(1)

# Our own files win over nothing (they live under /usr/installer and the unit symlinks).
for root, dirs, files in os.walk(rootfs):
    for name in files + [d for d in dirs if os.path.islink(os.path.join(root, d))]:
        src = os.path.join(root, name)
        put(src, os.path.join(out, os.path.relpath(src, rootfs)))
print(f"overlay: {added} files from packages (boot initrd already has the rest)", file=sys.stderr)
