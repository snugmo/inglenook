#!/usr/bin/env bash
# The guided install from the installer stick, end to end in QEMU: build the
# one-partition FAT32 stick (images/installer/stick.sh, with the image as a split
# oci-archive), boot it (USB, under OVMF, with a software TPM and a blank disk),
# run inglenook-install in the initrd's root shell with its questions answered
# through the environment, pull the stick out as soon as it says the stick is
# no longer needed, then boot the installed disk alone and check it.
#
#   images/test/install-from-stick.sh [image-ref]    (default: the newest ghcr.io/snugmo/inglenook)
#
# Environment: ENCRYPT=0 (plain root instead of LUKS2 + TPM2), RAM (installer VM
# memory, default 4G), KEY (ssh key the image trusts, default build/xfsvar/key,
# the one the image of images/test/xfsvar.sh has baked in), STICK_REUSE=1 (keep
# the stick of the last run), WORK (default build/install-from-stick),
# ROOT_SIZE (default 8G; the rest of the disk becomes /var), OLD_DATA=0 (a blank target
# disk; by default it holds an old filesystem and partitions, which the install wipes).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
IWORK=${WORK:-$REPO/build/install-from-stick}   # the installer VM; the installed disk is booted from $IWORK-boot
B=$IWORK-boot
export WORK=$IWORK
OVMF=/usr/share/OVMF
ENCRYPT=${ENCRYPT:-1}
RAM=${RAM:-4G}
KEY=${KEY:-$REPO/build/xfsvar/key}
ref=${1:-$(podman images --sort created --format '{{.Repository}}:{{.Tag}}' ghcr.io/snugmo/inglenook | awk 'NR==1')}
mkdir -p "$WORK"
cd "$WORK"

qmp() { printf '{"execute":"qmp_capabilities"}\n%s\n' "$1" | socat - UNIX-CONNECT:qmp.sock; }
run() { "$HERE/serial-run.py" serial.sock "$@"; }   # run <timeout> <command...> in the installer shell
cleanup() {
  if [[ -f qemu.pid ]] && kill -0 "$(cat qemu.pid)" 2>/dev/null; then
    qmp '{"execute":"system_powerdown"}' >/dev/null 2>&1 || true
    for _ in $(seq 20); do kill -0 "$(cat qemu.pid)" 2>/dev/null || break; sleep 1; done
    kill "$(cat qemu.pid)" 2>/dev/null || true
  fi
  WORK=$B "$HERE/vm.sh" stop 2>/dev/null || true
}
trap cleanup EXIT

# --- the stick (stick.sh puts the image on it) ---
if [[ -z ${STICK_REUSE:-} || ! -f stick.img ]]; then
  WORK=$WORK "$REPO/images/installer/stick.sh" "$ref" >/dev/null
fi

# --- the installer VM ---
rm -rf tpm target.img serial.sock qmp.sock tpm.sock qemu.pid
truncate -s "${TARGET_SIZE:-16G}" target.img
# Old data to be wiped: a labeled ext4 right where the new ESP will start (1 MiB) and an old
# 'root' partition after it. OLD_DATA=0 for a blank disk.
if [[ ${OLD_DATA:-1} == 1 ]]; then
  printf 'label: gpt\nstart=1MiB, size=1GiB, type=L, name=olddata\nstart=2GiB, size=1GiB, type=L, name=root\n' | sfdisk -q target.img
  mke2fs -q -F -t ext4 -L olddata -E offset=1048576 target.img 1048576
