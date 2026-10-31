#!/usr/bin/env bash
# Build the inglenook bootc image. The pipeline is ordered by what each step
# depends on (see the stages in Containerfile):
#   1. `pre`:  everything except the initrd
#   2. initrd: mkosi (images/initrd) from pre's kernel modules and bootc files
#   3. `base`: pre + that initrd; its composefs digest is computed from the
#              stored layers
#   4. final:  base + a UKI embedding that digest (base layers come from cache)
# Needs buildah, podman, mkosi and network access for the initrd's packages.
# Environment: KARGS, PCR_PRIVATE_KEY and PCR_PUBLIC_KEY (the key that signs the
# UKI's PCR 11 prediction; default dev-keys/pcr-{private,public}.pem, made with
# `ukify genkey` when missing: a test key, never published),
# SELINUX_ENFORCING (default 0 = permissive), SELINUX_NO_DONTAUDIT (default 0; 1 logs the dontaudit denials too),
# FEDORA_VERSION, DEV_REGISTRY,
# VARIANT (default tpm2; no-tpm builds the other image variant: the initrd gains
# the drop-in that unlocks the LUKS root with a FIDO2 token / empty slot instead
# of the TPM, docs/encryption.md; the choice is recorded as an image label, and
# the installer stick made from the image (images/installer/stick.sh) picks it
# up to mark the addon).
# Usage: images/build.sh [push]
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=inglenook
REGISTRY=${DEV_REGISTRY:-ghcr.io/snugmo}
FEDORA_VERSION=${FEDORA_VERSION:-45}
VARIANT=${VARIANT:-tpm2}
[[ $VARIANT == tpm2 || $VARIANT == no-tpm ]] || { echo "VARIANT must be tpm2 or no-tpm (got '$VARIANT')" >&2; exit 1; }
VERSION=$(git describe --tags --always --dirty 2>/dev/null || true)
VERSION=${VERSION#v}
VERSION=${VERSION:-latest}
REVISION=$(git rev-parse HEAD 2>/dev/null || echo unknown)
IMAGE=$REGISTRY/$NAME:$VERSION
PRE=localhost/$NAME-pre:$VERSION
BASE=localhost/$NAME-base:$VERSION
WORK=build/initrd
PCR_PRIVATE_KEY=${PCR_PRIVATE_KEY:-dev-keys/pcr-private.pem}
PCR_PUBLIC_KEY=${PCR_PUBLIC_KEY:-dev-keys/pcr-public.pem}

# The PCR signing key pair goes into the UKI stage as build secrets.
if [[ ! -f $PCR_PRIVATE_KEY || ! -f $PCR_PUBLIC_KEY ]]; then
  mkdir -p "$(dirname "$PCR_PRIVATE_KEY")" "$(dirname "$PCR_PUBLIC_KEY")"
  (umask 077; ukify genkey --pcr-private-key "$PCR_PRIVATE_KEY" --pcr-public-key "$PCR_PUBLIC_KEY")
fi

args=(--build-arg "VERSION=$VERSION" --build-arg "REVISION=$REVISION"
      --build-arg "FEDORA_VERSION=$FEDORA_VERSION"
      --build-arg "VARIANT=$VARIANT")
[[ -n ${SELINUX_NO_DONTAUDIT:-} ]] && args+=(--build-arg "SELINUX_NO_DONTAUDIT=$SELINUX_NO_DONTAUDIT")

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

# The no-tpm variant adds one file to the initrd: the drop-in that replaces
# gpt-auto-generator's root cryptsetup ExecStart (docs/encryption.md).
extra_trees=( --extra-tree "$PWD/images/initrd/no-tpm:/usr/lib/systemd/system" )
[[ $VARIANT == tpm2 ]] && extra_trees=()

# SOURCE_DATE_EPOCH keeps the cpio timestamps stable across runs.
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)} \
mkosi --directory images/initrd --force --build-sources= --release "$FEDORA_VERSION" \
  --output-directory "$PWD/$WORK/out" \
  --extra-tree "$PWD/$WORK/in/modules:/usr/lib/modules/$kver" \
  --extra-tree "$PWD/$WORK/in/bootc:/usr/lib/bootc" \
  --extra-tree "$PWD/$WORK/in/units:/usr/lib/systemd/system" \
  "${extra_trees[@]}"
