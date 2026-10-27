#!/usr/bin/env bash
# Install an EndeavourOS desktop disk by driving Calamares with the keyboard.
#
# WHY THE KEYBOARD
#
# EndeavourOS ships Calamares and nothing else: packages.x86_64 has one installer
# line, 'calamares', and no archinstall. Calamares has no unattended mode - five
# command-line options, none of them automatic, and no 'automatic' or
# 'noninteractive' key anywhere in its settings schema. There is no profile to
# write. The keyboard is the interface.
#
# WHAT THE PROBE ESTABLISHED
#
# probe-calamares.yml booted the ISO and photographed it four times:
#
#   60s   tty1, liveuser auto-logged-in, "will now launch"
#   120s  KDE desktop with the EndeavourOS Welcome window
#   180s  the same, stable
#   240s  the same
#
# and the Welcome window is the first obstacle: Calamares does not start by
# itself, it starts when someone presses "Start the Installer".
#
# WHY THE ISO IS BOOTED AS A CD
#
# The bake cannot use -kernel/-initrd the way the CachyOS one does:
#
#   qemu: initrd is too large, cannot support.(max: 134053887, need 246610177)
#
# EndeavourOS's initramfs is 246 MB and qemu's -initrd path caps near 134 MB. An
# archiso-wide problem, not this image's. Booting the CD hands the initrd to the
# kernel through ISOLINK, where there is no limit - at the price of not being able
# to add console=ttyS0. That price matters less than it sounds: everything here is
# driven and judged through the framebuffer, which is what a keyboard automation
# has to look at anyway.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUT="${OUT:?set OUT to the qcow2 to produce}"
ENDEAVOUROS_VERSION="${ENDEAVOUROS_VERSION:-2026.08.15}"
ISO_URL="${ISO_URL:-https://mirrors.gigenet.com/endeavouros/iso/EndeavourOS_Titan-Nova-${ENDEAVOUROS_VERSION}.iso}"
DISK_SIZE="${DISK_SIZE:-24G}"

WORK="$(dirname "$OUT")"
mkdir -p "$WORK" && cd "$WORK"

echo "=== ISO ==="
ISO="$(basename "$ISO_URL")"
[ -s "$ISO" ] || curl -fsSL --retry 3 --retry-delay 2 -o "$ISO" "$ISO_URL"
ls -la "$ISO"

echo "=== install disk ==="
qemu-img create -f qcow2 disk.qcow2 "$DISK_SIZE" > /dev/null
ls -la disk.qcow2

echo "=== boot, and drive the installer ==="
# One process owns qemu; one owns the keyboard and the camera. They talk through
# the monitor socket, which is the only channel that survives -nographic being
# unavailable here.
MON="$WORK/mon.sock"
rm -f "$MON"

qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 6144 \
  -drive "file=$ISO,media=cdrom,readonly=on" \
  -drive "file=$WORK/disk.qcow2,if=virtio,format=qcow2" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -display none \
  -monitor "unix:$MON,server=on,wait=off" \
  -serial "file:$WORK/console.log" \
  > "$WORK/qemu.log" 2>&1 &
QEMU_PID=$!
echo "qemu pid $QEMU_PID"

python3 "$HERE/drive-calamares.py" "$MON" "$WORK" || {
  echo "the keyboard driver failed" >&2
  kill "$QEMU_PID" 2>/dev/null || true
  exit 1
}

echo "=== the installer finished; waiting for it to power off ==="
for _ in $(seq 1 120); do
  kill -0 "$QEMU_PID" 2>/dev/null || break
  sleep 10
done
kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true

echo "=== what the installer said ==="
if [ -f "$WORK/installer.log" ]; then
  tail -60 "$WORK/installer.log"
fi

echo "=== the disk ==="
qemu-img info disk.qcow2
# Same shape as bake_compress_disk in the lib, inlined because this script does
# not source it: the lib's bake_qemu_install asserts -nographic and this bake
# cannot use it.
qemu-img convert -O qcow2 -c -o compression_type=zstd disk.qcow2 "$OUT"
ls -la "$OUT"
echo "BAKED endeavouros -> $OUT"
