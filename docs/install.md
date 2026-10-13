# Installing inglenook to the internal drive

From the USB stick (see [usb.md](usb.md)) you can install the same OS onto the
machine's NVMe drive. This is plain `bootc install`; nothing here is specific to
the stick. The whole flow is tested in QEMU by `images/test/nvme-install.sh`
(live stick as a USB device, blank virtual NVMe drive, then boot from the NVMe alone).

**This erases the target drive.** Check the device name twice.

## 1. Boot the stick and log in

The live stick logs in as root on the console by itself (no password; the
installed system does not). Over the network use `ssh user@inglenook.local` (see
usb.md) and `run0` for root. Identify the internal drive:

```sh
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINT      # the stick is TRAN=usb; the target is e.g. nvme0n1
```

## 2. Install

`bootc install` normally runs from inside a container of the image to be
installed. The live stick avoids copying that image anywhere: it runs the
installer from its own root filesystem (`podman run --rootfs /`) and gives it the
OCI copy of the image that is kept on the stick (`/sysroot/installer/inglenook`,
read-only). Nothing is written to the stick or to the RAM-backed `/var` first:

```sh
podman run --rm --privileged --pid=host \
    --security-opt label=type:unconfined_t \
    -v /dev:/dev -v /sysroot/installer:/installer:ro --rootfs /:O \
    bootc install to-disk --composefs-backend --bootloader systemd \
        --filesystem ext4 --source-imgref oci:/installer/inglenook:latest \
        --wipe /dev/nvme0n1
```

That single command does everything you listed:

| Step | Result on `/dev/nvme0n1` |
| --- | --- |
| partitions the drive (GPT) | `p1` 1 MiB BIOS boot (unused on UEFI), `p2` 1 GiB EFI System, `p3` root (the rest of the drive, or `--root-size`) |
| writes the ESP | FAT32, mounted at `/boot`: `\EFI\BOOT\BOOTX64.EFI` (systemd-boot as the removable-media fallback) and `\EFI\systemd\systemd-bootx64.efi`; the UKI as `\EFI\Linux\bootc\bootc_composefs-<digest>.efi`; `\loader\loader.conf` and a boot-loader-spec entry in `\loader\entries\`. No NVRAM boot entry is registered (see below) |
| root filesystem | ext4 with fs-verity enabled (`-O verity`, which composefs wants), holding the composefs object store and the per-deployment state, including `/etc` and `/var` |

The kernel command line (including `composefs=<digest>`, `rw`, `enforcing=0` and
the hostname) lives inside the UKI, so the installed system boots exactly like
the stick does, except that it is not live: the live addon sits only on the
stick's ESP and is not copied, so `/etc` and `/var` persist on the new drive.

When it prints `Installation complete!` two optional steps remain, both while the
stick is still running:

```sh
# a. carry over the console password: it is a credential on the *stick's* ESP,
#    which the install does not copy, and the new system sets the password when
#    it creates `user` on its first boot (/boot is the stick's ESP, read-only)
mount /dev/nvme0n1p2 /mnt
cp -r /boot/loader/credentials /mnt/loader/
umount /mnt

# b. register a firmware boot entry (the install does not; the firmware finds the
#    fallback loader by itself and most machines then offer the drive as a boot
#    device, but an explicit entry is more predictable)
efibootmgr -c -d /dev/nvme0n1 -p 2 -L inglenook -l '\EFI\systemd\systemd-bootx64.efi'
```

Then `poweroff`, remove the stick and boot the machine; it comes up from the
NVMe drive (use the firmware boot menu if it still prefers the stick). The
installed system has the same logins as the stick: the ssh key is baked into the
image.

## A persistent `/var` partition

By default `/var` of the installed system is a directory on the root filesystem,
so it is persistent already, just not on its own partition. For all of `/var` on
its own XFS partition build the stick with the XFS flag:

```sh
XFS_VAR=1 WORK=$PWD/build/usb-xfs images/usb.sh      # on the build machine; write that image to the stick
```

The image gets the `inglenook.var=xfs` flag in its UKI, so the installed system
creates the partition; the live stick skips that (its `/var` is RAM). Install
with a limited root so there is free space left on the drive:

```sh
... bootc install to-disk --composefs-backend --bootloader systemd \
        --filesystem ext4 --source-imgref oci:/installer/inglenook:latest \
        --root-size 64G --wipe /dev/nvme0n1
```

On first boot the initrd creates the XFS partition in everything after the root
(`systemd-repart`), mounts it as `/var` and the system carries on; the next boots
just mount it. Details are in AGENTS.md (the opt-in XFS `/var`). Putting `/var`
on a different filesystem later by hand is possible but not what is tested.

## Afterwards

- `bootc status` shows the booted deployment. The image reference recorded at
  install time comes from the stick's OCI directory, which nobody can update
  from. Once the image is published, add
  `--target-imgref ghcr.io/snugmo/inglenook:<tag>` to the install command (or
  run `bootc switch` later) so that `bootc upgrade` has somewhere to pull from.
- Other layouts (keeping existing partitions, dual boot, LUKS) need
  `bootc install to-filesystem` on a filesystem you prepared yourself; that path
  is not tested here.
