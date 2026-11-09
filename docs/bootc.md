# Building and deploying the inglenook image

The build pipeline, what it must keep true, and how a built image gets onto a
disk. The short versions of these notes live in AGENTS.md (Key Conventions →
Build Script; Gotchas 1, 2, 4, 5, 6a-9).

## The pipeline (`images/build.sh`)

- Uses `buildah` (not `docker`) — rootless, works in CI without a Docker daemon
  (the bootc base image needs no special build tooling; the bootc stage is
  inherited through the build).
- The tag is the git-describe version (`git describe --tags --always --dirty`,
  leading `v` stripped, falls back to `latest`), so the image ref is
  `ghcr.io/snugmo/inglenook:<tag>` — e.g. `0.1.0`.
- Registry defaults to `ghcr.io/snugmo`; `./images/build.sh push` publishes to
  GitHub Container Registry. For local dev / CI use `DEV_REGISTRY=localhost:5000`.
- Passes `--build-arg VERSION=<tag>` and `--build-arg REVISION=$(git rev-parse
  HEAD)` for the `org.opencontainers.image.*` labels in the Containerfile (same
  convention as cote).
- Environment: `SSH_PUBKEY` (baked-in login key), `KARGS` (UKI kernel command
  line), `FEDORA_VERSION`, `DEV_REGISTRY`.
- The stages: the `pre` target → the mkosi initrd → the `base` target → the
  composefs digest → the final image with the UKI.

## The UKI's PCR 11 signature

The UKI's PCR 11 prediction is signed (`.pcrsig`, `.pcrpkey`) with a test key
`dev-keys/pcr-{private,public}.pem` that `build.sh` makes with `ukify genkey`
when missing (`PCR_PRIVATE_KEY`/`PCR_PUBLIC_KEY` override; gitignored, never
commit). The private key reaches the UKI stage only as the build secret
`pcrkey`; the public key is the UKI's `.pcrpkey`, which systemd-stub's tmpfiles
rule copies to `/run/systemd/tpm2-pcr-public-key.pem`, where systemd 262
`systemd-tpm2-setup` looks for it to create the NvPCRs. **Do not install it
under `/usr/lib/systemd` or `/etc/systemd`**: `systemd-cryptenroll` (bootc's
`--block-setup tpm2-luks`) then binds the key to the signed PCR 11 and needs
the signature to open the device, which the installer VM (no UKI) does not have
("Failed to load PCR signature"). The same key is in `/run/systemd` inside the
booted UKI's initrd, where `systemd-repart` would bind the new `/var` (and the
installer's root) to the signed PCR 11 too, and the unmeasured test VM then
cannot unlock it on the next boot: `inglenook-var-repart.service` and the
installer pass `--tpm2-public-key-pcrs=` (empty; `--tpm2-public-key=` does not
turn it off in repart, although it does in `systemd-cryptenroll`) to keep the
TPM keys PCR-less until the PCR policy is designed (without it
`systemd-tpm2-setup-early` and the `systemd-pcrproduct`/`pcrlogin@` units fail
with ENOENT on a measured boot; the test VM is not measured, so only real
hardware shows it). The UKI must also be built with `ukify --sign-initrd-pcrs`:
systemd 262 creates the NvPCRs with a write policy that only a signature bound
to the `enter-initrd` phase with the policy reference `initrd` satisfies, and
without that extra signature every NvPCR initialisation fails with `Couldn't
find signature for this PCR bank, PCR index and public key` (surfacing as
`Device not a stream`; the `NV_DefineSpace` `0x14c` lines
(`TPM_RC_NV_DEFINED`) next to it are the harmless "index exists, reuse it"
path, so a TPM clear is not needed). A key per release, kept outside the repo,
is still to be decided.

## The initrd and the digest

**No dracut.** The initrd is built by mkosi (`images/initrd`) from the `pre`
stage's kernel modules and bootc's `initramfs-setup`/`bootc-root-setup.service`,
and installed as `/usr/lib/modules/<kver>/initramfs.img` in the `base` stage.
Anything the initrd needs (modules, units) is mkosi config, not a dracut
module. The initrd is part of the composefs digest, so it must be in place
before the digest is computed.

**Stale `pre` layers = wrong initrd modules.** The initrd's kernel modules come
from the `pre` target, the UKI's kernel from the final image. After
`fedora-bootc:45` moved to a newer kernel a cached `pre` still had the old one
(kernel 7.2.11 booting with 7.2.9 modules: no `usb_storage`/`sd_mod`, the
installer saw no stick; virtio is built in, so a plain VM boot hid it).
Symptom: `ls /usr/lib/modules` in the initrd lists two versions. Fix: remove
the `localhost/inglenook-*` images and `podman image prune -a`, rebuild.

