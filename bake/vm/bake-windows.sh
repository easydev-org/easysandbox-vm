#!/usr/bin/env bash
# Bake a CLEAN Windows golden disk by running dockur/windows, then extract the
# disk it produced.
#
# Division of labour, deliberately:
#
#   dockur/windows  -> PRODUCES the disk. It is a complete QEMU guest with
#                      unattended installation wired in (answer.sh rewrites the
#                      autounattend XML per version), so nothing here has to
#                      drive a Windows installer by hand.
#   easysandbox     -> CONSUMES it, and stays that way. Its Containerfile takes
#                      GOLDEN_DISK_IMAGE and boots an overlay; it should never
#                      grow a second, divergent install path.
#
# This script only shepherds: start the container, wait for the boot marker,
# copy the qcow2 out, stop the container.
#
# WHAT "DONE" MEANS. Not a timer. dockur creates /boot only after the
# installation has completed (install.sh createMarker "boot"), and it is what
# stops the same container re-installing on the next start. Polling for that
# file is the only signal that means "installed" rather than "has been running
# for a while".
set -Eeuo pipefail

VERSION="${VERSION:-11}"
ARCH="${ARCH:-x64}"
DISK_SIZE="${DISK_SIZE:-64G}"
RAM="${RAM:-4G}"
CPUS="${CPUS:-4}"
STORAGE="${STORAGE:?set STORAGE to the host path mounted at /storage}"
OUT="${OUT:?set OUT to the qcow2 path to write}"
# A first install pulls an ISO and runs Setup; 60 minutes is generous but the
# timeout must exist or a stuck install burns the whole job budget.
WAIT="${WAIT:-5400}"
NAME="winbake-$ARCH-$$"

echo "=== windows $VERSION ($ARCH) -> $OUT ==="
mkdir -p "$STORAGE" "$(dirname "$OUT")"

# KVM is not optional: without it the guest falls back to TCG and a Windows
# install goes from tens of minutes to many hours, which is worse than failing.
[ -e /dev/kvm ] || { echo "NO /dev/kvm"; exit 2; }

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# dockurr/windows is a multi-arch image and picks its variant from the host:
#
#   x86_64 host -> build-amd64 -> qemux/qemu-windows qemu-system-x86_64,
#                  installing an x86_64 Windows guest, natively accelerated.
#   arm64 host  -> build-arm64 -> dockurr/windows-arm, which carries its own
#                  aarch64 QEMU and installs ARM64 Windows, also natively.
#
# So "both architectures" means running the SAME workflow on an x86_64 runner
# and on an arm64 runner. There is no emulation and nothing to configure here;
# passing --platform would defeat it, so do not.
#
# There is no AUTO_UNATTEND knob: unattended installation is the default and
# MANUAL is the escape hatch, forced on only when an answer file is genuinely
# missing (install.sh setXML). Inventing a variable would have been ignored.
echo "=== starting dockur/windows (host arch $(uname -m)) ==="
docker run -d --name "$NAME" \
  --device=/dev/kvm \
  -e "VERSION=$VERSION" \
  -e "DISK_SIZE=$DISK_SIZE" \
  -e "RAM_SIZE=$RAM" \
  -e "CPU_CORES=$CPUS" \
  -v "$STORAGE:/storage" \
  dockurr/windows > /dev/null

echo "=== waiting for the install to finish (boot marker) ==="
deadline=$(( SECONDS + WAIT ))
while (( SECONDS < deadline )); do
  if [ -f "$STORAGE/boot" ]; then
    echo "boot marker present after ${SECONDS}s"
    break
  fi
  if ! docker ps --format "{{.Names}}" | grep -qx "$NAME"; then
    echo "container exited before the marker appeared; log tail:"
    docker logs "$NAME" 2>&1 | tail -40 || true
    exit 1
  fi
  sleep 20
done
[ -f "$STORAGE/boot" ] || { echo "TIMEOUT waiting for the boot marker"; docker logs "$NAME" 2>&1 | tail -40 || true; exit 1; }

# Ask the guest to power off so the filesystem is consistent; the qcow2 is
# then safe to copy.
echo "=== stopping the guest ==="
docker stop -t 180 "$NAME" >/dev/null 2>&1 || true

shopt -s nullglob
cands=("$STORAGE"/data.qcow2 "$STORAGE"/*.qcow2)
[ ${#cands[@]} -gt 0 ] || { echo "no qcow2 under $STORAGE:"; ls -la "$STORAGE"; exit 1; }
SRC="${cands[0]}"
echo "=== extracting $SRC ==="
ls -la "$SRC"
# Convert, so the output is a standalone qcow2 no matter what dockur used.
qemu-img convert -O qcow2 "$SRC" "$OUT"
qemu-img info "$OUT" | head -6
echo "BAKED windows $VERSION ($ARCH) -> $OUT"
