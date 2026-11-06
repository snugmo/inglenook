#!/usr/bin/env bash
# A FIDO2 security key on the LUKS volumes, end to end in QEMU, with a software
# FIDO2 token (softfido.py) inside the VM.
#
# The installer's own enrolment step (step 7, the volumes still closed in the
# initrd) needs a FIDO2 device in the initrd, which has no python3, so
# softfido.py cannot run there (its no-key path is covered by
# install-from-stick.sh FIDO2=1). This test covers the other end of the
# feature: install a disk (reusing install-from-stick.sh), boot it, enrol the
# software token into the LUKS volumes' 1 MiB headers from the booted system
# (systemd-cryptenroll on an active LUKS2 device fetches the volume key from
# the kernel), then reboot without the token:
#
#   ENCRYPT=luks (the no-tpm image: root and /var are empty-key volumes) -
#   the volumes are token-gated: the initrd waits the 30-second token timeout,
#   the unit fails, and the boot never reaches a login (the empty key is not
#   tried after the token wait, docs/encryption.md).
#
#   ENCRYPT=tpm2 (the tpm2 image: the root is sealed to the software TPM, /var
#   too) - the TPM unlocks /var before the token is tried, so a boot without
#   the key still boots: the key stays the fallback for a lost TPM.
#
#   images/test/install-fido2.sh [image-ref]
#
# Environment: ENCRYPT=tpm2|luks (default luks; luks needs the image ref of
# the no-tpm variant, the tpm2 installer refuses it - without a ref the
# newest ghcr.io/snugmo/inglenook image is used, which is tpm2), plus
# install-from-stick.sh's (WORK, RAM, KEY, STICK_REUSE, ROOT_SIZE, TARGET_SIZE,
# OLD_DATA). A disk left in $WORK-boot by a previous install-from-stick run is
# reused instead of reinstalling.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
IWORK=${WORK:-$REPO/build/install-fido2}
B=$IWORK-boot
vm=$HERE/vm.sh
ENCRYPT=${ENCRYPT:-luks}
[[ $ENCRYPT == tpm2 || $ENCRYPT == luks ]] || { echo "ENCRYPT must be tpm2 or luks (got '$ENCRYPT')" >&2; exit 1; }
ref=${1:-}
if [[ -z $ref ]]; then
  [[ $ENCRYPT == luks ]] && { echo "ENCRYPT=luks needs an image ref of the no-tpm variant" >&2; exit 1; }
  ref=$(podman images --sort created --format '{{.Repository}}:{{.Tag}}' ghcr.io/snugmo/inglenook | awk 'NR==1')
fi
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
trap '"$vm" stop' EXIT

# --- 1. a freshly installed disk (install-from-stick leaves it in $B) ---
if [[ ! -f $B/target.img ]]; then
  WORK=$IWORK "$HERE/install-from-stick.sh" "$ref"
fi
[[ -f $B/key ]] || { echo "need $B/key from the install" >&2; exit 1; }

# --- 2. boot the disk, enrol the software token into the LUKS volumes ---
export WORK=$B
if [[ $ENCRYPT == tpm2 ]]; then export TPM=1; else export TPM=0; fi
# The disk's first boot already happened in install-from-stick; keep the
# same wizard-suppression conditions so no prompt can block these boots.
export VM_FIRSTBOOT=1 VM_CMDLINE="inglenook.cryptenroll=no inglenook.tokenenroll=no"
check() { # description command-run-as-root-in-VM expected
  local got; got=$(SSH_USER=root "$vm" ssh "$2" 2>&1 || true)
  if [[ $got == "$3" ]]; then ok "$1"; else echo "FAIL $1: got '$got', want '$3'"; fail=1; fi
}
g() { SSH_USER=root "$vm" ssh "$@"; }

echo "boot: the installed disk, enrol the FIDO2 token"
"$vm" start net
"$vm" wait
tar -C "$HERE/token" -c . -C "$HERE" softfido.py | g 'mkdir -p /var/tmp/token && tar -x -C /var/tmp/token'
g 'systemctl stop softfido 2>/dev/null; modprobe uhid; systemd-run -q --unit=softfido python3 /var/tmp/token/softfido.py /var/tmp/token/state && sleep 2'
check "systemd sees the FIDO2 token" 'systemd-cryptenroll --fido2-device=list | grep -c "^/dev/hidraw"' 1

# Enrolment from the booted system: the volume is active, so cryptenroll fetches
# the volume key from the kernel (crypt_volume_key_get) and adds one keyslot
# (the volume key, keyed by the token's secret) plus one systemd-fido2 token.
VOLS=
[[ $ENCRYPT == luks ]] && VOLS="root var" || VOLS="var"
for v in $VOLS; do
  g "systemd-cryptenroll --fido2-device=auto /dev/disk/by-partlabel/$v"
done
for v in $VOLS; do
  check "the $v volume got a systemd-fido2 token" "cryptsetup luksDump /dev/disk/by-partlabel/$v 2>/dev/null | grep -c systemd-fido2" 1
  check "the $v volume now has two keyslots (the old key and the token's)" "cryptsetup luksDump /dev/disk/by-partlabel/$v 2>/dev/null | grep -cE '^  [0-9]+: luks2'" 2
done
check "no failed units" 'systemctl --failed --no-legend | wc -l' 0

# --- 3. reboot without the token (a cold boot: the transient softfido unit is gone) ---
echo "boot: without the token"
"$vm" start net
if [[ $ENCRYPT == tpm2 ]]; then
  "$vm" wait
  check "the boot without the key still boots (the TPM unlocks /var before the token is tried)" 'true' true
  check "/var is the unlocked var volume" 'findmnt -rno SOURCE -t xfs /var' /dev/mapper/var
  check "no failed units" 'systemctl --failed --no-legend | wc -l' 0
else
  # The empty-key volumes are token-gated: the initrd waits the 30-second token
  # timeout, the unit fails, and the boot never reaches a login.
  for _ in $(seq 180); do grep -aq 'login: ' "$B/target.log" 2>/dev/null && break; sleep 1; done
  if grep -aq 'login: ' "$B/target.log" 2>/dev/null; then bad "the boot without the token reached a login (should be token-gated)"
  else ok "the boot without the token never reached a login (token-gated)"; fi
  if grep -aq "Security token.*not present for unlocking volume root" "$B/target.log"; then ok "the initrd waited for the FIDO2 token and gave up"
  else bad "no 'Security token not present' in the initrd log"; fi
fi
"$vm" stop
exit $fail
