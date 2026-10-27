#!/usr/bin/env bash
# What inglenook-install does BEFORE it erases anything: it shows the disk and what is
# on it, refuses without the typed device name, rejects a bad root size and a
# non-disk, offers the disks without the installer stick, and leaves the disk
# byte-for-byte alone in all those cases. QEMU/OVMF; the disk holds an old filesystem
# and a partition labeled 'root'.
#
#   images/test/install-safety.sh
# Needs the stick of images/test/install-from-stick.sh (build/install-from-stick/stick.img;
# run that test once) or STICK=path.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${WORK:-$REPO/build/install-safety}
STICK=${STICK:-$REPO/build/install-from-stick/stick.img}
OVMF=/usr/share/OVMF
[[ -f $STICK ]] || { echo "no stick at $STICK; run images/test/install-from-stick.sh first" >&2; exit 1; }
mkdir -p "$WORK"; cd "$WORK"

# a disk with old data: a labeled ext4 and a partition labeled root. Big enough that the
# disk-level size check passes and the per-root-size checks below are the ones that fire.
rm -f target.img; truncate -s 32G target.img
printf 'label: gpt\nstart=1MiB, size=1GiB, type=L, name=olddata\nstart=2GiB, size=1GiB, type=L, name=root\n' | sfdisk -q target.img
mke2fs -q -F -t ext4 -L olddata -E offset=1048576 target.img 1048576
sum_before=$(sha256sum target.img | cut -d' ' -f1)

cp "$OVMF/OVMF_VARS.fd" vars.fd
rm -f serial.sock qemu.pid
qemu-system-x86_64 -accel kvm -machine q35 -cpu host -smp 2 -m 3G -display none -nodefaults -no-reboot \
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF/OVMF_CODE.fd" -drive "if=pflash,format=raw,file=vars.fd" \
  -device qemu-xhci,id=xhci -drive file="$STICK",format=raw,if=none,id=stick,readonly=on \
  -device usb-storage,bus=xhci.0,drive=stick,bootindex=0 \
  -drive file=target.img,format=raw,if=virtio,cache=writethrough \
  -serial unix:serial.sock,server,nowait -daemonize -pidfile qemu.pid
trap 'kill "$(cat qemu.pid)" 2>/dev/null || true' EXIT

T=$'\t'
rc=0
"$HERE/serial-shell.py" serial.sock 180 'bash-.*# ' <<CHECKS || rc=1
the stick is up${T}for i in \$(seq 40); do blkid -L INGLENOOK >/dev/null && break; sleep 1; done; blkid -L INGLENOOK${T}/dev/sd
the disks offered do not include the stick${T}printf '\n' | inglenook-install 2>&1 | grep -cE '^ +[0-9]+\) /dev/sd'${T}^0
the only disk offered is the target${T}printf '\n' | inglenook-install 2>&1 | grep -E '^ +[0-9]+\) /dev/'${T}1\) /dev/vda
what is on the disk is shown${T}printf 'x\n' | INSTALL_DISK=/dev/vda inglenook-install 2>&1 | grep -cE 'olddata|has a partition labeled .root.|EVERYTHING ON /dev/vda WILL BE ERASED'${T}^[3-9]
a wrong typed name does not erase${T}printf 'wrong\n' | INSTALL_DISK=/dev/vda inglenook-install 2>&1 | tail -2${T}Not confirmed; nothing was changed
the disk name alone is not enough${T}printf '/dev/vd\n' | INSTALL_DISK=/dev/vda inglenook-install 2>&1 | tail -2${T}Not confirmed
a partition is not a disk${T}INSTALL_DISK=/dev/vda1 inglenook-install 2>&1 | tail -2${T}is not a disk
a root too small is rejected before anything is erased${T}INSTALL_DISK=/dev/vda INSTALL_YES=1 INSTALL_ROOT_SIZE=4G INSTALL_ENCRYPT=none inglenook-install 2>&1 | tail -2${T}root must be between
a root that is not a size is rejected${T}INSTALL_DISK=/dev/vda INSTALL_YES=1 INSTALL_ROOT_SIZE=lots INSTALL_ENCRYPT=none inglenook-install 2>&1 | tail -2${T}is not a size
the old filesystem is still there${T}blkid -s LABEL -o value /dev/vda1${T}olddata
the old root partition label is still there${T}lsblk -rno PARTLABEL /dev/vda | grep -c root${T}^1
CHECKS

# power off by hand: the initrd has no logind for an ACPI button
"$HERE/serial-run.py" serial.sock 20 '(setsid systemctl poweroff >/dev/null 2>&1 &)' >/dev/null 2>&1 || true
for _ in $(seq 40); do kill -0 "$(cat qemu.pid)" 2>/dev/null || break; sleep 1; done
sum_after=$(sha256sum target.img | cut -d' ' -f1)
if [[ $sum_before == "$sum_after" ]]; then echo "ok   the disk is byte-for-byte unchanged"; else echo "FAIL the disk changed"; rc=1; fi
exit $rc
