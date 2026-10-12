#!/usr/bin/env bash
# Build the inglenook bootc image. The pipeline is ordered by what each step
# depends on (see the stages in Containerfile):
#   1. `pre`:  everything except the initrd
#   2. initrd: mkosi (images/initrd) from pre's kernel modules and bootc files
#   3. `base`: pre + that initrd; its composefs digest is computed from the
#              stored layers
#   4. final:  base + a UKI embedding that digest (base layers come from cache)
# Needs buildah, podman, mkosi and network access for the initrd's packages.
# Usage: images/build.sh [push]
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=inglenook
REGISTRY=${DEV_REGISTRY:-ghcr.io/snugmo}
FEDORA_VERSION=${FEDORA_VERSION:-45}
VERSION=$(git describe --tags --always --dirty 2>/dev/null || true)
VERSION=${VERSION#v}
VERSION=${VERSION:-latest}
REVISION=$(git rev-parse HEAD 2>/dev/null || echo unknown)
IMAGE=$REGISTRY/$NAME:$VERSION
PRE=localhost/$NAME-pre:$VERSION
BASE=localhost/$NAME-base:$VERSION
WORK=build/initrd

args=(--build-arg "VERSION=$VERSION" --build-arg "REVISION=$REVISION"
      --build-arg "FEDORA_VERSION=$FEDORA_VERSION"
      --build-arg "SSH_PUBKEY=${SSH_PUBKEY:-}")

# --layers: buildah defaults to no layer cache, and the later passes must reuse
# the earlier base layers byte for byte or the digest below no longer matches.
build() { buildah build --layers -f images/Containerfile "${args[@]}" "$@" images; }

build --target pre -t "$PRE"

# Initrd inputs that come from the image itself: its kernel modules (mkosi
# filters them) and bootc's initramfs-setup and unit.
rm -rf "$WORK"
mkdir -p "$WORK/in/bootc" "$WORK/in/units" "$WORK/out"
c=$(podman create "$PRE")
trap 'podman rm -f "$c" >/dev/null' EXIT
kver=$(podman run --rm "$PRE" sh -c 'set -- /usr/lib/modules/*; test $# -eq 1 && basename "$1"')
podman cp "$c:/usr/lib/modules/$kver" "$WORK/in/modules"
podman cp "$c:/usr/lib/bootc/initramfs-setup" "$WORK/in/bootc/"
podman cp "$c:/usr/lib/systemd/system/bootc-root-setup.service" "$WORK/in/units/"
rm -f "$WORK/in/modules/vmlinuz" "$WORK/in/modules/initramfs.img"

# SOURCE_DATE_EPOCH keeps the cpio timestamps stable across runs.
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)} \
mkosi --directory images/initrd --force --build-sources= --release "$FEDORA_VERSION" \
  --output-directory "$PWD/$WORK/out" \
  --extra-tree "$PWD/$WORK/in/modules:/usr/lib/modules/$kver" \
  --extra-tree "$PWD/$WORK/in/bootc:/usr/lib/bootc" \
  --extra-tree "$PWD/$WORK/in/units:/usr/lib/systemd/system"
args+=(--build-context "initrd=$WORK/out")

build --target base -t "$BASE"

# Needs the image's own bootc plus access to the container storage.
store=$(podman info --format '{{.Store.GraphRoot}}')
composefs_digest() {
  podman run --rm --privileged --security-opt label=disable \
    -v "$store:/var/lib/containers/storage" "$BASE" \
    bootc container compute-composefs-digest-from-storage "$1"
}
digest=$(composefs_digest "$BASE")
echo "composefs digest: $digest"

[[ -n ${KARGS:-} ]] && args+=(--build-arg "KARGS=$KARGS")
build --build-arg "COMPOSEFS_DIGEST=$digest" -t "$IMAGE"

# The UKI is only bootable if the final image still measures the same.
final=$(composefs_digest "$IMAGE")
if [[ $final != "$digest" ]]; then
  echo "error: final image digest $final != UKI digest $digest" >&2
  exit 1
fi

echo "built $IMAGE"
[[ ${1:-} == push ]] && podman push "$IMAGE"
exit 0
