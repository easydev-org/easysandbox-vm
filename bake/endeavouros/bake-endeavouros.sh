#!/usr/bin/env bash
# Build an EndeavourOS desktop disk with pacstrap, driven over the serial console.
#
# WHY PACSTRAP AND NOT CALAMARES
#
# EndeavourOS ships Calamares and nothing else. Calamares has no unattended mode:
# no profile format, no command-line switch, only its window. Five rounds went into
# driving that window - initrd too large for -kernel, Escape closing the Welcome
# dialog, a 640x480 framebuffer, and a button 39 pixels from the one being aimed
# at - and not one of them installed anything.
#
# pacstrap is what Calamares itself calls to do the work, it is on the live ISO, and
# it is scriptable. The package list is the ISO's own packages.x86_64: the same
# repositories, the same packages, the same kernel. What comes out is an
# EndeavourOS system; what it is not, is the installer's own bookkeeping.
#
# WHY THE ISO IS BOOTED AS A CD
#
#   qemu: initrd is too large, cannot support.(max: 134053887, need 246610177)
#
# EndeavourOS's initramfs is 246 MB and qemu's -initrd path caps near 134 MB. This
# is archiso-wide. Booting the CD hands the initrd to the kernel through ISOLINUX,
# where no limit applies. The serial console is archiso's own - it puts ttyS0 up
# by itself, which is all this script needs.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/qemu-bake.sh
. "$HERE/../lib/qemu-bake.sh"

OUT="${OUT:?set OUT to the qcow2 to produce}"
ENDEAVOUROS_VERSION="${ENDEAVOUROS_VERSION:-2026.08.15}"
ISO_URL="${ISO_URL:-https://mirrors.gigenet.com/endeavouros/iso/EndeavourOS_Titan-Nova-${ENDEAVOUROS_VERSION}.iso}"
DISK_SIZE="${DISK_SIZE:-24G}"
QEMU_MAX="${QEMU_MAX:-3600}"
# 6144, and it is not a preference.
#
# Without -m, qemu starts with 128 MB. The probe ran with 6144 and booted fine; the
# first bake of this shape ran without it and ISOLINUX could not load the initramfs:
#
#   Loading /arch/boot/x86_64/vmlinuz-linux... ok
#   Loading /arch/boot/x86_64/initramfs-linux.img...failed: Bad file number
#
# 246 MB does not fit in 128 MB, and the error names a file rather than the memory,
# which is why it read as a corrupted ISO.
QEMU_SMP="${QEMU_SMP:-4}"
QEMU_MEM="${QEMU_MEM:-6144}"

WORK="$(dirname "$OUT")"
mkdir -p "$WORK" && cd "$WORK"

echo "=== ISO ==="
ISO="$(basename "$ISO_URL")"
[ -s "$ISO" ] || curl -fsSL --retry 3 --retry-delay 2 -o "$ISO" "$ISO_URL"
ls -la "$ISO"

echo "=== the package list, from the ISO's own archiso profile ==="
PACKAGES="$WORK/eos-packages.txt"
if [ ! -s "$PACKAGES" ]; then
  curl -fsSL --retry 3 -o "$PACKAGES" \
    "https://raw.githubusercontent.com/endeavouros-team/EndeavourOS-ISO/main/packages.x86_64" \
    || { echo "cannot fetch packages.x86_64" >&2; exit 2; }
fi
echo "package lines: $(grep -vc '^#\|^[[:space:]]*$' "$PACKAGES")"

echo "=== install disk ==="
qemu-img create -f qcow2 disk.qcow2 "$DISK_SIZE" > /dev/null
ls -la disk.qcow2

echo "=== serve the script and the list ==="
rm -rf srv && mkdir -p srv
cp "$PACKAGES" srv/eos-packages.txt
cp "$HERE/pacstrap.sh" srv/pacstrap.sh
( cd srv && exec python3 -m http.server 8000 --bind 0.0.0.0 ) > httpd.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 2
curl -fsS http://127.0.0.1:8000/pacstrap.sh > /dev/null || { echo "server down" >&2; exit 2; }
echo "server up"

