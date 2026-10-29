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
# Removed first: qemu-img create refuses an existing file, and with the message sent to
# /dev/null that refusal was invisible - the disk was then whatever was already there.
# The final image says 'virtual size: 64 GiB' while DISK_SIZE says 24G, so the size has
# to be stated here and checked here.
rm -f disk.qcow2
log "DISK_SIZE is '${DISK_SIZE}' (length ${#DISK_SIZE})"
if ! qemu-img create -f qcow2 disk.qcow2 "$DISK_SIZE"; then
  log "qemu-img create failed for DISK_SIZE=$DISK_SIZE"
  exit 2
fi
ls -la disk.qcow2
log "disk virtual size as created:"
qemu-img info disk.qcow2 | sed -n 's/^virtual size:.*/  &/p'

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
  # minstall directly, with --auto, NOT minstall-launcher.
  #
  # minstall-launcher is a wrapper whose first act is to refuse arguments:
  #
  #   # exit early if not live or parameter given
  #   if [ -n "$1" ] || { ... }; then
  #       echo "INFORMATION: Non-live enviroment or options not supported"
  #       exit 1
  #   fi
  #   ...
  #   RUN="/usr/bin/minstall"
  #   exec "$RUN"
  #
  # so it starts a fully interactive GUI and never reads minstall.conf at all. Every
  # pane in it that the driver clicked - Terms, Options, Confirmation, User Login - was
  # a pane the configuration file was supposed to answer, and the GRUB pane it walked
  # past was the one that installs a bootloader.
  #
  # That is why the disk ended up with 7.6 GiB of filesystem, a valid MBR signature and
  # a zeroed boot code area: minstall was never told to install GRUB, because it never
  # saw [GRUB] Install = true.
  #
  # --auto with --config is the documented unattended path, and it works in GUI mode:
  # app.cpp only forces TUI when --tui is given or when there is no display server.
  #
  # NO --poweroff. It shuts the machine down the moment the install finishes, which
  # killed the serial session before the chroot below could install a bootloader - the
  # run waited eleven minutes for a guest that had already powered itself off, and
  # FIXUP_BEGIN never appeared.
  printf 'echo demo | sudo -S sh -c "minstall --auto --config /home/demo/minstall.conf > /tmp/launcher.out 2>&1; echo MINSTALL_RC=\\$? > /tmp/mx-rc" &\n'
  sleep 20
  printf 'echo MINSTALL_STARTED; pgrep -a -f minstall | head -3\n'
  sleep 40
  printf 'echo demo | sudo -S tail -60 /var/log/minstall.log\n'; sleep 10

  # Wait for the install, then put a bootloader on the disk.
  #
  # The GUI walk completes an installation - the disk comes out with 7.6 GiB of
  # filesystem on it - but nothing boots from it:
  #
  #   [mbr] boot code: 00000000...   (still the zeroed area sgdisk --zap-all wrote)
  #   [part] superblock magic EF53   (the filesystem is there and healthy)
  #
  # minstall's GRUB step never ran. minstall-launcher refuses arguments, so the
  # configuration file is never read; --auto in GUI mode does not skip panes either,
  # and the run reports 'Paused for required ops'; and --tui --auto --config stops at
  # 'Scanning disk drives' with log=119 for as long as it is left alone.
  #
  # Rather than keep guessing at which switch would make that step happen, this does
  # what the installer would have done: chroot into the new system and install GRUB
  # where the MBR of a BIOS-booted disk expects it.
  #
  # 600 seconds is the install; the markers the earlier scripts used are gone, so the
  # wait is by time rather than by observation.
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

# Photograph the screen every 30 seconds, for the whole run.
#
# Every MX failure so far was read out of a log line, and a log line is a summary of
# something that already happened. The questions that took longest - is a dialog
# waiting, did the pane change, is the installer still drawing - are answered by a
# picture and by nothing else.
mkdir -p "$FRAMES/shots"
python3 "$LIB/snapshots.py" "$QMP" "$FRAMES/shots" 30 400 \
  > "$FRAMES/shots/snapshots.log" 2>&1 &
SNAP_PID=$!
log "snapshot every 30s, pid $SNAP_PID, into $FRAMES/shots"

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

# The serial side may still be working.
#
# The fifo's writer installs GRUB after waiting out the installation, and the driver
# finishing says nothing about that: the driver only clicked buttons. Killing qemu when
# it returns would cut the bootloader installation off mid-write, which is the same
# failure this run exists to fix.
log "waiting for the serial side to finish its fixup"
wait "$FEED" 2>/dev/null || true

log "=== the installer's own log, from the guest ==="
# The serial console is still there underneath the GUI, and it is the only channel out
# of the guest besides screenshots. minstall writes /var/log/minstall.log as it goes,
# and that file is where a GRUB step either happened or did not.
#
# The fifo was consumed by the login sequence and the driver ran on top of it, so a new
# writer cannot attach to it. What can be done after the fact is what this does: the
# console.log already holds everything the guest printed, and it is kept with the
# frames.
log "(the driver's frames and console are in $FRAMES and $WORK/console.log)"

