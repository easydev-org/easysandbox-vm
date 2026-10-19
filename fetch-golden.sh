#!/usr/bin/env bash
# fetch-golden.sh — pull a golden Linux desktop disk from its ghcr.io image.
#
#   ./fetch-golden.sh gnome /storage/data.qcow2
#   ./fetch-golden.sh kde   /storage/data.qcow2
#
# Why ghcr: the disks are multi-GB and no single GitHub store fits them —
# Git LFS caps a file at 2 GiB (Free/Pro) / 5 GiB (Enterprise), release assets
# at 2 GiB, and an OCI layer at 10 GiB with a 10-minute upload timeout. These
# desktop disks are only ~3.1-3.6 GiB, so one layer each is enough (the
# windows/macos disks are 15/18 GiB and need 5 shards).
#
# Each image is a single zstd layer holding `disks/<name>`; this extracts it,
# verifies the whole-disk sha256, and writes the disk.
set -Eeuo pipefail

WHICH="${1:?usage: $0 <gnome|kde> <out.qcow2>}"
OUT="${2:?usage: $0 <gnome|kde> <out.qcow2>}"
REPO=ghcr.io/silvermelon233/golden-linux-desktop

case "$WHICH" in
  gnome) TAG=linux-desktop-gnome-v17
         SHA=4edd9f6f8cf7c323938f454021610ad0681ac73ff6bd14edf961b08c10bccdc6 ;;
  kde)   TAG=linux-desktop-kde-v27
         SHA=52ee2d8279c4e6802a9a0eb86ae0032f46874ccee306e3696b0b7ea2719b56cf ;;
  *) echo "unknown desktop: $WHICH (gnome|kde)" >&2; exit 2 ;;
esac

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
echo "pulling $REPO:$TAG"
# The packages are private today; log in first (skopeo login ghcr.io) or make
# them public in the package settings.
skopeo copy --src-tls-verify=false "docker://$REPO:$TAG" "dir:$WORK/d"

# The layer is the largest file in the dir (the config is a few hundred bytes).
BLOB=$(find "$WORK/d" -maxdepth 1 -type f -printf '%s %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
mkdir -p "$WORK/x"
# buildctl compressed the layer with zstd; `tar --zstd` needs the zstd binary.
tar --zstd -xf "$BLOB" -C "$WORK/x"
DISK=$(find "$WORK/x" -type f | head -1)

echo "verifying sha256 ..."
got=$(sha256sum "$DISK" | awk '{print $1}')
[ "$got" = "$SHA" ] || { echo "SHA256 MISMATCH: got $got want $SHA" >&2; exit 1; }
echo "sha256 ok"

mkdir -p "$(dirname "$OUT")"
mv -f "$DISK" "$OUT"
echo "wrote $OUT ($(stat -c%s "$OUT") bytes)"
