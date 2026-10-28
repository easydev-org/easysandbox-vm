#!/usr/bin/env bash
# Bake an Arch desktop disk with pacstrap, driven over the serial console.
#
# The Arch ISO ships no desktop and no installer that needs a GUI: archiso puts a
# root shell on ttyS0, `pacstrap` takes a package list, and the list names the
# desktop. That is the whole method.
#
# TWO THINGS ABOUT THE BOOT THAT ARE NOT OBVIOUS
#
# 1. The ISO is booted as a CD, not with -kernel/-initrd. archiso's initramfs is
#    large enough to matter and qemu's -initrd path caps around 134 MB - the
#    EndeavourOS bake hit exactly this:
#
#      qemu: initrd is too large, cannot support.(max: 134053887, need 246610177)
#
# 2. archiso's own GRUB already enables the serial console
#    (terminal_input --append serial), so no console= needs to be typed at the boot
#    menu - unlike EndeavourOS, whose ISOLINUX menu needed a Tab and an edit.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/qemu-bake.sh
. "$HERE/../lib/qemu-bake.sh"

OUT="${OUT:?set OUT to the qcow2 to produce}"
DESKTOP="${DESKTOP:-kde}"
ARCH_VERSION="${ARCH_VERSION:-2026.10.01}"
ARCH_MIRROR="${ARCH_MIRROR:-https://geo.mirror.pkgbuild.com}"
ISO_URL="${ISO_URL:-${ARCH_MIRROR}/iso/${ARCH_VERSION}/archlinux-${ARCH_VERSION}-x86_64.iso}"
DISK_SIZE="${DISK_SIZE:-24G}"
QEMU_MAX="${QEMU_MAX:-3600}"
# 6144, and it is not a preference: without -m qemu starts with 128 MB and a large
# initramfs cannot be loaded. The EndeavourOS bake spent a round on
# "initramfs: Bad file number" because of exactly this.
QEMU_SMP="${QEMU_SMP:-4}"
QEMU_MEM="${QEMU_MEM:-6144}"

WORK="$(dirname "$OUT")"
mkdir -p "$WORK" && cd "$WORK"

echo "=== ISO ==="
ISO="$(basename "$ISO_URL")"
[ -s "$ISO" ] || curl -fsSL --retry 3 --retry-delay 2 -o "$ISO" "$ISO_URL"
ls -la "$ISO"

echo "=== install disk ==="
qemu-img create -f qcow2 disk.qcow2 "$DISK_SIZE" > /dev/null
ls -la disk.qcow2

echo "=== serve the install script ==="
rm -rf srv && mkdir -p srv
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
  # archiso autologins root on tty1 but ttyS0 gets a login prompt, and boot takes a
  # few minutes. Sending root repeatedly is harmless at a shell prompt and is what
  # makes a slow boot work without knowing how slow: the EndeavourOS bake slept a
  # fixed 122 seconds, typed into a kernel that was still starting, and sat at the
  # login prompt until the watchdog killed it.
  for _ in $(seq 1 14); do
    printf 'root\n'
    sleep 2
    printf '\n'
    sleep 13
  done

  printf 'echo PACSTRAP_BEGIN; id; ls /dev/vda\n'; sleep 3
  printf 'F="curl -fsS -o"; command -v curl >/dev/null || F="wget -qO"; '
  printf '$F /root/pacstrap.sh http://10.0.2.2:8000/pacstrap.sh || echo FETCH_FAIL\n'
  sleep 5
  printf 'chmod +x /root/pacstrap.sh; ls -la /root/pacstrap.sh\n'; sleep 3
  printf 'DESKTOP=%s HOSTNAME_TARGET=arch-sandbox sh /root/pacstrap.sh 2>&1; echo PACSTRAP_RC=$?; sync; poweroff -f\n' "$DESKTOP"
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
  if [ -n "$first" ]; then
    sed -n "$((first>20?first-20:1)),$((first+40))p" console.log >&2
  else
    tail -60 console.log >&2
  fi
  exit 1
fi

echo "=== the disk ==="
qemu-img info disk.qcow2
# Refuse to call an empty disk a bake: the Calamares attempts reported success with
# 196 KiB images containing nothing.
DISK_BYTES=$(stat -c%s disk.qcow2)
echo "disk.qcow2 is ${DISK_BYTES} bytes"
if [ "$DISK_BYTES" -lt 1000000000 ]; then
  echo "=== THE DISK IS EMPTY (${DISK_BYTES} bytes) ===" >&2
  exit 1
fi

bake_compress_disk disk.qcow2 "$OUT"
echo "BAKED arch-$DESKTOP -> $OUT"