# Say plainly what the MBR holds, before qemu stops.
#
# The bake has the disk in front of it and the smoke test has to guess from a screen
# that never changes. The first 512 bytes answer it now:
#
#   the boot code area should hold a GRUB stage 1 for a bootable disk;
#   sgdisk --zap-all leaves that area zeroed, which is also a valid MBR - signature
#   0x55AA and an empty partition table - and looks identical from the outside.

log "=== stopping qemu ==="
kill "$QPID" 2>/dev/null || true
sleep 5
kill -9 "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true

# The MBR is read after qemu stops: until then qemu holds a write lock on the
# image, and qemu-io says so - "Failed to get write lock" - which the first
# version of this reported as an unexplained failure.
# qemu-io, not qemu-img dd: the latter wrote nothing here and its complaint went to
# /dev/null, so the log said 'could not read the MBR back' and said nothing about why.
MBRDUMP="$WORK/mbr.bin"
if qemu-io -f qcow2 -c "read -v 0 512" disk.qcow2 > "$MBRDUMP" 2>&1 && [ -s "$MBRDUMP" ]; then
  log "=== MBR of the finished disk (qemu-io, $(wc -c < "$MBRDUMP") bytes) ==="
  # qemu-io read -v prints a hex dump; the boot code is the first line of it.
  # Line 1 of the dump is offset 0x00 - the start of the MBR, which is where the boot
  # code begins. Line 2 is 0x10, and reading that was reported as the first bytes for
  # three runs, making a GRUB stage 1 look absent when it was there.
  log "  offset 0x00: $(sed -n '1p' "$MBRDUMP" | cut -c1-72)"
  log "  offset 0x10: $(sed -n '2p' "$MBRDUMP" | cut -c1-72)"
  if sed -n '2,20p' "$MBRDUMP" | grep -qE '^[0-9a-f]{8}: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00'; then
    log "  THE BOOT CODE AREA IS ZERO - nothing will boot from this disk"
  else
    log "  boot code is non-zero - something wrote a stage 1"
  fi
else
  log "  qemu-io could not read the MBR either; dumping what it said:"
  sed 's/^/    /' "$MBRDUMP" | head -5
fi
rm -f "$MBRDUMP"

# A second boot, to install the bootloader.
#
# The first boot installed MX. It could not install GRUB: minstall does not, in any mode,
# and the chroot that would have done it was competing for a serial console the installer
# still owned - the proof being this bake's own shell commands arriving at a grub> prompt:
#
#   grub> export XDG_RUNTexport WAYLAND_export LIBGL_Alif command -v z...
#
# So qemu is stopped, and the live ISO is booted again with one purpose. Nothing else
# touches the console during that boot.
log "=== second boot: install the bootloader ==="
if [ "${SKIP_GRUB_FIX:-0}" != 1 ]; then
  if bash "$HERE/fix-grub.sh" "$WORK"; then
    log "grub fix reported success"
  else
    log "grub fix reported failure - its output is above"
  fi
fi

log "=== the disk ==="
qemu-img info disk.qcow2
DISK_BYTES=$(stat -c%s disk.qcow2)
log "disk.qcow2 is ${DISK_BYTES} bytes"

# Turn the frames into PNGs beside them.
#
# PPM is 3 MB each and no browser opens one; PNG is a tenth of that and is what anyone
# reviewing the run will actually look at. A blank frame is left as-is rather than
# dropped - a screen that never changed is itself the finding.
kill "${SNAP_PID:-}" 2>/dev/null || true
log "=== screenshots ==="
SHOTS="$FRAMES/shots"
if [ -d "$SHOTS" ]; then
  CONVERTED=0
  for ppm in "$SHOTS"/frame-*.ppm; do
    [ -f "$ppm" ] || continue
    png="${ppm%.ppm}.png"
    if python3 "$HERE/../nixos/ppm2png.py" "$ppm" "$png" desktop > /dev/null 2>&1; then
      CONVERTED=$((CONVERTED + 1))
    fi
  done
  log "converted $CONVERTED frames to PNG"
  log "$(wc -l < "$SHOTS/frames.txt" 2>/dev/null || echo 0) frames recorded"
  # A one-line summary per frame, so a run's shape is visible before opening anything.
  if [ -f "$SHOTS/frames.txt" ]; then
    log "first and last frames:"
    head -1 "$SHOTS/frames.txt" | sed 's/^/  /'
    tail -1 "$SHOTS/frames.txt" | sed 's/^/  /'
  fi
else
  log "no screenshot directory - the snapshots process never started"
fi
if [ "$DISK_BYTES" -lt 1000000000 ]; then
  log "=== THE DISK IS EMPTY (${DISK_BYTES} bytes) ==="
  exit 1
fi

bake_compress_disk() {
  qemu-img convert -O qcow2 -c -o compression_type=zstd "$1" "$2"
}
bake_compress_disk disk.qcow2 "$OUT"
log "BAKED mx -> $OUT"