args+=(--build-context "initrd=$WORK/out")

# The initrd must track the image, not the mkosi release cache: a stale pull
# once gave an initrd from the previous Fedora (its systemd 259 against the
# image's 262), which broke the unlock paths in ways a boot log did not
# explain. The kernel modules come from the image (above); verify the rest -
# the release, the systemd version and the kernel tree - against the pre
# stage, which carries the same base layer as the final image.
initrd="$WORK/out/initrd.cpio.zst"
[[ -f $initrd ]] || { echo "error: mkosi did not produce $initrd" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'podman rm -f "$c" >/dev/null; chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
# Extract only what the checks need (the mkosi cpio mirrors the ostree image:
# /usr is read-only, so a full extract cannot be cleaned up unprivileged).
zstdcat "$initrd" | cpio -it --quiet 2>/dev/null \
  | grep -oE '^usr/lib/modules/[^/]+/' | sed -E 's#^usr/lib/modules/##; s#/$##' | sort -u > "$tmp/mods"
mods=$(tr '\n' ' ' < "$tmp/mods")
[[ $mods == "$kver " ]] || { echo "error: the initrd has the kernel trees: $mods (the image: $kver)" >&2; exit 1; }
# The mkosi cpio has no rpm db (mkosi strips it), so the systemd version is
# read from the build note rpm embeds in the binary itself ({"type":"rpm",
# "name":"systemd","version":"262-3.fc45",...}).
zstdcat "$initrd" | cpio -idm --quiet --directory "$tmp" 'usr/lib/systemd/systemd' 'usr/lib/os-release' 2>/dev/null
image_systemd=$(podman run --rm "$PRE" rpm -q systemd | sed -E 's/^systemd-//; s/\.x86_64$//')
initrd_systemd=$(strings -n 3 "$tmp/usr/lib/systemd/systemd" 2>/dev/null \
  | grep -oE '"name":"systemd","version":"[^"]+"' | head -1 \
  | sed -E 's/.*"version":"([^"]+)"/\1/')
[[ -n $initrd_systemd ]] || { echo "error: no systemd version note in the initrd binary" >&2; exit 1; }
[[ $initrd_systemd == $image_systemd ]] || { echo "error: initrd systemd '$initrd_systemd' != image '$image_systemd' (stale mkosi release?)" >&2; exit 1; }
initrd_ver=$(sed -n 's/^VERSION_ID=//p' "$tmp/usr/lib/os-release" 2>/dev/null)
image_ver=$(podman run --rm "$PRE" sed -n 's/^VERSION_ID=//p' /etc/os-release)
[[ -z $initrd_ver || $initrd_ver == $image_ver ]] || { echo "error: initrd Fedora $initrd_ver != image Fedora $image_ver" >&2; exit 1; }
echo "initrd matches the image: Fedora ${initrd_ver:-?}, systemd $initrd_systemd, kernel $kver"

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
[[ -n ${SELINUX_ENFORCING:-} ]] && args+=(--build-arg "SELINUX_ENFORCING=$SELINUX_ENFORCING")
build --build-arg "COMPOSEFS_DIGEST=$digest" --secret "id=pcrkey,src=$PCR_PRIVATE_KEY" --secret "id=pcrpub,src=$PCR_PUBLIC_KEY" -t "$IMAGE"

# The UKI is only bootable if the final image still measures the same.
final=$(composefs_digest "$IMAGE")
if [[ $final != "$digest" ]]; then
  echo "error: final image digest $final != UKI digest $digest" >&2
  exit 1
fi

echo "built $IMAGE"
[[ ${1:-} == push ]] && podman push "$IMAGE"
exit 0
