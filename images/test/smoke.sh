#!/usr/bin/env bash
# End-to-end check: build the image, install it, boot it with no NIC, ssh in
# over vsock and verify the basics. Needs KVM, OVMF, qemu and vhost-device-vsock.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${WORK:-$REPO/build/vm}
export WORK
vm=$HERE/vm.sh

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
check "selinux is enforcing" 'getenforce' Enforcing
check "no selinux denials" 'journalctl -b --no-pager | grep -ac "avc:  denied"' 0
# Kernel noise a VM cannot avoid is filtered: TDX probing on non-TDX hosts.
check "no journal errors" 'journalctl -b -p err --no-pager -q | grep -avE "virt/tdx|sudo\[" | wc -l' 0
check "no failed units" 'systemctl --failed --no-legend | wc -l' 0
check "user is in wheel" 'id -nG user | tr " " "\n" | grep -x wheel' wheel
check "no network interface besides lo" 'ip -br link | grep -vc "^lo"' 0
check "/var is mounted read-write" 'findmnt -no OPTIONS /var | cut -d, -f1' rw
check "root is composefs" 'findmnt -no FSTYPE,SOURCE / | cut -d: -f1' 'overlay composefs'
exit $fail
