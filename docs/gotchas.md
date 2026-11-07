# Gotcha deep dives

The full reasoning behind the long Gotchas in AGENTS.md. The AGENTS.md entry is
the rule; this page is why — the exact mechanisms, options, and failure
histories. Numbers follow AGENTS.md (an "item N" reference here points at
AGENTS.md entry N).

## 10. Login and SSH

The tests log in as **root** over ssh with `$WORK/key` (`vm.sh` hands its
public half to the VM in the `ssh.authorized_keys.root` SMBIOS credential;
`SSH_USER=` selects another account); nothing is baked into the image.
ssh-over-vsock's per-connection sshd only reads `ssh.ephemeral-authorized_keys-all`
(a hypervisor-injected key) plus `~/.ssh/authorized_keys`. The credential sits
in the per-service subdirectory of `/run/credentials`, which is root-only, so
the credential route works for root only: on the release a non-root session is
stopped by the file permissions before SELinux is even consulted (the SELinux
denial the prerelease showed no longer surfaces; a non-root vsock login through
a home `authorized_keys` logs no denial at all). The `sshd_session_t` CIL allow
(item 17) is still needed on the release — the stock 45.23 policy has no such
allow — for the root session to read the credential file. Homed users carry
their ssh keys in the record (`sshAuthorizedKeys`; sshd asks `userdbctl`, see
docs/tokens.md).

## 11. Factory /etc

The last `pre` step snapshots the finished `/etc` into `/usr/share/factory/etc`
(relabeling it with `setfiles` — in the image it is `container_file_t` — so
the `C` copy carries the real labels) and generates
`/usr/lib/tmpfiles.d/inglenook-etc-factory.conf` (`C! /etc/<entry>` per
top-level entry; `hostname`, `credstore*` and the `-` backup copies are
excluded on purpose). If `/etc` is wiped, `inglenook-etc-restore.service` in
the initrd restores all of it before switch-root and labels it, because PID 1
loads the SELinux policy from `/etc/selinux` and early services (udev, hwdb)
read `/etc` before tmpfiles in the real root has run.

**Labeling in the initrd** (no policy loaded in the kernel yet) uses
`setfiles -m -F -r /sysroot -c <policy.NN in the target> <file_contexts in the
target> /sysroot/etc`: `-r` strips the prefix so the path-based patterns match
as `/etc/...`, `-c` validates against the policy file in the target tree, and
`-m` is essential: without it setfiles reads /proc/mounts and silently skips
mounts that do not show `seclabel` yet, which made a plain `setfiles` a no-op
(files stayed labeled `kernel`). With it the first boot after a wipe is clean.
Anything added to `/etc` in the Containerfile must come before the factory
snapshot step. Test with `images/test/wipe.sh`.

`passwd`, `group`, `shadow` and `gshadow` are in the factory set (system
accounts are in `/usr/lib/{passwd,group}` via nss-altfiles; `wheel` has to
stay in `/etc/group` so that accounts can be members; there is no shadow
source under `/usr/lib`, so the files must be restored for NSS/PAM to work —
the CIL module (item 17) allows `systemd_tmpfiles_t` to stat and copy
`shadow_t`, which the stock policy denies).

`machine-id` is included as an *empty* file on purpose: an existing-but-empty
file is not a first boot per machine-id(5) (PID 1 bind-mounts a temporary ID
and commits it later), while a missing one is — a wiped `/etc` without it
would trigger first-boot preset-all (which re-enables the disabled `mcelog`)
and the first-boot wizards.

## 16. Encrypted everything, XFS /var

