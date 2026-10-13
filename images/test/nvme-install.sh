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
# The XFS /var variant has a few more first-boot denials (see xfsvar.sh).
[[ -n ${ROOT_SIZE:-} ]] && export AVC_BASELINE_EXTRA=$HERE/selinux-denials.xfsvar.baseline

mkdir -p "$WORK"
# vm.sh ssh uses $WORK/key; the stick has dev-keys/authorized_keys baked in.
cp "$REPO/dev-keys/id_ed25519" "$WORK/key"; chmod 600 "$WORK/key"
cp --sparse=always "$STICK" "$WORK/stick.img"
rm -f "$WORK/nvme.img"; truncate -s "${NVME_SIZE:-24G}" "$WORK/nvme.img"
pw=$(cat "$PASSWORD_FILE")

echo "boot 1: the stick (USB) with a blank NVMe drive"
cp "$WORK/stick.img" "$WORK/target.img"
VM_QEMU_EXTRA="-drive file=nvme.img,format=raw,if=none,id=nvm -device nvme,drive=nvm,serial=inglenook-nvme" \
  BOOT_DEVICE=usb "$vm" start net
"$vm" wait
"$vm" ssh 'lsblk -dno NAME,SIZE,TRAN,MODEL | grep -E "^(nvme|sd)"'

# The commands from docs/install.md, run as root through sudo (-S reads the
# password from stdin, so the script itself comes in via -c).
ROOT_SIZE=${ROOT_SIZE:-}   # set for the XFS /var stick, which needs free space
root_opt=${ROOT_SIZE:+--root-size $ROOT_SIZE}
sudo_sh() { "$vm" ssh "echo '$pw' | sudo -S -p '' sh -c '$1'"; }
sudo_sh 'bootc image copy-to-storage'
sudo_sh "podman run --rm --privileged --pid=host --security-opt label=type:unconfined_t \\
  -v /dev:/dev -v /var/lib/containers:/var/lib/containers localhost/bootc \\
  bootc install to-disk --composefs-backend --bootloader systemd --filesystem ext4 \\
  $root_opt --wipe /dev/nvme0n1"
"$vm" ssh 'lsblk -no NAME,SIZE,FSTYPE,PARTLABEL /dev/nvme0n1'
# Carry the stick's credentials (the console password) over to the new ESP, which
# the install does not copy; then show what ended up on it.
sudo_sh 'mount /dev/nvme0n1p2 /mnt && cp -r /boot/loader/credentials /mnt/loader/ && umount /mnt'
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
check "running from the nvme drive" 'findmnt -no SOURCE /sysroot | grep -c nvme0n1' 1
check "hostname" 'hostnamectl hostname' inglenook
check "selinux mode is $expect_mode" 'getenforce' "$expect_mode"
check "no failed units" 'systemctl --failed --no-legend | wc -l' 0
check "no journal errors" 'journalctl -b -p err --no-pager -q | grep -avE "virt/tdx" | cut -c1-200 | head -5' ''
# The install registers no NVRAM entry (the firmware boots the fallback path); the
# documented efibootmgr step adds one.
sudo_sh 'efibootmgr -c -d /dev/nvme0n1 -p 2 -L inglenook -l \\EFI\\systemd\\systemd-bootx64.efi >/dev/null'
check "firmware boot entry added with efibootmgr" 'efibootmgr | grep -cE "^Boot[0-9A-F]+\* inglenook\s"' 1
check "console password was applied from the carried-over credential" "echo '$pw' | sudo -S -p '' true && echo ok" ok
if [[ -n $ROOT_SIZE ]]; then
  check "/var is xfs on the same drive" 'stat -f -c %T /var' xfs
  check "/var is the var partition" 'findmnt -rno SOURCE -t xfs /var | xargs lsblk -no PARTLABEL' var
fi
"$vm" new-avc || fail=1
exit $fail
