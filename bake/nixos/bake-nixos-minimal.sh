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

NIXPKGS="${NIXPKGS:-nixos-unstable}"
ISO_URL="${ISO_URL:-https://channels.nixos.org/nixos-unstable/latest-nixos-minimal-x86_64-linux.iso}"
OUT="${OUT:?set OUT to the qcow2 to produce}"
# Hard ceiling on the qemu call. The guest is asked to power itself off, but the
# host must not depend on that: twice it did not, and the run sat until the
# outer timeout. This is the backstop, not the mechanism.
QEMU_MAX="${QEMU_MAX:-1800}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== baking the minimal base on $NIXPKGS ==="
mkdir -p "$(dirname "$OUT")" && cd "$(dirname "$OUT")"

echo "=== ISO ==="
[ -s nixos.iso ] || curl -fsSL --retry 3 --retry-delay 2 -o nixos.iso "$ISO_URL"
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
K=$(find "$PWD/x" -path "*linux-6.18.57/bzImage" | head -1)
I=$(find "$PWD/x" -path "*initrd-linux-6.18.57/initrd" -type f | head -1)
[ -s "$K" ] && [ -s "$I" ] || { echo "PAIR_FAIL (kernel/initrd version mismatch)"; exit 2; }
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

# tee, not ">": a long install that writes only to a file is indistinguishable
# from a hung job in the Actions log. The heartbeat covers the quiet stretches.
LASTLOG=$(mktemp)
(
  start=$(date +%s)
  while true; do
    sleep 60
    now=$(date +%s)
    lines=$(wc -l < console.log 2>/dev/null || echo 0)
    echo "[heartbeat] $(( (now-start)/60 ))m elapsed, $lines console lines, last: $(tail -1 console.log 2>/dev/null | tr -d '\r' | cut -c1-90)"
  done
) & HB=$!

timeout "$QEMU_MAX" qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 6144 \
  -kernel "$K" -initrd "$I" \
  -append "edd=off init=$INITRE nohibernate root=fstab loglevel=4 console=ttyS0,115200n8" \
  -drive file=nixos.iso,media=cdrom,readonly=on \
  -drive file=disk.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -nographic -no-reboot < serial.in 2>&1 | tee console.log

kill "$HB" 2>/dev/null || true

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

qemu-img convert -O qcow2 disk.qcow2 "$OUT"
ls -la "$OUT"
echo "BAKED minimal base -> $OUT"
