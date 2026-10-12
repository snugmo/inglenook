#!/usr/bin/env bash
# Build the inglenook bootc image. Two passes, because the UKI embeds the
# composefs digest of the finished rootfs (see the `uki` stage in Containerfile):
#   1. build the `base` target and compute its digest from the stored layers
#   2. build the full image with that digest (base layers come from cache)
# Usage: images/build.sh [push]
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=inglenook
REGISTRY=${DEV_REGISTRY:-ghcr.io/snugmo}
VERSION=$(git describe --tags --always --dirty 2>/dev/null || true)
VERSION=${VERSION#v}
VERSION=${VERSION:-latest}
REVISION=$(git rev-parse HEAD 2>/dev/null || echo unknown)
IMAGE=$REGISTRY/$NAME:$VERSION
BASE=localhost/$NAME-base:$VERSION

args=(--build-arg "VERSION=$VERSION" --build-arg "REVISION=$REVISION"
      --build-arg "SSH_PUBKEY=${SSH_PUBKEY:-}")
[[ -n ${FEDORA_VERSION:-} ]] && args+=(--build-arg "FEDORA_VERSION=$FEDORA_VERSION")
[[ -n ${KARGS:-} ]] && args+=(--build-arg "KARGS=$KARGS")

# --layers: buildah defaults to no layer cache, and pass 2 must reuse pass 1's
# base layers byte for byte or the digest below no longer matches.
buildah build --layers -f images/Containerfile --target base "${args[@]}" -t "$BASE" images

# Needs the image's own bootc plus access to the container storage.
store=$(podman info --format '{{.Store.GraphRoot}}')
composefs_digest() {
  podman run --rm --privileged --security-opt label=disable \
    -v "$store:/var/lib/containers/storage" "$BASE" \
    bootc container compute-composefs-digest-from-storage "$1"
}
digest=$(composefs_digest "$BASE")
echo "composefs digest: $digest"

buildah build --layers -f images/Containerfile "${args[@]}" \
  --build-arg "COMPOSEFS_DIGEST=$digest" -t "$IMAGE" images

# The UKI is only bootable if the final image still measures the same.
final=$(composefs_digest "$IMAGE")
if [[ $final != "$digest" ]]; then
  echo "error: final image digest $final != UKI digest $digest" >&2
  exit 1
fi

echo "built $IMAGE"
[[ ${1:-} == push ]] && podman push "$IMAGE"
exit 0
