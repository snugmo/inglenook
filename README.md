# Inglenook

A small, complete Linux system built as a [bootc](https://github.com/containers/bootc)
image: one image to build, one USB stick to install from, one command to update.
Fedora 45 underneath, a Sway desktop on top, an encrypted disk, and no setuid
binaries anywhere.

**Status: early but working.** The image builds, boots and installs (below); the
SELinux policy is still being worked out, so it boots permissive for now.

## What you get

- **One OCI image, built with bootc.** The system root is a read-only composefs
  image; updates are transactional — `bootc upgrade` pulls and switches to a new
  image, `bootc rollback` undoes it, `bootc status` shows where you are.
- **No GRUB, no dracut.** The system boots a UKI (Unified Kernel Image) through
  systemd-boot; the initrd is built by mkosi.
- **Two image variants**, differing in how an encrypted root is unlocked
  ([docs/encryption.md](docs/encryption.md)):
  - `tpm2` (the default): the root is LUKS2 sealed to the machine's TPM 2.0 —
    plain, when the machine has no TPM.
  - `no-tpm`: the root is always LUKS2 with an empty key slot that unlocks
    hands-off; a FIDO2 token or a recovery key can be enrolled later.

    `/var` is LUKS2 either way (TPM-sealed, or an empty slot otherwise).
- **A desktop.** Sway with sddm as the login screen (`graphical.target`).
- **The first user is a systemd-homed account**, created at install time (or
  asked for on the first boot). Hardware-key (FIDO2) logins work at the
  console, for `run0` and over ssh — tested with a software token, no real
  YubiKey yet ([docs/tokens.md](docs/tokens.md)).
- **No setuid, no sudo.** Privilege escalation is `run0` (polkit).
- **SELinux** runs on the stock Fedora policy plus a small local CIL module,
  permissive until that module is complete.

## Layout

```
images/
  Containerfile  # The OS image: Fedora base + packages + host configuration
  build.sh       # buildah wrapper: pre → mkosi initrd → base → composefs digest → UKI
  initrd/        # mkosi config for the initrd (replaces dracut)
  rootfs/        # Files copied into the image as-is (units, drop-ins, issue banner)
  installer/     # The installer stick: UKI addon + inglenook-install (docs/installer.md)
  addons/        # UKI addons for per-machine boot tuning (the serial console)
  test/          # Rootless QEMU/KVM tests
docs/            # On-demand reference docs (see below)
```

## Building

```sh
./images/build.sh           # → ghcr.io/snugmo/inglenook:<git-describe tag>
./images/build.sh push      # and publish to GitHub Container Registry
```

Rootless buildah (no Docker daemon); mkosi is needed for the initrd.
`VARIANT=tpm2|no-tpm` selects the image variant; `KARGS` tunes the UKI's
kernel command line; see [AGENTS.md](AGENTS.md) for the full environment table.

## Testing

Rootless QEMU/KVM tests — they need KVM, OVMF and vhost-vsock, and the TPM
ones also swtpm (`images/test/tpm-setup.sh` fetches it):

| Test | What it checks |
| ---- | ---- |
| `images/test/smoke.sh` | build, install, boot, basic health |
| `images/test/wipe.sh` | wipe `/etc` and `/var`, boot twice: factory restore, clean journal |
| `images/test/xfsvar.sh` | first-boot `/var` (LUKS2 + XFS) made by the initrd, twice, data survives |
| `images/test/install-from-stick.sh` | the whole stick flow: install, stick pulled, boot the disk |
| `images/test/install-safety.sh` | every refusal, and the disk byte-for-byte untouched before confirmation |
| `images/test/token.sh` | FIDO2 (software token) logins: homed, `run0`, ssh |

## Installing on a machine

1. Build an image and make a stick: `images/installer/stick.sh <image-ref>`
   writes `build/installer/stick.img` — put it on a USB stick (or extract its
   tree onto any FAT32 drive).
2. Boot the stick (Secure Boot off; the UKI and addon are unsigned) and, in the
   root shell it offers, run `inglenook-install`.
   It shows the disks and what is on them (a wipe needs the device name typed),
   asks how big to make the root, whether to encrypt, and for the first user.
   Then it partitions (`systemd-repart`, seeded by the new machine id), copies
   the image into the new `/var` — the scratch space — installs with
   `bootc install`, writes the machine id, and is done: pull the stick and
   reboot.
3. On the machine: `bootc upgrade` to update, `bootc status` to inspect.

What the stick is and what `inglenook-install` does, step by step:
[docs/installer.md](docs/installer.md).

## Documentation

| | |
| ---- | ---- |
| [docs/installer.md](docs/installer.md) | The installer stick and `inglenook-install` |
| [docs/encryption.md](docs/encryption.md) | Disk encryption at boot |
| [docs/tokens.md](docs/tokens.md) | Hardware-token (FIDO2) logins |
| [docs/upstream/](docs/upstream/) | Draft issues for upstream (not filed) |
| [AGENTS.md](AGENTS.md) | The working context: build details, gotchas, conventions |

## License

[GNU AGPL v3](LICENSE)
