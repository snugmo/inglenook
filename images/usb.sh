#!/usr/bin/env bash
# Build a raw disk image that boots on a physical UEFI machine, for writing to
# a USB stick. By default it is a live installer: the system runs from the
# stick with /etc and /var in RAM and the stick mounted read-only, and the image
# to install sits on the stick (/installer/inglenook.oci). See docs/usb.md and
# docs/install.md. LIVE=0 builds the old persistent stick instead (/etc and /var
# on the stick, a full system to try things on).
#
#   images/usb.sh                   -> build/usb/inglenook.img (+ .zst)
#   sudo dd if=build/usb/inglenook.img of=/dev/sdX bs=4M conv=fsync status=progress
#
# The image is a normal `bootc install --composefs-backend --bootloader systemd
# --generic-image`, so systemd-boot sits at the removable-media path
# \EFI\BOOT\BOOTX64.EFI and the root partition grows to fill the stick on first
# boot. Secure Boot must be off: the UKI and loader are unsigned.
#
# Logins. Nothing is hardcoded in the repo; this script generates, under
# build/usb (gitignored):
#   key, key.pub   an ssh test key; key.pub is baked in as user's authorized key
#   password       a random console password, delivered as a systemd credential
#                  (passwd.hashed-password.user) on the ESP, which systemd-sysusers
#                  applies when it creates `user` on first boot
# To use your own instead, put your public key in build/usb/key.pub (and delete
# build/usb/password) before running, or add credentials to the stick's ESP
# afterwards: \loader\credentials\<name>.cred, made with `systemd-creds encrypt
# --with-key=null --name=<name> - <name>.cred`, e.g.
# ssh.authorized_keys.root or passwd.hashed-password.user.
#
# Environment: TARGET_SIZE (default 14G; must fit the stick); LIVE=0 for the
# persistent stick; XFS_VAR=1 builds the opt-in variant with all of /var on an
# XFS partition that fills the rest of the drive: on a live stick that is the
# system it installs (install with --root-size, see docs/install.md); with LIVE=0
# the stick itself gets it (ROOT_SIZE, default 8G, is its root partition; see
# AGENTS.md).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
WORK=${WORK:-$REPO/build/usb}
export WORK
vm=$HERE/test/vm.sh

mkdir -p "$WORK/esp/loader/credentials"
LIVE=${LIVE:-1}
rm -rf "$WORK/esp/loader/addons"
if [[ $LIVE == 1 ]]; then
  "$HERE/live-addon.sh" "$WORK/esp"
  export IMAGE_ON_ROOT=1
fi

# The login key is dev-keys/authorized_keys (images/build.sh generates it on
# first use; gitignored).
if [[ ! -f $WORK/password ]]; then
  head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16 > "$WORK/password"
  chmod 600 "$WORK/password"
fi
cred=$WORK/esp/loader/credentials/passwd.hashed-password.user.cred
# systemd-creds only encrypts locally as root (otherwise it asks a varlink
# service that does not exist in a container); `unshare -r` gives it a fake one.
openssl passwd -6 -stdin < "$WORK/password" | tr -d '\n' \
  | unshare -r systemd-creds encrypt --with-key=null --name=passwd.hashed-password.user - "$cred"

# console= order: the last one becomes /dev/console, so tty0 (the screen) goes
# last; ttyS0 still receives the kernel log for machines with a serial port.
kargs="rw console=ttyS0,115200n8 console=tty0"
if [[ ${XFS_VAR:-} == 1 ]]; then
  kargs+=" inglenook.var=xfs"
  [[ $LIVE == 1 ]] || ROOT_SIZE=${ROOT_SIZE:-8G}
fi
ref=$(KARGS="$kargs" \
        "$REPO/images/build.sh" | tee /dev/stderr | sed -n 's/^built //p')

"$vm" prep
ESP_FILES=$WORK/esp TARGET_SIZE=${TARGET_SIZE:-14G} ROOT_SIZE=${ROOT_SIZE:-} "$vm" install "$ref"

rm -f "$WORK/inglenook.img"
mv "$WORK/target.img" "$WORK/inglenook.img"
zstd -T0 -q -f "$WORK/inglenook.img" -o "$WORK/inglenook.img.zst"

cat <<EOF

image:     $WORK/inglenook.img   ($(du -h --apparent-size "$WORK/inglenook.img" | cut -f1); also .zst)
write:     sudo dd if=$WORK/inglenook.img of=/dev/sdX bs=4M conv=fsync status=progress
mode:      $([[ $LIVE == 1 ]] && echo "live (RAM state, read-only stick, image in /installer)" || echo "persistent")
login:     user / $(cat "$WORK/password")   (console)
           ssh -i $REPO/dev-keys/id_ed25519 user@inglenook.local   (or the IP shown on the login screen)
EOF
