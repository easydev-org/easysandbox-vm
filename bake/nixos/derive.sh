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
(
  exec 3> ser.in
  # The base disk boots straight to a getty - it has no desktop to start - so the
  # 120s covers GRUB and userspace.
  sleep 120

  # ONE command line that ends in poweroff, the same shape as the minimal bake.
  # Everything after the boot happens inside a single guest shell: fetch both
  # config files, rebuild, collect garbage, report, sync, shut down. Two earlier
  # shapes of this failed - a pipe through tail buffered the output so progress
  # was invisible and a failure was only noticed 40 minutes later, and separate
  # keystrokes with fixed sleeps meant the host was guessing when each stage had
  # finished. A shell script with its own exit status removes both.
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
export NIX_PATH=nixpkgs=https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz
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

  # Feed the script line by line over the fifo. The fifo cannot take a heredoc, so
  # base64 it: quoting, newlines and shell metacharacters then survive intact.
  # NOT one giant command line. Pasting a base64 blob of the script into the
  # serial console is fragile - a line that long can be truncated by the tty
  # buffer, and the failure is silent: the guest runs a partial script and
  # nothing says so. Instead serve the script over the same HTTP server as the
  # configs and have the guest fetch it, which also means the file it ran is in
  # the uploaded artifact.
  cp derive-guest.sh srv/derive-guest.sh 2>/dev/null || cp derive-guest.sh srv/ || true
  printf 'curl -fsS -o /tmp/derive.sh http://10.0.2.2:8000/derive-guest.sh && echo GOT_SCRIPT || echo SCRIPT_FAIL
' >&3
  sleep 5
  printf 'sudo -i sh /tmp/derive.sh
' >&3
) &
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
# The serial goes to a FILE, not to stdout: stdin is the command fifo,
# so there is no stdio to share. A follower streams that file to the
# job log so progress is visible while it happens.
( tail -F -n +1 derive.log 2>/dev/null & echo $! > /tmp/tailpid ) &
TAILPID=$!
timeout "${QEMU_MAX:-3600}" qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 6144 \
  -drive file=work.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -display none -monitor none \
  -chardev file,id=ser0,path=derive.log,append=on \
  -serial chardev:ser0 \
  < ser.in > /dev/null 2>&1 || echo "qemu exited rc=$?"
kill "$TAILPID" 2>/dev/null || true
pkill -f "tail -F -n +1 derive.log" 2>/dev/null || true
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