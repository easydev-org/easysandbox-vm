#!/usr/bin/env bash
# Build + push the easysandbox-vm image (a Linux desktop in a QEMU guest).
#
#   ./build.sh
#
# The guest disk is NOT built here: it is the pre-baked golden qcow2 published
# by bake/ (see bake/README.md). This image only carries the QEMU runtime, the
# nginx that serves the guest its binaries, and the URL of that golden disk.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REGISTRY="${REGISTRY:-artifact.worker.svc.cluster.local}"
NAMESPACE="${NAMESPACE:-sandbox}"
NAME="${NAME:-sandbox-linux-vm}"
TAG="${TAG:-debian-trixie}"
DEST="${REGISTRY}/${NAMESPACE}/${NAME}:${TAG}"
BUILDKIT="${BUILDKIT_ADDR:-tcp://buildkitd.worker.svc.cluster.local:1234}"
PROXY="${PROXY:-http://mihomo.develop.svc.cluster.local:7890}"
NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,.svc,.svc.cluster.local,.cluster.local,artifact.worker.svc.cluster.local,buildkitd.worker.svc.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}"
export NO_PROXY no_proxy="${no_proxy:-$NO_PROXY}"

WORKER_VERSION="${WORKER_VERSION:-v0.3.0}"
EASYSTREAM_VERSION="${EASYSTREAM_VERSION:-v0.6.0}"
# The golden disk published by bake/ (anonymous read).
# The golden disk is NOT shipped in the image (the image only carries the
# runtime + oem.sh; the disk is downloaded on first boot). Its URL therefore
# decides WHICH DESKTOP the sandbox runs, and the artifact store has ONE
# `desktop.qcow2` per version — no gnome/kde subdirectories. Verified by
# booting each and checking the session:
#
#   v17 -> GNOME 49   (gnome-shell, /usr/share/wayland-sessions/gnome*.desktop)
#   v23 -> KDE Plasma (plasmashell, kwin_wayland, plasma.desktop)
#   v27 -> KDE Plasma (same as v23)
#
# v1 (the old default) is a 2026-early image with neither desktop installed,
# so it boots to a text console. Pick a version deliberately.
GOLDEN_DISK_VERSION="${GOLDEN_DISK_VERSION:-27}"
GOLDEN_DISK_URL="${GOLDEN_DISK_URL:-http://artifact.worker.svc.cluster.local/artifacts/generic/golden-linux-desktop/v${GOLDEN_DISK_VERSION}/desktop.qcow2}"

BUILDCTL="${BUILDCTL:-$(command -v buildctl || echo /opt/tools/mise/installs/aqua-moby-buildkit/0.32.2/bin/buildctl)}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cp "${DIR}/Containerfile" "${WORK}/Dockerfile"
# Bust the COPY layers: buildkit reuses them even when the source files
# change, which shipped a stale 00-token.conf (no /oem.sh route).
ENTRY_HASH="$( { cat "${DIR}/Containerfile" "${DIR}/00-token.conf" "${DIR}/oem.sh" "${DIR}/start.sh" "${DIR}/golden-disk.sh"; find "${DIR}/vendor" -type f -exec cat {} +; } | sha256sum | cut -c1-16)"
cp "${DIR}/start.sh" "${DIR}/golden-disk.sh" "${DIR}/00-token.conf" "${DIR}/oem.sh" "${WORK}/"
cp -a "${DIR}/vendor" "${WORK}/vendor"

echo "Building ${NAME}:${TAG} (buildkitd=${BUILDKIT})"
"${BUILDCTL}" --addr "${BUILDKIT}" build \
  --frontend dockerfile.v0 \
  --local "context=${WORK}" \
  --local "dockerfile=${WORK}" \
  --opt "filename=Dockerfile" \
  --opt "build-arg:ENTRY_HASH=${ENTRY_HASH}" \
  --opt "build-arg:WORKER_VERSION=${WORKER_VERSION}" \
  --opt "build-arg:EASYSTREAM_VERSION=${EASYSTREAM_VERSION}" \
  --opt "build-arg:RELEASE_PROXY=${PROXY}" \
  --opt "build-arg:RELEASE_CACHEBUST=$(date +%s)" \
  --opt "build-arg:GOLDEN_DISK_URL=${GOLDEN_DISK_URL}" \
  --opt "build-arg:HTTP_PROXY=${PROXY}" \
  --opt "build-arg:HTTPS_PROXY=${PROXY}" \
  --opt "build-arg:NO_PROXY=${NO_PROXY}" \
  --output "type=image,name=${DEST},push=true,registry.insecure=true,compression=zstd" \
  --progress plain

echo "Pushing to ${DEST}"
echo "pushed by buildctl: ${DEST}"
