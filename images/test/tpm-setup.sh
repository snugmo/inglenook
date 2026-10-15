#!/usr/bin/env bash
# Fetch swtpm (a software TPM 2.0) into build/swtpm when the host has none, so that
# `TPM=1 vm.sh ...` can give the test VM a virtual TPM. Needs dnf's download plugin
# and rpm2cpio; nothing is installed system-wide.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
dest=$REPO/build/swtpm
command -v swtpm >/dev/null && { echo "swtpm is installed"; exit 0; }
[[ -x $dest/usr/bin/swtpm ]] && { echo "swtpm is in $dest"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
dnf download --destdir "$tmp" swtpm swtpm-libs swtpm-tools libtpms
mkdir -p "$dest"
for r in "$tmp"/*.x86_64.rpm; do rpm2cpio "$r" | (cd "$dest" && cpio -idm 2>/dev/null); done
"$dest/usr/bin/swtpm" --version
