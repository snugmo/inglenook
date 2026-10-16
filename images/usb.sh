#!/usr/bin/env bash
# Build a raw disk image that boots the whole OS from a USB stick on a physical
# UEFI machine, with /etc and /var persistent on the stick: a system to try things
# on, not an installer (the installer stick is images/installer/stick.sh, see
# docs/installer.md). See docs/usb.md.
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
# Environment: TARGET_SIZE (default 14G; must fit the stick). The stick has no encrypted
# root or /var: it travels between machines, so no TPM key can follow it.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
WORK=${WORK:-$REPO/build/usb}
export WORK
vm=$HERE/test/vm.sh

mkdir -p "$WORK/esp/loader/credentials"

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
# No inglenook.var=xfs: a stick that travels between machines has no TPM key for a var volume.
ref=$(KARGS="$kargs" \
        "$REPO/images/build.sh" | tee /dev/stderr | sed -n 's/^built //p')

"$vm" prep
# Not encrypted: the stick moves between machines, a TPM-sealed key would not follow it.
BLOCK_SETUP=direct ESP_FILES=$WORK/esp TARGET_SIZE=${TARGET_SIZE:-14G} ROOT_SIZE=${ROOT_SIZE:-} "$vm" install "$ref"

rm -f "$WORK/inglenook.img"
mv "$WORK/target.img" "$WORK/inglenook.img"
zstd -T0 -q -f "$WORK/inglenook.img" -o "$WORK/inglenook.img.zst"
(cd "$WORK" && sha256sum inglenook.img inglenook.img.zst > SHA256SUMS)

cat <<EOF

image:     $WORK/inglenook.img   ($(du -h --apparent-size "$WORK/inglenook.img" | cut -f1); also .zst)
write:     sudo dd if=$WORK/inglenook.img of=/dev/sdX bs=4M conv=fsync status=progress
mode:      persistent (/etc and /var are on the stick)
login:     user / $(cat "$WORK/password")   (console)
           ssh -i $REPO/dev-keys/id_ed25519 user@inglenook.local   (or the IP shown on the login screen)
EOF
