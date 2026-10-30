#!/usr/bin/env bash
# Build the installer UKI addon:
#
#   images/installer/build-addon.sh <out.addon.efi>
#
# The addon has two sections. .cmdline makes the initrd's systemd boot
# inglenook-installer.target (rd.systemd.unit=) instead of initrd.target, so it
# never switches root: the installer is a root shell in the initrd. .initrd is
# a cpio overlay that the kernel unpacks over the boot initrd: the packages
# listed in images/installer/mkosi.conf (minus the files the boot initrd already
# has, see overlay.py; needs the boot initrd from images/build.sh) plus the
# hand-written tree images/installer/rootfs. It is userspace only, so it has no .uname and works with any
# kernel; modules the installer needs beyond the boot initrd's would be a
# separate addon with a .uname. systemd-stub loads addons from
# \loader\addons\ on the partition it booted from. Secure Boot must be off
# (unsigned addon, like the image's UKI).
# Environment: VARIANT (tpm2|no-tpm, default tpm2): written into the overlay
# as /usr/installer/variant, which inglenook-install reads to pick its
# encryption options. The no-tpm image's initrd (which this addon is layered
# over) carries the matching root-unlock drop-in, so the two must agree:
# stick.sh passes the variant it read from the image's label.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: build-addon.sh <out.addon.efi>}
VARIANT=${VARIANT:-tpm2}
[[ $VARIANT == tpm2 || $VARIANT == no-tpm ]] || { echo "VARIANT must be tpm2 or no-tpm (got '$VARIANT')" >&2; exit 1; }
tmp=$(mktemp -d)
# the unpacked boot initrd has read-only directories
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

# The packages (mkosi.conf) minus what the boot initrd has, plus rootfs/. The
# boot initrd comes from images/build.sh.
REPO=$(cd "$HERE/../.." && pwd)
INITRD=${INITRD:-$REPO/build/initrd/out/initrd.cpio.zst}
[[ -f $INITRD ]] || { echo "no boot initrd at $INITRD; run images/build.sh first (or set INITRD)" >&2; exit 1; }
mkdir -p "$tmp/initrd"
# Regular files and symlinks are enough to compare against (no device nodes).
(cd "$tmp/initrd" && zstd -dc "$INITRD" | cpio -id --quiet --no-absolute-filenames 'usr/*' 2>/dev/null) || true
mkosi --directory "$HERE" --force --output-directory "$tmp/mkosi" >"$tmp/mkosi.log" 2>&1 \
  || { cat "$tmp/mkosi.log" >&2; exit 1; }
# Files of the packages in exclude-packages.txt (dependencies the installer never runs).
grep -vE '^(#|$)' "$HERE/exclude-packages.txt" | while read -r pkg; do
  rpm --root "$tmp/mkosi/installer" --dbpath /usr/lib/sysimage/rpm -ql "$pkg" | sed 's#^/##'
done > "$tmp/excluded"
python3 -I "$HERE/overlay.py" "$tmp/mkosi/installer" "$tmp/initrd" "$HERE/rootfs" "$tmp/overlay" "$tmp/excluded"
# The variant marker (a build decision, so written here rather than in rootfs/).
printf '%s\n' "$VARIANT" > "$tmp/overlay/usr/installer/variant"

# Stable order, root ownership regardless of who builds.
[[ -n ${LIST_OVERLAY:-} ]] && (cd "$tmp/overlay" && find . -type f -o -type l | sort) >&2
(cd "$tmp/overlay" && find . -mindepth 1 -print0 | sort -z \
  | cpio --null -o -H newc --reproducible --owner=0:0 --quiet) | zstd -q -19 -o "$tmp/installer.cpio.zst"

mkdir -p "$(dirname "$out")"
ukify build --stub /usr/lib/systemd/boot/efi/addonx64.efi.stub \
  --cmdline 'rd.systemd.unit=inglenook-installer.target' \
  --initrd "$tmp/installer.cpio.zst" --output "$out"
