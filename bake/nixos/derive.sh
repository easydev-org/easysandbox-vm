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

# configuration-desktop.nix, not configuration.nix: the base image is built from
# configuration-minimal.nix and the desktop file imports it, so replacing
# /etc/nixos/configuration.nix with this keeps every filesystem, boot and user
# setting while adding the desktop.
sed "s|@DESKTOP@|$DESKTOP|" "$HERE/configuration-desktop.nix" > target.nix
echo "target configuration: $(wc -l < target.nix) lines"

# Serve the PAIR. configuration-desktop.nix imports ./configuration-minimal.nix
# by a relative path, so the guest needs both files in one directory or nixos-rebuild
# fails with 'path /etc/nixos/configuration-minimal.nix does not exist'.
rm -rf srv && mkdir -p srv
cp target.nix srv/configuration.nix
cp "$HERE/configuration-minimal.nix" srv/configuration-minimal.nix
( cd srv && python3 -m http.server 8000 >/dev/null 2>&1 ) & SRV=$!
trap "kill $SRV 2>/dev/null || true" EXIT
sleep 2
# Start from an empty log: append=on plus a follower would otherwise replay
# previous runs, and the DERIVE_RC grep could match a stale one.
rm -f derive.log
rm -f ser.in
mkfifo ser.in
# The guest script must be on disk BEFORE the fifo is opened for writing:
# opening a fifo for writing blocks until a reader appears, and the reader is
# qemu, which starts further down. An earlier version created the script inside
# a subshell that had already done `exec 3> ser.in`, so it blocked there, the
# script was never written, the cp found nothing, and no command ever reached
# the guest - 250 lines of console output and not one command.
cat > derive-guest.sh <<'GUEST'
#!/bin/sh
# Runs INSIDE the guest. Nothing here may assume the host is watching.
echo DERIVE_BEGIN

echo "--- network ---"
if curl -fsS -o /dev/null -m 30 https://cache.nixos.org/nix-cache-info; then
  echo NET_OK
else
  echo NET_FAIL
  echo DERIVE_RC=1
  sync
  poweroff -f
fi

echo "--- configuration ---"
# Both files: configuration-desktop.nix imports ./configuration-minimal.nix by a
# relative path, so they must sit together under /etc/nixos.
curl -fsS -o /etc/nixos/configuration.nix http://10.0.2.2:8000/configuration.nix || { echo CONFIG_FAIL; echo DERIVE_RC=1; sync; poweroff -f; }
curl -fsS -o /etc/nixos/configuration-minimal.nix http://10.0.2.2:8000/configuration-minimal.nix || { echo MINIMAL_FAIL; echo DERIVE_RC=1; sync; poweroff -f; }
echo GOT_CONFIG

echo "--- rebuilding ---"
# No pipe and no tail: this is the only progress a twenty-minute build emits.
# BOTH entries. Setting NIX_PATH replaces the default instead of extending it,
# and the default carries nixos-config=/etc/nixos/configuration.nix. Pinning only
# nixpkgs made nixos-rebuild fail with "file 'nixos-config' was not found in the
# Nix search path" - it had nothing to build.
export NIX_PATH="nixpkgs=https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz:nixos-config=/etc/nixos/configuration.nix"
nixos-rebuild boot
rc=$?
echo REBUILD_RC=$rc
if [ $rc -ne 0 ]; then
  echo DERIVE_RC=$rc
  sync
  poweroff -f
fi

echo "--- collecting old generations ---"
# Without this the disk keeps every previous closure, i.e. gigabytes of the base
# underneath the desktop that will never be booted again.
nix-collect-garbage -d
echo GC_DONE
echo DERIVE_RC=0
sync
poweroff -f
GUEST

cp derive-guest.sh srv/derive-guest.sh

# Same construction as the minimal bake, which is proven: a block whose stdout
# IS the fifo. The sleep covers GRUB and userspace on a disk that has no
# desktop to start; then the guest fetches the script and runs it as root.
{
  sleep 120
  printf "curl -fsS -o /tmp/derive.sh http://10.0.2.2:8000/derive-guest.sh && echo GOT_SCRIPT || echo SCRIPT_FAIL\n"
  sleep 8
  printf "\n"
  printf "sudo -i sh /tmp/derive.sh\n"
  sleep 3600
} > ser.in &
HOLD=$!

LASTLOG=$(mktemp)
(
  # Heartbeat: nixos-rebuild can be silent for minutes while it evaluates
  # and downloads, and silence in the log reads as a hang from outside.
  start=$(date +%s)
  while true; do
    sleep 60
    now=$(date +%s)
    lines=$(wc -l < derive.log 2>/dev/null || echo 0)
    echo "[heartbeat] $(( (now-start)/60 ))m elapsed, $lines console lines, last: $(tail -1 derive.log 2>/dev/null | tr -d '\r' | cut -c1-90)"
  done
) & HB=$!

# tee, not ">": a long rebuild writing only to a file cannot be told
# apart from a hung job. The heartbeat covers the quiet stretches.
# Serial on stdio, exactly as the minimal bake does it, because that is
# the pair that actually delivers INPUT. With -serial chardev:ser0 the
# console went to a file and stdin had nowhere to go: every command
# written to the fifo reached qemu and stopped there. The guest sat at a
# login prompt for thirty-five minutes while 250 lines of output scrolled
# past in the log - output worked, input had no path at all.
timeout "${QEMU_MAX:-3600}" qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 6144 \
  -drive file=work.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -nographic -no-reboot \
  < ser.in 2>&1 | tee derive.log || echo "qemu exited rc=$?"
kill "$HB" 2>/dev/null || true

echo "=== result ==="
# Judge on the exit status the guest printed, not on a phrase in the log.
rc=$(grep -ao "DERIVE_RC=[0-9]*" derive.log | tail -1 | cut -d= -f2)
echo "derive exit status: ${rc:-<never returned>}"
grep -aE "NET_OK|NET_FAIL|GOT_CONFIG|CONFIG_FAIL|MINIMAL_FAIL|REBUILD_RC=|GC_DONE" derive.log | tail -8 || true
if [ "${rc:-1}" != "0" ]; then
  echo "=== DERIVE FAILED (rc=${rc:-none}) ==="
  # The first error with context, not the tail: a nix evaluation error appears
  # near the top and the tail is only the shell prompt coming back.
  first=$(grep -an "error:" derive.log | head -1 | cut -d: -f1)
  if [ -n "$first" ]; then sed -n "$((first>8?first-8:1)),$((first+30))p" derive.log
  else tail -60 derive.log; fi
  exit 1
fi

qemu-img convert -O qcow2 work.qcow2 "$OUT"
ls -la "$OUT"
echo "DERIVED $DESKTOP -> $OUT"