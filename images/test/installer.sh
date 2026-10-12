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
podman run --rm --privileged --pid=host --security-opt label=disable \
  -v /dev:/dev -v /var/lib/containers:/var/lib/containers \
  "$IMG" \
  bootc install to-disk --composefs-backend --bootloader systemd --generic-image --wipe \
    --filesystem ext4 --skip-fetch-check /dev/vdb
rc=$?
echo "INSTALL_EXIT=$rc" | tee /mnt/share/result
sync
systemctl poweroff -f