**The UKI embeds the image digest.** The UKI's `composefs=<digest>` must equal
the composefs digest of the finished rootfs, so `build.sh` builds the `base`
target, computes the digest with `bootc container
compute-composefs-digest-from-storage`, then builds the final image with
`COMPOSEFS_DIGEST`. Do not use `bootc container ukify --rootfs` in the
Containerfile — it measures a mount whose directory mtimes are the
layer-extraction time, which never matches what `bootc install` computes.
`/boot` is excluded from the digest, so the UKI itself can be added last.
Build with layer caching (`--layers`): a rebuilt base has different contents
and a different digest; `build.sh` fails if the final image's digest differs.

**`rw` on the UKI command line.** Without it `/sysroot` mounts read-only and
the `/var` and `/etc` binds inherit that, so `/var` is read-only and services
fail.

## Building in the dev container

No loop devices / root in the dev container: `bootc install` therefore runs
inside a throwaway installer VM (`images/test/vm.sh install`), not on the
host. Never debug a stale image: `vm.sh` passes the image ref through the 9p
share, and the installer removes the old tag before loading.

**Disk images**: the ostree-rs-era `bootc image-prepare` verb is *not* part of
the current (1.17) CLI. Raw disk images are made with `bootc install` inside
the installer VM of `images/test/vm.sh` (the dev container has no loop devices
or root). ISO/other formats are still TBD (an osbuild-based or equivalent
flow), to be added to `images/build.sh` rather than a second `Containerfile`.

## Deploying

- **The bootc stage is mandatory**: `bootc install` only works on images with
  a bootc stage (the `containers.bootc` label + bootc tooling, i.e. an ostree
  commit as the base layer). Our base is bootc-ified and the stage persists
  through added layers — but don't base a stage on a *non*-bootc image without
  a `switch-to-bootc-container` step, and never override the bootc labels.
- **Image pull access**: `bootc install` — and host-side `bootc
  upgrade`/`switch` — pull the image from a registry; the machine running them
  must have credentials for the registry.
- **Update, don't reinstall**: deployed hosts are updated with `bootc upgrade`
  (or `bootc switch` to change image). Re-running `bootc install` on an
  already-installed host is not the update path.
- **Layer caching**: the bootc stage must stay last; do not reorder
  instructions above it without understanding the stage architecture.

## Other build quirks

- **Plymouth** is in the image (`plymouth`, `plymouth-system-theme`: with it
  come the two-step and label plugins and the Cantarell font the prompt text
  needs) and in the initrd (mkosi's `plymouth` profile in
  `images/initrd/mkosi.conf`). `systemd-ask-password-plymouth.path` (shipped
  by the plymouth package) forwards every password/PIN question to it, so no
  extra glue is needed. The kernel command line has no `splash`/`quiet`, so it
  shows the text mode with the boot messages; add `splash` (and `quiet`) to
  `KARGS` for the graphical splash. Untested on the machine; its SELinux
  denials, if any, are not yet in the policy.
- **apse** (github.com/snugmo/apse) — the unprivileged in-process sandbox for
  GUI apps on the Sway desktop (namespaces + a rebuilt rootfs + Landlock/
  seccomp via the nono crate, and `wp_security_context_v1`-tagged Wayland
  sockets; the successor to wlsctx) — has no releases, so the `apse-build`
  stage at the top of the Containerfile builds the binary with cargo from a
  commit pinned by tarball SHA-256 (`--locked`); only `/usr/bin/apse` goes
  into the image. Its SELinux module is vendored at
  `rootfs/usr/share/inglenook/selinux/apse.cil` (the same pin the stage builds
  from) and is installed into the policy store by the same `semodule -n -i`
  as `inglenook.cil`; the factory /etc snapshot carries the store, so on a
  deployed system the policy defines `apse_t` / `apse_app_t` / `apse_shim_t`
  and the `apse_exec_t` file context for `/usr/bin/apse` — `restorecon
  /usr/bin/apse` labels the binary and the exec transition into `apse_t`
  fires (the stack runs unconfined, module inert, until it is). It requires
  the flatpak types (`flatpak_home_t`), so `flatpak-selinux` stays in the
  desktop dnf above. The user units (the clipboard prompt broker) are not
  installed; they are per-user (the README's broker unit expects
  `/usr/local/bin/apse`, a one-line drop-in if it is used).