echo "=== boot the ISO and run pacstrap over the serial console ==="
rm -f serial.in && mkfifo serial.in
{
  # 1. Get console=ttyS0 onto the kernel command line FIRST.
  #
  # Booting the CD works - ISOLINUX loads the 246 MB initramfs fine once qemu has
  # enough memory - but archiso then switches its output to tty1 and the serial
  # port goes quiet after 'Probing EDD':
  #
  #   Loading /arch/boot/x86_64/initramfs-linux.img...ok
  #   Probing EDD (edd=off to disable)... ock
  #   <nothing, until the stall watchdog killed it>
  #
  # The kernel command line belongs to the ISO on this path, so the only way to add
  # console=ttyS0 is at the boot menu: Tab opens the line for editing, the text is
  # appended, Enter boots it. That is a keyboard, but it is ONE keystroke at one
  # known place - the boot menu - not eight pages of a GUI installer.
  sleep 12
  # A literal Tab byte. printf '\t' in bash is a tab, but it is written as an
  # escape for clarity that it is one keystroke and not the word.
  printf '\011'
  sleep 2
  printf ' console=ttyS0,115200n8\n'
  sleep 3

  # 2. Then wait for the live shell.
  #
  # archiso autologins liveuser on tty1 while ttyS0 gets a login prompt - the same
  # split that cost a round on CachyOS. root has no password there.
  sleep 110
  printf 'root\n'; sleep 3
  printf '\n'; sleep 5
  printf 'echo PACSTRAP_BEGIN; id; ls /dev/vda\n'; sleep 3
  printf 'F="curl -fsS -o"; command -v curl >/dev/null || F="wget -qO"; '
  printf '$F /root/pacstrap.sh http://10.0.2.2:8000/pacstrap.sh && $F /root/eos-packages.txt http://10.0.2.2:8000/eos-packages.txt || echo FETCH_FAIL\n'
  sleep 6
  printf 'chmod +x /root/pacstrap.sh; wc -l /root/eos-packages.txt\n'; sleep 3
  printf 'PKGLIST=/root/eos-packages.txt DESKTOP=kde sh /root/pacstrap.sh 2>&1; echo PACSTRAP_RC=$?; sync; poweroff -f\n'
} > serial.in &

BAKE_STDIN=serial.in QEMU_MAX="$QEMU_MAX" bake_qemu_install \
  -drive "file=$ISO,media=cdrom,readonly=on" \
  -drive "file=$WORK/disk.qcow2,if=virtio,format=qcow2" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -device "VGA,edid=on,xres=${SCREEN_W:-1280},yres=${SCREEN_H:-800}"

echo "=== result ==="
rc=$(grep -ao "PACSTRAP_RC=[0-9]*" console.log | tail -1 | cut -d= -f2)
echo "pacstrap exit status: ${rc:-<never returned>}"
if [ "${rc:-1}" != "0" ]; then
  echo "=== INSTALL FAILED (rc=${rc:-none}) ===" >&2
  first=$(grep -anE "PACSTRAP FAILED|error:|ERROR|failed" console.log | head -1 | cut -d: -f1 || true)
  if [ -n "$first" ]; then sed -n "$((first>10?first-10:1)),$((first+40))p" console.log >&2
  else tail -60 console.log >&2; fi
  exit 1
fi

echo "=== the disk ==="
qemu-img info disk.qcow2

# Refuse to call an empty disk a bake. The Calamares attempt reported "BAKED" and
# uploaded a 196 KiB qcow2 with nothing on it; this check is why that cannot happen
# again silently.
DISK_BYTES=$(stat -c%s disk.qcow2)
echo "disk.qcow2 is ${DISK_BYTES} bytes"
if [ "$DISK_BYTES" -lt 1000000000 ]; then
  echo "=== THE DISK IS EMPTY (${DISK_BYTES} bytes) ===" >&2
  exit 1
fi

bake_compress_disk disk.qcow2 "$OUT"
echo "BAKED endeavouros -> $OUT"
