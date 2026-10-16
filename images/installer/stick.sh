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
# The image to install is on the stick too, unless NO_IMAGE=1 (fast stick for the
# environment test): /inglenook/image.oci.tar.NNN is `skopeo copy` of the image as
# an oci-archive, split in 1 GiB parts for FAT32, with SHA256SUMS, target-imgref
# (where updates come from; default: the image ref) and the image's own
# prepare-root.conf. The parts are cached in build/installer/parts-<image id>.
#
# Environment: STICK_SIZE (default: the content plus 300 MiB, in whole GiB), PTYPE (sfdisk partition type for the
# GPT partition: "U" EFI system, "L" Linux data, default "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
# basic data), WORK (default build/installer). Firmware boots the fallback path
# from any FAT partition; PTYPE=none writes no partition table at all.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${WORK:-$REPO/build/installer}
ref=${1:?usage: stick.sh <image-ref>}
PTYPE=${PTYPE:-EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}

rm -rf "$WORK/tree"; mkdir -p "$WORK/tree/EFI/BOOT" "$WORK/tree/EFI/Linux" "$WORK/tree/loader/addons"
c=$(podman create "$ref")
trap 'podman rm -f "$c" >/dev/null' EXIT
podman cp "$c:/usr/lib/systemd/boot/efi/systemd-bootx64.efi" "$WORK/tree/EFI/BOOT/BOOTX64.EFI"
podman cp "$c:/boot/EFI/Linux/inglenook.efi" "$WORK/tree/EFI/Linux/inglenook.efi"
"$HERE/build-addon.sh" "$WORK/tree/loader/addons/10-installer.addon.efi"

if [[ -z ${NO_IMAGE:-} ]]; then
  id=$(podman image inspect --format '{{.Id}}' "$ref")
  parts=$WORK/parts-${id:0:12}
  if [[ ! -f $parts/SHA256SUMS ]]; then
    rm -rf "$parts"; mkdir -p "$parts"
    skopeo copy --quiet "containers-storage:$ref" "oci-archive:$parts/archive.tar:latest"
    split -b 1G -d -a 3 "$parts/archive.tar" "$parts/image.oci.tar."
    rm -f "$parts/archive.tar"
    (cd "$parts" && sha256sum image.oci.tar.* > SHA256SUMS)
  fi
  mkdir -p "$WORK/tree/inglenook"
  cp --reflink=auto "$parts"/* "$WORK/tree/inglenook/"
  echo "${TARGET_IMGREF:-$ref}" > "$WORK/tree/inglenook/target-imgref"
  podman cp "$c:/usr/lib/ostree/prepare-root.conf" "$WORK/tree/inglenook/prepare-root.conf"
  cp "$HERE/README.stick.txt" "$WORK/tree/inglenook/README.txt"
fi

content=$(du -sb "$WORK/tree" | cut -f1)
size=${STICK_SIZE:-$(( (content + 300 * 1048576 + 1073741823) / 1073741824 ))G}
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
