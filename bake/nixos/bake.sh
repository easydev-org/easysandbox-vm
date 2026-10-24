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
  # No pipe and no tail: nixos-install prints one line per copied path, which is
  # the only progress signal a 30-minute install has. Piping it through tail
  # buffered every line until the end, so a working run and a hung one looked
  # identical from the job log.
  # The guest reports its own exit status. Without that marker the host
  # has no idea an install failed: it sent the command, slept for thirty
  # minutes and only then noticed, so a failure at minute 3 held the
  # runner for the full 1800s and the job looked hung rather than red.
  printf "sudo nixos-install --root /mnt --no-root-password --no-channel-copy 2>&1; echo INSTALL_RC=$?\n"
  # Poll instead of sleeping a fixed time, so a failure releases the job
  # immediately and a slow success is not cut short.
  i=0
  while [ $i -lt 480 ]; do
    # if, not "grep ... && break": under set -e a failed grep makes the
    # whole AND-list return 1, which kills this subshell on the FIRST
    # iteration - before the install has printed its status. The script
    # then never reached poweroff, so a successful install sat until the
    # timeout while the heartbeat kept reporting. That is exactly what
    # happened: INSTALL_RC=0 was in the log and the guest never shut down.
    if grep -aq "INSTALL_RC=" console.log 2>/dev/null; then break; fi
    sleep 5; i=$((i+1))
  done
  printf "sudo poweroff -f\n"
} > serial.in &

# tee, not ">": a 30-minute install that writes only to a file is
# indistinguishable from a hung job in the Actions log. The serial console
# carries nixos-install progress - one line per copied path - so stream it
# to the job log and keep a copy for the failure dump.
LASTLOG=$(mktemp)
(
  # A progress line every 60s, because nixos-install can be quiet for
  # minutes at a time (evaluating, then building one big derivation) and
  # silence in the log reads as a hang from the outside.
  start=$(date +%s)
  while true; do
    sleep 60
    now=$(date +%s)
    lines=$(wc -l < console.log 2>/dev/null || echo 0)
    echo "[heartbeat] $(( (now-start)/60 ))m elapsed, $lines console lines, last: $(tail -1 console.log 2>/dev/null | tr -d '\r' | cut -c1-90)"
  done
) & HB=$!

timeout 5400 qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 6144 \
  -kernel "$K" -initrd "$I" \
  -append "edd=off init=$INITRE nohibernate root=fstab loglevel=4 console=ttyS0,115200n8" \
  -drive file=nixos.iso,media=cdrom,readonly=on \
  -drive file=disk.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -nographic -no-reboot < serial.in 2>&1 | tee console.log

kill "$HB" 2>/dev/null || true

echo "=== result ==="
# Judge on the exit status the guest printed, not on a phrase in the log:
# a failed install still prints plenty of text, and the assertion that
# broke the first base bake produced no "installation finished" line at
# all - only an Nix evaluation error several screens earlier.
rc=$(grep -ao "INSTALL_RC=[0-9]*" console.log | tail -1 | cut -d= -f2)
echo "nixos-install exit status: ${rc:-<never returned>}"
if [ "${rc:-1}" != "0" ]; then
  echo "=== INSTALL FAILED (rc=${rc:-none}) ==="
  # Show the first error, not the last 60 lines: the assertion text is
  # near the top and the tail is only the shell prompt coming back.
  grep -anE "^error:|error:|Failed assertions|assertion" console.log | head -20 || true
  echo "--- context around the first error ---"
  first=$(grep -an "error:" console.log | head -1 | cut -d: -f1)
  [ -n "$first" ] && sed -n "$((first>6?first-6:1)),$((first+25))p" console.log || tail -60 console.log
  exit 1
fi

qemu-img convert -O qcow2 disk.qcow2 "$OUT" 2>/dev/null || cp disk.qcow2 "$OUT"
ls -la "$OUT"
echo "BAKED $DESKTOP -> $OUT"
