#!/usr/bin/env bash
# Bake MX Linux by driving its graphical installer with OCR and the pointer.
#
# WHY GUI, AFTER THE TUI WAS TRIED
#
# minstall --tui --auto --config runs, and then stops at 'Scanning disk drives...'
# and stays there. Its own log shows the same three commands looping:
#
#   Exec #29: lsblk -T -bJo TYPE,NAME,PATH,...
#   Exec #30: parted -lm
#   Exec #31: lsblk ... /dev/mapper/*
#
# A GPT label on the target fixed the first cause of that (parted cannot describe a
# disk with no partition table, so the drive list was empty), and it still stops.
# Fourteen minutes with log=119 lines unchanged. That is the end of what the TUI
# route can tell us from outside.
#
# The probe then established the two things the GUI route needs:
#
#   * with -display none -vga std the guest draws a real desktop - four screendumps
#     came back as 537 KB PNGs showing MX Welcome at 1280x800, with the pointer
#     visible where it had been moved;
#   * -device usb-tablet gives an ABSOLUTE pointer, which is what QMP's
#     input-send-event needs. Without it the events are relative and go nowhere -
#     dockur-macos measured that as 64 clicks with the pointer still in the corner.
#
# So this bakes the way dockur-macos installs macOS: read the screen with tesseract,
# click what it says.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib"

OUT="${OUT:?set OUT to the qcow2 to produce}"
MX_VERSION="${MX_VERSION:-25.3}"
MX_EDITION="${MX_EDITION:-Xfce}"
ISO_URL="${ISO_URL:-https://sourceforge.net/projects/mx-linux/files/Final/${MX_EDITION}/MX-${MX_VERSION}_${MX_EDITION}_x64.iso/download}"
DISK_SIZE="${DISK_SIZE:-24G}"
SCREEN_W="${SCREEN_W:-1280}"
SCREEN_H="${SCREEN_H:-800}"
DRIVE_SECONDS="${DRIVE_SECONDS:-1500}"

WORK="$(dirname "$OUT")"
mkdir -p "$WORK/frames" && cd "$WORK"
FRAMES="$WORK/frames"

log() { echo "[bake $(date -u +%H:%M:%S)] $*" | tee -a "$FRAMES/bake.log"; }

log "=== ISO ==="
ISO="$WORK/mx.iso"
# From ghcr, and only from ghcr.
#
# This bake used to spend fifty-six minutes on a stalled SourceForge redirect with one
# line in its log. publish-isos.yml fetches the image once, checks its byte count and
# ISO9660 signature, and pushes it; bake_fetch_iso pulls that. No fallback: a bake that
# quietly reaches a mirror is a bake whose cache failures nobody sees.
. "$HERE/../lib/iso.sh"
bake_fetch_iso "mx" "$ISO"
ls -la "$ISO"
[ "$(stat -c%s "$ISO")" -gt 500000000 ] || { log "ISO looks like a redirect page"; exit 2; }

log "=== kernel and initrd from /antiX/ ==="
rm -rf x && mkdir -p x
7z x -y -o"x" "$ISO" "antiX/vmlinuz" "antiX/initrd.gz" 2>&1 | tail -3
K=$(find "$PWD/x" -name 'vmlinuz*' -type f | head -1)
I=$(find "$PWD/x" -name 'initrd*' -type f | head -1)
log "kernel: $K"
log "initrd: $I ($(stat -c%s "$I") bytes)"

log "=== disk ==="
qemu-img create -f qcow2 disk.qcow2 "$DISK_SIZE" > /dev/null
ls -la disk.qcow2

log "=== qemu: display, absolute pointer, QMP ==="
# The desktop only appears after a login, and the only channel for typing it is the
# serial console - which is why -serial stdio with a fifo rather than a file. The
# probe did exactly this and reached a full MX Welcome window.
rm -f serial.in && mkfifo serial.in
{
  for _ in $(seq 1 12); do
    printf 'demo\n'; sleep 2; printf 'demo\n'; sleep 13
  done
  printf 'echo BAKE_LOGIN_OK $(id -u)\n'; sleep 3
  # minstall-launcher is what MX's own login banner tells a CLI user to run.
  printf 'echo demo | sudo -S nohup minstall-launcher > /tmp/launcher.out 2>&1 &\n'
  sleep 10
  printf 'echo LAUNCHER_STARTED; pgrep -a -f minstall | head -3\n'
  sleep 25
  printf 'echo demo | sudo -S tail -40 /var/log/minstall.log\n'; sleep 8
} > serial.in &
FEED=$!
QMP="$FRAMES/monitor.sock.qmp"
MON="$FRAMES/monitor.sock"
rm -f "$QMP" "$MON"

qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 8192 \
  -kernel "$K" -initrd "$I" \
  -append "console=ttyS0,115200n8 init=/lib/systemd/systemd" \
  -drive "file=$ISO,media=cdrom,readonly=on" \
  -drive "file=$WORK/disk.qcow2,if=virtio,format=qcow2" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -display none \
  -vga std \
  -device qemu-xhci,id=xhci \
  -device usb-tablet,bus=xhci.0 \
  -monitor "unix:$MON,server=on,wait=off" \
  -qmp "unix:$QMP,server=on,wait=off" \
  -serial stdio \
  < serial.in > console.log 2>&1 &
QPID=$!
log "qemu pid $QPID"

sleep 15
if ! kill -0 "$QPID" 2>/dev/null; then
  log "qemu died at startup:"
  tail -30 "$WORK/qemu.log" || true
  exit 1
fi

log "=== driving the installer ==="
set +e
timeout "$DRIVE_SECONDS" python3 "$HERE/drive-mx.py" "$QMP" "$FRAMES"
DRIVE_RC=$?
set -e
log "driver exit $DRIVE_RC"

log "=== the installer's own log, from the guest ==="
# minstall writes /var/log/minstall.log on the live system. Reaching it needs the
# serial console, which is still there underneath the GUI.
log "(the driver's frames are in $FRAMES)"

log "=== stopping qemu ==="
kill "$QPID" 2>/dev/null || true
sleep 5
kill -9 "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true

log "=== the disk ==="
qemu-img info disk.qcow2
DISK_BYTES=$(stat -c%s disk.qcow2)
log "disk.qcow2 is ${DISK_BYTES} bytes"
if [ "$DISK_BYTES" -lt 1000000000 ]; then
  log "=== THE DISK IS EMPTY (${DISK_BYTES} bytes) ==="
  exit 1
fi

bake_compress_disk() {
  qemu-img convert -O qcow2 -c -o compression_type=zstd "$1" "$2"
}
bake_compress_disk disk.qcow2 "$OUT"
log "BAKED mx -> $OUT"
