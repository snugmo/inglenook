#!/usr/bin/env bash
# Rootless KVM test harness for the inglenook image. No loop devices or root
# are needed: `bootc install` runs as root inside a throwaway installer VM
# (the fedora-bootc base itself, direct-kernel-booted), onto a raw disk that
# is then booted under OVMF. State lives in $WORK (default build/vm).
#
#   vm.sh prep               build the installer VM disk (once)
#   vm.sh install <image>    install <image> onto a fresh target disk
#   vm.sh debug <script>     run a script as root in the installer VM, on the existing target disk
#   vm.sh start [vsock|net]  boot the target disk in the background
#   vm.sh ssh [cmd...]       ssh to the running VM as $SSH_USER (default: root; the key is $WORK/key)
#   vm.sh wait               wait until ssh works
#   vm.sh stop               stop the VM
#   vm.sh avc                summarize this boot's SELinux denials (avc-summary.py)
#   vm.sh new-avc            the denials not in selinux-denials.baseline; exit 1 if any
#
# Environment: VM_QEMU_EXTRA (start: extra qemu arguments), ROOT_SIZE (install:
# bootc --root-size, default 8G; set it empty for the whole disk), TARGET_SIZE (install: disk size, default 20G), ESP_FILES (install:
# tree copied into the ESP), BOOT_DEVICE=usb|nvme (start: attach the disk as a
# USB stick or an NVMe drive instead of virtio), KEEP_VARS=1 (start), TPM=1 (install,
# start: attach a software TPM 2.0, state in $WORK/tpm, kept between install and
# start and wiped by a new install; tpm-setup.sh fetches swtpm), BLOCK_SETUP=tpm2-luks
# (install: bootc --block-setup, needs TPM=1), VM_CMDLINE (start: extra kernel command line),
# VM_FIRSTBOOT=1 (start: let the first-boot encryption wizard run; the tests skip it).
#
# Debugging without a root login: VM_EXTRA_UNIT=path/to/x.service vm.sh start
# injects that unit through the systemd.extra-unit.* credential (SMBIOS) and
# pulls it into multi-user.target with a systemd.unit-dropin.* credential; with
# StandardOutput=tty its output lands in $WORK/target.log (the serial console).
#
# vsock mode has no NIC at all: ssh goes over vhost-device-vsock. net mode
# forwards host port 2222. The VM also gets $WORK/key.pub as root's
# authorized key (SMBIOS credential) for debugging.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${WORK:-$REPO/build/vm}
BASE=registry.fedoraproject.org/fedora-bootc:${FEDORA_VERSION:-45}
OVMF=/usr/share/OVMF

# The test VM has a software TPM and installs an encrypted root by default (TPM=0: neither).
: "${TPM=1}"
[[ $TPM == 0 ]] && TPM=

mkdir -p "$WORK/share"
# Unix socket paths are limited to 108 bytes; use relative ones from here.
cd "$WORK"

qemu_common=(-accel kvm -machine q35 -cpu host -smp 4 -m 4G -display none
  -nodefaults -monitor none -no-reboot)

# TPM=1: a software TPM 2.0 on a unix socket; qemu_tpm gets the qemu arguments. swtpm
# exits when qemu disconnects (--terminate). Its state outlives the VM runs, because
# keys sealed at install time must unseal at boot.
qemu_tpm=()
tpm_start() {
  [[ -n ${TPM:-} ]] || return 0
  local swtpm=swtpm
  if ! command -v swtpm >/dev/null; then
    swtpm=$REPO/build/swtpm/usr/bin/swtpm
    [[ -x $swtpm ]] || { echo "TPM=1 needs swtpm; run $HERE/tpm-setup.sh" >&2; return 1; }
    export LD_LIBRARY_PATH=$REPO/build/swtpm/usr/lib64:$REPO/build/swtpm/usr/lib64/swtpm
  fi
  mkdir -p tpm; rm -f tpm.sock
  "$swtpm" socket --tpm2 --tpmstate dir=tpm --ctrl type=unixio,path=tpm.sock \
    --flags startup-clear --terminate --daemon 2>/dev/null
  for _ in $(seq 20); do [[ -S tpm.sock ]] && break; sleep 0.2; done
  qemu_tpm=(-chardev socket,id=chrtpm,path=tpm.sock -tpmdev emulator,id=tpm0,chardev=chrtpm
    -device tpm-tis,tpmdev=tpm0)
}

