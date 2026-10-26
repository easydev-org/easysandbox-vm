#!/usr/bin/env bash
# Install the Ubuntu desktop sandbox disk from the official live-server ISO,
# headlessly, with autoinstall.
#
# HOW THIS DIFFERS FROM THE NIXOS BAKE
#
# NixOS: boot the ISO's kernel, get a shell over the serial console, type
# `nixos-install`. The install is whatever we type.
#
# Ubuntu: boot the ISO's kernel with `autoinstall ds=nocloud-net;s=http://...`
# appended. subiquity fetches user-data from that URL and does the rest; there
# is no shell to type into. The whole configuration is bake/ubuntu/user-data,
# generated here with the desktop substituted in.
#
# Both end the same way - the guest powers itself off and we convert the qcow2 -
# and that shared tail is what a common lib will eventually hold.
#
# The -kernel/-initrd path is not a trick: it is what Ubuntu's own autoinstall
# quick-start uses (casper/vmlinuz + casper/initrd), and it avoids depending on
# the ISO's boot menu.
set -Eeuo pipefail

DESKTOP="${DESKTOP:?set DESKTOP to ubuntu | kubuntu | xubuntu}"
OUT="${OUT:?set OUT to the qcow2 to produce}"
# 26.04.1 LTS is the current point release. Pinned, not `latest`: autoinstall
# keys and the casper layout are stable within a release and not across them.
UBUNTU_VERSION="${UBUNTU_VERSION:-26.04.1}"
ISO_URL="${ISO_URL:-https://releases.ubuntu.com/26.04/ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso}"
RELEASE="${RELEASE:-resolute}"
DISK_SIZE="${DISK_SIZE:-24G}"
QEMU_MAX="${QEMU_MAX:-3600}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$DESKTOP" in
  ubuntu)  PKG=ubuntu-desktop ;;
  kubuntu) PKG=kubuntu-desktop ;;
  xubuntu) PKG=xubuntu-desktop ;;
  *) echo "unknown DESKTOP '$DESKTOP' (ubuntu|kubuntu|xubuntu)" >&2; exit 2 ;;
esac

mkdir -p "$(dirname "$OUT")" && cd "$(dirname "$OUT")"

echo "=== ISO ==="
ISO="ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
[ -s "$ISO" ] || curl -fsSL --retry 3 --retry-delay 2 -o "$ISO" "$ISO_URL"
ls -la "$ISO"

# The kernel and initrd come straight out of the image's casper directory - the
# same pair Ubuntu's own autoinstall instructions boot. Extract with 7z rather
# than mounting, because the bake also runs where mount is not permitted.
echo "=== casper kernel and initrd ==="
rm -rf x && mkdir -p x
7z x -y -o"x" "$ISO" casper/vmlinuz casper/initrd > /dev/null
K="$PWD/x/casper/vmlinuz"
I="$PWD/x/casper/initrd"
[ -s "$K" ] && [ -s "$I" ] || { echo "PAIR_FAIL: casper kernel/initrd not found in the ISO" >&2; exit 2; }
ls -la "$K" "$I"

echo "=== autoinstall config (desktop=$DESKTOP, package=$PKG) ==="
rm -rf srv && mkdir -p srv
sed -e "s|@DESKTOP@|$PKG|g" -e "s|@RELEASE@|$RELEASE|g" "$HERE/user-data" > srv/user-data
cp "$HERE/meta-data" srv/meta-data
grep -nE "^  (version|updates|shutdown):" srv/user-data || true
grep -n "@DESKTOP@\|@RELEASE@" srv/user-data && { echo "SUBSTITUTION LEFT A PLACEHOLDER" >&2; exit 1; } || true
wc -l srv/user-data

echo "=== serve the seed over user-net ==="
# qemu user networking exposes the host at 10.0.2.2, which is the `_gateway`
# cloud-init resolves when the seed URL names it. subiquity fetches
# /user-data and /meta-data from here.
( cd srv && python3 -m http.server 8000 >/dev/null 2>&1 ) & SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 2
curl -fsS http://127.0.0.1:8000/user-data > /dev/null && echo "seed server up"

qemu-img create -f qcow2 disk.qcow2 "$DISK_SIZE" > /dev/null

# -no-reboot plus `shutdown: poweroff` in user-data: the guest turns itself off
# and qemu exits. QEMU_MAX is the backstop, not the mechanism - the NixOS bake
# taught that lesson twice.
echo "=== install (autoinstall, no typing) ==="
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
trap 'kill $SRV $HB 2>/dev/null || true' EXIT

timeout "$QEMU_MAX" qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 6144 \
  -kernel "$K" -initrd "$I" \
  -append "autoinstall ds=nocloud-net;s=http://10.0.2.2:8000/ console=ttyS0,115200n8" \
  -drive file="$ISO",media=cdrom,readonly=on \
  -drive file=disk.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -nographic -no-reboot > console.log 2>&1 || echo "qemu exited rc=$?"

kill "$HB" 2>/dev/null || true

echo "=== result ==="
# subiquity prints a definite final line. Judging on it rather than on qemu's
# exit status, which -no-reboot turns into a reboot-triggered exit that also
# happens on a failed install.
if grep -aq "UBUNTU_BAKE_OK\|Installation complete" console.log; then
  echo "autoinstall reported success"
else
  echo "=== INSTALL DID NOT COMPLETE ==="
  # The first error with context: a schema violation lands near the top and the
  # tail is the shell prompt coming back.
  first=$(grep -an "ERROR\|Traceback\|failed" console.log | head -1 | cut -d: -f1)
  if [ -n "$first" ]; then sed -n "$((first>8?first-8:1)),$((first+40))p" console.log
  else tail -80 console.log; fi
  exit 1
fi

# Confirm the marker the late-command wrote, by mounting nothing and reading the
# disk's filesystem directly: it proves the file landed inside the image we are
# about to publish, not just that the installer said it was finished.
echo "=== the marker is on the disk ==="
if command -v virt-cat >/dev/null 2>&1; then
  virt-cat -a disk.qcow2 /var/log/ubuntu-bake-ok || { echo "marker not readable" >&2; exit 1; }
else
  echo "(virt-cat not installed; skipping the read-back)"
fi

qemu-img convert -O qcow2 -c -o compression_type=zstd disk.qcow2 "$OUT"
ls -la "$OUT"
echo "BAKED $DESKTOP -> $OUT ($(du -h "$OUT" | cut -f1))"
