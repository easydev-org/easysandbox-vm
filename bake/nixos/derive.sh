#!/usr/bin/env bash
# Derive a desktop disk from an already-installed base disk, instead of running
# nixos-install again.
#
# WHY: every nixos-install repeats the same work - partition, format, unpack the
# kernel and every base package - before it touches the desktop, and all four
# flavours pay for it separately. Install the base ONCE, then let each flavour
# boot that disk and run nixos-rebuild, so the shared part is written once.
#
# The difference that makes this possible: nixos-install takes its packages from
# the ISO store and needs no network, while nixos-rebuild must fetch the desktop
# closure from cache.nixos.org. The guest therefore needs real egress, which qemu
# user networking gives it (10.0.2.2 is the host, everything else is NAT).
#
# nixos-rebuild BOOT, not switch: build the new generation and make it the boot
# default without activating a desktop in a throwaway VM. Then collect the old
# generations, because they are gigabytes that would otherwise ship in the disk.
set -Eeuo pipefail

BASE="${BASE:?set BASE to the base qcow2}"
DESKTOP="${DESKTOP:?set DESKTOP}"
OUT="${OUT:?set OUT}"
WAIT="${WAIT:-180}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== derive $DESKTOP from $BASE ==="
ls -la "$BASE"

cp --reflink=auto "$BASE" work.qcow2 2>/dev/null || cp "$BASE" work.qcow2
qemu-img resize work.qcow2 24G >/dev/null

sed "s|@DESKTOP@|$DESKTOP|" "$HERE/configuration.nix" > target.nix
echo "target configuration: $(wc -l < target.nix) lines"

rm -rf srv && mkdir -p srv && cp target.nix srv/configuration.nix
( cd srv && python3 -m http.server 8000 >/dev/null 2>&1 ) & SRV=$!
trap "kill $SRV 2>/dev/null || true" EXIT
sleep 2
rm -f ser.in
mkfifo ser.in
(
  exec 3> ser.in
  # The base disk boots straight to a getty - it has no desktop to start - so the
  # 120s covers GRUB and userspace. Then fetch the target config and rebuild.
  sleep 120
  printf 'echo DERIVE_BEGIN\n' >&3; sleep 3
  printf 'curl -fsS -o /tmp/c.nix http://10.0.2.2:8000/configuration.nix && echo GOT_CONFIG || echo GOT_FAIL\n' >&3; sleep 8
  printf 'curl -fsS -o /dev/null -m 25 https://cache.nixos.org/nix-cache-info && echo NET_OK || echo NET_FAIL\n' >&3; sleep 10
  printf 'sudo cp /tmp/c.nix /etc/nixos/configuration.nix\n' >&3; sleep 4
  printf 'echo === REBUILDING ===\n' >&3; sleep 2
  # Pin nixpkgs by URL so the closure matches the release the base was installed
  # from; nixos-rebuild otherwise follows whatever channel the disk carries.
  printf 'sudo env NIX_PATH=nixpkgs=https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz nixos-rebuild boot 2>&1 | tail -40\n' >&3; sleep 2400
  printf 'echo REBUILD_DONE\n' >&3; sleep 3
  # Without this the disk keeps every previous closure, i.e. gigabytes of the
  # base underneath the desktop that will never be booted again.
  printf 'sudo nix-collect-garbage -d >/dev/null 2>&1; echo GC_DONE\n' >&3; sleep 90
  printf 'sudo poweroff -f\n' >&3
) &
HOLD=$!

timeout 3000 qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 6144 \
  -drive file=work.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -display none -monitor none \
  -chardev file,id=ser0,path=derive.log,append=on \
  -serial chardev:ser0 \
  < ser.in > /dev/null 2>&1 || echo "qemu exited rc=$?"
kill "$HOLD" 2>/dev/null || true

echo "=== result ==="
grep -aE 'NET_OK|NET_FAIL|GOT_CONFIG|GOT_FAIL|REBUILD_DONE|GC_DONE|^error:' derive.log | tail -12 || true
if ! grep -aq 'REBUILD_DONE' derive.log; then
  echo 'DERIVE FAILED; last 50 lines:'
  tail -50 derive.log
  exit 1
fi

qemu-img convert -O qcow2 work.qcow2 "$OUT"
ls -la "$OUT"
echo "DERIVED $DESKTOP -> $OUT"
