#!/usr/bin/env bash
# Install from the installer stick without a container, end to end in QEMU:
# build the one-partition FAT32 stick with the image as a split oci-archive,
# boot it (USB, under OVMF, with a software TPM and a blank disk), run the
# install procedure (installer-bootc-steps.sh) in the initrd's root shell, pull
# the stick out as soon as the image is extracted, then boot the installed disk
# alone and check it.
#
#   images/test/installer-bootc.sh [image-ref]    (default: the newest ghcr.io/snugmo/inglenook)
#
# Environment: ENCRYPT=0 (plain root instead of LUKS2 + TPM2), RAM (installer VM
# memory, default 4G), KEY (ssh key the image trusts, default build/xfsvar/key,
# the one the image of images/test/xfsvar.sh has baked in), STICK_REUSE=1 (keep
# the stick of the last run), WORK (default build/installer-bootc).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
IWORK=${WORK:-$REPO/build/installer-bootc}   # the installer VM; the installed disk is booted from $IWORK-boot
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

# --- the image as a split oci-archive (cached per image id), and the stick ---
id=$(podman image inspect --format '{{.Id}}' "$ref")
parts=$WORK/parts-${id:0:12}
if [[ ! -f $parts/SHA256SUMS ]]; then
  rm -rf "$parts"; mkdir -p "$parts"
  skopeo copy --quiet "containers-storage:$ref" "oci-archive:$parts/archive.tar:latest"
  split -b 1G -d -a 3 "$parts/archive.tar" "$parts/image.oci.tar."
  rm -f "$parts/archive.tar"
  (cd "$parts" && sha256sum image.oci.tar.* > SHA256SUMS)
fi
if [[ -z ${STICK_REUSE:-} || ! -f stick.img ]]; then
  STICK_SIZE=${STICK_SIZE:-3G} "$REPO/images/installer/stick.sh" "$ref" >/dev/null
  off=1048576   # stick.sh: partition 1 starts at 1 MiB
  export MTOOLS_SKIP_CHECK=1
  mmd -i "stick.img@@$off" ::inglenook ::test
  mcopy -i "stick.img@@$off" "$parts"/* ::inglenook/
  mcopy -i "stick.img@@$off" "$HERE/installer-bootc-steps.sh" ::test/steps.sh
fi

# --- the installer VM ---
rm -rf tpm target.img serial.sock qmp.sock tpm.sock qemu.pid
truncate -s "${TARGET_SIZE:-16G}" target.img
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
run 240 'echo 1 > /proc/sys/kernel/printk; for i in $(seq 60); do blkid -L INGLENOOK && break; sleep 1; done; mkdir -p /mnt/t && mount -o ro "$(blkid -L INGLENOOK)" /mnt/t && cp /mnt/t/test/steps.sh /tmp/steps.sh && umount /mnt/t' >/dev/null
run 20 "(TARGET_IMGREF='$ref' ENCRYPT=$ENCRYPT setsid bash /tmp/steps.sh > /tmp/install.log 2>&1 &)" >/dev/null
run 900 'until grep -q "STICK-FREE" /tmp/install.log; do sleep 1; if grep -q "^Error\|exited" /tmp/install.log; then break; fi; done; grep -c STICK-FREE /tmp/install.log' | tail -1 | grep -q '^1' \
  && ok "the image was extracted from the stick" || bad "the install never got past the image extraction"

echo "pulling the stick (QMP device_del)"
qmp '{"execute":"device_del","arguments":{"id":"stickdev"}}' >/dev/null
sleep 3
n=$(run 30 'udevadm settle; lsblk -dno TRAN | grep -c usb || true' | tail -1)
[[ $n == 0 ]] && ok "the stick is gone from the installer" || bad "the stick is still there ($n)"

run 900 'until grep -qE "INSTALL-DONE|^error|Error" /tmp/install.log; do sleep 2; done; grep -E "^PHASE|INSTALL-DONE|^error|Installation complete" /tmp/install.log' | tee phases.txt
grep -q INSTALL-DONE phases.txt && ok "bootc installed without the stick" || { bad "the install did not finish"; run 30 'tail -30 /tmp/install.log' ; }
run 30 "awk '{ if (min==\"\" || \$2<min) min=\$2; if (\$3>root) root=\$3 } END { print \"min available RAM \" min \" MB, RAM-backed root peak \" root \" MB\" }' /tmp/mem.log" | tail -1 | tee mem.txt
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
echo "boot: the installed disk alone"
"$vm" start net
"$vm" wait
check() { # description command expected (as root)
  local got; got=$(SSH_USER=root "$vm" ssh "$2" 2>&1 || true)
  if [[ $got == "$3" ]]; then ok "$1"; else echo "FAIL $1: got '$got', want '$3'"; fail=1; fi
}
check "running from the disk" 'lsblk -srno NAME "$(findmnt -no SOURCE /sysroot)" | grep -cx vda' 1
if [[ $ENCRYPT == 1 ]]; then
  check "the root is LUKS2" 'cryptsetup status root | sed -n "s/^ *type: *//p"' LUKS2
  check "the root has one key slot, a TPM2 token" 'cryptsetup luksDump /dev/disk/by-partlabel/root 2>/dev/null | grep -cE "^  [0-9]+: (luks2|systemd-tpm2)"' 2
  check "/var is the unlocked var volume" 'findmnt -rno SOURCE -t xfs /var' /dev/mapper/var
  check "/var is xfs" 'stat -f -c %T /var' xfs
fi
check "bootc knows the registry image" "bootc status --format=json | grep -o '\"image\":\"[^\"]*\"' | head -1" "\"image\":\"$ref\""
check "no failed units" 'systemctl --failed --no-legend | wc -l' 0
check "no journal errors" 'journalctl -b -p err --no-pager -q | grep -avE "virt/tdx|tpm tpm0: A TPM error \(256\)" | cut -c1-200 | head -5' ''
"$vm" new-avc || fail=1
exit $fail