stop_pid() { # pidfile
  if [[ -f $1 ]]; then kill "$(cat "$1")" 2>/dev/null || true; rm -f "$1"; fi
}

cmd_prep() {
  # Rebuild the installer disk when its scripts change, not only on --force.
  local stamp; stamp=$(cat "$HERE/installer.sh" "$HERE/installer.service" | sha256sum | cut -d' ' -f1)
  [[ -f installer.img && $(cat installer.stamp 2>/dev/null) == "$stamp" && ${1:-} != --force ]] && return
  podman pull -q "$BASE" >/dev/null
  local c kver
  c=$(podman create "$BASE")
  podman export "$c" -o rootfs.tar
  kver=$(podman run --rm "$BASE" ls /usr/lib/modules)
  podman cp "$c:/usr/lib/modules/$kver/vmlinuz" vmlinuz
  podman cp "$c:/usr/lib/modules/$kver/initramfs.img" initramfs.img
  podman rm "$c" >/dev/null
  # mke2fs here has no tarball support, so unpack as (user-namespace) root
  # and populate from the directory; no mount needed.
  podman unshare sh -c '
    rm -rf rootfs && mkdir rootfs
    tar -xf rootfs.tar -C rootfs --numeric-owner --exclude="./dev/*"
    install -m755 "$1/installer.sh" rootfs/usr/local/bin/installer.sh
    install -m644 "$1/installer.service" rootfs/etc/systemd/system/installer.service
    mkdir -p rootfs/etc/systemd/system/multi-user.target.wants
    ln -sf /etc/systemd/system/installer.service rootfs/etc/systemd/system/multi-user.target.wants/
    rm -f installer.img && truncate -s 12G installer.img
    mke2fs -q -t ext4 -L installer -d rootfs installer.img
    rm -rf rootfs' sh "$HERE"
  rm -f rootfs.tar
  echo "$stamp" > installer.stamp
}

cmd_install() {
  local ref=${1:?usage: vm.sh install <image>}
  # Defaults: an 8G root (the rest of the disk becomes the encrypted XFS /var in the initrd), a
  # root encrypted with the TPM. Set but empty ROOT_SIZE means the whole disk; BLOCK_SETUP=direct
  # means no encryption.
  : "${ROOT_SIZE=8G}"
  [[ -n ${TPM:-} ]] && : "${BLOCK_SETUP=tpm2-luks}"
  cmd_stop
  rm -rf share/result share/inglenook.oci share/esp share/rootsize share/blocksetup target.img
  [[ -n ${TPM:-} ]] && rm -rf tpm
  [[ -n ${BLOCK_SETUP:-} ]] && echo "$BLOCK_SETUP" > share/blocksetup
  echo "$ref" > share/imgref
  [[ -n ${ROOT_SIZE:-} ]] && echo "$ROOT_SIZE" > share/rootsize
  # ESP_FILES: a directory tree copied into the ESP after the install (for
  # example loader/credentials/*.cred).
  [[ -n ${ESP_FILES:-} ]] && cp -r "$ESP_FILES" share/esp
  podman save --format oci-archive -o share/inglenook.oci "$ref"
  tpm_start
  truncate -s "${TARGET_SIZE:-20G}" target.img
  # SELinux off in the installer: its rootfs is unlabeled.
  # With a TPM the installer boots under OVMF too (-kernel goes through the firmware's loader),
  # so the PCRs it seals the root's key to (7, Secure Boot state) match a later boot of the target.
  local fw=()
  if [[ -n ${TPM:-} ]]; then
    cp "$OVMF/OVMF_VARS.fd" installer-vars.fd
    fw=(-drive "if=pflash,format=raw,readonly=on,file=$OVMF/OVMF_CODE.fd" -drive if=pflash,format=raw,file=installer-vars.fd)
  fi
  timeout 900 qemu-system-x86_64 "${qemu_common[@]}" "${qemu_tpm[@]}" "${fw[@]}" -serial file:installer.log \
    -kernel vmlinuz -initrd initramfs.img \
    -append "root=/dev/vda rw rootfstype=ext4 console=ttyS0 selinux=0" \
    -drive file=installer.img,format=raw,if=virtio,cache=unsafe \
    -drive file=target.img,format=raw,if=virtio,cache=unsafe \
    -virtfs local,path=share,mount_tag=share,security_model=none,id=share \
    -nic none || true
  [[ $(cat share/result 2>/dev/null) == INSTALL_EXIT=0 ]] \
    || { echo "install failed; see $WORK/installer.log" >&2; return 1; }
}

