#!/usr/bin/env bash
# Bake an MX Linux desktop disk with its own installer in unattended mode.
#
# WHY THIS ONE IS EASY, AFTER ENDEAVOURS WAS NOT
#
# MX ships gazelle-installer (minstall), and its manpage documents exactly what
# this bake needs:
#
#   --auto           Install automatically using the configuration file
#   -c, --config <f> Load a configuration file
#   -f, --poweroff   Shut down automatically when done
#   --tui            Text interface (ncurses)
#
# and app.cpp checks for --tui BEFORE constructing a QApplication, so nothing here
# needs a display server. It runs on the serial console, which is where the harness
# reads and writes.
#
# That is the difference from Calamares, which took five rounds and installed
# nothing: no configuration file, no command-line switch, only a window.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/qemu-bake.sh
. "$HERE/../lib/qemu-bake.sh"

OUT="${OUT:?set OUT to the qcow2 to produce}"
MX_VERSION="${MX_VERSION:-25.3}"
MX_EDITION="${MX_EDITION:-Xfce}"
# The real name is MX-25.3_Xfce_x64.iso, from the release index at
# sourceforge.net/projects/mx-linux/files/Final/ - "MX-25.3 is the current release".
# SourceForge serves it through a redirect, so -L is required and the landed file
# has to be the 2.9 GB image rather than an HTML page; the size check below is what
# catches that.
#
# The two ISP mirrors tried first both 404 on this path, so the download goes
# through SourceForge's redirect and the size check is the guard.
ISO_URL="${ISO_URL:-https://sourceforge.net/projects/mx-linux/files/Final/${MX_EDITION}/MX-${MX_VERSION}_${MX_EDITION}_x64.iso/download}"
DISK_SIZE="${DISK_SIZE:-24G}"
QEMU_MAX="${QEMU_MAX:-3600}"
# 6144: without -m qemu starts with 128 MB, and MX's initramfs would not load - the
# EndeavourOS bake reported that as "initramfs: Bad file number" for a whole round.
QEMU_SMP="${QEMU_SMP:-4}"
QEMU_MEM="${QEMU_MEM:-6144}"

WORK="$(dirname "$OUT")"
mkdir -p "$WORK" && cd "$WORK"

echo "=== ISO ==="
ISO="$WORK/mx.iso"
if [ ! -s "$ISO" ]; then
  # SourceForge redirects to a mirror; -L is required and the downloaded file has to
  # be an ISO rather than a HTML landing page, so the size is checked.
  curl -fsSL --retry 3 --retry-delay 2 -o "$ISO" "$ISO_URL"
fi
ls -la "$ISO"
if [ "$(stat -c%s "$ISO")" -lt 500000000 ]; then
  echo "the ISO is under 500 MB - that is a redirect page, not an image" >&2
  head -c 400 "$ISO" >&2
  exit 2
fi

echo "=== install disk ==="
qemu-img create -f qcow2 disk.qcow2 "$DISK_SIZE" > /dev/null
ls -la disk.qcow2

echo "=== serve the installer configuration ==="
rm -rf srv && mkdir -p srv
cp "$HERE/minstall.conf" srv/minstall.conf
( cd srv && exec python3 -m http.server 8000 --bind 0.0.0.0 ) > httpd.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 2
curl -fsS http://127.0.0.1:8000/minstall.conf > /dev/null || { echo "server down" >&2; exit 2; }
echo "server up"

echo "=== boot the live ISO and run the installer unattended ==="
rm -f serial.in && mkfifo serial.in
{
  # MX's live session autologins as demo on tty1; ttyS0 gets a login prompt. Sending
  # root repeatedly is harmless at a shell prompt and removes the guess about how
  # long boot takes - a fixed sleep typed into a kernel that was still starting, on
  # the EndeavourOS bake, and the run sat at the prompt until the watchdog killed it.
  for _ in $(seq 1 14); do
    printf 'root\n'
    sleep 2
    printf '\n'
    sleep 13
  done

  printf 'echo MX_BEGIN; id; ls /dev/vda; command -v minstall\n'; sleep 3
  printf 'F="curl -fsS -o"; command -v curl >/dev/null || F="wget -qO"; '
  printf '$F /root/minstall.conf http://10.0.2.2:8000/minstall.conf || echo FETCH_FAIL\n'
  sleep 4
  printf 'wc -l /root/minstall.conf\n'; sleep 2
  # --tui first, so no display server is wanted; --auto to accept the file;
  # --poweroff so qemu stops when the install ends.
  printf 'minstall --tui --auto --poweroff --config /root/minstall.conf 2>&1; echo MINSTALL_RC=$?\n'
} > serial.in &

BAKE_STDIN=serial.in QEMU_MAX="$QEMU_MAX" bake_qemu_install \
  -drive "file=$ISO,media=cdrom,readonly=on" \
  -drive "file=$WORK/disk.qcow2,if=virtio,format=qcow2" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -device "VGA,edid=on,xres=${SCREEN_W:-1280},yres=${SCREEN_H:-800}"

echo "=== result ==="
rc=$(grep -ao "MINSTALL_RC=[0-9]*" console.log | tail -1 | cut -d= -f2)
echo "minstall exit status: ${rc:-<never returned>}"

# The installer's own log is on the target as well; keep the live copy if it exists.
if grep -q "MINSTALL_RC=0" console.log; then
  echo "installer reported success"
else
  echo "=== INSTALL DID NOT REPORT SUCCESS (rc=${rc:-none}) ===" >&2
  first=$(grep -anE "error|ERROR|failed|Failed|cannot" console.log | head -1 | cut -d: -f1 || true)
  if [ -n "$first" ]; then
    sed -n "$((first>20?first-20:1)),$((first+50))p" console.log >&2
  else
    tail -70 console.log >&2
  fi
  exit 1
fi

echo "=== the disk ==="
qemu-img info disk.qcow2
DISK_BYTES=$(stat -c%s disk.qcow2)
echo "disk.qcow2 is ${DISK_BYTES} bytes"
if [ "$DISK_BYTES" -lt 1000000000 ]; then
  echo "=== THE DISK IS EMPTY (${DISK_BYTES} bytes) ===" >&2
  exit 1
fi

bake_compress_disk disk.qcow2 "$OUT"
echo "BAKED mx -> $OUT"
