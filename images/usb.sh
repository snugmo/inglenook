#!/usr/bin/env bash
# Build a raw disk image that boots on a physical UEFI machine, for writing to
# a USB stick:
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
# Environment: TARGET_SIZE (default 14G; must fit the stick).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
WORK=${WORK:-$REPO/build/usb}
export WORK
vm=$HERE/test/vm.sh

mkdir -p "$WORK/esp/loader/credentials"

[[ -f $WORK/key.pub ]] || ssh-keygen -q -t ed25519 -N '' -C inglenook-usb -f "$WORK/key"

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
ref=$(SSH_PUBKEY=$(cat "$WORK/key.pub") KARGS="rw console=ttyS0,115200n8 console=tty0" \
        "$REPO/images/build.sh" | tee /dev/stderr | sed -n 's/^built //p')

"$vm" prep
ESP_FILES=$WORK/esp TARGET_SIZE=${TARGET_SIZE:-14G} "$vm" install "$ref"

rm -f "$WORK/inglenook.img"
mv "$WORK/target.img" "$WORK/inglenook.img"
zstd -T0 -q -f "$WORK/inglenook.img" -o "$WORK/inglenook.img.zst"

cat <<EOF

image:     $WORK/inglenook.img   ($(du -h --apparent-size "$WORK/inglenook.img" | cut -f1); also .zst)
write:     sudo dd if=$WORK/inglenook.img of=/dev/sdX bs=4M conv=fsync status=progress
login:     user / $(cat "$WORK/password")   (console)
           ssh -i $WORK/key user@inglenook.local   (or the IP shown on the login screen)
EOF
