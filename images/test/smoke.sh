#!/usr/bin/env bash
# End-to-end check: build the image, install it, boot it with no NIC, ssh in
# over vsock and verify the basics. Needs KVM, OVMF, qemu and vhost-device-vsock.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${WORK:-$REPO/build/vm}
export WORK
vm=$HERE/vm.sh
# The UKI is permissive by default while the policy is worked out (the build
# honors SELINUX_ENFORCING too); expect the matching mode.
[[ ${SELINUX_ENFORCING:-0} == 1 ]] && expect_mode=Enforcing || expect_mode=Permissive

mkdir -p "$WORK"
[[ -f $WORK/key ]] || ssh-keygen -q -t ed25519 -N '' -C inglenook-test -f "$WORK/key"

"$vm" prep
ref=$(SSH_PUBKEY=$(cat "$WORK/key.pub") "$REPO/images/build.sh" | tee /dev/stderr | sed -n 's/^built //p')
"$vm" install "$ref"
trap '"$vm" stop' EXIT
"$vm" start vsock
"$vm" wait

fail=0
check() { # description command-run-in-guest expected-output
  local got; got=$("$vm" ssh "$2" 2>&1 || true)
  if [[ $got == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$got', want '$3'"; fail=1; fi
}
check "selinux mode is $expect_mode" 'getenforce' "$expect_mode"
"$vm" new-avc || fail=1
# Kernel noise a VM cannot avoid is filtered: TDX probing on non-TDX hosts.
check "no journal errors" 'journalctl -b -p err --no-pager -q | grep -avE "virt/tdx|tpm tpm0: A TPM error \(256\)" | cut -c1-200 | head -5' ''
check "no failed units" 'systemctl --failed --no-legend | wc -l' 0
check "user is in wheel" 'id -nG user | tr " " "\n" | grep -x wheel' wheel
check "no console autologin on an installed system" 'loginctl list-sessions --no-legend | awk "\$3==\"root\" && \$6 ~ /^user/ " | wc -l' 0
check "no setuid files" 'find / -xdev -type f -perm -4000 2>/dev/null | head -3' ''
check "no network interface besides lo" 'ip -br link | grep -vc "^lo"' 0
check "/var is mounted read-write" 'findmnt -no OPTIONS /var | tail -1 | cut -d, -f1' rw
check "root is composefs" 'findmnt -no FSTYPE,SOURCE / | cut -d: -f1' 'overlay composefs'
exit $fail
