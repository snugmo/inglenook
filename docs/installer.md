# The installer stick

A stick that installs Inglenook onto a disk of the machine it is plugged into. It boots
a root shell in the *initrd*, runs `inglenook-install`, and is not needed once the image
has been copied. Secure Boot must be off (the UKI and the addon are unsigned).

## What the stick is

ONE FAT32 partition (any partition type, or no partition table; firmware boots
`\EFI\BOOT\BOOTX64.EFI` from any FAT volume), built by `images/installer/stick.sh <image-ref>`
without root or loop devices (`sfdisk`, `mkfs.vfat`, mtools). The same tree can be extracted
onto any FAT32 drive (`build/installer/tree`).

```
/EFI/BOOT/BOOTX64.EFI                   systemd-boot (the removable-media path)
/EFI/Linux/inglenook.efi                the image's own UKI, unmodified
/loader/addons/10-installer.addon.efi   the installer (below)
/inglenook/image.oci.tar.000, .001 ...  the image: `skopeo copy` oci-archive, split in 1 GiB parts (FAT32)
/inglenook/SHA256SUMS                   checked before anything is touched
/inglenook/target-imgref                where updates come from (a registry, not this stick)
/inglenook/prepare-root.conf            the image's own ostree config, which bootc reads
/inglenook/accounts                     the image's user and group names (one per line): the first user's name must not be one of them
```

The installer is a UKI **addon** (`images/installer/build-addon.sh`): `.cmdline` is
`rd.systemd.unit=inglenook-installer.target`, so the boot initrd's systemd never switches
root; `.initrd` is a userspace-only cpio overlay (no kernel modules, no `.uname`, works with
any kernel). The overlay is the packages of `images/installer/mkosi.conf` minus every file
the boot initrd already has (`overlay.py`; a shared file that differs is an error), plus
`images/installer/rootfs`. Everything of ours is under `/usr/installer` (units are reached
by symlinks from `/usr/lib/systemd/system`). `exclude-packages.txt` keeps packages that are
only dependencies (podman, for bootc) out of the overlay. The installed system never has the
addon, and the boot initrd stays small: **anything an installed system needs to unlock and
mount its disks (dm-crypt, TPM, FIDO2 libraries, HID modules) belongs in the boot initrd
(`images/initrd/mkosi.conf`), not here.** Hardware support the installer needs beyond that
(modules) would be another addon with a `.uname`.

## Using it

Boot the stick (the console shows a banner), then run `inglenook-install`. It:

1. finds the image on any vfat volume (`/inglenook/image.oci.tar.000`) and checks `SHA256SUMS`;
2. lists the disks (not the stick), then shows the chosen one in full (`lsblk`, signatures,
   a hint if it looks like Windows, LUKS or an earlier Inglenook). A disk with anything on it
   is erased only after you type its device name; an empty one after a yes. Disks with mounted
   filesystems are refused;
3. asks for the root size (default 50G; the rest of the disk becomes the encrypted `/var`,
   which the installed system's initrd creates on its first boot);
4. encrypts with the TPM if there is one (`/dev/tpmrm0`), offering a recovery key; without a
   TPM it asks before installing unencrypted;
5. asks for the **first user** (below), because root is locked and there is no other account, so
   without one nobody could log in;
6. wipes the disk, partitions it with `systemd-repart` from `/usr/installer/repart.d/`
   (`00-esp.conf`, `10-root.conf`, `90-scratch.conf`: the shape of each partition is in the
   committed definitions; the installer appends the chosen root size, `Encrypt=tpm2` when
   selected, and a scratch size that fits the image: ext4 with fs-verity),
   unpacks the image from the stick to the scratch partition, says the stick is no longer needed,
   runs `bootc install to-filesystem` straight from the initrd (no container), adds a firmware boot
   entry (`efibootmgr`, non-fatal), removes the scratch partition and asks for the stick to be
   unplugged before the reboot.

Questions whose answer is in the environment are not asked (`INSTALL_DISK`, `INSTALL_ROOT_SIZE`,
`INSTALL_ENCRYPT=tpm2|none`, `INSTALL_RECOVERY_KEY`, `INSTALL_USER`, `INSTALL_REALNAME`,
`INSTALL_USER_PASSWORD`, `INSTALL_NO_USER=1`, `INSTALL_YES=1`, `INSTALL_NO_REBOOT=1`,
`INSTALL_TARGET_IMGREF`, `INSTALL_IMAGE_DIR`); the tests use that.

Measured in QEMU: about 45 s for the install itself, 276 MB peak in the RAM-backed root; it works
with 2 GB of RAM (1 GB is not safe).

## The first user

A fresh install has a locked root account and no regular account at all, so the installer sets up one
systemd-homed account:

- **In the installer:** username, full name (optional) and a password (twice, at least 8 characters).
  After `bootc install` it writes a `home.create.<name>` credential, a homed JSON user record, into the
  new system's `/etc/credstore` (that is under `/state/deploy/<digest>/etc` on the root, so it is on the
  encrypted volume, mode 0600, SELinux-labeled with `setfiles` like the initrd does). The record is in
  the `wheel` group (so `run0` works), has `/bin/bash` as shell, and holds the password hash plus the
  password itself in its `secret` section: homed needs the secret to create a home.