# vm.sh debug <script>: boot the installer VM on the existing target disk (and TPM state) and
# run the script there as root; its output is printed. For poking at an encrypted root.
cmd_debug() {
  local script=${1:?usage: vm.sh debug <script>}
  cmd_stop
  rm -f share/debugout share/result; cp "$script" share/debugcmd
  tpm_start
  local fw=()
  if [[ -n ${TPM:-} ]]; then
    cp "$OVMF/OVMF_VARS.fd" installer-vars.fd
    fw=(-drive "if=pflash,format=raw,readonly=on,file=$OVMF/OVMF_CODE.fd" -drive if=pflash,format=raw,file=installer-vars.fd)
  fi
  timeout 300 qemu-system-x86_64 "${qemu_common[@]}" "${qemu_tpm[@]}" "${fw[@]}" -serial file:installer.log \
    -kernel vmlinuz -initrd initramfs.img \
    -append "root=/dev/vda rw rootfstype=ext4 console=ttyS0 selinux=0" \
    -drive file=installer.img,format=raw,if=virtio,cache=unsafe \
    -drive file=target.img,format=raw,if=virtio,cache=unsafe \
    -virtfs local,path=share,mount_tag=share,security_model=none,id=share \
    -nic none || true
  rm -f share/debugcmd
  cat share/debugout
}

cmd_start() {
  local mode=${1:-vsock}
  cmd_stop
  echo "$mode" > mode
  # KEEP_VARS=1 keeps the firmware variables (boot entries the guest registered).
  [[ -n ${KEEP_VARS:-} && -f vars.fd ]] || cp "$OVMF/OVMF_VARS.fd" vars.fd
  rm -f qmp.sock
  tpm_start
  local args=("${qemu_common[@]}" "${qemu_tpm[@]}" -serial file:target.log -daemonize -pidfile qemu.pid
    -qmp unix:qmp.sock,server,nowait
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF/OVMF_CODE.fd"
    -drive "if=pflash,format=raw,file=vars.fd")
  if [[ ${BOOT_DEVICE:-virtio} == nvme ]]; then
    args+=(-drive file=target.img,format=raw,if=none,id=nvmedisk
      -device nvme,drive=nvmedisk,serial=inglenook,bootindex=0)
  elif [[ ${BOOT_DEVICE:-virtio} == usb ]]; then
    # As a USB stick behind an xHCI controller, like on real hardware.
    args+=(-device qemu-xhci,id=xhci -drive file=target.img,format=raw,if=none,id=usbdisk
      -device usb-storage,bus=xhci.0,drive=usbdisk,bootindex=0)
  else
    args+=(-drive file=target.img,format=raw,if=virtio)
  fi
  # Extra kernel command line through systemd-stub's SMBIOS string (Secure Boot is off in the VM).
  # The first-boot disk encryption wizard (systemd-cryptenroll --firstboot) waits for input, so
  # the tests skip it unless VM_FIRSTBOOT=1.
  local cmdline_extra=${VM_CMDLINE:-}
  [[ -z ${VM_FIRSTBOOT:-} ]] && cmdline_extra="systemd.firstboot=no $cmdline_extra"
  [[ -n $cmdline_extra ]] && args+=(-smbios "type=11,value=io.systemd.stub.kernel-cmdline-extra=$cmdline_extra")
  [[ -f key.pub ]] && args+=(-smbios "type=11,value=io.systemd.credential:ssh.authorized_keys.root=$(cat key.pub)")
  # VM_QEMU_EXTRA: extra qemu arguments, word-split (e.g. a virtual smartcard
  # reader: "-device usb-ccid").
  # shellcheck disable=SC2206
  [[ -n ${VM_QEMU_EXTRA:-} ]] && args+=($VM_QEMU_EXTRA)
  if [[ -n ${VM_EXTRA_UNIT:-} ]]; then
    local unit; unit=$(basename "$VM_EXTRA_UNIT")
    args+=(-smbios "type=11,value=io.systemd.credential.binary:systemd.extra-unit.$unit=$(base64 -w0 "$VM_EXTRA_UNIT")"
      -smbios "type=11,value=io.systemd.credential.binary:systemd.unit-dropin.multi-user.target=$(printf '[Unit]\nWants=%s\n' "$unit" | base64 -w0)")
  fi
  case $mode in
    vsock)
      rm -f vhost.sock vm.vsock*
      setsid vhost-device-vsock --guest-cid 3 --socket vhost.sock --uds-path vm.vsock \
        > vsockd.log 2>&1 < /dev/null &
      echo $! > vsockd.pid
      for _ in $(seq 20); do [[ -S vhost.sock ]] && break; sleep 0.5; done
      args+=(-machine q35,memory-backend=mem -object memory-backend-memfd,id=mem,size=4G,share=on
        -chardev socket,id=vsockc,path=vhost.sock -device vhost-user-vsock-pci,chardev=vsockc
        -nic none) ;;
    net) args+=(-nic user,hostfwd=tcp::2222-:22) ;;
    *) echo "unknown mode $mode" >&2; return 2 ;;
  esac
  : > target.log
  qemu-system-x86_64 "${args[@]}"
}

