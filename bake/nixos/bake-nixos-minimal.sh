#!/usr/bin/env bash
# Install the minimal NixOS base image from the official ISO, headlessly.
#
# This is the only disk in the family that is installed from scratch. Desktop
# images are derived from it with nixos-rebuild (derive.sh), because partition,
# format and unpack are identical across flavours and nixos-install pays that
# cost every time.
#
# Runs under QEMU/KVM on a CI runner or the in-cluster bake pod. The ISO is
# booted with -kernel/-initrd instead of through its boot menu: the bake needs a
# fully scripted console and must not depend on a GRUB prompt. The kernel and
# initrd paths are read out of the image so they cannot drift from the release.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/qemu-bake.sh
. "$HERE/../lib/qemu-bake.sh"

NIXPKGS="${NIXPKGS:-nixos-unstable}"
ISO_URL="${ISO_URL:-https://channels.nixos.org/nixos-unstable/latest-nixos-minimal-x86_64-linux.iso}"
OUT="${OUT:?set OUT to the qcow2 to produce}"
# QEMU_MAX is set in the lib; the NixOS install is faster than a full Ubuntu
# one, so the ceiling is lower here.
QEMU_MAX="${QEMU_MAX:-1800}"
QEMU_SMP="${QEMU_SMP:-4}"
QEMU_MEM="${QEMU_MEM:-6144}"

echo "=== baking the minimal base on $NIXPKGS ==="
mkdir -p "$(dirname "$OUT")" && cd "$(dirname "$OUT")"

echo "=== ISO ==="
. "$HERE/../lib/iso.sh"
bake_fetch_iso "nixos" "${ISO:-nixos.iso}"
ls -la nixos.iso

echo "=== boot parameters, read from the image ==="
7z e -so nixos.iso EFI/BOOT/grub.cfg > g.cfg
INITRE=$(grep -m1 "^  linux " g.cfg | sed -E "s#.*init=([^ ]+).*#\1#")
echo "INITRE=$INITRE"

echo "=== the kernel and its matching initrd ==="
rm -rf x && mkdir -p x
# Wildcards with -r are what work; an exact store path extracts nothing.
7z x -y -r -ox nixos.iso "bzImage" > /dev/null 2>&1 || true
7z x -y -r -ox nixos.iso "initrd" > /dev/null 2>&1 || true
# The pair must be the SAME version or the guest boots with no modules.
#
# The version is READ FROM THE IMAGE, not written down here.
#
# latest-nixos-minimal is a rolling release: its kernel moves, and this script had
# 6.18.57 baked into the two paths below. When the image moved on, the find matched
# nothing, and the bake reported
#
#   PAIR_FAIL (kernel/initrd version mismatch)
#
# on an ISO that had downloaded correctly and was perfectly fine - the failure was the
# hardcoded version, not the image.
#
# grub.cfg names the store path of the init it boots, and the kernel and initrd live
# in sibling store paths whose names carry the same version:
#
#   /nix/store/<hash>-nixos-system-nixos-26.11pre.../init
#   /nix/store/<hash>-linux-<version>/bzImage
#   /nix/store/<hash>-initrd-linux-<version>/initrd
#
# so the version is taken from whatever the image actually contains.
KVER="${NIXOS_KERNEL:-}"
if [ -z "$KVER" ]; then
  KVER=$(find "$PWD/x" -name bzImage -type f | sed -E 's#.*/linux-([^/]+)/bzImage#\1#' | head -1)
fi
[ -n "$KVER" ] || { echo "PAIR_FAIL (no bzImage in the image)"; exit 2; }
echo "kernel version in this image: $KVER"
K=$(find "$PWD/x" -path "*linux-$KVER/bzImage" | head -1)
I=$(find "$PWD/x" -path "*initrd-linux-$KVER/initrd" -type f | head -1)
[ -s "$K" ] && [ -s "$I" ] || {
  echo "PAIR_FAIL (kernel/initrd version mismatch for $KVER)" >&2
  echo "bzImages found:" >&2
  find "$PWD/x" -name bzImage -type f >&2
  echo "initrds found:" >&2
  find "$PWD/x" -name initrd -type f >&2
  exit 2
}
echo "K=$K"
echo "I=$I"

