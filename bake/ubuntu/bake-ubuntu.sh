#!/usr/bin/env bash
# Install an Ubuntu desktop sandbox disk from the official live-server ISO,
# headlessly, with autoinstall.
#
# THE INSTALL, AND ONLY THE INSTALL
#
# Booting the VM, keeping the console visible, judging the result and compressing
# the disk are in bake/lib/qemu-bake.sh, because they are the same for every
# distribution. What is here is the part that is Ubuntu: fetch the ISO, take the
# casper kernel and initrd out of it, serve user-data over HTTP, and boot with
# `autoinstall ds=nocloud-net;...` on the kernel command line.
#
# There is no shell to type into. subiquity fetches the seed and does the rest;
# the guest shuts itself down when `shutdown: poweroff` fires. That is the whole
# difference from the NixOS bake, where the install is whatever we type.
#
# -kernel/-initrd is not a trick: it is what Ubuntu's own autoinstall quick
# start does (casper/vmlinuz + casper/initrd), and it avoids depending on the
# ISO's boot menu.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/qemu-bake.sh
. "$HERE/../lib/qemu-bake.sh"

DESKTOP="${DESKTOP:?set DESKTOP to ubuntu | kubuntu | xubuntu}"
OUT="${OUT:?set OUT to the qcow2 to produce}"
# Pinned, not `latest`: autoinstall keys and the casper layout are stable within
# an Ubuntu release and not across them, so `latest` would mean a bake that
# breaks on someone else's schedule.
UBUNTU_VERSION="${UBUNTU_VERSION:-26.04.1}"
ISO_URL="${ISO_URL:-https://releases.ubuntu.com/26.04/ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso}"
RELEASE="${RELEASE:-resolute}"
DISK_SIZE="${DISK_SIZE:-24G}"
QEMU_SMP="${QEMU_SMP:-4}"
QEMU_MEM="${QEMU_MEM:-6144}"

case "$DESKTOP" in
  ubuntu)  PKG=ubuntu-desktop ;;
  kubuntu) PKG=kubuntu-desktop ;;
  xubuntu) PKG=xubuntu-desktop ;;
  *) echo "unknown DESKTOP '$DESKTOP' (ubuntu|kubuntu|xubuntu)" >&2; exit 2 ;;
esac

BAKE_WORKDIR="$(dirname "$OUT")"
mkdir -p "$BAKE_WORKDIR" && cd "$BAKE_WORKDIR"
export BAKE_WORKDIR

echo "=== ISO ==="
ISO="ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
[ -s "$ISO" ] || curl -fsSL --retry 3 --retry-delay 2 -o "$ISO" "$ISO_URL"
ls -la "$ISO"

# Extracted with 7z rather than mounted: the bake also runs where mount is not
# permitted.
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
# A placeholder left behind is a bake that installs the wrong thing quietly.
grep -n "@DESKTOP@\|@RELEASE@" srv/user-data \
  && { echo "SUBSTITUTION LEFT A PLACEHOLDER" >&2; exit 1; } || true
wc -l srv/user-data

echo "=== serve the seed over user-net ==="
# qemu user networking puts the host at 10.0.2.2, which is the `_gateway`
# cloud-init resolves for that address. subiquity fetches /user-data and
# /meta-data from here.
( cd srv && python3 -m http.server 8000 >/dev/null 2>&1 ) & SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 2
curl -fsS http://127.0.0.1:8000/user-data > /dev/null && echo "seed server up"

qemu-img create -f qcow2 disk.qcow2 "$DISK_SIZE" > /dev/null

echo "=== install (autoinstall, no typing) ==="
bake_qemu_install -kernel "$K" -initrd "$I" -- \
  -append "autoinstall ds=nocloud-net;s=http://10.0.2.2:8000/ console=ttyS0,115200n8" \
  -drive "file=$ISO,media=cdrom,readonly=on" \
  -drive "file=disk.qcow2,if=virtio,format=qcow2" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0

# The marker reached the console, which is the evidence that the install landed.
#
# The autoinstall late-command writes UBUNTU_BAKE_OK to /var/log/ubuntu-bake-ok
# AND to /dev/ttyS0. The console copy arrives while the guest is running, in the
# log this bake judges on; reading the file back off the finished disk would need
# virt-cat, which cannot be installed on the image these bakes run in.
echo "=== the marker reached the console ==="
bake_assert_installed "UBUNTU_BAKE_OK|Installation complete" "ubuntu autoinstall"

bake_compress_disk disk.qcow2 "$OUT"
echo "BAKED $DESKTOP -> $OUT"
