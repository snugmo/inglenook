# AGENTS.md — Inglenook Bootc Image Agent Configuration

> **Status: early but working.** The image builds (`images/build.sh`) and boots in
> QEMU with the composefs backend, systemd-boot and a UKI (no GRUB, no dracut),
> SELinux permissive (while the policy is worked out), a clean journal and a
> wipe-able `/etc` and `/var`. `images/installer/stick.sh` makes the installer
> stick (docs/installer.md): a root shell in the initrd, `inglenook-install`
> installs the image to the internal drive and does all the disk provisioning
> there (machine id, repart with the machine id as `--seed`, LUKS2 root and
> /var, /var doubling as the image-copy scratch), and can enrol a FIDO2
> security key into the volumes' LUKS2 headers while they are still closed.
> There are two image variants (`VARIANT=tpm2` the default, `no-tpm`): how an
> encrypted root is unlocked differs (TPM-sealed vs empty-key-slot LUKS,
> docs/encryption.md). A Sway desktop and its tools are in the image packages;
> the default target is graphical.target and sddm (enabled by its preset) shows
> the login screen. Update this file as things change.

## Project Overview

**inglenook** — a Fedora-based bootable OS image built with [bootc](https://github.com/containers/bootc) (bootable containers), from the [Snugmo](https://github.com/snugmo) GitHub org. The image is defined by a `Containerfile` that FROMs the official Fedora bootc base, built into an OCI image with `podman`/`buildah` (the base's bootc stage is inherited), and is installed on a host with `bootc install` from a running container; deployed hosts update transactionally via `bootc upgrade`.

## Structure

Layout:

```
images/
  Containerfile  # The OS image: Fedora base + packages + host configuration
  build.sh       # buildah wrapper: pre -> mkosi initrd -> base -> composefs digest -> UKI image
  initrd/        # mkosi config for the initrd (replaces dracut): mkosi.conf + mkosi.extra/
  rootfs/        # Files copied into the image as-is (units, drop-ins, issue banner)
  installer/     # The installer stick: UKI addon (tools + inglenook-install under /usr/installer, incl. the /usr/installer/variant marker), stick.sh, mkosi.conf of its packages; see docs/installer.md
  addons/        # UKI addons for per-machine boot tuning (serial-console.sh: console=ttyS0)
  test/          # Rootless QEMU/KVM tests: vm.sh (harness), smoke.sh, wipe.sh, xfsvar.sh; work dirs under build/
docs/            # On-demand reference docs — read when relevant (see below)
```

## Essential Commands

| Task                     | Command                                                                          |
| ------------------------ | -------------------------------------------------------------------------------- |
| Build bootc OCI image    | `./images/build.sh` (needs mkosi; a plain `buildah build` fails: the `initrd` build context and `COMPOSEFS_DIGEST` are required) |
| Build + push to ghcr     | `./images/build.sh push`                                                          |
| Stateless-boot test      | `./images/test/wipe.sh` (after smoke.sh: wipes /etc and /var, boots twice, checks SELinux and the journal) |
| First-boot /var test     | `./images/test/xfsvar.sh` (installs with `--root-size`, grows the disk, checks the initrd safety net makes the LUKS2 XFS /var partition, twice, and that data survives) |
| Installer stick (no live mode) | `images/installer/stick.sh <image-ref>` builds `build/installer/stick.img` (one FAT32 partition); tests: `installer-env.sh`, `install-from-stick.sh` (whole install onto a disk with old data, stick pulled, boot from the disk; `FIDO2=1` covers the no-key path), `install-fido2.sh` (FIDO2 on the LUKS volumes: `ENCRYPT=luks` boots with a ~30 s token wait per volume, `tpm2` TPM-first; `luks` needs the no-tpm image), `install-safety.sh` (refusals, disk untouched) — docs/installer.md |
| Hardware-token login test | `./images/test/token.sh` (software FIDO2 token in the VM: homed users, run0's polkit stack, pam-u2f, ssh; see docs/tokens.md) |
| SELinux denials of a boot | `images/test/vm.sh avc` (summary) / `new-avc` (not in the baseline); on the machine: `ausearch -m avc` as root |
| Smoke-test the image     | `./images/test/smoke.sh` (build, install, boot over vsock, check; needs KVM, OVMF, vhost-device-vsock) |
| Install image to disk    | `bootc install` (from inside a running container)                                 |
| Inspect a deployed host  | `bootc status` (on the host)                                                      |
| Update a deployed host   | `bootc upgrade` (alias `bootc update`, on the host)                               |
| Switch image reference   | `bootc switch <ref>` (on the host)                                                |
| Roll back a deployment   | `bootc rollback` (on the host)                                                    |

> **Disk images**: not part of the current (1.17) bootc CLI; raw disks come from
> `bootc install` in the installer VM of `images/test/vm.sh`, ISO/other is TBD
> — docs/bootc.md.

## Key Conventions

### Commit Conventions

- Small commits, one per meaningful change, committed as you go.
- Subject: `<emoji> <type>: <summary>` — a conventional type prefix
  (`feat:`, `fix:`, `chore:`, `docs:`, …) and a summary under 72 chars.
  The single emoji is chosen per change to capture what actually changed;
  there is no fixed set of allowed emojis.
- End the message with an `Assisted-by: <agent>:<model>` trailer (no
  "generated with" line).

### OS Image (`Containerfile`)

- Based on **Fedora 45** via `registry.fedoraproject.org/fedora-bootc:45`
  (`FEDORA_VERSION` drives the `FROM` and the base.name label). The earliest
  bootc-capable layer of the Fedora image cake (bootc-ified `fedora-minimal`,
  no desktop/GUI), not UBI; has no baked-in account (the first user is created
  by the installer). We stay off Rawhide/46 so unfinished upstream work doesn't
  mask our own tooling issues.
- The final stage must be a bootc stage — our base already is, and the stage is
  inherited through added layers. Never base a stage on a *non*-bootc image
  without adding a `switch-to-bootc-container` step.
- All binary downloads are verified as far as possible (SHA-256
  `ADD --checksum=…`, cosign signatures, or SLSA provenance).
- Order instructions least-to-most frequently changing; package installs before
  configuration, to maximize layer reuse.

### Build Script (`images/build.sh`)

- Uses `buildah` (not `docker`) — rootless, no daemon. The pipeline: `pre`
  target → mkosi initrd → `base` target → composefs digest → final image with
  the UKI.
- The tag is the git-describe version (leading `v` stripped, `latest`
  fallback), so the image ref is `ghcr.io/snugmo/inglenook:<tag>` — e.g.
  `0.1.0`. Registry defaults to `ghcr.io/snugmo`; `push` publishes,
  `DEV_REGISTRY=localhost:5000` for local dev / CI.
- Passes `--build-arg VERSION=<tag>` and `--build-arg REVISION=$(git rev-parse
  HEAD)` for the `org.opencontainers.image.*` labels in the Containerfile.
- The UKI's PCR 11 prediction is signed with a generated test key
  (`dev-keys/pcr-{private,public}.pem`, built with `ukify --sign-initrd-pcrs`).
  **Do not install the public key under `/usr/lib/systemd` or `/etc/systemd`**
  (cryptenroll would then bind the TPM keys to the signed PCR 11 and the
  UKI-less installer VM could not open the volume); the TPM keys stay PCR-less
  (`--tpm2-public-key-pcrs=`) until the PCR policy is designed. Details:
  docs/bootc.md.
- Environment: `SSH_PUBKEY` (baked-in login key), `KARGS` (UKI kernel command
  line), `FEDORA_VERSION`, `DEV_REGISTRY`.

### Shell Scripts

- Target **POSIX sh** in new scripts: `/bin/sh` shebang, no bashisms — bash
  only where a feature actually needs it (`[[ ]]`, arrays, process
  substitution). The existing test and build scripts are bash on purpose
  (`token/answerer.sh` and `token/nopw.sh` are the `/bin/sh` examples); don't
  rewrite them, and `inglenook-install` must stay bash (`set -E`, arrays).
- `set -euo pipefail` in bash scripts (the installer adds `-E` with an ERR
  trap); a failing `cd` gets `|| exit`.
- Quote words that carry glob or comma characters (QEMU argument values, the
  RHS of `[[ == ]]`); remote commands passed to ssh/serial stay single-quoted
  so they expand on the machine, not locally.
- Run `shellcheck` before committing; a `# shellcheck disable=<code>` needs a
  reason comment (the one standing exception: the space-separated
  `AVC_BASELINE_EXTRA`).

### Security

- Never put secrets (API keys, tokens, passwords) in committed files, logs, or
  commit messages.

### Machine Config

- Do not modify live configuration outside this repo (agent configs under
  `~/.config`, shell rc files, …) unless explicitly asked.

### Context Hygiene

- Keep this file short: hard rules plus pointers; long-form playbooks live in
  `docs/` and are read on demand.

## Gotchas

The entries below are the rules; the long ones link to docs/gotchas.md (full
reasoning) and, where relevant, the topic docs.

1. **The bootc stage is mandatory**: `bootc install` only works on images with
   a bootc stage (the `containers.bootc` label + bootc tooling, i.e. an ostree
   commit as the base layer). Our base is bootc-ified and the stage persists
   through added layers — but don't base a stage on a *non*-bootc image without
   a `switch-to-bootc-container` step, and never override the bootc labels.
2. **Image pull access**: `bootc install` — and host-side
   `bootc upgrade`/`switch` — pull the image from a registry; the machine
   running them must have credentials for the registry.
3. **No baked-in account.** The image has no regular account (the old `user`,
   UID 1000 shared with the cote workspace images, is gone), no ssh key and no
   sudo. The first user is a systemd-homed account made from the installer's
   credential (gotcha 25); homed UIDs are in the 60001-60513 range. Host volume
   mounts must be writable by that user.
4. **Update, don't reinstall**: deployed hosts are updated with `bootc upgrade`
   (or `bootc switch` to change image). Re-running `bootc install` on an
   already-installed host is not the update path.
5. **Layer caching**: the bootc stage must stay last; do not reorder
   instructions above it without understanding the stage architecture.
6a. **Stale `pre` layers = wrong initrd modules.** The initrd's modules come
    from the `pre` target, the UKI's kernel from the final image; a cached
    `pre` after a kernel bump leaves mismatched modules (symptom: two versions
    under `/usr/lib/modules` in the initrd). Fix: remove the
    `localhost/inglenook-*` images, `podman image prune -a`, rebuild. Details:
    docs/bootc.md.
6b. **Plymouth** is in the image and the initrd (mkosi profile);
    `systemd-ask-password-plymouth.path` forwards every password/PIN question
    to it, no glue needed. The kernel command line has no `splash`/`quiet`
    (text mode with the boot messages); add them to `KARGS` for the graphical
    splash. Details: docs/bootc.md.
6c. **apse** (github.com/snugmo/apse) — the in-process sandbox for GUI apps
    on the Sway desktop (successor to wlsctx) — has no releases, so the
    `apse-build` stage builds the binary with cargo from a commit pinned by
    tarball SHA-256 (`--locked`); only `/usr/bin/apse` goes into the image.
    Its SELinux module is vendored next to `inglenook.cil` and installed by
    the same `semodule -n -i` (it needs `flatpak_home_t`, so flatpak-selinux
    stays in the desktop dnf); `restorecon /usr/bin/apse` on a deployed system
    labels it `apse_exec_t` and starts the confined run. The user units (the
    clipboard prompt broker) are not installed; they are per-user. Details:
    docs/bootc.md.
6. **No dracut**: the initrd is built by mkosi (`images/initrd`) from the
   `pre` stage's kernel modules and bootc's `initramfs-setup`/`bootc-root-setup.service`,
   and installed as `/usr/lib/modules/<kver>/initramfs.img` in the `base`
   stage. Anything the initrd needs (modules, units) is mkosi config, not a
   dracut module. The initrd is part of the composefs digest, so it must be in
   place before the digest is computed.
7. **The UKI embeds the image digest**: the UKI's `composefs=<digest>` must
   equal the composefs digest of the finished rootfs, so `build.sh` computes it
   between the `base` target and the final image (`COMPOSEFS_DIGEST`); `/boot`
   is excluded from the digest, so the UKI itself can be added last. Do not use
   `bootc container ukify --rootfs` in the Containerfile — it measures a mount
   whose directory mtimes are the layer-extraction time, which never matches.
   Details: docs/bootc.md.
8. **`rw` on the UKI command line**: without it `/sysroot` mounts read-only and
   the `/var` and `/etc` binds inherit that, so `/var` is read-only and
   services fail.
9. **No loop devices / root in the dev container**: `bootc install` therefore
   runs inside a throwaway installer VM (`images/test/vm.sh install`), not on
   the host. Never debug a stale image: `vm.sh` passes the image ref through
   the 9p share, and the installer removes the old tag before loading.
10. **Login and SSH**: the tests log in as **root** over ssh with `$WORK/key`
    (an SMBIOS credential; `SSH_USER=` selects another account); nothing is
    baked into the image. The vsock credential route works for root only (the
    per-service subdirectory of `/run/credentials` is root-only); homed users
    carry their ssh keys in the record (`sshAuthorizedKeys`; sshd asks
    `userdbctl`). Details: docs/gotchas.md, docs/tokens.md.
11. **Factory /etc**: the last `pre` step snapshots the finished `/etc` into
    `/usr/share/factory/etc` and generates the tmpfiles `C!` rules; if `/etc`
    is wiped, `inglenook-etc-restore.service` in the initrd restores and labels
    it before switch-root (PID 1 loads the SELinux policy from `/etc/selinux`,
    and early services read `/etc` before tmpfiles in the real root). Anything
    added to `/etc` in the Containerfile must come before the snapshot step.
    `machine-id` is in the set as an *empty* file on purpose (an existing-but-
    empty one is not a first boot, so the first-boot wizards and preset-all
    stay off). Details: docs/gotchas.md.
12. **Units with `DefaultDependencies=no` race tmpfiles on a fresh `/var`**
    (e.g. `rpc-statd-notify`): add `After=systemd-tmpfiles-setup.service` in a
    drop-in under `rootfs/`. The wipe and smoke tests fail on any
    `journalctl -p err` line except the VM's TDX probe, so such races show up.
13. **Never kill the test VM**: `vm.sh stop` powers it down over QMP; killing
    qemu loses recent writes (ext4 delayed allocation leaves zero-length
    files, which once looked like a broken factory copy).
14. **Debugging without a root login**: `VM_EXTRA_UNIT=file.service vm.sh
    start` injects a unit via SMBIOS credentials; remember systemd expands `%`
    in `ExecStart` (write `%%`) and `$`-less shell is easier.
15. **Rootless podman/buildah** need `/etc/subuid` and `/etc/subgid` entries
    and a homed account gets none by itself, so `inglenook-install` appends
    `<user>:524288:65536` to both in the new system's `/etc` (and labels them).
    The image seeds nothing.
16. **Encrypted everything, XFS /var (the default of an installed system).**
    The root is LUKS2 (sealed to the TPM on the tpm2 variant, an empty keyslot
    on the no-tpm one; ext4 inside, because composefs needs fs-verity and
    `mkfs.xfs` has none), and the installer creates a LUKS2 XFS /var in all
    free space after the root, with the machine id as repart `--seed` (every
    UUID a deterministic function of it). For systems that skip the installer,
    the initrd services (`inglenook-var-repart`, `inglenook-var-mount`) are a
    first-boot safety net; a fresh /var is skeletonized and labelled with
    `setfiles` before switch-root. The growth units (bootc's growpart, systemd
    262's growfs) are masked — the installer fixes the sizes at install time.
    Do not use `systemd-tpm2-setup-early`'s SRK file or
    `systemd-analyze has-tpm2` as the "is there a TPM" test: both need a
    measured boot, which the test VM's OVMF does not give. Details:
    docs/gotchas.md (layout, labelling, growth), docs/encryption.md (unlocking),
    docs/installer.md (provisioning).
17. **SELinux is permissive on purpose**: the UKI carries `enforcing=0` —
    `SELINUX_ENFORCING=1` does **not boot yet** (the mkosi initrd has no
    policy; shipping it there is the long-term plan). Local policy is CIL
    (`images/rootfs/usr/share/inglenook/selinux/*.cil`, `semodule -n -i` at
    build; no compiler needed). Hunt denials with `ausearch -m avc` as root (or
    `vm.sh avc`); `images/test/selinux-denials.baseline` is the to-do list —
    tests fail only on denials missing from it, so shrink it as rules land.
    Never allow the dontaudit noise (siginh, rlimitinh, noatsecure). Details:
    docs/gotchas.md.
18. **No dev key in the image.** Logins come from credentials passed to the VM
    or from the installer; `dev-keys/` (gitignored; never commit a key) is the
    home of the PCR signing key only.
19. *(Removed with the live stick; the install flow is gotcha 24 and
    docs/installer.md.)*
20. **Wrong or missing labels on the mutable state** (`/etc`, `/var`,
    `/sysroot/state`; the OS content is labeled inside the composefs image):
    recovery is to boot permissive (the UKI default), then
    `restorecon -R /etc /var` (the mounted views only). **Never run restorecon
    (or an autorelabel) on `/sysroot` or anything under it** — labels are
    derived from the path against the running system's file-context patterns,
    so on the backing directories most files get a generic fallback label and
    the system breaks. This rules out `touch /.autorelabel` (a full relabel)
    and `restorecon -R /sysroot/state`. Details: docs/gotchas.md.
21. *(Removed with the live stick.)*
22. **No setuid files**: the Containerfile strips the setuid bit from
    everything in `/usr` (sudo, GRUB, shim and bootupd are removed too) and
    `smoke.sh` fails on any setuid file. Privilege escalation is `run0` (polkit
    authorizes, wheel is admin); the password agent needs
    `polkit-agent-helper.socket` enabled. File capabilities (`newuidmap`,
    `newgidmap`, `arping`) are kept for rootless podman. `run0` needs a tty
    (`ssh -t`) and the account needs a password (a homed user has the one from
    the installer).
23. **Token logins** (docs/tokens.md): authselect has `with-systemd-homed`;
    `with-pam-u2f` is off; sshd reads keys from homed records. Never add
    `AuthenticationMethods publickey,password` to sshd (locks out root and
    token-only users); a homed user's ssh login needs the token in the
    *server*. Details: docs/gotchas.md.
24. **The installer** (playbook: docs/installer.md) runs in the initrd of the
    stick's own UKI: `bootc install to-filesystem` without a container. The
    machine id is generated *before* partitioning and passed as
    `systemd-repart --seed`, so every UUID is a deterministic function of it;
    the /var partition doubles as the image-copy scratch; the machine id is
    written into the deployment's `/etc` so the first boot is not a first boot.
    The installed system has **no `/boot` mount and no `/etc/fstab`** (the ESP
    *is* the boot partition; bootc finds it by device scan). The image variant
    decides the encryption modes offered and the root-unlock drop-in; the
    addon's package overlay must stay byte-identical to the boot initrd (the
    overlay's bootc is pinned to the initrd's version). Details:
    docs/gotchas.md.
25. **The first user.** Root is locked, so `inglenook-install` writes a
    `home.create.<name>` credential (a homed record: `memberOf: [wheel]`, the
    password hash and the plain password in `secret` — homed refuses to create
    a home from a hash alone) into the deployment's `/etc/credstore`;
    `systemd-homed-firstboot` creates the account and deletes the credential.
    The image ships `/etc/machine-id` as an *empty file* on purpose: an
    existing-but-empty file is not a first boot per machine-id(5), so
    `ConditionFirstBoot` is never true and the first-boot wizards and preset-all
    stay off. Details: docs/gotchas.md.

## Adding New Components

- **New package/tool**: add it to `images/Containerfile` (respecting
  layer-cache ordering), rebuild, and verify the bootc labels survived (e.g.
  `skopeo inspect --config ghcr.io/snugmo/inglenook:<tag> | jq .config.Labels`).
- **New media** (e.g. VM image, ISO): not part of the current bootc CLI — work
  out an osbuild-based flow first, then add it to `images/build.sh` rather
  than a second `Containerfile`.

## On-Demand Reference Docs

This file holds only the context useful for *any* work in this repo: hard
rules plus pointers. The detailed reasoning lives in `docs/` — read the
matching one when doing that kind of work.

- **docs/gotchas.md** — the deep dives behind the long Gotchas: login and SSH,
  factory `/etc`, the encrypted layout and labelling, SELinux permissive,
  restorecon, token logins, the installer, the first user.
- **docs/bootc.md** — building and deploying the image: the buildah pipeline,
  the PCR 11 signature, the initrd/digest coupling, dev-container constraints,
  disk images, `bootc install`/`upgrade`/`switch`/`rollback`.
- **docs/tokens.md** — hardware-token logins: homed + FIDO2/PKCS#11, pam-u2f,
  what was tested with the software token and the limits.
- **docs/installer.md** — the installer stick: one FAT32 partition, the UKI
  addon, `inglenook-install`, the first user, the tests (replaced the live
  stick).
- **docs/encryption.md** — how the initrd unlocks the LUKS root
  (gpt-auto-generator, cryptsetup-generator, the options that can and cannot
  be injected), systemd-cryptsetup's unlock order and why a missing FIDO2
  token delays rather than gates a boot, LUKS2 header/keyslot facts, and the
  no-TPM2 FIDO2 path (the `no-tpm` image variant: a static drop-in in the
  initrd with its own `systemd-cryptsetup attach` options; no per-machine
  kargs — a locked-down type-2 UKI has none — and no wrapper).
- **docs/upstream/** — drafts of issues to file upstream (not filed, not part
  of the image): currently `repart-uuid-change-ignored.md`, a
  `context_changed()` gap in `systemd-repart` that makes a UUID-only change a
  silent no-op (why the installer assigns the machine id *before*
  partitioning instead of two-phase).

Planned (to be created when needed):

- **docs/adding-a-package.md** — how to add a package or binary tool to the
  image, including checksum verification and layer ordering.
