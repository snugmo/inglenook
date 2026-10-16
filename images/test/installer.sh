#!/usr/bin/env bash
# Installer environment test (design spike): build the installer stick (one
# FAT32 partition, images/installer/stick.sh), boot it in QEMU/OVMF as a USB
# drive, and check that the installer addon puts the machine in a root shell in
# the initrd, without switching root.
#
#   images/test/installer.sh [image-ref]     (default: the newest ghcr.io/snugmo/inglenook image)
# Environment: PTYPE (see stick.sh), WORK (default build/installer).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${WORK:-$REPO/build/installer}
export WORK
OVMF=/usr/share/OVMF
ref=${1:-$(podman images --sort created --format '{{.Repository}}:{{.Tag}}' ghcr.io/snugmo/inglenook | awk 'NR==1')}

"$REPO/images/installer/stick.sh" "$ref"

cd "$WORK"
cp "$OVMF/OVMF_VARS.fd" vars.fd
rm -f serial.sock qemu.pid
qemu-system-x86_64 -accel kvm -machine q35 -cpu host -smp 2 -m 2G -display none -nodefaults -no-reboot \
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF/OVMF_CODE.fd" -drive "if=pflash,format=raw,file=vars.fd" \
  -device qemu-xhci,id=xhci -drive file=stick.img,format=raw,if=none,id=stick \
  -device usb-storage,bus=xhci.0,drive=stick,bootindex=0 \
  -serial unix:serial.sock,server,nowait -daemonize -pidfile qemu.pid
trap 'kill "$(cat qemu.pid)" 2>/dev/null || true' EXIT

T=$'\t'
"$HERE/serial-shell.py" serial.sock 120 'bash-.*# ' <<CHECKS
the shell is root${T}id -un${T}^root\$
the addon cmdline is appended${T}cat /proc/cmdline${T}rd.systemd.unit=inglenook-installer.target
the UKI cmdline is still there${T}cat /proc/cmdline${T}composefs=
we are in the initrd, not the real root${T}findmnt -no FSTYPE /${T}(rootfs|tmpfs|ramfs)
switch-root never ran${T}systemctl is-active initrd-switch-root.service${T}inactive
the installer tree is there${T}ls /usr/installer${T}units
the units are reachable through their symlinks${T}systemctl is-active inglenook-installer.target${T}^active
the boot medium is one vfat partition${T}lsblk -no FSTYPE,LABEL /dev/sda1 /dev/sda${T}vfat +INGLENOOK
CHECKS
