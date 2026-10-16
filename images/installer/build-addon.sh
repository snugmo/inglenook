#!/usr/bin/env bash
# Build the installer UKI addon:
#
#   images/installer/build-addon.sh <out.addon.efi>
#
# The addon has two sections. .cmdline makes the initrd's systemd boot
# inglenook-installer.target (rd.systemd.unit=) instead of initrd.target, so it
# never switches root: the installer is a root shell in the initrd. .initrd is
# a cpio overlay (images/installer/rootfs) that the kernel unpacks over the
# boot initrd. It is userspace only, so it has no .uname and works with any
# kernel; modules the installer needs beyond the boot initrd's would be a
# separate addon with a .uname. systemd-stub loads addons from
# \loader\addons\ on the partition it booted from. Secure Boot must be off
# (unsigned addon, like the image's UKI).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: build-addon.sh <out.addon.efi>}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# SOURCE_DATE_EPOCH-style stable timestamps; root ownership regardless of who builds.
(cd "$HERE/rootfs" && find . -mindepth 1 -print0 | sort -z \
  | cpio --null -o -H newc --reproducible --owner=0:0 --quiet) | zstd -q -19 -o "$tmp/installer.cpio.zst"

mkdir -p "$(dirname "$out")"
ukify build --stub /usr/lib/systemd/boot/efi/addonx64.efi.stub \
  --cmdline 'rd.systemd.unit=inglenook-installer.target' \
  --initrd "$tmp/installer.cpio.zst" --output "$out"