fi
tpm=()
if [[ $ENCRYPT == 1 ]]; then
  swtpm=swtpm
  if ! command -v swtpm >/dev/null; then
    swtpm=$REPO/build/swtpm/usr/bin/swtpm
    [[ -x $swtpm ]] || { echo "needs swtpm; run $HERE/tpm-setup.sh" >&2; exit 1; }
    export LD_LIBRARY_PATH=$REPO/build/swtpm/usr/lib64:$REPO/build/swtpm/usr/lib64/swtpm
  fi
  mkdir -p tpm
  "$swtpm" socket --tpm2 --tpmstate dir=tpm --ctrl type=unixio,path=tpm.sock --flags startup-clear --terminate --daemon 2>/dev/null
  for _ in $(seq 20); do [[ -S tpm.sock ]] && break; sleep 0.2; done
  tpm=(-chardev socket,id=chrtpm,path=tpm.sock -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0)
fi
cp "$OVMF/OVMF_VARS.fd" vars.fd
qemu-system-x86_64 -accel kvm -machine q35 -cpu host -smp 4 -m "$RAM" -display none -nodefaults -no-reboot "${tpm[@]}" \
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF/OVMF_CODE.fd" -drive "if=pflash,format=raw,file=vars.fd" \
  -device qemu-xhci,id=xhci -drive file=stick.img,format=raw,if=none,id=stick,readonly=on \
  -device usb-storage,bus=xhci.0,drive=stick,id=stickdev,bootindex=0 \
  -drive file=target.img,format=raw,if=virtio,cache=unsafe \
  -serial unix:serial.sock,server,nowait -qmp unix:qmp.sock,server,nowait -daemonize -pidfile qemu.pid

fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

echo "installer VM: waiting for the shell"
run 240 'echo 1 > /proc/sys/kernel/printk; for i in $(seq 60); do blkid -L INGLENOOK && break; sleep 1; done' >/dev/null
run 20 "(INSTALL_DISK=/dev/vda INSTALL_ROOT_SIZE=${ROOT_SIZE:-8G} INSTALL_ENCRYPT=$([[ $ENCRYPT == 1 ]] && echo tpm2 || echo none) INSTALL_RECOVERY_KEY=0 INSTALL_USER=alice INSTALL_TOKEN=1 INSTALL_REALNAME='Alice Example' INSTALL_USER_PASSWORD='correct horse battery' INSTALL_YES=1 INSTALL_NO_REBOOT=1 setsid inglenook-install > /tmp/install.log 2>&1 &)" >/dev/null
run 900 'until grep -q "no longer needed" /tmp/install.log; do sleep 1; if grep -q "^ERROR:" /tmp/install.log; then break; fi; done; grep -c "no longer needed" /tmp/install.log' | tail -1 | grep -q '^1' \
  && ok "the image was extracted from the stick" || bad "the install never got past the image extraction"

echo "pulling the stick (QMP device_del)"
qmp '{"execute":"device_del","arguments":{"id":"stickdev"}}' >/dev/null
sleep 3
n=$(run 30 'udevadm settle; lsblk -dno TRAN | grep -c usb || true' | tail -1)
[[ $n == 0 ]] && ok "the stick is gone from the installer" || bad "the stick is still there ($n)"

run 900 'until grep -qE "^==> Installation complete[.]|^ERROR:" /tmp/install.log; do sleep 2; done; grep -E "^==>|^ERROR:|^WARNING:|^    credential:|Installation complete[.]" /tmp/install.log' | tee phases.txt
grep -q "^==> Installation complete[.]" phases.txt && ok "inglenook-install finished without the stick" || { bad "the install did not finish"; run 30 'tail -40 /tmp/install.log' ; }
# (ACPI powerdown does nothing here: the initrd has no logind to handle the button)
run 20 '(setsid systemctl poweroff >/dev/null 2>&1 &)' >/dev/null || true
for _ in $(seq 60); do kill -0 "$(cat qemu.pid)" 2>/dev/null || break; sleep 1; done
kill -0 "$(cat qemu.pid)" 2>/dev/null && { bad "the installer VM did not power off"; }
[[ $fail == 0 ]] || exit 1

