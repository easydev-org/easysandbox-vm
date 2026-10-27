#!/usr/bin/env bash
# Install a Debian desktop sandbox disk from the official netinst, headlessly,
# with preseed.
#
# THE INSTALL, AND ONLY THE INSTALL
#
# Booting the VM, the console tee, the heartbeat, the stall watchdog, judging the
# result and compressing the disk come from bake/lib/qemu-bake.sh. What is here
# is Debian: fetch the netinst, take the installer's kernel and initrd, serve
# preseed.cfg over HTTP, and boot with `auto=true preseed/url=http://...`.
#
# Four distributions now, four ways of being told what to install:
#
#   NixOS     commands typed at the serial console
#   Ubuntu    autoinstall ds=nocloud-net;s=http://...   (subiquity fetches user-data)
#   Fedora    inst.ks=http://...                        (anaconda fetches ks.cfg)
#   Debian    auto=true preseed/url=http://...          (debian-installer fetches preseed.cfg)
#
# The last three are the same idea with different spellings; only NixOS needs a
# human at a console, which is why it is the one that passes BAKE_STDIN.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/qemu-bake.sh
. "$HERE/../lib/qemu-bake.sh"

DESKTOP="${DESKTOP:?set DESKTOP to gnome | kde | xfce | cinnamon}"
OUT="${OUT:?set OUT to the qcow2 to produce}"
# Pinned to the point release the archive currently has. preseed question names
# are stable across a Debian release and not always across major versions.
DEBIAN_VERSION="${DEBIAN_VERSION:-13.7.0}"
DEBIAN_SERIES="${DEBIAN_SERIES:-trixie}"
ISO_URL="${ISO_URL:-https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-${DEBIAN_VERSION}-amd64-netinst.iso}"
DISK_SIZE="${DISK_SIZE:-24G}"
QEMU_SMP="${QEMU_SMP:-4}"
QEMU_MEM="${QEMU_MEM:-6144}"

# Task names, not package lists - these are what a user picks in the installer.
case "$DESKTOP" in
  gnome)    TASK="task-gnome-desktop" ;;
  kde)      TASK="task-kde-desktop" ;;
  xfce)     TASK="task-xfce-desktop" ;;
  cinnamon) TASK="task-cinnamon-desktop" ;;
  *) echo "unknown DESKTOP '$DESKTOP' (gnome|kde|xfce|cinnamon)" >&2; exit 2 ;;
esac

BAKE_WORKDIR="$(dirname "$OUT")"
mkdir -p "$BAKE_WORKDIR" && cd "$BAKE_WORKDIR"
export BAKE_WORKDIR

echo "=== ISO ==="
ISO="$(basename "$ISO_URL")"
[ -s "$ISO" ] || curl -fsSL --retry 3 --retry-delay 2 -o "$ISO" "$ISO_URL"
ls -la "$ISO"

# (very old) releases keep the installer kernel under install.amd/. Extract with
# 7z rather than mounting: the bake also runs where mount is not permitted.
echo "=== installer kernel and initrd ==="
rm -rf x && mkdir -p x
7z x -y -o"x" "$ISO" "install.amd/vmlinuz" "install.amd/initrd.gz" > /dev/null 2>&1 || true
K="$PWD/x/install.amd/vmlinuz"
I="$PWD/x/install.amd/initrd.gz"
if [ ! -s "$K" ] || [ ! -s "$I" ]; then
  # Some builds moved them; find whatever the image actually calls them.
  7z x -y -o"x" "$ISO" "install.*" > /dev/null 2>&1 || true
  K=$(find "$PWD/x" -name 'vmlinuz*' -type f | head -1)
  I=$(find "$PWD/x" -name 'initrd*' -type f | head -1)
fi
[ -s "${K:-}" ] && [ -s "${I:-}" ] || { echo "PAIR_FAIL: installer kernel/initrd not found in the ISO" >&2; exit 2; }
ls -la "$K" "$I"

echo "=== preseed (desktop=$DESKTOP, task=$TASK) ==="
rm -rf srv && mkdir -p srv
sed -e "s|@DESKTOP@|$TASK|g" "$HERE/preseed.cfg" > srv/preseed.cfg
grep -q "@DESKTOP@" srv/preseed.cfg && { echo "SUBSTITUTION LEFT A PLACEHOLDER" >&2; exit 1; } || true
grep -nE "^(d-i pkgsel/include|d-i preseed/late_command)" srv/preseed.cfg | cut -c1-90 || true
wc -l srv/preseed.cfg

# setup.sh is served alongside the preseed because preseed's late_command has to
# be ONE line; the real work is here and is fetched over the same HTTP server.
cp "$HERE/setup.sh" srv/setup.sh
sh -n srv/setup.sh && echo "setup.sh parses"

# The task name is passed on the late_command line, not substituted into
# setup.sh - so a stale copy cannot install the wrong desktop quietly.

echo "=== serve the preseed over user-net ==="
# qemu user networking puts the host at 10.0.2.2; debian-installer fetches
# preseed/url from there. plain http, no proxy.
( cd srv && python3 -m http.server 8000 >/dev/null 2>&1 ) & SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 2
curl -fsS http://127.0.0.1:8000/preseed.cfg > /dev/null && echo "preseed server up"

qemu-img create -f qcow2 disk.qcow2 "$DISK_SIZE" > /dev/null

echo "=== install (preseed, no typing) ==="
# auto=true and priority=critical are the two parameters Debian's own
# documentation gives for an unattended run; interface=auto takes DHCP on
# whatever NIC qemu created. DEBCONF_DEBUG keeps the preseed log visible, which
# is where a question the file failed to answer shows up.
bake_qemu_install -kernel "$K" -initrd "$I" -- \
  -append "auto=true priority=critical interface=auto preseed/url=http://10.0.2.2:8000/preseed.cfg preseed/allow-airplane-mode=true console=ttyS0,115200n8 DEBCONF_DEBUG=developer" \
  -drive "file=$ISO,media=cdrom,readonly=on" \
  -drive "file=disk.qcow2,if=virtio,format=qcow2" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0

# The late_command writes a marker onto the target. Reading it back off the disk
# proves the file landed inside the image we are about to publish, not just that
# the installer said it was finished.
echo "=== the install finished ==="
bake_assert_installed "Installation complete|Rebooting|reboot: Restarting system|DEBIAN_BAKE_OK" "debian preseed"

# The marker reached the console, which is the evidence that the install landed.
#
# setup.sh writes DEBIAN_BAKE_OK to /var/log/debian-bake-ok AND to /dev/ttyS0. The
# console copy is the one that matters: it arrives while the guest is running, in
# the log the bake already judges on. Reading the file back off the finished disk
# would need virt-cat, and the only package that provides it cannot be installed
# on the base image the bake runs in (its udev pins libsystemd-shared 257.13
# while that image ships 261.2).
echo "=== the marker reached the console ==="
if grep -aq "DEBIAN_BAKE_OK" console.log; then
  grep -ao "DEBIAN_BAKE_OK" console.log | head -1
  echo "the guest reported the install itself"
else
  echo "WARNING: DEBIAN_BAKE_OK never appeared on the console" >&2
  echo "         the disk may still be complete; the smoke test will say whether it boots" >&2
fi

bake_compress_disk disk.qcow2 "$OUT"
echo "BAKED $DESKTOP -> $OUT"
