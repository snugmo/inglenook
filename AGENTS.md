# AGENTS.md — Inglenook Bootc Image Agent Configuration

> **Status: early.** `images/Containerfile` and `images/build.sh` exist; the image
> builds and boots (composefs backend, systemd-boot, UKI, no GRUB) in QEMU. The
> rest of the structure and conventions below is still the plan — update this
> file as the plan becomes reality.

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
  usb.sh         # Build a raw disk image for a physical machine / USB stick (build/usb)
  test/          # Rootless QEMU/KVM tests: vm.sh (harness), smoke.sh, wipe.sh; work dir is build/vm
docs/            # On-demand reference docs — read when relevant (see below)
```

## Essential Commands

| Task                     | Command                                                                          |
| ------------------------ | -------------------------------------------------------------------------------- |
| Build bootc OCI image    | `./images/build.sh` (needs mkosi; a plain `buildah build` fails: the `initrd` build context and `COMPOSEFS_DIGEST` are required) |
| Build + push to ghcr     | `./images/build.sh push`                                                          |
| Stateless-boot test      | `./images/test/wipe.sh` (after smoke.sh: wipes /etc and /var, boots twice, checks SELinux and the journal) |
| Build a USB stick image  | `./images/usb.sh` then `dd` build/usb/inglenook.img to the stick (see the script header) |
| Smoke-test the image     | `./images/test/smoke.sh` (build, install, boot over vsock, check; needs KVM, OVMF, vhost-device-vsock) |
| Install image to disk    | `bootc install` (from inside a running container)                                 |
| Inspect a deployed host  | `bootc status` (on the host)                                                      |
| Update a deployed host   | `bootc upgrade` (alias `bootc update`, on the host)                               |
| Switch image reference   | `bootc switch <ref>` (on the host)                                                |
| Roll back a deployment   | `bootc rollback` (on the host)                                                    |

> **VM/ISO media**: the ostree-rs-era `bootc image-prepare` verb is *not* part of the
> current (1.16) CLI. If/when we need to distribute VM or ISO images, that will be an
> osbuild-based (or equivalent) flow — TBD, and it would live in `images/build.sh`.

## Key Conventions

### Commit Conventions

- Make small, logically contained commits; one per meaningful change, committed as you go.
- Prefix every commit subject with a single emoji representing the change, followed by the conventional type prefix used in this repo (`feat:`, `chore:`, `docs:`, `fix:`, `refactor:`, …); keep subjects under 72 characters. Use `feat:` when the change adds a new capability to the image (a new package, tool, or service), and `chore:` for maintenance such as version bumps and internal adjustments. Examples: `✨ feat: add Rust toolchain to OS image`, `📦 chore: update Fedora base from 44 to 45`, `✏️ docs: …`, `🐛 fix: …`.
- End commit messages with an `Assisted-by: <agent>:<model>` trailer, where `<agent>` is the coding agent doing the committing (no "generated with" line).

### OS Image (`Containerfile`)

- Based on **Fedora 45** via `registry.fedoraproject.org/fedora-bootc:45` (a single `FEDORA_VERSION` build arg drives the `FROM` and the base.name label; we stay off Rawhide/46 on purpose, so upstream pre-release bugs don't mask our own tooling issues) — the earliest bootc-capable layer of the Fedora image cake (bootc-ified `fedora-minimal`, no desktop/GUI), not UBI; runs as non-root user `user` (UID 1000).
- The final stage must be a bootc stage — our base already is, and the stage is inherited through added layers. Never base a stage on a *non*-bootc image without adding a `switch-to-bootc-container` step.
- All binary downloads are verified as far as possible (SHA-256 `ADD --checksum=…`, cosign signatures, or SLSA provenance).
- Order instructions least-to-most frequently changing; package installs before configuration, to maximize layer reuse.

### Build Script (`images/build.sh`)

- Uses `buildah` (not `docker`) — rootless, works in CI without a Docker daemon (the bootc base image needs no special build tooling; the bootc stage is inherited through the build).
- The tag is the git-describe version (`git describe --tags --always --dirty`, leading `v` stripped, falls back to `latest`), so the image ref is `ghcr.io/snugmo/inglenook:<tag>` — e.g. `0.1.0`.
- Registry defaults to `ghcr.io/snugmo`; `./images/build.sh push` publishes to GitHub Container Registry. For local dev / CI use `DEV_REGISTRY=localhost:5000`.
- Passes `--build-arg VERSION=<tag>` and `--build-arg REVISION=$(git rev-parse HEAD)` for the `org.opencontainers.image.*` labels in the Containerfile (same convention as cote).

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

11. **Factory /etc**: the last `pre` step snapshots the finished `/etc` into `/usr/share/factory/etc` and generates `/usr/lib/tmpfiles.d/inglenook-etc-factory.conf` (`C! /etc/<entry>` per top-level entry; account databases, `machine-id`, `hostname`, `credstore*` are excluded on purpose). If `/etc` is wiped, `inglenook-etc-restore.service` in the initrd restores all of it before switch-root, because PID 1 loads the SELinux policy from `/etc/selinux` and early services (udev, hwdb) read `/etc` before tmpfiles in the real root has run. Restored files are unlabeled, so `inglenook-etc-relabel.service` (marker: `/run/inglenook`, left by the initrd unit) runs `restorecon -R /etc` as early as possible. Anything added to `/etc` in the Containerfile must come before the factory snapshot step. Test with `images/test/wipe.sh`.
12. **Units with `DefaultDependencies=no` race tmpfiles on a fresh `/var`** (e.g. `rpc-statd-notify`): add `After=systemd-tmpfiles-setup.service` in a drop-in under `rootfs/`. The wipe and smoke tests fail on any `journalctl -p err` line except the VM's TDX probe, so such races show up.
13. **Never kill the test VM**: `vm.sh stop` powers it down over QMP; killing qemu loses recent writes (ext4 delayed allocation leaves zero-length files, which once looked like a broken factory copy).
14. **Debugging without a root login**: `VM_EXTRA_UNIT=file.service vm.sh start` injects a unit via SMBIOS credentials; remember systemd expands `%` in `ExecStart` (write `%%`) and `$`-less shell is easier.
15. **Rootless podman/buildah** need `/etc/subuid` and `/etc/subgid` entries; a sysusers.d account gets none, so the Containerfile seeds them (carried by the factory copy). The sysusers account is `user` (UID 1000).

## Adding New Components

- **New package/tool**: add it to `images/Containerfile` (respecting layer-cache ordering), rebuild, and verify the bootc labels survived (e.g. `skopeo inspect --config ghcr.io/snugmo/inglenook:<tag> | jq .config.Labels`).
- **New media** (e.g. VM image, ISO): not part of the current bootc CLI — work out an osbuild-based flow first, then add it to `images/build.sh` rather than a second `Containerfile`.

## On-Demand Reference Docs

This file holds only the context useful for *any* work in this repo. As the image matures, detailed task-specific playbooks live in `docs/` — read the matching one when doing that kind of work. Planned (to be created when needed):

- **docs/bootc.md** — the build/deploy/update flow: image build, `bootc install`, `upgrade`/`switch`/`rollback`, and the `Containerfile` stage architecture.
- **docs/adding-a-package.md** — how to add a package or binary tool to the image, including checksum verification and layer ordering.
