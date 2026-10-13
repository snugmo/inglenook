#!/usr/bin/env bash
# Build the UKI addon that turns a stick into a live system:
#
#   images/live-addon.sh <esp-tree>   -> <esp-tree>/loader/addons/live.addon.efi
#
# systemd-stub appends the .cmdline of every \loader\addons\*.addon.efi it finds
# on the ESP it was booted from to the UKI's own command line (unsigned addons
# are accepted with Secure Boot off, which these images require anyway). The
# addon lives on the stick's ESP only: `bootc install` does not copy it to a
# drive it installs, so the installed system boots the plain, persistent UKI.
#   ro                  the stick is mounted read-only (the UKI says rw, the last wins)
#   fsck.mode=skip      no fsck: even on a clean filesystem e2fsck rewrites the superblock
#   inglenook.live=1    initrd: /etc and /var on RAM filesystems (inglenook-live-state.service)
# systemd-boot itself still creates and rewrites \loader\random-seed (and
# \loader\boot-secret-mixin) on the ESP at every boot; there is no loader.conf
# switch for it in this version. That is the boot loader's entropy, not OS state.
set -euo pipefail

out=${1:?usage: live-addon.sh <esp-tree>}
mkdir -p "$out/loader/addons"
ukify build --stub /usr/lib/systemd/boot/efi/addonx64.efi.stub \
  --cmdline 'ro fsck.mode=skip inglenook.live=1' --output "$out/loader/addons/live.addon.efi"