The root is LUKS2 (sealed to the TPM on the tpm2 variant, an empty key slot on
the no-tpm one; docs/installer.md; ext4 inside, because composefs needs
fs-verity and `mkfs.xfs` has none; bootc also adds an empty unencrypted `boot`
partition; only the ESP is plain). `inglenook.var=xfs` is in the image's
default kernel command line (which has no `console=`: on a machine without a
UART `console=ttyS0` makes the getty generator start a `serial-getty@ttyS0`
that fails and restarts every 10 s, since the 8250 driver always has a ttyS0
node with a `device` link; a serial console is the addon of
`images/addons/serial-console.sh` in `\loader\addons\` of the ESP: the stub
concatenates the addon's cmdline to the UKI's, which is the only
kernel-argument channel a locked-down (type-2) UKI has, and `console=` only
selects consoles, which is why it is safe there. The stick carries the addon
for its own boot (without it the installer has no console on real firmware),
the installer asks about it and copies it to the installed system's ESP on
request (`INSTALL_CONSOLE`; `INSTALL_YES=1` answers yes), and `vm.sh install`
puts it on every test ESP — `vm.sh start` still passes `console=` via SMBIOS,
which a locked-down image ignores) (`KARGS` in the Containerfile).

**The installer does the provisioning** (docs/installer.md): it generates the
machine id and passes it to `systemd-repart` as `--seed`, so every partition,
LUKS and filesystem UUID is a deterministic function of it, and it creates /var
(LUKS2: `Encrypt=tpm2` when there is a TPM to seal to, `Encrypt=key-file` — an
empty slot that unlocks hands-off — otherwise; there is no unencrypted mode)
with XFS in all free space after the root, and can enrol a FIDO2 security key
into the volumes' LUKS2 headers while they are still closed (`INSTALL_FIDO2`;
/var in both variants, plus the no-tpm variant's empty-key root — the
TPM-sealed root is not offered, its gpt-auto unit carries no FIDO2 option;
docs/installer.md).

**The initrd services are a first-boot safety net** for systems installed
without the installer (a plain `bootc install`, which makes no /var):
`inglenook-var-repart.service` runs the wrapper `/usr/lib/inglenook/var-repart`,
which runs `systemd-repart` before bootc sets up the root with the definitions
in `/usr/lib/inglenook/repart.d` (a TPM) or `/usr/lib/inglenook/repart-no-tpm.d`
(none) — deliberately *not* `/usr/lib/repart.d`: files there make the stock
`systemd-repart.service` run in the initrd and fail. On a fresh (stick)
install the partition already exists and repart has nothing to do.
`inglenook-var-mount.service` runs `/usr/lib/inglenook/var-mount`: it attaches
the volume with `systemd-cryptsetup` (options
`tpm2-device=auto,fido2-device=auto,try-empty-password=true,headless=yes` — a
superset that covers the TPM-sealed, token-enrolled and empty-slot states;
`try-empty-password=true` is what unlocks the fresh no-TPM volumes) and mounts
it over the ext4 `/var` bind that `bootc-root-setup` makes at `/sysroot/var`.
It is a *service*, not a `sysroot-var.mount` unit: systemd skips a mount unit
for a path that is already mounted.

**Labeling a fresh /var:** no SELinux policy is loaded in the initrd, and a
mount `rootcontext=` fails silently without one (it never labels the XFS
root), so a /var without the `/var/.inglenook-relabelled` marker is prepared in
the script before switch-root: the directory skeleton the first services write
into (`log/journal`, `lib`, `cache`, `empty`, `spool`) is created and the whole
tree labelled with `setfiles -m -F -r /sysroot -c <target policy> <target
file_contexts> /sysroot/var`, the same technique as the factory `/etc`
restore. Files created afterwards inherit their parent's label, so the first
boot never sees `unlabeled_t` under `/var` (the first to surface was
`plymouthd`'s `/var/log/boot.log`, created before any labelling existed).

**First-boot relabel:** the main root's `inglenook-var-relabel.service`
(enabled in the image) runs `restorecon -R /var` and drops the marker: files
created between switch-root and it still carry inherited labels (`var_t`,
`var_log_t`, …) that do not match their paths, so it fixes them by path; the
marker makes both it and the initrd's preparation one-shots per fresh /var (a
wipe or a new partition removes it, so they re-run). Without free space after
the root, `/var` stays on the root (repart fails, logged, not fatal). Both
initrd services are ordered `After=tpm2.target` (no `Wants=`:
systemd-tpm2-generator hooks the target in only when firmware reports a TPM
whose device is not there yet, so it waits for a slow driver and is a no-op
without a TPM). Do not use `systemd-tpm2-setup-early`'s SRK file or
`systemd-analyze has-tpm2` as the "is there a TPM" test: both need a measured
boot, which the test VM's OVMF does not give, so they say no/partial there
although the TPM works.

Growth is masked, not done: the base image's
`bootc-generic-growpart.service` (grows a plain root partition to the end of
the disk, VM only, skipped for LUKS) and systemd 262's auto-growfs units
(`systemd-growfs-root.service`, `systemd-growfs@.service`) are all masked in
the Containerfile — growpart with a plain root in a VM ate the space meant for
`/var`, and systemd 262's repart marks every filesystem partition it creates
with the GPT 'grow file system' attribute, so the gpt-auto generator starts a
growfs unit for it at every boot, which is a no-op (the filesystems already
fill their partitions) and wrong (`/` is a composefs image file, not a block
device; the LUKS `/var` rejects `crypt_resize` with EPERM); the installer
fixes the sizes at install time. systemd 262's
`systemd-cryptenroll-firstboot.service` is a no-op on a fresh install (the
installer wrote the machine id, so its
`ConditionFileNotEmpty=!/sysroot/etc/machine-id` fails; an empty-slot volume
would also exit silently through `--prompt-suppress=password`) but still acts
on a pre-installer legacy install (the tests pass `systemd.firstboot=no` via
the SMBIOS string, and `inglenook.cryptenroll=no` through our drop-in
condition). The TPM keys have no PCR policy yet (bootc's cryptenroll uses
none, and the VM's OVMF does not measure). bootc state stays on the ext4
root. Early units that create directories in `/var` themselves race tmpfiles
on the empty filesystem and get denied: order them after
`systemd-tmpfiles-setup.service` (done for `rpc-statd-notify` and
`systemd-random-seed`).

**Test harness:** `vm.sh` attaches a software TPM (swtpm,
`images/test/tpm-setup.sh` fetches it into `build/swtpm`) and installs with
`--block-setup tpm2-luks --root-size 8G` by default (`TPM=0`,
`BLOCK_SETUP=direct`, `ROOT_SIZE=` opt out). Start the VM with the same `TPM`
setting as the install (the key is sealed to that TPM's state, in
`$WORK/tpm`), and note the installer VM boots under OVMF as well (PCR 7 must
match). `vm.sh debug <script>` runs a script as root in the installer VM
against the existing disk and TPM, useful when the initrd fails to unlock (the
emergency shell has a locked root). The `to-disk` test layout partlabels its
ESP `EFI-SYSTEM` (bootc's name); the stick's repart names it `ESP` — checks
that mount the ESP must use the layout they are written for.

**Revisit: an XFS root.** The root is ext4 because composefs wants fs-verity
and neither the kernel nor `mkfs.xfs` (7.1.1) offers it on XFS. fs-verity for
XFS is on its way upstream (Andrey Albershteyn's v17 series, posted
2026-10-02; the core fsverity patches are in the 7.4 fsverity tree, the XFS
ones target 7.5, with a read-only-compatible on-disk feature flag; thread:
https://ratatoskr.run/linux-fsdevel/2026/10/17694139). Check back when the
image's kernel is 7.5 or later: does `mkfs.xfs` have a verity option, and does
`bootc install --filesystem xfs` with the composefs backend enable it (bootc
passes `-O verity` for ext4 today)? Until then do not use
`--allow-missing-verity`, it drops the integrity check.

## 17. SELinux is permissive on purpose

The UKI carries `enforcing=0` (`SELINUX_ENFORCING=0`). `SELINUX_ENFORCING=1`
does **not boot yet**: the mkosi initrd has no policy, and its systemd freezes
with "Failed to load SELinux policy" when `enforcing=1` is on the command line
(dracut would have put the policy there). Shipping the policy in the initrd
is the long-term plan, not started. The stock `dontaudit` rules are kept, so
the audit log has no siginh/rlimitinh/noatsecure spam (those are harmless and
must not be allowed). Building with `SELINUX_NO_DONTAUDIT=1` runs
`semodule -DB` and logs every denial the strict policy would produce,
including those a `dontaudit` rule hides (no kernel switch for that; it is
compiled into the policy): use it when hunting for missing rules, not for
normal builds. Local policy is CIL (`images/rootfs/usr/share/inglenook/selinux/*.cil`,
installed with `semodule -n -i` at build; no compiler needed). To find the
rules a domain needs: boot, `ausearch -m avc` as root (or `vm.sh avc`), add
`(allow ...)` lines. The tests fail only on denials missing from
`images/test/selinux-denials.baseline`: the baseline is the to-do list, shrink
it as rules or upstream fixes land. Process-transition perms (siginh,
rlimitinh, noatsecure) are ignored as dontaudit noise (only seen in
`SELINUX_NO_DONTAUDIT=1` builds).

The sshd rule lets `sshd_session_t` read the `ssh.ephemeral-authorized_keys-all`
credential (`init_var_run_t`) — still absent from the stock policy on the
release (45.23) — and works for root only: the credential sits in a root-only
per-service subdirectory of `/run/credentials` and sshd reads it as the target
user (item 10). The tmpfiles rule lets `systemd_tmpfiles_t` stat and copy
`shadow_t` — the stock policy only gives domains the generic `mmap` on it —
for the factory `C!` rules on `/etc/shadow` and `/etc/gshadow` (item 11).

## 20. Wrong or missing labels on the mutable state

The OS content itself is labeled inside the composefs image; the mutable parts
are `/etc`, `/var` and the backing directories under `/sysroot/state` on the
root filesystem, which carry ordinary xattr labels. Symptom: AVCs with
`unlabeled_t` targets, or with `trawcon="kernel"` for files written before a
policy was loaded. Recovery: boot permissive (the UKI default), then
`sudo restorecon -R /etc /var` (the mounted views only).

**Never run restorecon (or an autorelabel) on `/sysroot` or anything under
it.** restorecon takes the label from the *path* of each file, and the
file-context patterns describe the running system (`/usr`, `/etc`, `/var`, …);
run on `/sysroot/state/...` or the object store the paths match nothing
meaningful, so most files get a generic fallback label and the system breaks
until a correct full relabel. The content-addressed object store is the worst
case: its names are digests, so no pattern could ever be right (on ostree it
also wrecks the hardlinked targets). The same reason is why
`restorecon -R /etc /var` is fine: it is run on the paths as the running
system sees them, never on their backing directories under `/sysroot/state`,
and the initrd's `setfiles -r /sysroot ... /sysroot/etc` does the same (the
prefix is stripped, so the patterns see `/etc/...`). This rules out
`touch /.autorelabel` (a full relabel) and `restorecon -R /sysroot/state`.

## 23. Token logins

authselect has `with-systemd-homed` (set in the Containerfile, so
`pam_systemd_home` is in `system-auth`), `pam-u2f` is installed but
`with-pam-u2f` is off, and `sshd_config.d/20-systemd-homed.conf` reads keys
from homed records.

**FIDO2 on homed records**: `homectl update --fido2-device=` (and
`homectl create --fido2-device=` without `--storage=`) fails with "Object
field 'perMachine' has wrong type null, expected array" (systemd issue 39599)
when the record has no `perMachine` array: the installer's credential therefore
carries `perMachine: []`, and a record made without it needs
`--storage=directory` on the update (which writes the entry).
`DefaultStorage=` in homed.conf does *not* help.

Never add `AuthenticationMethods publickey,password` to sshd (locks out root
and token-only users). A homed user's ssh login needs the token in the
*server*. `images/test/token.sh` drives `softfido.py`, a small software CTAP2
authenticator over uhid; it checks the wiring, not real YubiKeys. Pitfalls:
`homectl create` always asks for a password (remove it afterwards with
`images/test/token/nopw.sh`), `$PIN` is ignored (answer the ask-password
queue), and `pkill -f` matches your own ssh command line.

## 24. The installer

(The playbook is docs/installer.md; this is the mechanism.)

It runs in the initrd of the stick's own UKI, selected by the addon's
`rd.systemd.unit=`. It is `bootc install to-filesystem` without a container:
`--source-imgref oci:<dir>` skips bootc's container check, and
`/etc/ostree/prepare-root.conf` must exist (the script copies the image's own
from the stick; `/usr` is read-only there). It generates the machine id and
passes it as `systemd-repart --seed`, so the ESP, root and /var partition
UUIDs (and the LUKS2 and filesystem UUIDs they seed) are all derived from it;
the /var partition doubles as the scratch the image is extracted into (never
RAM; the stick is unmounted right after and can be pulled), and the machine id
is written into the deployment's `/etc` so the first boot is not a first boot.
There is no separate scratch partition. Test commands go to an *interactive*
bash over the serial console, so `!!` expands as history: never print or grep
`!!!`.

`systemd-repart` makes the root (`SYSTEMD_REPART_MKFS_OPTIONS_EXT4='-O verity'`,
`Encrypt=` appended per the chosen mode: `tpm2`, `key-file` for the no-tpm
variant's empty-slot root, or nothing); do not seal TPM keys to PCR 12 (the
addon changes it). `bootc-generic-growpart.service` of the base image is
masked (it grew a plain root in VMs only). Do not put a TPM-presence test on
`systemd-tpm2-setup-early`'s SRK file or `systemd-analyze has-tpm2`: the test
VM's boot is not measured, so both say no/partial while the TPM works; use
`/dev/tpmrm0` after `After=tpm2.target`.

The installed system has **no `/boot` mount and no `/etc/fstab`**: in this
layout the ESP *is* the boot partition (bootc never persists a boot mount for
`to-filesystem`), and bootc finds the ESP by device scan
(`find_first_colocated_esp` from the root device) at install, upgrade and
switch, so nothing needs it mounted; tools that want the boot files must mount
`/dev/disk/by-partlabel/ESP` themselves.

The image variant (`VARIANT` in `build.sh`, a label on the image, the
`/usr/installer/variant` marker in the addon) decides the encryption modes the
installer offers and the initrd's root-unlock drop-in (docs/encryption.md): a
stick must be made from the variant it will install. The addon's package
overlay comes from a fresh `dnf` resolve (`build-addon.sh`'s mkosi), but every
file it carries that the boot initrd also has must be byte-identical (the
overlay unpacks over that initrd, and `overlay.py` rejects a differing copy),
so `build-addon.sh` pins the overlay's `bootc` to the version the boot initrd
carries (read from the rpm build note embedded in `initramfs-setup`;
`mkosi.conf` deliberately does not list it) — a fresh resolve picks the newest
from updates, which broke the stick build once.

## 25. The first user

Root is locked, so `inglenook-install` writes a `home.create.<name>`
credential (a homed JSON record with `memberOf: [wheel]`, the password hash
and the plain password in `secret`: homed refuses to create a home from a hash
alone) into the deployment's `/etc/credstore` and labels it with
`setfiles -r <deployment>`. `systemd-homed-firstboot.service` is enabled in the
Containerfile; its drop-in adds `--member-of=wheel`, deletes
`/etc/credstore/home.create.*` afterwards and replaces
`ConditionFirstBoot=yes` by `ConditionDirectoryNotEmpty=!/var/lib/systemd/home`:
the image ships `/etc/machine-id` as an *empty file*, which machine-id(5) rule
4 calls "not a first boot", so `ConditionFirstBoot` is never true in the real
system (this also keeps `systemd-firstboot.service`, which would prompt for a
root password, from ever running; shipping `uninitialized` instead would turn
that on, and would make the initrd's cryptenroll wizard, which tests
`ConditionFileNotEmpty=!/sysroot/etc/machine-id`, skip).

`homectl firstboot` prompts on the console only when no regular user exists,
which is now the case on an install without a first user: the wizard asks for
one at the first boot (the account joins `wheel`). Without a credential it
prompts on the console. `systemd.firstboot=no` (what `vm.sh` adds by default)
also skips this wizard: tests that need it use `VM_FIRSTBOOT=1` and skip the
disk-encryption wizard (it prompts on a console nobody answers) with
`VM_CMDLINE=inglenook.cryptenroll=no`, a condition our drop-in adds to it in
the initrd (`systemd.mask=` did not stop it there).