- **On the first boot:** `systemd-homed-firstboot.service` (enabled in the image, drop-in
  `10-inglenook.conf`) runs `homectl firstboot`, which creates the account from the credential without
  asking, and the drop-in deletes the credential afterwards. The unit does not use
  `ConditionFirstBoot=`: the image ships an empty `/etc/machine-id`, which systemd treats as "not a first
  boot" (machine-id(5)); it runs while homed has no record. The home is a plain directory when the root
  is encrypted (it already is), homed's default (a LUKS image) when it is not.
- **Skipped in the installer:** the same service prompts on the console on the first boot (username and
  password; the account joins `wheel`). Nothing is stored anywhere before that. To add users later from an
  existing login: `homectl create <name> --member-of=wheel`.
- The installer also appends `<name>:524288:65536` to `/etc/subuid` and `/etc/subgid` (rootless podman).
- Without disk encryption the password sits on the unencrypted disk in `/etc/credstore` until the first
  boot deletes the file (and stays recoverable from free space); the installer warns about that.
- Tokens (FIDO2, PKCS#11) for the account: [tokens.md](tokens.md).

## Tests

- `images/test/installer-env.sh`: the addon on a stick without the image: root shell in the initrd,
  banner, every installer tool runs.
- `images/test/install-from-stick.sh`: the whole install onto a disk that holds old data, TPM-sealed
  root and a first user, the stick pulled over QMP as soon as it is no longer needed, then the disk booted
  alone: the account exists, is in `wheel`, takes the password and not a wrong one, and the credential is gone.
- `images/test/install-safety.sh`: everything `inglenook-install` does before it erases: what it shows,
  the typed confirmation, bad sizes, a non-disk, and that the disk is byte-for-byte unchanged afterwards.

`images/test/serial-shell.py` and `serial-run.py` drive the root shell over the serial console. The
console shell is an interactive bash: a `!!` in a command is history expansion, so the installer prints
`ERROR:` / `WARNING:` and never `!!!`.

- **A security key (optional):** the installer asks whether to enrol a FIDO2 key for the user
  (`INSTALL_TOKEN=1|0` answers it). Enrolling needs homed running, which the initrd does not have, so
  the installer only leaves the user name in `/etc/inglenook/enroll-token`. On the first boot
  `inglenook-token-enroll.service` (after the homed wizard, before the login prompts, on the console)
  asks to insert the key and runs `homectl update <user> --fido2-device=auto --fido2-with-client-pin=yes
  --fido2-with-user-presence=yes`; homectl asks for the account password and the key's PIN (set one
  beforehand, `ykman fido access change-pin`). `s` skips; the marker is removed either way. One key
  only: each `--fido2-device=` replaces the account's keys (docs/tokens.md). The password keeps working.
  The test checks the marker and that the unit is enabled; the wizard itself was **not** driven end to
  end (the tests boot with `inglenook.tokenenroll=no`, as nobody answers the console).

## Not done yet

Swap, a no-TPM2 LUKS mode with FIDO2 (docs/encryption.md, the proposed per-variant initrd drop-in), FIDO2 enrollment of the
encrypted volumes during the install, an unattended mode driven by a config file, a PCR policy for the TPM
keys, LVM (an addon if ever needed), and any test on real hardware.
