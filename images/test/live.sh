#!/usr/bin/env bash
# Live-stick check: install the image with the live addon on the ESP (what
# usb.sh does by default), boot it, and verify that the system runs from RAM and
# that the boot writes nothing to the stick (see snapshot() below).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${WORK:-$REPO/build/live}
export WORK
vm=$HERE/vm.sh
# The fresh /var of the live system has the same first-boot denials as the XFS
# one (journald flushing before the new filesystem root is labeled).
export AVC_BASELINE_EXTRA=$HERE/selinux-denials.live.baseline
[[ ${SELINUX_ENFORCING:-0} == 1 ]] && expect_mode=Enforcing || expect_mode=Permissive

mkdir -p "$WORK"
[[ -f $WORK/key ]] || ssh-keygen -q -t ed25519 -N '' -C inglenook-test -f "$WORK/key"

"$vm" prep
ref=$(SSH_PUBKEY=$(cat "$WORK/key.pub") "$REPO/images/build.sh" | tee /dev/stderr | sed -n 's/^built //p')
rm -rf "$WORK/esp"
"$REPO/images/live-addon.sh" "$WORK/esp"
ESP_FILES=$WORK/esp TARGET_SIZE=${TARGET_SIZE:-8G} "$vm" install "$ref"
trap '"$vm" stop' EXIT

# What the boot may change on the stick: nothing in the root partition, and in
# the ESP only systemd-boot's own entropy files, \loader\random-seed and
# \loader\boot-secret-mixin. Snapshot both.
snapshot() { # dir
  rm -rf "$1"; mkdir -p "$1"
  local start size
  read -r start size < <(sfdisk -d "$WORK/target.img" | sed -n 's/.*start= *\([0-9]*\), size= *\([0-9]*\),.*name="root".*/\1 \2/p')
  dd if="$WORK/target.img" bs=512 skip="$start" count="$size" status=none | sha256sum | cut -d' ' -f1 > "$1/root.sha256"
  read -r start < <(sfdisk -d "$WORK/target.img" | sed -n 's/.*start= *\([0-9]*\),.*name="EFI-SYSTEM".*/\1/p')
  mcopy -s -n -i "$WORK/target.img@@$((start * 512))" :: "$1/esp"
}
snapshot "$WORK/before"
"$vm" start vsock
"$vm" wait

fail=0
check() { # description command-run-in-guest expected-output
  local got; got=$("$vm" ssh "$2" 2>&1 || true)
  if [[ $got == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$got', want '$3'"; fail=1; fi
}
check "live flag is on the command line" 'grep -o "inglenook.live=1" /proc/cmdline' inglenook.live=1
check "/etc is the RAM filesystem" 'findmnt -rno SOURCE,FSTYPE /etc | tail -1' '/dev/loop0 ext4'
check "/var is the RAM filesystem" 'findmnt -rno SOURCE,FSTYPE /var | tail -1' '/dev/loop1 ext4'
check "root is composefs" 'findmnt -no FSTYPE,SOURCE / | cut -d: -f1' 'overlay composefs'
check "root is read-only" 'findmnt -no OPTIONS / | cut -d, -f1' ro
check "the stick's root partition is read-only" 'findmnt -rno OPTIONS /sysroot | cut -d, -f1' ro
check "the stick's ESP is read-only" 'findmnt -rno OPTIONS -t vfat /boot | cut -d, -f1' ro
check "selinux mode is $expect_mode" 'getenforce' "$expect_mode"
check "the serial console is logged in as root (autologin)" 'loginctl list-sessions --no-legend | awk "\$3==\"root\" && \$7==\"ttyS0\"" | wc -l' 1
# On hardware logind starts kmsconvt@tty1 (the VT console) by itself; the VM has
# no display, so start it by hand and check that it logs root in on the seat.
SSH_USER=root "$vm" ssh 'systemctl start kmsconvt@tty1.service' || fail=1
sleep 3
check "the tty1 console (kmscon) logs in as root" 'loginctl list-sessions --no-legend | awk "\$3==\"root\" && \$4==\"seat0\"" | wc -l' 1
check "user is in wheel" 'id -nG user | tr " " "\n" | grep -x wheel' wheel
check "no failed units" 'systemctl --failed --no-legend | wc -l' 0
"$vm" new-avc || fail=1
check "no journal errors" 'journalctl -b -p err --no-pager -q | grep -avE "virt/tdx" | cut -c1-200 | head -5' ''
"$vm" stop
trap - EXIT
snapshot "$WORK/after"
if cmp -s "$WORK/before/root.sha256" "$WORK/after/root.sha256"; then echo "ok   the root partition was not written"
else echo "FAIL the root partition changed during the boot"; fail=1; fi
changed=$(diff -rq "$WORK/before/esp" "$WORK/after/esp" | grep -v -E 'random-seed|boot-secret-mixin' || true)
if [[ -z $changed ]]; then echo "ok   the ESP changed only in systemd-boot's entropy files"
else echo "FAIL the ESP changed: $changed"; fail=1; fi
exit $fail
