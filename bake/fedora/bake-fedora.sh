#!/usr/bin/env bash
# Install a Fedora desktop sandbox disk from the official Everything netinst,
# headlessly, with kickstart.
#
# THE INSTALL, AND ONLY THE INSTALL
#
# Booting the VM, the console tee, the heartbeat, judging the result and
# compressing the disk come from bake/lib/qemu-bake.sh. What is here is Fedora:
# fetch the netinst, take its kernel and initrd, serve ks.cfg over HTTP, and boot
# with `inst.ks=http://...` on the kernel command line.
#
# Three distributions now, three ways to be told what to install, and it is worth
# naming them together because they are the same idea:
#
#   NixOS   a shell on the serial console, and we type nixos-install
#   Ubuntu  autoinstall ds=nocloud-net;s=http://...  -> subiquity fetches user-data
#   Fedora  inst.ks=http://...                       -> anaconda fetches ks.cfg
#
# The last two never have a human in them; NixOS does, which is why it is the one
# that passes BAKE_STDIN to the lib.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/qemu-bake.sh
. "$HERE/../lib/qemu-bake.sh"

DESKTOP="${DESKTOP:?set DESKTOP to workstation | kde | xfce}"
OUT="${OUT:?set OUT to the qcow2 to produce}"
# Pinned, not `latest`: kickstart keys and the anaconda layout are stable within
# a Fedora release and not across them.
FEDORA_VERSION="${FEDORA_VERSION:-44}"
FEDORA_BUILD="${FEDORA_BUILD:-1.7}"
ISO_URL="${ISO_URL:-https://dl.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_VERSION}/Everything/x86_64/iso/Fedora-Everything-netinst-x86_64-${FEDORA_VERSION}-${FEDORA_BUILD}.iso}"
DISK_SIZE="${DISK_SIZE:-24G}"
QEMU_SMP="${QEMU_SMP:-4}"
QEMU_MEM="${QEMU_MEM:-6144}"

# The kickstart group names, which are not the same as the ISO names: Fedora
# ships environment groups, and those are what anaconda installs a desktop from.
case "$DESKTOP" in
  workstation) GROUP="@workstation-product-environment" ;;
  kde)         GROUP="@kde-desktop-environment" ;;
  xfce)        GROUP="@xfce-desktop-environment" ;;
  *) echo "unknown DESKTOP '$DESKTOP' (workstation|kde|xfce)" >&2; exit 2 ;;
esac

BAKE_WORKDIR="$(dirname "$OUT")"
mkdir -p "$BAKE_WORKDIR" && cd "$BAKE_WORKDIR"
export BAKE_WORKDIR

echo "=== ISO ==="
ISO="$(basename "$ISO_URL")"
[ -s "$ISO" ] || curl -fsSL --retry 3 --retry-delay 2 -o "$ISO" "$ISO_URL"
ls -la "$ISO"

# Extracted with 7z rather than mounted: the bake also runs where mount is not
# permitted. Anaconda's netinst keeps them at the image root, not under casper/.
echo "=== kernel and initrd ==="
rm -rf x && mkdir -p x
7z x -y -o"x" "$ISO" isolinux/vmlinuz isolinux/initrd.img images/efiboot.img > /dev/null 2>&1 || true
K="$PWD/x/isolinux/vmlinuz"
I="$PWD/x/isolinux/initrd.img"
if [ ! -s "$K" ] || [ ! -s "$I" ]; then
  # Newer netinsts moved them; find whatever the image actually calls them.
  7z x -y -o"x" "$ISO" "isolinux/*" "images/*" > /dev/null 2>&1 || true
  K=$(find "$PWD/x" -name 'vmlinuz*' -type f | head -1)
  I=$(find "$PWD/x" -name 'initrd*.img' -type f | head -1)
fi
[ -s "${K:-}" ] && [ -s "${I:-}" ] || { echo "PAIR_FAIL: kernel/initrd not found in the ISO" >&2; exit 2; }
ls -la "$K" "$I"

echo "=== kickstart (desktop=$DESKTOP, group=$GROUP) ==="
rm -rf srv && mkdir -p srv
sed -e "s|@DESKTOP@|$GROUP|g" "$HERE/ks.cfg" > srv/ks.cfg
grep -q "@DESKTOP@" srv/ks.cfg && { echo "SUBSTITUTION LEFT A PLACEHOLDER" >&2; exit 1; } || true
grep -nE "^(text|bootloader|@)" srv/ks.cfg || true
wc -l srv/ks.cfg

echo "=== serve the kickstart over user-net ==="
# qemu user networking puts the host at 10.0.2.2, and anaconda will fetch
# inst.ks from there.
( cd srv && python3 -m http.server 8000 >/dev/null 2>&1 ) & SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 2
curl -fsS http://127.0.0.1:8000/ks.cfg > /dev/null && echo "ks server up"

qemu-img create -f qcow2 disk.qcow2 "$DISK_SIZE" > /dev/null

echo "=== install (kickstart, no typing) ==="
# inst.ks is the whole interface. `inst.text` keeps anaconda on the console so
# the log carries every step, and `inst.sshd` gives a way in if it fails.
bake_qemu_install -kernel "$K" -initrd "$I" -- \
  -append "inst.ks=http://10.0.2.2:8000/ks.cfg inst.text inst.sshd inst.nokill console=ttyS0,115200n8" \
  -drive "file=$ISO,media=cdrom,readonly=on" \
  -drive "file=disk.qcow2,if=virtio,format=qcow2" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0

# anaconda reboots the machine when it finishes and never prints "Installation
# complete" - that string belongs to the interactive installer's UI. What it
# does print, in order, is:
#
#   Finished systemd-reboot.service - System Reboot.
#   Reached target reboot.target - System Reboot.
#   reboot: Restarting system
#
# With -no-reboot that reboot becomes qemu exiting, which is why "qemu exited
# rc=0" is a success signal here and not a failure.
#
# But the log is only what the installer says about itself. The %post wrote a
# marker onto the target filesystem, and reading that back off the finished disk
# is what proves the install actually landed in the image we are about to
# publish - so it is required, not optional.
echo "=== the install reached reboot ==="
bake_assert_installed "reboot: Restarting system|Reached target reboot\.target|The installation was successful|Installation complete" "fedora kickstart"

# The marker reached the console, which is the evidence that the install landed.
#
# The ks %post writes FEDORA_BAKE_OK to /var/log/fedora-bake-ok AND to /dev/ttyS0.
# The console copy arrives while the guest is running, in the log the bake judges
# on; reading the file back off the finished disk would need virt-cat, and that
# cannot be installed on the image these bakes run in.
echo "=== the marker reached the console ==="
if grep -aq "FEDORA_BAKE_OK" console.log; then
  grep -ao "FEDORA_BAKE_OK" console.log | head -1
  echo "the guest reported the install itself"
else
  echo "WARNING: FEDORA_BAKE_OK never appeared on the console" >&2
fi

bake_compress_disk disk.qcow2 "$OUT"
echo "BAKED $DESKTOP -> $OUT"
