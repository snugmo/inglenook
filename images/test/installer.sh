#!/bin/bash
# Runs inside the installer VM (see vm.sh prep). The host shares its work
# directory over 9p; imgref names the image, inglenook.oci is its archive.
exec > >(tee /dev/ttyS0) 2>&1
set -x
mkdir -p /mnt/share
mount -t 9p -o trans=virtio,version=9p2000.L share /mnt/share || echo MOUNTFAIL
IMG=$(cat /mnt/share/imgref)
podman rmi -f "$IMG" || true
podman load -i /mnt/share/inglenook.oci
# ROOT_SIZE (optional, from vm.sh install): leave free space after the root.
ROOT_SIZE=$(cat /mnt/share/rootsize 2>/dev/null)
podman run --rm --privileged --pid=host --security-opt label=disable \
  -v /dev:/dev -v /var/lib/containers:/var/lib/containers \
  "$IMG" \
  bootc install to-disk --composefs-backend --bootloader systemd --generic-image --wipe \
    --filesystem ext4 --skip-fetch-check ${ROOT_SIZE:+--root-size "$ROOT_SIZE"} /dev/vdb
rc=$?
if [ "$rc" -eq 0 ] && [ -d /mnt/share/esp ]; then
  mkdir -p /mnt/esp
  mount /dev/vdb2 /mnt/esp && cp -rT /mnt/share/esp /mnt/esp && sync && umount /mnt/esp || rc=1
fi
if [ "$rc" -eq 0 ] && [ -e /mnt/share/imageonroot ]; then
  mkdir -p /mnt/root
  mount /dev/vdb3 /mnt/root && mkdir -p /mnt/root/installer \
    && skopeo copy oci-archive:/mnt/share/inglenook.oci oci:/mnt/root/installer/inglenook:latest \
    && sync && umount /mnt/root || rc=1
fi
echo "INSTALL_EXIT=$rc" | tee /mnt/share/result
sync
systemctl poweroff -f
