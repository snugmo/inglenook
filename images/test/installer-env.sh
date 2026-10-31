#!/usr/bin/env bash
# Installer environment test (design spike; not images/test/installer.sh, which is vm.sh's installer VM script): build the installer stick (one
# FAT32 partition, images/installer/stick.sh), boot it in QEMU/OVMF as a USB
# drive, and check that the installer addon puts the machine in a root shell in
# the initrd, without switching root.
#
#   images/test/installer-env.sh [image-ref]     (default: the newest ghcr.io/snugmo/inglenook image)
# Environment: PTYPE (see stick.sh), WORK (default build/installer).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${WORK:-$REPO/build/installer}
export WORK
OVMF=/usr/share/OVMF
ref=${1:-$(podman images --sort created --format '{{.Repository}}:{{.Tag}}' ghcr.io/snugmo/inglenook | awk 'NR==1')}

NO_IMAGE=1 "$REPO/images/installer/stick.sh" "$ref"

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
the banner reached the console, whole${T}@console${T}inglenook-install
the shell is root${T}id -un${T}^root\$
the addon cmdline is appended${T}cat /proc/cmdline${T}rd.systemd.unit=inglenook-installer.target
the console addon cmdline is appended${T}cat /proc/cmdline${T}console=ttyS0,115200n8
the UKI cmdline is still there${T}cat /proc/cmdline${T}composefs=
we are in the initrd, not the real root${T}findmnt -no FSTYPE /${T}(rootfs|tmpfs|ramfs)
switch-root never ran${T}systemctl is-active initrd-switch-root.service${T}inactive
the installer tree is there${T}ls /usr/installer${T}units
the units are reachable through their symlinks${T}systemctl is-active inglenook-installer.target${T}^active
the boot medium is one vfat partition${T}for i in \$(seq 30); do [ -b /dev/sda1 ] && break; sleep 1; done; udevadm settle; lsblk -no FSTYPE,LABEL /dev/sda1 /dev/sda${T}vfat +INGLENOOK
gdisk is installed${T}gdisk --version${T}GPT fdisk
sgdisk makes a GPT${T}truncate -s 64M /tmp/d.img && sgdisk -o -n 1:0:0 -c 1:x /tmp/d.img >/dev/null && sgdisk -p /tmp/d.img${T}^ +1 +2048 
util-linux works${T}lsblk --version${T}util-linux
xfsprogs works${T}mkfs.xfs -V${T}mkfs.xfs version
btrfs-progs works${T}btrfs --version${T}btrfs-progs
cryptsetup works${T}cryptsetup --version${T}cryptsetup
fuse3 works${T}fusermount3 --version${T}fusermount3
iputils works${T}ping -V${T}iputils
iproute works${T}ip -V${T}iproute2
curl works${T}curl --version${T}curl
tar works${T}tar --version${T}GNU tar
gzip works${T}gzip --version${T}gzip
bzip2 works${T}bzip2 --help 2>&1${T}bzip2
zstd works${T}zstd --version${T}Zstandard
xz works${T}xz --version${T}xz
zip works${T}zip -v${T}Zip
unzip works${T}unzip -v${T}UnZip
procps-ng works${T}ps --version${T}procps-ng
less works${T}less --version${T}less
which works${T}which which${T}which
dosfstools works${T}fsck.fat --version${T}fsck.fat
nvme-cli works${T}nvme version${T}nvme version
pciutils works${T}lspci --version${T}lspci version
attr works${T}getfattr --version${T}getfattr
acl works${T}getfacl --version${T}getfacl
libselinux-utils works${T}getsebool -h 2>&1${T}[Uu]sage
tpm2-tools works${T}tpm2_getcap --version${T}tpm2_getcap
bind-utils works${T}dig -v 2>&1${T}DiG
git-core works${T}git --version${T}git version
skopeo works${T}skopeo --version${T}skopeo version
skopeo has a default signature policy${T}test -s /usr/share/containers/policy.json -o -s /etc/containers/policy.json && echo has-policy${T}^has-policy
the install script is on the PATH${T}command -v inglenook-install${T}inglenook-install
efibootmgr is there${T}command -v efibootmgr${T}efibootmgr
CHECKS