echo "=== configuration ==="
cp "$HERE/configuration-minimal.nix" install.nix
wc -l install.nix

echo "=== serve install.nix to the guest over user-net ==="
# qemu user networking puts the host at 10.0.2.2; the guest curls from there.
# A heredoc over the serial fifo cannot carry quotes or multi-line files, so
# the configuration is fetched over HTTP instead.
rm -rf srv && mkdir -p srv && cp install.nix srv/configuration.nix
( cd srv && python3 -m http.server 8000 >/dev/null 2>&1 ) & SRV=$!
trap "kill $SRV 2>/dev/null || true" EXIT
sleep 2
curl -fsS http://127.0.0.1:8000/configuration.nix > /dev/null && echo "config server up"

qemu-img create -f qcow2 disk.qcow2 20G > /dev/null

echo "=== install over the serial console ==="
rm -f serial.in && mkfifo serial.in
{
  sleep 115
  printf "echo BAKE_BEGIN\n"; sleep 3
  printf "curl -fsS -o /tmp/c.nix http://10.0.2.2:8000/configuration.nix && wc -l /tmp/c.nix || echo CONFIG_FETCH_FAIL\n"; sleep 8
  # One partition starting at 1MiB leaves the MBR free for GRUB core.img.
  printf "sudo sgdisk --zap-all /dev/vda >/dev/null 2>&1 || true\n"; sleep 2
  printf "sudo parted -s /dev/vda mklabel msdos\n"; sleep 3
  printf "sudo parted -s /dev/vda mkpart primary ext4 1MiB 100%%\n"; sleep 3
  printf "sudo partprobe /dev/vda 2>/dev/null || true\n"; sleep 3
  printf "sudo mkfs.ext4 -F -L nixos /dev/vda1\n"; sleep 15
  printf "sudo mount /dev/vda1 /mnt\n"; sleep 5
  # Nothing from the sandbox goes on this disk: no /var/lib/easystream, no
  # launcher script. It is a plain NixOS system and stays one.
  printf "sudo mkdir -p /mnt/etc/nixos\n"; sleep 3
  printf "sudo cp /tmp/c.nix /mnt/etc/nixos/configuration.nix\n"; sleep 3
  # ONE command line, ending in poweroff: install, report status, sync, shut
  # down, all in the same shell. Nothing depends on the host noticing a marker
  # and injecting another keystroke later - two attempts at that failed and both
  # left a finished install sitting until the timeout.
  printf "echo === INSTALLING ===\n"; sleep 2
  printf "sudo nixos-install --root /mnt --no-root-password --no-channel-copy 2>&1; echo INSTALL_RC=$?; sync; sudo poweroff -f\n"
} > serial.in &

# The lib runs qemu, tees the console and does the heartbeat. BAKE_STDIN is what
# makes this distribution different: NixOS is installed by typing into the
# serial console, so the fifo of commands goes in on stdin. Ubuntu passes
# nothing and lets the installer fetch its own configuration.
BAKE_STDIN=serial.in bake_qemu_install -kernel "$K" -initrd "$I" -- \
  -append "edd=off init=$INITRE nohibernate root=fstab loglevel=4 console=ttyS0,115200n8" \
  -drive "file=nixos.iso,media=cdrom,readonly=on" \
  -drive "file=disk.qcow2,if=virtio,format=qcow2" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0

echo "=== result ==="
# Judge on the exit status the guest printed, not on a phrase in the log: a
# failed install still prints plenty of text.
rc=$(grep -ao "INSTALL_RC=[0-9]*" console.log | tail -1 | cut -d= -f2)
echo "nixos-install exit status: ${rc:-<never returned>}"
if [ "${rc:-1}" != "0" ]; then
  echo "=== INSTALL FAILED (rc=${rc:-none}) ==="
  # The first error, not the last 60 lines: the assertion sits near the top and
  # the tail is only the shell prompt returning.
  first=$(grep -an "error:" console.log | head -1 | cut -d: -f1)
  if [ -n "$first" ]; then sed -n "$((first>6?first-6:1)),$((first+25))p" console.log
  else tail -60 console.log; fi
  exit 1
fi

bake_compress_disk disk.qcow2 "$OUT"
echo "BAKED minimal base -> $OUT"
