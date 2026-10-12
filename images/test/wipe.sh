#!/usr/bin/env bash
# Stateless-boot check: boot the image installed by smoke.sh, delete everything
# in /etc and /var, power off, then boot twice more and verify it comes back to
# a working state (the image must boot with a wiped /etc and /var; see
# AGENTS.md). Boot 2 is the boot that has to restore /etc from the factory
# copy; boot 3 is the ordinary boot after that, which is where files restored
# without SELinux labels would bite.
# The wipe runs as an injected unit (vm.sh VM_EXTRA_UNIT), so no root login is
# needed.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${WORK:-$REPO/build/vm}
export WORK
vm=$HERE/vm.sh
trap '"$vm" stop' EXIT

wait_down() { # the VM runs with -no-reboot, so a power-off ends the qemu process
  for _ in $(seq 60); do kill -0 "$(cat "$WORK/qemu.pid" 2>/dev/null)" 2>/dev/null || return 0; sleep 1; done
  echo "VM did not power off" >&2; return 1
}

fail=0
check() { # description command-run-in-guest expected-output
  local got; got=$("$vm" ssh "$2" 2>&1 || true)
  if [[ $got == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$got', want '$3'"; fail=1; fi
}
# checks [relaxed]: on the first boot after a wipe, the restored /etc is
# unlabeled while PID 1 does its first-boot work, so the AVC and journal-error
# checks are skipped there (known limitation, see AGENTS.md); boot 3 is strict.
checks() {
  check "user account is back" 'id -un' user
  check "user is in wheel" 'id -nG user | tr " " "\n" | grep -x wheel' wheel
  check "selinux policy restored" 'test -s /etc/selinux/targeted/policy/policy.* && echo yes' yes
  check "selinux is enforcing" 'getenforce' Enforcing
  check "subuid restored for rootless podman" 'cut -d: -f1 /etc/subuid' user
  check "no failed units" 'systemctl --failed --no-legend | wc -l' 0
  if [[ ${1:-} == relaxed ]]; then
    echo "skip no selinux denials / no journal errors (known limitation on this boot)"
    return
  fi
  check "no selinux denials" 'journalctl -q -b --no-pager | grep -ac "avc:  denied"' 0
  check "no journal errors" 'journalctl -b -p err --no-pager -q | grep -avE "virt/tdx" | cut -c1-200 | head -5' ''
}

echo "boot 1: wipe /etc and /var from inside the guest, then power off"
VM_EXTRA_UNIT=$HERE/wipe.service "$vm" start vsock
wait_down

echo "boot 2: first boot with an empty /etc and /var"
"$vm" start vsock
"$vm" wait
checks relaxed
"$vm" stop

echo "boot 3: ordinary boot after the restore"
"$vm" start vsock
"$vm" wait
checks
exit $fail