cmd_ssh() {
  local opts=(-i key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=10)
  if [[ $(cat mode) == vsock ]]; then
    ssh "${opts[@]}" -o "ProxyCommand=$HERE/vsock-proxy.py vm.vsock 22" "${SSH_USER:-root}@vsock" "$@"
  else
    ssh "${opts[@]}" -p 2222 "${SSH_USER:-root}@127.0.0.1" "$@"
  fi
}

cmd_avc() {
  cmd_ssh 'journalctl -q -b --no-pager -o cat | grep -a "avc:  denied"' | "$HERE/avc-summary.py"
}

# The baseline lists the denials known today (the policy is being worked out, the
# UKI is permissive and dontaudit rules are off); a test fails only on new ones.
cmd_new_avc() {
  local new
  # AVC_BASELINE_EXTRA: more known denials for a variant (a space-separated list of files).
  new=$(cmd_avc | comm -13 <(sort -u "$HERE/selinux-denials.baseline" ${AVC_BASELINE_EXTRA:-}) -)
  if [[ -z $new ]]; then echo "ok   no new selinux denials"; else
    echo "FAIL new selinux denials (not in selinux-denials.baseline):"; echo "$new" | sed 's/^/       /'; return 1
  fi
}

cmd_wait() {
  # Let the boot reach the (serial) login prompt before probing ssh: until
  # systemd-user-sessions removes /run/nologin, pam_nologin refuses logins and
  # sshd logs each refused probe as an error, which the journal checks would
  # then flag.
  for _ in $(seq 120); do grep -aq 'login: ' target.log 2>/dev/null && break; sleep 1; done
  for _ in $(seq 60); do cmd_ssh true 2>/dev/null && return; sleep 3; done
  echo "timed out waiting for ssh; see $WORK/target.log" >&2
  return 1
}

# Press the ACPI power button over QMP so the guest shuts down cleanly (a kill
# loses recent writes: ext4 delayed allocation leaves zero-length files); fall
# back to killing qemu after 40 s.
cmd_stop() {
  if [[ -f qemu.pid ]] && kill -0 "$(cat qemu.pid 2>/dev/null)" 2>/dev/null; then
    if [[ -S qmp.sock ]]; then
      printf '{"execute":"qmp_capabilities"}\n{"execute":"system_powerdown"}\n' \
        | socat - UNIX-CONNECT:qmp.sock >/dev/null 2>&1 || true
      for _ in $(seq 40); do kill -0 "$(cat qemu.pid 2>/dev/null)" 2>/dev/null || break; sleep 1; done
    fi
  fi
  stop_pid qemu.pid
  stop_pid vsockd.pid
}

sub=${1:?usage: vm.sh prep|install|debug|start|ssh|wait|avc|new-avc|stop}
"cmd_${sub//-/_}" "${@:2}"
