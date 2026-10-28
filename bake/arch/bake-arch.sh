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

# Pull the kernel and initrd out, so the boot needs NO keyboard at all.
#
# The alternative - Tab at the ISOLINUX menu and append console=ttyS0 - was tried
# and it half-worked, which is worse than not working:
#
#   ...archisosearchuuid=2026-10-01-14-49-03-00 initrd=... console=ttyS0,root
#                                                                     ^^^^^^^^^^^
#   115200n8 was dropped, so the Return never took, and the next thing written to
#   the port (the word root, from the login loop) was appended to the kernel
#   command line.
#
# Passing -kernel/-initrd puts the command line under our control instead. qemu caps
# that path at about 134 MB, which archiso's initramfs has outgrown for some
# distributions - EndeavourOS needs 246 MB - so the size is checked and the menu
# route is kept as a fallback.
echo "=== kernel and initrd ==="
rm -rf x && mkdir -p x
# 7z's own output is kept, not discarded.
#
# The first attempt piped it to /dev/null and added "|| true", so when the
# extraction produced nothing there was no record of why - the same mistake that
# cost two rounds on the EndeavourOS bake with bootctl. If this fails again, the
# reason will be in the log.
echo "  extracting with 7z:"
7z x -y -o"x" "$ISO" "arch/boot/x86_64/vmlinuz-linux" \
                     "arch/boot/x86_64/initramfs-linux.img" 2>&1 | tail -12
echo "  extracted tree:"
find "$PWD/x" -type f 2>/dev/null | head -10 || echo "  (nothing)"
K=$(find "$PWD/x" -name 'vmlinuz*' -type f 2>/dev/null | head -1)
I=$(find "$PWD/x" -name 'initramfs*' -type f 2>/dev/null | head -1)
DIRECT_BOOT=0
if [ -n "${K:-}" ] && [ -s "${K:-}" ] && [ -n "${I:-}" ] && [ -s "${I:-}" ]; then
  K_SIZE=$(stat -c%s "$I")
  echo "kernel: $K"
  echo "initrd: $I ($K_SIZE bytes)"
  # 130 MiB, just under qemu's ~134 MB ceiling.
  if [ "$K_SIZE" -lt 136314880 ]; then
    DIRECT_BOOT=1
    echo "small enough for -kernel/-initrd: the boot needs no keystrokes"
  else
    echo "too large for -kernel/-initrd ($K_SIZE > 134 MB): falling back to the boot menu"
  fi
else
  echo "could not extract the pair: falling back to the boot menu"
fi

# The ISO9660 volume label, which archiso searches for when there is no UUID to
# match. Read from the primary volume descriptor rather than guessed.
VOLID=$(python3 - "$ISO" <<'PYVOL'
import sys
with open(sys.argv[1], "rb") as f:
    f.seek(16 * 2048)
    pvd = f.read(2048)
if pvd[0] != 1 or pvd[1:6] != b"CD001":
    sys.exit(1)
print(pvd[40:72].decode("ascii", "replace").rstrip())
PYVOL
) || VOLID=""
echo "volume label: ${VOLID:-<unreadable>}"

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
  # Two ways in, and the direct one is preferred.
  #
  # DIRECT_BOOT means the kernel and initrd were extracted and are passed with
  # -kernel/-initrd, so the kernel command line - console=ttyS0 included - is ours
  # and no key is ever pressed at a boot menu. That is what the menu route could not
  # do reliably: ISOLINUX's line editor dropped characters from a fast serial write
  # and produced
  #
  #   console=ttyS0,root
  #
  # with 115200n8 missing and the word root - from the login loop - glued on.
  if [ "${DIRECT_BOOT:-0}" != 1 ]; then
    # The fallback: Tab at the ISOLINUX menu, append, Return.
    #
    # archiso sets TIMEOUT 150, tenths of a second, so fifteen seconds; five seconds
    # in leaves plenty of margin. The characters are sent one at a time because the
    # line editor drops whatever arrives too fast - which is exactly how the first
    # attempt lost 115200n8.
    sleep 5
    printf '\011'
    sleep 2
    # The leading space matters: without it the parameter is glued to the last
    # token on the line, and the kernel sees an initrd path of
    # "...initramfs-linux.imgconsole=ttyS0". That is exactly what the previous
    # run produced.
    for ch in ' ' c o n s o l e = t t y S 0 , 1 1 5 2 0 0 n 8; do
      printf '%s' "$ch"
      sleep 0.12
    done
    sleep 2
    printf '\n'
    sleep 3
  fi

  # 2. Log in.
  #
  # archiso autologins root on tty1 while ttyS0 gets a login prompt, and boot takes
  # a few minutes. Sending root repeatedly is harmless at a shell prompt and removes
  # the guess about how slow - the EndeavourOS bake slept a fixed 122 seconds, typed
  # into a kernel that was still starting, and sat at the prompt until the watchdog
  # killed it.
  for _ in $(seq 1 14); do
    printf 'root\n'
    sleep 2
    printf '\n'
    sleep 13
  done

  printf 'echo PACSTRAP_BEGIN; id; ls /dev/vda\n'; sleep 3
  # One short command at a time, with pauses.
  #
  # The previous run showed the shell echoing mangled input:
  #
  #   root@archiso ~ # :(e
  #   ... rc=127
  #
  # 127 is "command not found", and the mangled text is a long line arriving faster
  # than the live shell could echo it - the same class of loss that hit the ISOLINUX
  # line editor. Short commands, sent one at a time, are echoed back so the next
  # screenshot shows what actually ran.
  send() { printf '%s\n' "$1"; sleep "${2:-3}"; }

  send 'curl -fsS -o /root/pacstrap.sh http://10.0.2.2:8000/pacstrap.sh; echo CURL_RC=$?' 6
  send 'ls -la /root/pacstrap.sh' 3
  send 'wc -l /root/pacstrap.sh' 3
  send 'chmod +x /root/pacstrap.sh' 2
  # The exit status has to be echoed on the SAME line as the script, or $? belongs to
  # whatever ran in between - here, a sleep.
  send "DESKTOP=$DESKTOP HOSTNAME_TARGET=arch-sandbox sh /root/pacstrap.sh; echo PACSTRAP_RC=\$?" 5
  send 'sync' 2
  send 'poweroff -f' 2
} > serial.in &

if [ "${DIRECT_BOOT:-0}" = 1 ]; then
  echo "booting with -kernel/-initrd; the command line is ours"
  # archiso finds its own root by the ISO9660 label, and without archisolabel it
  # drops to a rescue shell - which is what a bare -kernel/-initrd boot of an
  # archiso image does.
  BAKE_STDIN=serial.in QEMU_MAX="$QEMU_MAX" bake_qemu_install \
    -kernel "$K" -initrd "$I" -- \
    -append "archisobasedir=arch archisolabel=${VOLID} console=ttyS0,115200n8 modprobe.blacklist=floppy" \
    -drive "file=$ISO,media=cdrom,readonly=on" \
    -drive "file=$WORK/disk.qcow2,if=virtio,format=qcow2" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -device "VGA,edid=on,xres=${SCREEN_W:-1280},yres=${SCREEN_H:-800}"
else
  echo "booting the CD; console=ttyS0 goes in at the ISOLINUX menu"
  BAKE_STDIN=serial.in QEMU_MAX="$QEMU_MAX" bake_qemu_install \
    -drive "file=$ISO,media=cdrom,readonly=on" \
    -drive "file=$WORK/disk.qcow2,if=virtio,format=qcow2" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -device "VGA,edid=on,xres=${SCREEN_W:-1280},yres=${SCREEN_H:-800}"
fi

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
