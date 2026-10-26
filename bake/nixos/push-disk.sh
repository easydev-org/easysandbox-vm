#!/usr/bin/env bash
# Publish a baked qcow2 as a ghcr image the VM image can pull.
#
# WHY THIS EXISTS
#
# The Containerfile expects GOLDEN_DISK_IMAGE to be an OCI image whose root holds
# the disk split into 1 GiB pieces named data.part000, data.part001, ... It then
# joins them with `cat /golden-ro/data.part*` inside the qemu stage.
#
# bake-nixos.yml built the disks and uploaded them as Actions artifacts, and the
# `publish` input described pushing them to the store - but nothing ever turned a
# qcow2 into that image, so the chain stopped one step short: the disks existed
# and no image could boot them.
#
#   ./push-disk.sh nixos-labwc.qcow2 ghcr.io/easydev-org/sandbox-disk-labwc:latest
#
# The pieces are 1 GiB each, not one big tar:
#   * registry layers are cheaper to resume and to cache in 1 GiB pieces;
#   * the join happens with `cat` in name order, so the names must sort.
set -euo pipefail

DISK="${1:?usage: $0 <disk.qcow2> <image-ref>}"
REF="${2:?usage: $0 <disk.qcow2> <image-ref>}"

[ -s "${DISK}" ] || { echo "no such disk: ${DISK}" >&2; exit 1; }

CHUNK=$(( 1024 * 1024 * 1024 ))
SIZE=$(stat -c%s "${DISK}")
echo "$(basename "${DISK}"): ${SIZE} bytes -> ${REF}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/ctx"

# Split. `split -b` names the pieces xaa, xab... so rename them to the sortable
# data.partNNN the join expects.
split -b "${CHUNK}" -d -a 3 "${DISK}" "${WORK}/ctx/data.part"
ls -l "${WORK}/ctx" | head

PARTS=$(ls "${WORK}/ctx" | wc -l)
echo "split into ${PARTS} pieces"

{
  echo "FROM scratch"
  for p in $(ls "${WORK}/ctx" | sort); do
    echo "COPY ${p} /"
  done
} > "${WORK}/ctx/Dockerfile"
cat "${WORK}/ctx/Dockerfile"

# sha256 of the source, recorded next to the image so a consumer can verify the
# join produced the file that was baked.
sha256sum "${DISK}" | awk '{print $1}' > "${WORK}/ctx/disk.sha256"
echo "COPY disk.sha256 /" >> "${WORK}/ctx/Dockerfile"

if command -v docker >/dev/null 2>&1; then
  docker build -t "${REF}" -f "${WORK}/ctx/Dockerfile" "${WORK}/ctx"
  docker push "${REF}"
elif command -v buildctl >/dev/null 2>&1; then
  buildctl build \
    --frontend dockerfile.v0 \
    --local "context=${WORK}/ctx" \
    --local "dockerfile=${WORK}/ctx" \
    --output "type=image,name=${REF},push=true"
else
  echo "need docker or buildctl to publish ${REF}" >&2
  exit 1
fi

echo "published ${REF}"
