#!/usr/bin/env bash
# Opt-in feature check: all of /var on its own XFS partition on a LUKS2 volume
# (inglenook.var=xfs on the kernel command line). Builds with the switch on,
# installs with a limited root (--root-size) on a bigger disk, and verifies
# the first-boot /var path: a fresh install made by `bootc install` (no
# installer) has no var partition, so the initrd's safety net (the
# inglenook-var-repart.service wrapper) creates it in the free space - sealed
# to the TPM when there is one, an empty key slot when there is not - and the
# boot unlocks and mounts it, the root keeps its size, boots stay clean and
# data survives a reboot. (The stick's installer makes the partition itself;
# that path is install-from-stick.sh.)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${WORK:-$REPO/build/xfsvar}
export WORK
vm=$HERE/vm.sh
# The UKI is permissive by default while the policy is worked out (the build
# honors SELINUX_ENFORCING too); expect the matching mode.
[[ ${SELINUX_ENFORCING:-0} == 1 ]] && expect_mode=Enforcing || expect_mode=Permissive
trap '"$vm" stop' EXIT

mkdir -p "$WORK"
[[ -f $WORK/key ]] || ssh-keygen -q -t ed25519 -N '' -C inglenook-test -f "$WORK/key"

"$vm" prep
ref=$("$REPO/images/build.sh" | tee /dev/stderr | sed -n 's/^built //p')
TPM=1 BLOCK_SETUP=tpm2-luks ROOT_SIZE=${ROOT_SIZE:-8G} TARGET_SIZE=${TARGET_SIZE:-14G} "$vm" install "$ref"
# A real stick is larger than the image: the partition must also use the space
# after the image's end (repart moves the backup GPT header).
truncate -s "${DISK_SIZE:-20G}" "$WORK/target.img"

fail=0
check() { # description command-run-in-guest expected-output
  local got; got=$("$vm" ssh "$2" 2>&1 || true)
  if [[ $got == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$got', want '$3'"; fail=1; fi
}
checks() {
  # stat -f: the filesystem of /var, not the mount stack (bootc's ext4 bind is under it)
  check "/var is xfs" 'stat -f -c %T /var' xfs
  check "/var uses the whole disk" 'findmnt -rno SOURCE -t xfs /var | xargs lsblk -bno SIZE | awk "{print (\$1 > 10*2^30) ? \"yes\" : \"no\"}"' yes
  check "/var is on a LUKS2 volume" 'cryptsetup status var | sed -n "s/^ *type: *//p"' LUKS2
  check "the var volume has a TPM2 token" 'cryptsetup luksDump /dev/disk/by-partlabel/var 2>/dev/null | grep -c "^  [0-9]*: systemd-tpm2"' 1
  check "the root is on LUKS2" 'cryptsetup status root | sed -n "s/^ *type: *//p"' LUKS2
  check "/var is the unlocked var volume" 'findmnt -rno SOURCE -t xfs /var' /dev/mapper/var
  check "selinux mode is $expect_mode" 'getenforce' "$expect_mode"
  "$vm" new-avc || fail=1
  check "no failed units" 'systemctl --failed --no-legend | wc -l' 0
  check "no journal errors" 'journalctl -b -p err --no-pager -q | grep -avE "virt/tdx|tpm tpm0: A TPM error \(256\)" | cut -c1-200 | head -5' ''
}

echo "boot 1: the initrd safety net creates and formats the partition"
export TPM=1 SSH_USER=root   # cryptsetup status needs root (SMBIOS credential key)
"$vm" start vsock
"$vm" wait
checks
"$vm" ssh 'echo kept > ~/marker; sync'
"$vm" stop

echo "boot 2: the partition exists; data survives"
"$vm" start vsock
"$vm" wait
checks
check "data on /var survived the reboot" 'cat ~/marker' kept
"$vm" stop

# No TPM: nothing to seal the volume to, but /var is still made - the safety net
# uses the no-tpm definitions (Encrypt=key-file: an empty key slot, not a TPM
# seal), which the boot unlocks hands-off with the empty password. The root
# stays unencrypted and at its size (a VM used to grow it over the free space
# with the base image's bootc-generic-growpart.service, now masked).
echo "no TPM: the initrd makes the /var LUKS volume with an empty key"
export TPM=0
BLOCK_SETUP=direct ROOT_SIZE=8G TARGET_SIZE=14G "$vm" install "$ref"
truncate -s "${DISK_SIZE:-20G}" "$WORK/target.img"
"$vm" start vsock
"$vm" wait
check "/var is xfs" 'stat -f -c %T /var' xfs
check "/var uses the whole disk" 'findmnt -rno SOURCE -t xfs /var | xargs lsblk -bno SIZE | awk "{print (\$1 > 10*2^30) ? \"yes\" : \"no\"}"' yes
check "/var is on a LUKS2 volume" 'cryptsetup status var | sed -n "s/^ *type: *//p"' LUKS2
check "the var volume has one key slot and no tokens (empty key)" 'cryptsetup luksDump /dev/disk/by-partlabel/var 2>/dev/null | grep -cE "^  [0-9]+: (luks2|systemd-tpm2)"' 1
check "/var is the unlocked var volume" 'findmnt -rno SOURCE -t xfs /var' /dev/mapper/var
check "the root keeps its size" 'lsblk -bno SIZE "$(findmnt -rno SOURCE /sysroot)" | awk "{print (\$1 < 9*2^30) ? \"small\" : \"grown\"}"' small
check "the root grow service is masked" 'systemctl is-enabled bootc-generic-growpart.service 2>&1' masked
check "selinux mode is $expect_mode" 'getenforce' "$expect_mode"
"$vm" new-avc || fail=1
check "no failed units" 'systemctl --failed --no-legend | wc -l' 0
check "no journal errors" 'journalctl -b -p err --no-pager -q | grep -avE "virt/tdx|tpm tpm0: A TPM error \(256\)" | cut -c1-200 | head -5' ''
exit $fail
