#!/usr/bin/env bash
# Boot EndeavourOS and photograph Calamares, without trying to install anything.
#
# WHY A PROBE AND NOT A SCRIPT
#
# EndeavourOS ships Calamares and nothing else: no archinstall, no CLI installer.
# Calamares has no unattended mode - its command line has five options and none
# of them is 'automatic', and a source search for 'automatic', 'noninteractive'
# and 'skip' returns nothing. So the only way in is the keyboard, and the only way
# to drive a keyboard is to know what is on screen.
#
# So this boots the live ISO, waits, and takes a series of screenshots while
# sending nothing at all. What comes back says whether the installer even starts
# by itself, what its first page looks like, and whether the window is legible
# enough at 1280x800 for coordinates to mean anything.
#
# Everything it learns goes to console.log and to screenshots; it installs
# nothing.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/qemu-bake.sh
. "$HERE/../lib/qemu-bake.sh"

ENDEAVOUROS_VERSION="${ENDEAVOUROS_VERSION:-2026.08.15}"
ISO_URL="${ISO_URL:-https://mirrors.gigenet.com/endeavouros/iso/EndeavourOS_Titan-Nova-${ENDEAVOUROS_VERSION}.iso}"
OUTDIR="${OUTDIR:-$PWD}"
mkdir -p "$OUTDIR" && cd "$OUTDIR"

echo "=== ISO ==="
ISO="$(basename "$ISO_URL")"
[ -s "$ISO" ] || curl -fsSL --retry 3 --retry-delay 2 -o "$ISO" "$ISO_URL"
ls -la "$ISO"

echo "=== kernel and initrd ==="
rm -rf x && mkdir -p x
7z x -y -o"x" "$ISO" "arch/boot/x86_64/vmlinuz-linux" \
                     "arch/boot/x86_64/initramfs-linux.img" > /dev/null 2>&1 || true
K=$(find "$PWD/x/arch/boot/x86_64" -name 'vmlinuz*' -type f 2>/dev/null | head -1)
I=$(find "$PWD/x/arch/boot/x86_64" -name 'initramfs*' -type f 2>/dev/null | head -1)
if [ -z "${K:-}" ] || [ -z "${I:-}" ]; then
  7z x -y -o"x" "$ISO" "arch/boot/*" > /dev/null 2>&1 || true
  K=$(find "$PWD/x" -name 'vmlinuz*' -type f | head -1)
  I=$(find "$PWD/x" -name 'initramfs*' -type f | head -1)
fi
[ -s "${K:-}" ] && [ -s "${I:-}" ] || { echo "PAIR_FAIL" >&2; exit 2; }
ls -la "$K" "$I"

echo "=== archiso boot parameters ==="
for p in "boot/grub" "loader" "syslinux" "boot/syslinux"; do
  7z x -y -o"x" "$ISO" "$p" > /dev/null 2>&1 || true
done
FOUND=$(find "$PWD/x" -type f \( -name '*.cfg' -o -name '*.conf' \) 2>/dev/null || true)
ARCHISO_LINE=""
if [ -n "$FOUND" ]; then
  ARCHISO_LINE=$(cat $FOUND 2>/dev/null \
    | grep -oE "archisobasedir=[^ ]+|archisolabel=[^ \"']+" \
    | sort -u | tr '\n' ' ' || true)
fi
if ! echo "$ARCHISO_LINE" | grep -q 'archisolabel='; then
  VOLID=$(python3 - "$ISO" <<'PY'
import sys
with open(sys.argv[1], "rb") as f:
    f.seek(16 * 2048)
    pvd = f.read(2048)
if pvd[0] != 1 or pvd[1:6] != b"CD001":
    sys.exit(1)
print(pvd[40:72].decode("ascii", "replace").rstrip())
PY
  ) || { echo "cannot read volume label" >&2; exit 2; }
  echo "volume label: $VOLID"
  ARCHISO_LINE="archisobasedir=arch archisolabel=${VOLID} ${ARCHISO_LINE}"
fi
echo "kernel arguments: ${ARCHISO_LINE}"

qemu-img create -f qcow2 disk.qcow2 24G > /dev/null

# The live ISO autologins liveuser on the GRAPHICAL console, so nothing is typed
# on ttyS0. This probe sends nothing and simply watches: what matters is whether
# Calamares starts by itself, and what the first page looks like.
echo "=== boot and photograph, twice ==="
rm -f serial.in && mkfifo serial.in
{
  # Hold the fifo open; the probe sends no keys.
  sleep 900
} > serial.in &
HOLD=$!

# The monitor is a socket so the host can ask for screendumps while qemu runs.
MON="$PWD/mon.sock"
rm -f "$MON"

BAKE_NO_NGRAPHIC=1 BAKE_STDIN=serial.in QEMU_MAX="${QEMU_MAX:-420}" bake_qemu_install \
  -kernel "$K" -initrd "$I" -- \
  -append "${ARCHISO_LINE} console=ttyS0,115200n8 modprobe.blacklist=floppy" \
  -drive "file=$ISO,media=cdrom,readonly=on" \
  -drive "file=disk.qcow2,if=virtio,format=qcow2" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -serial stdio \
  -monitor "unix:$MON,server=on,wait=off" &
QEMU_BG=$!

# A unix socket, so it needs a socket client - a shell redirect writes a FIFO, not
# a connect().
python3 - "$MON" "$PWD" <<'PY'
import os, socket, sys, time

mon, outdir = sys.argv[1], sys.argv[2]
deadline = time.time() + 60
s = None
while time.time() < deadline:
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(mon)
        break
    except OSError:
        s = None
        time.sleep(1)
if s is None:
    sys.exit("monitor socket never appeared")

for at in (90, 150, 210, 270):
    time.sleep(60)
    s.sendall(f"screendump {outdir}/shot-{at:03d}.ppm\n".encode())
    time.sleep(1)
s.sendall(b"quit\n")
s.close()
PY

kill "$HOLD" 2>/dev/null || true
wait "$QEMU_BG" 2>/dev/null || true

echo "=== screenshots ==="
ls -la shot-*.ppm 2>/dev/null || echo "none"
for f in shot-*.ppm; do
  [ -f "$f" ] || continue
  python3 "$HERE/../nixos/ppm2png.py" "$f" "${f%.ppm}.png" desktop || true
done
ls -la shot-*.png 2>/dev/null || true
