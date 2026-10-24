#!/usr/bin/env bash
# Bake a CLEAN macOS golden disk by running dockur/macos, then extract the disk.
#
# Same division of labour as bake-windows.sh: dockur PRODUCES, easysandbox
# CONSUMES. Nothing here drives the macOS installer.
#
# WHAT IS DIFFERENT FROM WINDOWS, and why this script does not look like it:
#
#  * No boot marker on the host. Windows leaves /boot behind
#    (install.sh createMarker). macOS keeps its progress inside the guest, at
#    /Volumes/installstate/bootstrap.done - a path the host cannot see. So the
#    completion signal has to come from the container log
#    ("[log] unattended bootstrap installed successfully") plus the fact that a
#    disk file has grown to a plausible size.
#
#  * The disk lives under a version subdirectory: install.sh does
#    STORAGE="/" when the primary disk is absent, so the
#    result is /storage/<version>/<something>.qcow2, not /storage/data.qcow2.
#
#  * x86_64 ONLY. dockur/macos pins qemu-system-x86_64 and its OpenCore tree
#    ships X64/EFI only; there is no ARM64 variant to pick. ARM macOS needs
#    Apple Virtualization.framework on Apple hardware, which a Linux runner is
#    not. ARCH is accepted so a caller can ask, but asking for arm64 fails
#    loudly here rather than producing something that cannot boot.
set -Eeuo pipefail

VERSION="${VERSION:-14}"
ARCH="${ARCH:-x64}"
DISK_SIZE="${DISK_SIZE:-96G}"
RAM="${RAM:-8G}"
CPUS="${CPUS:-4}"
STORAGE="${STORAGE:?set STORAGE}"
OUT="${OUT:?set OUT}"
WAIT="${WAIT:-7200}"
NAME="macbake-$$"

case "$ARCH" in
  x64|x86_64|amd64) ;;
  *)
    echo "macOS on $ARCH is not possible here: dockur/macos is x86_64 only"
    echo "(qemu-system-x86_64 + X64/EFI OpenCore). ARM guests need Apple"
    echo "Virtualization.framework on Apple hardware."
    exit 3 ;;
esac

echo "=== macos $VERSION ($ARCH) -> $OUT ==="
mkdir -p "$STORAGE" "$(dirname "$OUT")"
[ -e /dev/kvm ] || { echo "NO /dev/kvm"; exit 2; }
case "$(uname -m)" in
  x86_64|amd64) ;;
  *) echo "host is $(uname -m); dockur/macos needs an x86_64 host"; exit 3 ;;
esac

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "=== starting dockur/macos ==="
docker run -d --name "$NAME" \
  --device=/dev/kvm \
  -e "VERSION=$VERSION" \
  -e "DISK_SIZE=$DISK_SIZE" \
  -e "RAM_SIZE=$RAM" \
  -e "CPU_CORES=$CPUS" \
  -v "$STORAGE:/storage" \
  dockurr/macos > /dev/null

echo "=== waiting for the unattended install ==="
# 1 GiB is the bar for "a disk exists and has been written to"; a fresh qcow2
# is a few hundred KB. Size alone is not proof of a finished install, which is
# why the log line below is also required.
deadline=$(( SECONDS + WAIT ))
done_msg=0
while (( SECONDS < deadline )); do
  if docker logs "$NAME" 2>&1 | grep -q "unattended bootstrap installed successfully"; then
    done_msg=1
    echo "installer reported success after ${SECONDS}s"
    break
  fi
  if ! docker ps --format "{{.Names}}" | grep -qx "$NAME"; then
    echo "container exited before reporting success; log tail:"
    docker logs "$NAME" 2>&1 | tail -40 || true
    exit 1
  fi
  sleep 30
done
if [ "$done_msg" -ne 1 ]; then
  echo "TIMEOUT waiting for the install"; docker logs "$NAME" 2>&1 | tail -60 || true; exit 1
fi

echo "=== stopping the guest ==="
docker stop -t 240 "$NAME" >/dev/null 2>&1 || true

echo "=== locating the disk under $STORAGE ==="
SRC=""
while IFS= read -r f; do
  sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
  if [ "$sz" -gt $((1024*1024*1024)) ]; then SRC="$f"; break; fi
done < <(find "$STORAGE" -name "*.qcow2" -type f 2>/dev/null)
[ -n "$SRC" ] || { echo "no qcow2 larger than 1 GiB under $STORAGE:"; find "$STORAGE" -maxdepth 2 -type f | head; exit 1; }
echo "using $SRC"
ls -la "$SRC"

qemu-img convert -O qcow2 "$SRC" "$OUT"
qemu-img info "$OUT" | head -6
echo "BAKED macos $VERSION ($ARCH) -> $OUT"
