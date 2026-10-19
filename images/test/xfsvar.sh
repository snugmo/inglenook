#!/usr/bin/env bash
# Opt-in feature check: all of /var on its own XFS partition (inglenook.var=xfs
# on the kernel command line). Builds with the switch on, installs with a
# limited root (--root-size) on a bigger disk, and verifies that the initrd
# created the partition, that /var is XFS, that boots stay clean and that data
# survives a reboot.
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

echo "boot 1: the initrd creates and formats the partition"
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

# No TPM: nothing to seal the volume to. The initrd must skip the var service (not fail), /var
# stays on the root, and the root keeps its size (a VM used to grow it over the free space with
# the base image's bootc-generic-growpart.service, now masked).
echo "no TPM: /var stays on the root, the root does not grow"
export TPM=0
BLOCK_SETUP=direct ROOT_SIZE=8G TARGET_SIZE=14G "$vm" install "$ref"
truncate -s "${DISK_SIZE:-20G}" "$WORK/target.img"
"$vm" start vsock
"$vm" wait
check "/var is not xfs" 'test "$(stat -f -c %T /var)" != xfs && echo yes' yes
check "there is no var partition" 'test -e /dev/disk/by-partlabel/var && echo yes || echo no' no
check "the root keeps its size" 'lsblk -bno SIZE "$(findmnt -rno SOURCE /sysroot)" | awk "{print (\$1 < 9*2^30) ? \"small\" : \"grown\"}"' small
check "the root grow service is masked" 'systemctl is-enabled bootc-generic-growpart.service 2>&1' masked
check "the initrd skipped the var service" 'journalctl -b -o cat --no-pager | grep -q "Create the XFS /var partition.*skipped, unmet condition check ConditionPathExists=/dev/tpmrm0" && echo yes' yes
check "selinux mode is $expect_mode" 'getenforce' "$expect_mode"
"$vm" new-avc || fail=1
check "no failed units" 'systemctl --failed --no-legend | wc -l' 0
check "no journal errors" 'journalctl -b -p err --no-pager -q | grep -avE "virt/tdx|tpm tpm0: A TPM error \(256\)" | cut -c1-200 | head -5' ''
exit $fail
