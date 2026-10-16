#!/bin/bash
# The install procedure under test by installer-bootc.sh, run as root in the
# installer initrd (the root shell of the installer addon). It is the
# prototype of the real installer, not a part of it: partition, (optionally)
# LUKS2 + TPM2, extract the image from the stick, let go of the stick, then
# `bootc install to-filesystem` straight from the initrd, no container.
#
# Environment: TARGET_IMGREF (required, the registry reference that `bootc
# upgrade` will pull from), TARGET (default /dev/vda), ROOT_SIZE (default 8G;
# the rest of the disk stays free for the encrypted /var that the initrd's
# repart creates on the first boot), SCRATCH_SIZE (default 4G, deleted again),
# ENCRYPT (default 1: LUKS2 root sealed to the TPM; 0: plain ext4 root).
# Progress markers on stdout: PHASE <name> <seconds>, STICK-FREE, INSTALL-DONE.
set -euo pipefail

T=${TARGET:-/dev/vda}
ROOT_SIZE=${ROOT_SIZE:-8G}
SCRATCH_SIZE=${SCRATCH_SIZE:-4G}
ENCRYPT=${ENCRYPT:-1}
REF=${TARGET_IMGREF:?}
SECONDS=0
phase() { echo "PHASE $1 $((SECONDS - last))"; last=$SECONDS; }
last=0

# Memory and the RAM-backed root, sampled in the background for the report.
( while sleep 2; do echo "$(free -m | awk '/^Mem:/ {print $3, $7}') $(df -m --output=used / | tail -1)"; done > /tmp/mem.log 2>/dev/null ) &
sampler=$!
trap 'kill $sampler 2>/dev/null || true' EXIT

# 1. The stick: a vfat volume labeled INGLENOOK with /inglenook/image.oci.tar.NNN.
for _ in $(seq 30); do dev=$(blkid -L INGLENOOK 2>/dev/null) && break; sleep 1; done
mkdir -p /mnt/stick && mount -o ro "$dev" /mnt/stick
(cd /mnt/stick/inglenook && sha256sum --quiet -c SHA256SUMS)
phase stick-verified

# 2. Partitions: ESP, root (type root-x86-64, found by gpt-auto at boot), scratch at the end.
sgdisk -Z "$T" >/dev/null
sgdisk -n1:0:+1G -t1:EF00 -c1:ESP -n2:0:+"$ROOT_SIZE" -t2:8304 -c2:root \
  -n3:-"$SCRATCH_SIZE":0 -t3:8300 -c3:scratch "$T" >/dev/null
udevadm settle
for p in ESP root scratch; do for _ in $(seq 20); do [ -e /dev/disk/by-partlabel/$p ] && break; sleep 0.5; done; done
ESP=/dev/disk/by-partlabel/ESP ROOT=/dev/disk/by-partlabel/root SCRATCH=/dev/disk/by-partlabel/scratch

# 3. The root: LUKS2 with a TPM2 token and no other slot (what bootc's tpm2-luks does), or plain.
rootdev=$ROOT
if [ "$ENCRYPT" = 1 ]; then
  head -c 48 /dev/urandom | base64 -w0 > /tmp/key
  cryptsetup luksFormat --batch-mode --type luks2 --key-file /tmp/key "$ROOT"
  systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs= --unlock-key-file=/tmp/key "$ROOT"
  systemd-cryptenroll --wipe-slot=password --unlock-tpm2-device=auto "$ROOT"
  rm -f /tmp/key
  systemd-cryptsetup attach root "$ROOT" - tpm2-device=auto,headless=yes
  rootdev=/dev/mapper/root
fi
mkfs.vfat -F 32 -n ESP "$ESP" >/dev/null
mkfs.ext4 -q -O verity -L root "$rootdev"   # composefs wants fs-verity
mkfs.ext4 -q -L scratch "$SCRATCH"
mkdir -p /target /scratch
mount "$rootdev" /target && mkdir -p /target/boot && mount "$ESP" /target/boot
mount "$SCRATCH" /scratch
phase partitioned

# 4. The image: split oci-archive -> OCI layout on the scratch partition (nothing in RAM).
mkdir -p /scratch/oci /scratch/tmp
cat /mnt/stick/inglenook/image.oci.tar.* | tar -x -C /scratch/oci
phase extracted
umount /mnt/stick
echo STICK-FREE

# 5. bootc. The running root plays the part of the container's root: it wants
# ostree/prepare-root.conf from /usr/lib or /etc (/usr is read-only here, /etc is not) ...
mkdir -p /etc/ostree
printf '[composefs]\nenabled = yes\n[sysroot]\nreadonly = true\n' > /etc/ostree/prepare-root.conf
# ... and its temporary files go to the disk, not to RAM.
mount --bind /scratch/tmp /var/tmp
bootc install to-filesystem --composefs-backend --bootloader systemd --generic-image \
  --skip-fetch-check --source-imgref oci:/scratch/oci:latest --target-imgref "$REF" /target
phase bootc-install

# 6. Tidy up: the scratch partition goes, its space joins the free space after the root.
umount /var/tmp /scratch
sgdisk -d3 "$T" >/dev/null
umount /target/boot /target
[ "$ENCRYPT" = 1 ] && cryptsetup close root
sync
phase finished
echo INSTALL-DONE
