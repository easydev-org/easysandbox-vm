#!/usr/bin/env bash
# Bake a NixOS desktop disk from the official ISO, headlessly.
#
# Runs under QEMU/KVM on a CI runner (or the in-cluster bake pod). The ISO is
# booted with -kernel/-initrd instead of through its boot menu: the bake needs a
# fully scripted console and must not depend on a GRUB prompt. Everything GRUB
# would put on the command line is read out of the image, so it cannot drift
# from the release.
#
# DESKTOP picks the flavour: labwc | gnome | kde | cosmic.
set -Eeuo pipefail

DESKTOP="${DESKTOP:?set DESKTOP to labwc|gnome|kde|cosmic}"
NIXPKGS="${NIXPKGS:-nixos-unstable}"
ISO_URL="${ISO_URL:-https://channels.nixos.org/nixos-unstable/latest-nixos-minimal-x86_64-linux.iso}"
OUT="${OUT:-/work/desktop.qcow2}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== baking $DESKTOP on $NIXPKGS ==="
mkdir -p "$(dirname "$OUT")" && cd "$(dirname "$OUT")"

echo "=== ISO ==="
[ -s nixos.iso ] || curl -fsSL --retry 3 --retry-delay 2 -o nixos.iso "$ISO_URL"
ls -la nixos.iso

echo "=== boot parameters, read from the image ==="
7z e -so nixos.iso EFI/BOOT/grub.cfg > g.cfg
INITRE=$(grep -m1 "^  linux " g.cfg | sed -E "s#.*init=([^ ]+).*#\1#")
echo "INITRE=$INITRE"

echo "=== the LTS kernel and its matching initrd ==="
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

echo "=== configuration for $DESKTOP ==="
sed "s|@DESKTOP@|$DESKTOP|" "$HERE/configuration.nix" > install.nix
# A sanity check that the substitution happened, tolerant of labwc: its branch
# is programs.labwc.enable and contains no 'desktop == "labwc"' comparison, so
# a grep -c on that pattern returns 0 and exits 1, which set -e turned into a
# dead job. Look for the substituted name anywhere instead.
grep -q "$DESKTOP" install.nix || { echo "SUBSTITUTION_FAILED"; exit 2; }
echo "configuration mentions $DESKTOP"

echo "=== serve install.nix and bootstrap.sh to the guest over user-net ==="
# qemu user networking puts the host at 10.0.2.2; the guest curls from there.
# A heredoc over the serial fifo cannot carry quotes or multi-line files, so
# everything is fetched over HTTP instead.
rm -rf srv && mkdir -p srv
cp install.nix srv/configuration.nix
cp "$HERE/bootstrap.sh" srv/bootstrap.sh
( cd srv && python3 -m http.server 8000 >/dev/null 2>&1 ) &
SRV=$!
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
  printf "sudo mkdir -p /mnt/etc/nixos /mnt/var/lib/easystream\n"; sleep 3
  printf "sudo cp /tmp/c.nix /mnt/etc/nixos/configuration.nix\n"; sleep 3
  printf "curl -fsS -o /tmp/b.sh http://10.0.2.2:8000/bootstrap.sh\n"; sleep 5
  printf "sudo cp /tmp/b.sh /mnt/var/lib/easystream/bootstrap.sh\n"; sleep 3
  printf "sudo chmod 755 /mnt/var/lib/easystream/bootstrap.sh\n"; sleep 3
  printf "echo === INSTALLING ===\n"; sleep 2
  # nixos-install builds from the ISO own store, so the guest needs no network.
  printf "sudo nixos-install --root /mnt --no-root-password --no-channel-copy 2>&1 | tail -40\n"; sleep 1800
  printf "echo === INSTALL_DONE ===\n"; sleep 3
  printf "sudo poweroff -f\n"
} > serial.in &

timeout 5400 qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 6144 \
  -kernel "$K" -initrd "$I" \
  -append "edd=off init=$INITRE nohibernate root=fstab loglevel=4 console=ttyS0,115200n8" \
  -drive file=nixos.iso,media=cdrom,readonly=on \
  -drive file=disk.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -nographic -no-reboot < serial.in > console.log 2>&1

echo "=== result ==="
grep -aE "INSTALL_DONE|installation finished|INSTALL_FAIL" console.log | tail -5 || true
if ! grep -aq "installation finished" console.log; then
  echo "INSTALL DID NOT COMPLETE; last 60 lines:"
  tail -60 console.log
  exit 1
fi

qemu-img convert -O qcow2 disk.qcow2 "$OUT" 2>/dev/null || cp disk.qcow2 "$OUT"
ls -la "$OUT"
echo "BAKED $DESKTOP -> $OUT"