# --- the installed disk, alone ---
export WORK=$B TPM=1
vm=$HERE/vm.sh
rm -rf "$B"; mkdir -p "$B"
mv "$IWORK/target.img" "$B/target.img"
[[ $ENCRYPT == 1 ]] && cp -r "$IWORK/tpm" "$B/tpm"
cp "$KEY" "$B/key"; ssh-keygen -y -f "$B/key" > "$B/key.pub"; chmod 600 "$B/key"
[[ $ENCRYPT == 1 ]] || export TPM=0
# The first-boot wizard of homed must run (it creates the user from the credential), so no
# systemd.firstboot=no; the disk-encryption wizard asks on a console nobody answers.
export VM_FIRSTBOOT=1 VM_CMDLINE="inglenook.cryptenroll=no inglenook.tokenenroll=no"
echo "boot: the installed disk alone"
"$vm" start net
"$vm" wait
check() { # description command expected (as root)
  local got; got=$(SSH_USER=root "$vm" ssh "$2" 2>&1 || true)
  if [[ $got == "$3" ]]; then ok "$1"; else echo "FAIL $1: got '$got', want '$3'"; fail=1; fi
}
check "the old data is gone" 'lsblk -rno LABEL,PARTLABEL /dev/vda | grep -cE "olddata"' 0
check "running from the disk" 'lsblk -srno NAME "$(findmnt -no SOURCE /sysroot)" | grep -cx vda' 1
if [[ $ENCRYPT == 1 ]]; then
  check "the root is LUKS2" 'cryptsetup status root | sed -n "s/^ *type: *//p"' LUKS2
  check "the root has one key slot, a TPM2 token" 'cryptsetup luksDump /dev/disk/by-partlabel/root 2>/dev/null | grep -cE "^  [0-9]+: (luks2|systemd-tpm2)"' 2
  check "/var is the unlocked var volume" 'findmnt -rno SOURCE -t xfs /var' /dev/mapper/var
  check "/var is xfs" 'stat -f -c %T /var' xfs
fi
check "bootc knows the registry image" "bootc status --format=json | grep -o '\"image\":\"[^\"]*\"' | head -1" "\"image\":\"$ref\""
check "the first user was created" 'homectl list --no-legend | awk "{print \$1}"' alice
check "the user is in wheel and the password works" 'PASSWORD="correct horse battery" homectl with alice -- id alice | grep -o "10(wheel)"' '10(wheel)'
check "getent group wheel lists the user (merged sources)" 'getent group wheel' 'wheel:x:10:alice'
check "the key enrolment was asked for (marker left, wizard skipped by the test)" 'cat /etc/inglenook/enroll-token; systemctl is-enabled inglenook-token-enroll.service' $'alice\nenabled'
check "the user has subordinate ids for rootless podman" 'grep -c "^alice:" /etc/subuid /etc/subgid | tr "\n" " "' '/etc/subuid:1 /etc/subgid:1 '
check "the credential with the password is gone" 'ls /etc/credstore | wc -l' 0
[[ $ENCRYPT == 1 ]] && check "the home is a plain directory (the root is encrypted)" 'homectl inspect alice | sed -n "s/^ *Storage: //p"' 'directory (no encryption)'
check "no failed units" 'systemctl --failed --no-legend | wc -l' 0
check "no journal errors" 'journalctl -b -p err --no-pager -q | grep -avE "virt/tdx|tpm tpm0: A TPM error \(256\)" | cut -c1-200 | head -5' ''
"$vm" new-avc || fail=1
# last: a failed password makes homed ask again, which starts the ask-password agents and logs
# (plymouth is not in the image: 'systemd-ask-password-plymouth.path not loaded', one net_admin denial)
# homectl answers a wrong password with this message and then waits for another try: cap it
check "a wrong password is refused" 'timeout 15 env PASSWORD=wrong homectl --no-ask-password with alice -- true </dev/null 2>&1 | grep -o "Password incorrect"' 'Password incorrect'
exit $fail
