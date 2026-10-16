Inglenook installer stick
=========================

This drive installs Inglenook onto a disk of the machine you boot it on.
It holds the boot files, the installer, and the system image (split in parts
because FAT32 files may not exceed 4 GiB). Nothing here touches any disk until
you confirm it.

1. In the firmware setup, turn Secure Boot OFF (the loader, the kernel image and
   the installer are not signed yet).
2. Boot this drive (the firmware's one-time boot menu, usually F12, F8 or Esc;
   it must be a UEFI entry for this drive).
3. A root shell appears on the screen. Run:   inglenook-install
   It lists the disks, shows what is on the one you pick, asks for the size of
   the root, whether to encrypt with the TPM, and the first user (root is locked,
   so without a user nobody can log in), then installs.
4. When it says the stick is no longer needed you can unplug it. When it
   finishes, unplug the stick and reboot.

Files (keep them together; the installer checks them against SHA256SUMS):

  EFI/BOOT/BOOTX64.EFI                   systemd-boot
  EFI/Linux/inglenook.efi                the kernel image (UKI) of the system
  loader/addons/10-installer.addon.efi   turns this boot into the installer
  inglenook/image.oci.tar.000, .001 ...  the system image, in parts
  inglenook/SHA256SUMS                   checksums of the parts
  inglenook/target-imgref                where the installed system updates from
  inglenook/prepare-root.conf            the image's own boot-time configuration

The installer finds the image on any FAT32 volume with inglenook/image.oci.tar.000,
so a newer image can also come on a second drive.
