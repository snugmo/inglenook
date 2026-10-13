# AGENTS.md — Inglenook Bootc Image Agent Configuration

> **Status: early but working.** The image builds (`images/build.sh`) and boots in
> QEMU with the composefs backend, systemd-boot and a UKI (no GRUB, no dracut),
> SELinux permissive (while the policy is worked out), a clean journal and a
> wipe-able `/etc` and `/var`;
> `images/usb.sh` makes a live installer stick (docs/usb.md): it runs from RAM and
> installs the image to the internal drive (docs/install.md). No GUI yet.
> Update this file as things change.

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
  usb.sh         # Build a raw disk image for a physical machine / USB stick (build/usb); live installer by default
  live-addon.sh  # Build the ESP-only UKI addon that makes a stick live (ro, no fsck, inglenook.live=1)
  test/          # Rootless QEMU/KVM tests: vm.sh (harness), smoke.sh, wipe.sh, xfsvar.sh; work dirs under build/
docs/            # On-demand reference docs — read when relevant (see below)
```

## Essential Commands

| Task                     | Command                                                                          |
| ------------------------ | -------------------------------------------------------------------------------- |
| Build bootc OCI image    | `./images/build.sh` (needs mkosi; a plain `buildah build` fails: the `initrd` build context and `COMPOSEFS_DIGEST` are required) |
| Build + push to ghcr     | `./images/build.sh push`                                                          |
| Stateless-boot test      | `./images/test/wipe.sh` (after smoke.sh: wipes /etc and /var, boots twice, checks SELinux and the journal) |
| XFS /var variant test    | `./images/test/xfsvar.sh` (builds with `inglenook.var=xfs`, installs with `--root-size`, grows the disk, checks the XFS /var) |
| Live-stick test          | `./images/test/live.sh` (live addon on the ESP; /etc and /var in RAM; nothing written to the stick) |
| Install-to-NVMe flow test | `./images/test/nvme-install.sh` (live stick as USB + blank virtual NVMe; the documented install; boot from the NVMe) |
| SELinux denials of a boot | `images/test/vm.sh avc` (summary) / `new-avc` (not in the baseline); on the machine: `ausearch -m avc` as root |
| Build a USB stick image  | `./images/usb.sh` (live installer; `LIVE=0` for a persistent stick) then `dd` build/usb/inglenook.img to the stick (see the script header) |
| Smoke-test the image     | `./images/test/smoke.sh` (build, install, boot over vsock, check; needs KVM, OVMF, vhost-device-vsock) |
| Install image to disk    | `bootc install` (from inside a running container)                                 |
| Inspect a deployed host  | `bootc status` (on the host)                                                      |
| Update a deployed host   | `bootc upgrade` (alias `bootc update`, on the host)                               |
| Switch image reference   | `bootc switch <ref>` (on the host)                                                |
| Roll back a deployment   | `bootc rollback` (on the host)                                                    |

> **Disk images**: the ostree-rs-era `bootc image-prepare` verb is *not* part of the
> current (1.16) CLI. Raw disk images are made with `bootc install` inside the installer
> VM of `images/test/vm.sh` (the dev container has no loop devices or root); `images/usb.sh`
> uses that. ISO/other formats are still TBD (an osbuild-based or equivalent flow).

## Key Conventions

### Commit Conventions

- Make small, logically contained commits; one per meaningful change, committed as you go.
- Prefix every commit subject with a single emoji representing the change, followed by the conventional type prefix used in this repo (`feat:`, `chore:`, `docs:`, `fix:`, `refactor:`, …); keep subjects under 72 characters. Use `feat:` when the change adds a new capability to the image (a new package, tool, or service), and `chore:` for maintenance such as version bumps and internal adjustments. Examples: `✨ feat: add Rust toolchain to OS image`, `📦 chore: update Fedora base from 44 to 45`, `✏️ docs: …`, `🐛 fix: …`.
- End commit messages with an `Assisted-by: <agent>:<model>` trailer, where `<agent>` is the coding agent doing the committing (no "generated with" line).

### OS Image (`Containerfile`)

- Based on **Fedora 45** via `registry.fedoraproject.org/fedora-bootc:45` (a single `FEDORA_VERSION` build arg drives the `FROM` and the base.name label; F45 is the target because its release is due within weeks, so working out issues on F44 would mean redoing or discarding fixes at the rebase; we stay off Rawhide/46 so unfinished upstream work doesn't mask our own tooling issues; expect F45 prerelease quirks to change at release, so re-check workarounds then, e.g. the SELinux denial on `ssh.ephemeral-authorized_keys-all`) — the earliest bootc-capable layer of the Fedora image cake (bootc-ified `fedora-minimal`, no desktop/GUI), not UBI; runs as non-root user `user` (UID 1000).
- The final stage must be a bootc stage — our base already is, and the stage is inherited through added layers. Never base a stage on a *non*-bootc image without adding a `switch-to-bootc-container` step.
- All binary downloads are verified as far as possible (SHA-256 `ADD --checksum=…`, cosign signatures, or SLSA provenance).
- Order instructions least-to-most frequently changing; package installs before configuration, to maximize layer reuse.

### Build Script (`images/build.sh`)

- Uses `buildah` (not `docker`) — rootless, works in CI without a Docker daemon (the bootc base image needs no special build tooling; the bootc stage is inherited through the build).
- The tag is the git-describe version (`git describe --tags --always --dirty`, leading `v` stripped, falls back to `latest`), so the image ref is `ghcr.io/snugmo/inglenook:<tag>` — e.g. `0.1.0`.
- Registry defaults to `ghcr.io/snugmo`; `./images/build.sh push` publishes to GitHub Container Registry. For local dev / CI use `DEV_REGISTRY=localhost:5000`.
- Passes `--build-arg VERSION=<tag>` and `--build-arg REVISION=$(git rev-parse HEAD)` for the `org.opencontainers.image.*` labels in the Containerfile (same convention as cote).
- Environment: `SSH_PUBKEY` (baked-in login key), `KARGS` (UKI kernel command line), `FEDORA_VERSION`, `DEV_REGISTRY`. The pipeline is `pre` target → mkosi initrd → `base` target → composefs digest → final image with the UKI (see Gotchas 6-8).

## Gotchas

1. **The bootc stage is mandatory**: `bootc install` only works on images with a bootc stage (the `containers.bootc` label + bootc tooling, i.e. an ostree commit as the base layer). Our base is bootc-ified and the stage persists through added layers — but don't base a stage on a non-bootc image without a `switch-to-bootc-container` step, and never override the bootc labels.
2. **Image pull access**: `bootc install` — and host-side `bootc upgrade`/`switch` — pull the image from a registry; the machine running them must have credentials for the registry.
3. **UID 1000**: the default user is `user` (UID 1000), shared with Snugmo's cote workspace images. Host volume mounts must be writable by UID 1000.
4. **Update, don't reinstall**: deployed hosts are updated with `bootc upgrade` (or `bootc switch` to change image). Re-running `bootc install` on an already-installed host is not the update path.
5. **Layer caching**: the bootc stage must stay last; do not reorder instructions above it without understanding the stage architecture.

6. **No dracut**: the initrd is built by mkosi (`images/initrd`) from the `pre` stage's kernel modules and bootc's `initramfs-setup`/`bootc-root-setup.service`, and installed as `/usr/lib/modules/<kver>/initramfs.img` in the `base` stage. Anything the initrd needs (modules, units) is mkosi config, not a dracut module. The initrd is part of the composefs digest, so it must be in place before the digest is computed.
7. **The UKI embeds the image digest**: the UKI's `composefs=<digest>` must equal the composefs digest of the finished rootfs, so `build.sh` builds the `base` target, computes the digest with `bootc container compute-composefs-digest-from-storage`, then builds the final image with `COMPOSEFS_DIGEST`. Do not use `bootc container ukify --rootfs` in the Containerfile — it measures a mount whose directory mtimes are the layer-extraction time, which never matches what `bootc install` computes. `/boot` is excluded from the digest, so the UKI itself can be added last. Build with layer caching (`--layers`): a rebuilt base has different contents and a different digest; `build.sh` fails if the final image's digest differs.
8. **`rw` on the UKI command line**: without it `/sysroot` mounts read-only and the `/var` and `/etc` binds inherit that, so `/var` is read-only and services fail.

9. **No loop devices / root in the dev container**: `bootc install` therefore runs inside a throwaway installer VM (`images/test/vm.sh install`), not on the host. Never debug a stale image: `vm.sh` passes the image ref through the 9p share, and the installer removes the old tag before loading.
10. **Login and SSH**: the `user` account comes from `sysusers.d` (a userdb drop-in record was invisible to setuid `sudo`), the baked pubkey is `/usr/lib/ssh/authorized_keys/user` symlinked as `~/.ssh/authorized_keys` by `tmpfiles.d`. ssh-over-vsock's per-connection sshd overrides `AuthorizedKeysFile` (only `ssh.ephemeral-authorized_keys-all` plus `~/.ssh/authorized_keys`), which is why no sshd drop-in is used. On Fedora 45 prerelease SELinux denies sshd-session reading that credential, so the credential route does not work yet.

11. **Factory /etc**: the last `pre` step snapshots the finished `/etc` into `/usr/share/factory/etc` and generates `/usr/lib/tmpfiles.d/inglenook-etc-factory.conf` (`C! /etc/<entry>` per top-level entry; `machine-id`, `hostname`, `credstore*` and the `-` backup copies are excluded on purpose). If `/etc` is wiped, `inglenook-etc-restore.service` in the initrd restores all of it before switch-root and labels it, because PID 1 loads the SELinux policy from `/etc/selinux` and early services (udev, hwdb) read `/etc` before tmpfiles in the real root has run. **Labeling in the initrd** (no policy loaded in the kernel yet) uses `setfiles -m -F -r /sysroot -c <policy.NN in the target> <file_contexts in the target> /sysroot/etc`: `-r` strips the prefix so the path-based patterns match as `/etc/...`, `-c` validates against the policy file in the target tree, and `-m` is essential: without it setfiles reads /proc/mounts and silently skips mounts that do not show `seclabel` yet, which made a plain `setfiles` a no-op (files stayed labeled `kernel`). With it the first boot after a wipe is clean. Anything added to `/etc` in the Containerfile must come before the factory snapshot step. Test with `images/test/wipe.sh`. `passwd` and `group` are in the factory set (system accounts are in `/usr/lib/{passwd,group}` via nss-altfiles, and sysusers can only add `user` to `wheel` if `wheel` is in `/etc/group`); `shadow` and `gshadow` are not (the policy silently denies tmpfiles getattr on them, so a rule logs an error every boot).
12. **Units with `DefaultDependencies=no` race tmpfiles on a fresh `/var`** (e.g. `rpc-statd-notify`): add `After=systemd-tmpfiles-setup.service` in a drop-in under `rootfs/`. The wipe and smoke tests fail on any `journalctl -p err` line except the VM's TDX probe, so such races show up.
13. **Never kill the test VM**: `vm.sh stop` powers it down over QMP; killing qemu loses recent writes (ext4 delayed allocation leaves zero-length files, which once looked like a broken factory copy).
14. **Debugging without a root login**: `VM_EXTRA_UNIT=file.service vm.sh start` injects a unit via SMBIOS credentials; remember systemd expands `%` in `ExecStart` (write `%%`) and `$`-less shell is easier.
15. **Rootless podman/buildah** need `/etc/subuid` and `/etc/subgid` entries; a sysusers.d account gets none, so the Containerfile seeds them (carried by the factory copy). The sysusers account is `user` (UID 1000).

16. **Opt-in XFS /var** (`inglenook.var=xfs` on the kernel command line, e.g. `KARGS=... images/build.sh`, or `XFS_VAR=1 images/usb.sh`; off by default). In the initrd, `inglenook-var-repart.service` runs `systemd-repart` (definition in `/usr/lib/inglenook/repart.d`, deliberately *not* `/usr/lib/repart.d`: files there make the stock `systemd-repart.service` run in the initrd and fail) before bootc sets up the root, creating an XFS partition (type `var`, label `var`) in all free space after the root, including space past the image end on a bigger disk. `inglenook-var-mount.service` mounts it over the ext4 `/var` bind that `bootc-root-setup` makes at `/sysroot/var`, with `rootcontext=var_t` (a fresh XFS root is unlabeled). It is a *service*, not a `sysroot-var.mount` unit: systemd skips a mount unit for a path that is already mounted. Both services are skipped on a live stick (`!inglenook.live`: its `/var` is RAM), so `XFS_VAR=1 images/usb.sh` makes a live stick whose *installed* system gets the XFS `/var`. Install the image with `--root-size` (`ROOT_SIZE` for `vm.sh install`) so there is free space. bootc state stays on the ext4 root. Early units that create directories in `/var` themselves race tmpfiles on the empty filesystem and get denied: order them after `systemd-tmpfiles-setup.service` (done for `rpc-statd-notify` and `systemd-random-seed`).

17. **SELinux is permissive on purpose, with dontaudit off**: the UKI carries `enforcing=0` (`SELINUX_ENFORCING=0`; 1 restores enforcing) and the image's policy is built with `semodule -DB` (`SELINUX_NO_DONTAUDIT=1`), so one boot logs every denial the strict policy would produce, including those a `dontaudit` rule hides (there is no kernel switch for that; it is compiled into the policy). Local policy is CIL (`images/rootfs/usr/share/inglenook/selinux/*.cil`, installed with `semodule -n -i` at build; no compiler needed). To find the rules a domain needs: boot, `ausearch -m avc` as root (or `vm.sh avc`), add `(allow ...)` lines. The tests fail only on denials missing from `images/test/selinux-denials.baseline` (plus `...xfsvar.baseline` for the XFS variant): the baseline is the to-do list, shrink it as rules or upstream fixes land. Process-transition perms (siginh, rlimitinh, noatsecure) are ignored as dontaudit noise. The one rule so far lets `sshd_session_t` read the `ssh.ephemeral-authorized_keys-all` credential (`init_var_run_t`), which works for root only: the credential directory is root-only and sshd reads authorized_keys as the target user.
18. **Dev login key**: `images/build.sh` bakes in `dev-keys/authorized_keys` (an unprotected ed25519 key generated on first use; `dev-keys/` is gitignored — never commit a key) unless `SSH_PUBKEY` is set. This is for testing boot and login only; the private half is `dev-keys/id_ed25519`.
19. **Installing to a drive from the live stick**: see docs/install.md. The stick keeps the image as an OCI layout directory at `/installer/inglenook` on its root partition (`vm.sh install` with `IMAGE_ON_ROOT=1`, done by `usb.sh`) and the installer runs from the live root itself: `podman run --privileged --rootfs /:O … bootc install to-disk --source-imgref oci:/installer/inglenook:latest`. A directory, not an archive: containers/image extracts an `oci-archive` into temp space first, and the live `/var` is RAM. `bootc image copy-to-storage` would also fill that RAM with a 2.7 GB copy and is not used. `bootc install` registers no NVRAM boot entry (the fallback `\EFI\BOOT\BOOTX64.EFI` is used; `efibootmgr` can add one), and the password credential on the stick's ESP is not copied.

20. **Wrong or missing labels on the mutable state** (copied-over or restored files; the OS content itself is labeled inside the composefs image): the mutable parts are `/etc`, `/var` and the backing directories under `/sysroot/state` on the root filesystem, which carry ordinary xattr labels. Symptom: AVCs with `unlabeled_t` targets, or with `trawcon="kernel"` for files written before a policy was loaded. Recovery: boot permissive (the UKI default), then `sudo restorecon -R /etc /var` (the mounted views only). **Never run restorecon (or an autorelabel) on `/sysroot` or anything under it.** restorecon takes the label from the *path* of each file, and the file-context patterns describe the running system (`/usr`, `/etc`, `/var`, …); run on `/sysroot/state/...` or the object store the paths match nothing meaningful, so most files get a generic fallback label and the system breaks until a correct full relabel. The content-addressed object store is the worst case: its names are digests, so no pattern could ever be right (on ostree it also wrecks the hardlinked targets). The same reason is why `restorecon -R /etc /var` is fine: it is run on the paths as the running system sees them, never on their backing directories under `/sysroot/state`, and the initrd's `setfiles -r /sysroot ... /sysroot/etc` does the same (the prefix is stripped, so the patterns see `/etc/...`). This rules out `touch /.autorelabel` (a full relabel) and `restorecon -R /sysroot/state`.
21. **Live stick** (`images/usb.sh`, default; `LIVE=0` for a persistent one). The stick is a normal `bootc install`, made live only by `loader/addons/live.addon.efi` on its ESP (`images/live-addon.sh`): systemd-stub appends that addon's command line (`ro fsck.mode=skip inglenook.live=1`) to the UKI's. The addon is not part of the image, and `bootc install` does not copy ESP-only files, so an installed system boots the plain persistent UKI and the composefs digest is untouched. `inglenook.live` makes the initrd's `inglenook-live-state.service` put /etc and /var on two ext4 images in a tmpfs (`/run/inglenook-live`, half of RAM, mounted `discard`; /var is 3 GiB at most), over the state directories on the stick, and `inglenook-etc-restore.service` then fills the empty /etc from the factory copy exactly as after a wipe. ext4, not plain tmpfs: tmpfs files are labeled by SELinux transition rules and ignore the `security.selinux` xattr, which gave hundreds of `tmpfs_t` denials. `ro` + `fsck.mode=skip` keep the root partition untouched (even a clean `e2fsck` rewrites the superblock's write time), and a `boot.mount` drop-in copied to /run by the live service makes the ESP read-only (the gpt-auto automount is read-write otherwise and dirties FAT). What still writes the stick is systemd-boot itself: `\loader\random-seed` and `\loader\boot-secret-mixin` (no `random-seed-mode` switch in this version); `systemd-boot-random-seed.service` is skipped when live. `images/test/live.sh` checks all of this: the root partition must be byte-identical after a boot and the ESP may differ only in those two files. Live `/var` fills the same first-boot denials as the XFS one (`selinux-denials.live.baseline`). The console autologs in as root on a live boot only: `inglenook-live-state.service` copies `getty@tty1`, `kmsconvt@tty1` and `serial-getty@` autologin drop-ins (`initrd/mkosi.extra/usr/lib/inglenook/live`) to /run, so the installed system has a normal login; `live.sh` and `smoke.sh` check both. **tty1 is kmscon, not agetty**: the base ships kmscon, `kmsconvt@.service` is the preset-enabled alias of `autovt@.service` that logind starts, so a `getty@tty1` drop-in alone never applies on hardware (the VM has no display, so `live.sh` starts `kmsconvt@tty1` by hand); kmscon's autologin is `--login -- /bin/login -p -f root`. Needs RAM: the 4 GB QEMU VM is enough for the install; the first live boots on hardware are untested.

22. **No setuid files**: the Containerfile strips the setuid bit from everything in `/usr` (sudo, GRUB, shim and bootupd are removed too) and `smoke.sh` fails on any setuid file. Privilege escalation is `run0` (polkit authorizes, wheel is admin). The password agent needs `polkit-agent-helper.socket` enabled: without it the agent execs `polkit-agent-helper-1`, which refuses to run unless setuid. File capabilities (`newuidmap`, `newgidmap`, `arping`) are kept for rootless podman. `run0` needs a tty to ask for the password (`ssh -t`), and `user` needs a password for it; in the test VM inject one with `VM_EXTRA_UNIT` (a oneshot running `chpasswd`).

## Adding New Components

- **New package/tool**: add it to `images/Containerfile` (respecting layer-cache ordering), rebuild, and verify the bootc labels survived (e.g. `skopeo inspect --config ghcr.io/snugmo/inglenook:<tag> | jq .config.Labels`).
- **New media** (e.g. VM image, ISO): not part of the current bootc CLI — work out an osbuild-based flow first, then add it to `images/build.sh` rather than a second `Containerfile`.

## On-Demand Reference Docs

This file holds only the context useful for *any* work in this repo. As the image matures, detailed task-specific playbooks live in `docs/` — read the matching one when doing that kind of work.

- **docs/usb.md** — building, writing and trying the USB stick image on a physical machine (logins, what was verified, known limits).
- **docs/install.md** — installing to the internal drive from the stick (partitioning, ESP, composefs, persistent XFS `/var`).

Planned (to be created when needed):

- **docs/bootc.md** — the build/deploy/update flow: image build, `bootc install`, `upgrade`/`switch`/`rollback`, and the `Containerfile` stage architecture.
- **docs/adding-a-package.md** — how to add a package or binary tool to the image, including checksum verification and layer ordering.
