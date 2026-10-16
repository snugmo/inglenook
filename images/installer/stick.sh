#!/usr/bin/env bash
# Build the installer stick: ONE FAT32 partition that holds the boot files and
# the image to install, so it can also be made by extracting build/installer/tree
# onto any FAT32 drive. No root, no loop devices (sfdisk, mkfs.vfat and mtools
# work on a file).
#
#   images/installer/stick.sh <image-ref>        -> build/installer/stick.img
#
#   /EFI/BOOT/BOOTX64.EFI                systemd-boot (the removable-media path)
#   /EFI/Linux/inglenook.efi             the image's own UKI, as built
#   /loader/addons/10-installer.addon.efi   installer cmdline + initrd overlay
#
# Environment: STICK_SIZE (default 1G), PTYPE (sfdisk partition type for the
# GPT partition: "U" EFI system, "L" Linux data, default "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
# basic data), WORK (default build/installer). Firmware boots the fallback path
# from any FAT partition; PTYPE=none writes no partition table at all.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${WORK:-$REPO/build/installer}
ref=${1:?usage: stick.sh <image-ref>}
PTYPE=${PTYPE:-EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}
size=${STICK_SIZE:-1G}

rm -rf "$WORK/tree"; mkdir -p "$WORK/tree/EFI/BOOT" "$WORK/tree/EFI/Linux" "$WORK/tree/loader/addons"
c=$(podman create "$ref")
trap 'podman rm -f "$c" >/dev/null' EXIT
podman cp "$c:/usr/lib/systemd/boot/efi/systemd-bootx64.efi" "$WORK/tree/EFI/BOOT/BOOTX64.EFI"
podman cp "$c:/boot/EFI/Linux/inglenook.efi" "$WORK/tree/EFI/Linux/inglenook.efi"
"$HERE/build-addon.sh" "$WORK/tree/loader/addons/10-installer.addon.efi"

img=$WORK/stick.img
rm -f "$img"; truncate -s "$size" "$img"
if [[ $PTYPE == none ]]; then
  mkfs.vfat -F 32 -n INGLENOOK "$img" >/dev/null
  target=$img
else
  echo "label: gpt
start=1MiB, type=$PTYPE, name=inglenook" | sfdisk -q "$img"
  # Offset and size of partition 1 in sectors (512 B).
  read -r start sectors < <(sfdisk -J "$img" | python3 -I -c 'import json,sys; p=json.load(sys.stdin)["partitiontable"]["partitions"][0]; print(p["start"], p["size"])')
  mkfs.vfat -F 32 -n INGLENOOK --offset "$start" "$img" "$((sectors / 2))" >/dev/null
  target="$img@@$((start * 512))"
fi
MTOOLS_SKIP_CHECK=1 mcopy -i "$target" -s "$WORK"/tree/* ::
echo "wrote $img"
