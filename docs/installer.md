# The installer stick

A stick that installs Inglenook onto a disk of the machine it is plugged into. It is
not the live stick of [usb.md](usb.md) (which runs the whole OS from the stick); it boots
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
5. wipes the disk, partitions it with `systemd-repart` (`/usr/installer/repart.d/00-esp.conf` plus
   a root and a temporary scratch partition written at run time: ext4 with fs-verity, `Encrypt=tpm2`),
   unpacks the image from the stick to the scratch partition, says the stick is no longer needed,
   runs `bootc install to-filesystem` straight from the initrd (no container), adds a firmware boot
   entry (`efibootmgr`, non-fatal), removes the scratch partition and asks for the stick to be
   unplugged before the reboot.

Questions whose answer is in the environment are not asked (`INSTALL_DISK`, `INSTALL_ROOT_SIZE`,
`INSTALL_ENCRYPT=tpm2|none`, `INSTALL_RECOVERY_KEY`, `INSTALL_YES=1`, `INSTALL_NO_REBOOT=1`,
`INSTALL_TARGET_IMGREF`, `INSTALL_IMAGE_DIR`); the tests use that.

Measured in QEMU: about 45 s for the install itself, 276 MB peak in the RAM-backed root; it works
with 2 GB of RAM (1 GB is not safe).

## Tests

- `images/test/installer-env.sh`: the addon on a stick without the image: root shell in the initrd,
  banner, every installer tool runs.
- `images/test/install-from-stick.sh`: the whole install onto a disk that holds old data, TPM-sealed
  root, the stick pulled over QMP as soon as it is no longer needed, then the disk booted alone.
- `images/test/install-safety.sh`: everything `inglenook-install` does before it erases: what it shows,
  the typed confirmation, bad sizes, a non-disk, and that the disk is byte-for-byte unchanged afterwards.

`images/test/serial-shell.py` and `serial-run.py` drive the root shell over the serial console. The
console shell is an interactive bash: a `!!` in a command is history expansion, so the installer prints
`ERROR:` / `WARNING:` and never `!!!`.

## Not done yet

Swap, FIDO2 enrollment and homed users during the install, an unattended mode driven by a config file,
a PCR policy for the TPM keys, LVM (an addon if ever needed), and any test on real hardware.
