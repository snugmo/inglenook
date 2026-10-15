#!/usr/bin/env bash
# The "boot the stick, install to the internal drive" flow, end to end in QEMU:
# boot images/usb.sh's image as a USB stick with a blank virtual NVMe drive
# attached, run the documented install commands (docs/install.md) inside it,
# then boot from the NVMe alone and check the result.
#
#   images/test/nvme-install.sh [stick-image]     (default: build/usb/inglenook.img)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${WORK:-$REPO/build/nvme}
export WORK
vm=$HERE/vm.sh
STICK=${1:-$REPO/build/usb/inglenook.img}
PASSWORD_FILE=${PASSWORD_FILE:-$REPO/build/usb/password}
[[ ${SELINUX_ENFORCING:-0} == 1 ]] && expect_mode=Enforcing || expect_mode=Permissive
trap '"$vm" stop' EXIT

mkdir -p "$WORK"
# vm.sh ssh uses $WORK/key; the stick has dev-keys/authorized_keys baked in.
cp "$REPO/dev-keys/id_ed25519" "$WORK/key"; chmod 600 "$WORK/key"
# The image has no sudo: vm.sh also injects this key for root (SMBIOS credential),
# and the documented commands run as root over ssh (on the console the live
# stick logs in as root by itself).
ssh-keygen -y -f "$WORK/key" > "$WORK/key.pub"
cp --sparse=always "$STICK" "$WORK/stick.img"
rm -f "$WORK/nvme.img"; truncate -s "${NVME_SIZE:-24G}" "$WORK/nvme.img"
pw=$(cat "$PASSWORD_FILE")

echo "boot 1: the stick (USB) with a blank NVMe drive"
cp "$WORK/stick.img" "$WORK/target.img"
VM_QEMU_EXTRA="-drive file=nvme.img,format=raw,if=none,id=nvm -device nvme,drive=nvm,serial=inglenook-nvme" \
  BOOT_DEVICE=usb "$vm" start net
"$vm" wait
"$vm" ssh 'lsblk -dno NAME,SIZE,TRAN,MODEL | grep -E "^(nvme|sd)"'

# The commands from docs/install.md, run as root.
ROOT_SIZE=${ROOT_SIZE:-8G}   # the rest of the drive becomes the encrypted XFS /var
root_sh() { SSH_USER=root "$vm" ssh "sh -c '$1'"; }
# The live stick runs the installer from its own root (podman --rootfs /) and
# installs from the OCI directory kept on the stick, so nothing is copied into
# the RAM-backed /var first.
root_sh "podman run --rm --privileged --pid=host --security-opt label=type:unconfined_t \\
  -v /dev:/dev -v /sysroot/installer:/installer:ro --rootfs /:O \\
  bootc install to-disk --composefs-backend --bootloader systemd --filesystem ext4 \\
  --block-setup tpm2-luks --root-size $ROOT_SIZE \\
  --source-imgref oci:/installer/inglenook:latest --wipe /dev/nvme0n1"
"$vm" ssh 'lsblk -no NAME,SIZE,FSTYPE,PARTLABEL /dev/nvme0n1'
# Carry the stick's credentials (the console password) over to the new ESP, which
# the install does not copy; then show what ended up on it.
root_sh 'mount /dev/nvme0n1p2 /mnt && cp -r /boot/loader/credentials /mnt/loader/ && umount /mnt'
"$vm" stop

echo "boot 2: from the NVMe drive alone"
rm -f "$WORK/target.img" "$WORK/stick.img"
mv "$WORK/nvme.img" "$WORK/target.img"
BOOT_DEVICE=nvme KEEP_VARS=1 "$vm" start net
"$vm" wait

fail=0
check() { # description command-run-in-guest expected-output
  local got; got=$("$vm" ssh "$2" 2>&1 || true)
  if [[ $got == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$got', want '$3'"; fail=1; fi
}
check "running from the nvme drive" 'lsblk -srno NAME "$(findmnt -no SOURCE /sysroot)" | grep -cx nvme0n1' 1
check "hostname" 'hostnamectl hostname' inglenook
check "selinux mode is $expect_mode" 'getenforce' "$expect_mode"
check "no failed units" 'systemctl --failed --no-legend | wc -l' 0
check "no journal errors" 'journalctl -b -p err --no-pager -q | grep -avE "virt/tdx|tpm tpm0: A TPM error \(256\)" | cut -c1-200 | head -5' ''
# The install registers no NVRAM entry (the firmware boots the fallback path); the
# documented efibootmgr step adds one.
root_sh 'efibootmgr -c -d /dev/nvme0n1 -p 2 -L inglenook -l \\EFI\\systemd\\systemd-bootx64.efi >/dev/null'
check "firmware boot entry added with efibootmgr" 'efibootmgr | grep -cE "^Boot[0-9A-F]+\* inglenook\s"' 1
# The carried-over credential must have set the stick's password hash for `user`.
hash=$(root_sh 'grep ^user: /etc/shadow | cut -d: -f2')
salt=$(cut -d'$' -f3 <<<"$hash")
if [[ -n $salt && $hash == "$(openssl passwd -6 -salt "$salt" -stdin <<<"$pw")" ]]; then
  echo "ok   console password was applied from the carried-over credential"
else echo "FAIL console password was not applied"; fail=1; fi
check "/var is xfs" 'stat -f -c %T /var' xfs
check "/var is the unlocked var volume" 'findmnt -rno SOURCE -t xfs /var' /dev/mapper/var
got=$(root_sh 'for v in root var; do cryptsetup status $v | sed -n "s/^ *type: *//p"; done | tr "\n" " "')
if [[ $got == "LUKS2 LUKS2 " ]]; then echo "ok   the root and /var are LUKS2"; else echo "FAIL the root and /var are LUKS2: got '$got'"; fail=1; fi
"$vm" new-avc || fail=1
exit $fail
