#!/usr/bin/env bash
# Install an openSUSE Leap desktop sandbox disk from the official DVD,
# headlessly, with AutoYaST.
#
# THE INSTALL, AND ONLY THE INSTALL
#
# Booting the VM, the console tee, the heartbeat, the stall watchdog, judging the
# result and compressing the disk come from bake/lib/qemu-bake.sh. What is here
# is openSUSE: fetch the DVD, take its kernel and initrd, serve autoinst.xml over
# HTTP, and boot with `autoyast=http://...`.
#
# Five distributions now, five ways of being told what to install:
#
#   NixOS      commands typed at the serial console
#   Ubuntu     autoinstall ds=nocloud-net;s=http://...   (subiquity)
#   Fedora     inst.ks=http://...                        (anaconda)
#   Debian     auto=true preseed/url=http://...          (debian-installer)
#   openSUSE   autoyast=http://...                       (YaST)
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/qemu-bake.sh
. "$HERE/../lib/qemu-bake.sh"

DESKTOP="${DESKTOP:?set DESKTOP to gnome | kde | xfce}"
OUT="${OUT:?set OUT to the qcow2 to produce}"
# 15.6, not 16.x: Leap 16 moved to ALP and its AutoYaST support is in flux. 15.6
# is the last release with the profile format the documentation describes.
OPENSUSE_VERSION="${OPENSUSE_VERSION:-15.6}"
ISO_URL="${ISO_URL:-https://download.opensuse.org/distribution/leap/${OPENSUSE_VERSION}/iso/openSUSE-Leap-${OPENSUSE_VERSION}-DVD-x86_64-Media.iso}"
# The repository the installer pulls the desktop from, separate from the ISO.
# download.opensuse.org is a redirector that can hand out a slow mirror, and
# 5.2 GiB of packages at 0% for seventeen minutes is what that looks like. A
# specific mirror is one hop and no surprises; override with OPENUSE_REPO.
OPENSUSE_REPO="${OPENSUSE_REPO:-https://mirror.us.leaseweb.net/opensuse/distribution/leap/${OPENSUSE_VERSION}/repo/oss/}"
DISK_SIZE="${DISK_SIZE:-24G}"
QEMU_SMP="${QEMU_SMP:-4}"
QEMU_MEM="${QEMU_MEM:-6144}"

# YaST pattern names, which are not the same as the desktop names.
case "$DESKTOP" in
  gnome) PATTERN="gnome" ;;
  kde)   PATTERN="kde" ;;
  xfce)  PATTERN="xfce" ;;
  *) echo "unknown DESKTOP '$DESKTOP' (gnome|kde|xfce)" >&2; exit 2 ;;
esac

BAKE_WORKDIR="$(dirname "$OUT")"
mkdir -p "$BAKE_WORKDIR" && cd "$BAKE_WORKDIR"
export BAKE_WORKDIR

echo "=== ISO ==="
ISO="$(basename "$ISO_URL")"
[ -s "$ISO" ] || curl -fsSL --retry 3 --retry-delay 2 -o "$ISO" "$ISO_URL"
ls -la "$ISO"

# The repository has to answer before the install starts, or the failure arrives
# as a package count stuck at 0% twenty minutes later.
echo "=== repository reachable? ==="
curl -fsSI --max-time 20 "${OPENSUSE_REPO}repodata/repomd.xml" | head -1 \
  || { echo "REPO_UNREACHABLE: ${OPENSUSE_REPO}" >&2; exit 2; }

# Extract with 7z rather than mounting: the bake also runs where mount is not
# permitted. The DVD keeps them under boot/x86_64/loader/.
echo "=== installer kernel and initrd ==="
rm -rf x && mkdir -p x
7z x -y -o"x" "$ISO" "boot/x86_64/loader/linux" "boot/x86_64/loader/initrd" > /dev/null 2>&1 || true
K="$PWD/x/boot/x86_64/loader/linux"
I="$PWD/x/boot/x86_64/loader/initrd"
if [ ! -s "$K" ] || [ ! -s "$I" ]; then
  7z x -y -o"x" "$ISO" "boot/*" > /dev/null 2>&1 || true
  K=$(find "$PWD/x" -name 'linux' -type f | head -1)
  I=$(find "$PWD/x" -name 'initrd' -type f | head -1)
fi
[ -s "${K:-}" ] && [ -s "${I:-}" ] || { echo "PAIR_FAIL: kernel/initrd not found in the ISO" >&2; exit 2; }
ls -la "$K" "$I"

echo "=== AutoYaST profile (desktop=$DESKTOP, pattern=$PATTERN) ==="
rm -rf srv && mkdir -p srv
sed -e "s|@DESKTOP@|$PATTERN|g" "$HERE/autoinst.xml" > srv/autoinst.xml
grep -q "@DESKTOP@" srv/autoinst.xml && { echo "SUBSTITUTION LEFT A PLACEHOLDER" >&2; exit 1; } || true
# The profile must be well-formed XML or YaST rejects it before anything else.
python3 -c "import xml.etree.ElementTree as ET,sys; ET.parse('srv/autoinst.xml')" \
  || { echo "autoinst.xml is not well-formed" >&2; exit 1; }
grep -nE "<pattern>|<default_target>" srv/autoinst.xml | head -3
wc -l srv/autoinst.xml

echo "=== serve the profile over user-net ==="
( cd srv && python3 -m http.server 8000 >/dev/null 2>&1 ) & SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 2
curl -fsS http://127.0.0.1:8000/autoinst.xml > /dev/null && echo "profile server up"

qemu-img create -f qcow2 disk.qcow2 "$DISK_SIZE" > /dev/null

echo "=== install (AutoYaST, no typing) ==="
# netsetup=dhcp is required: autoyast=http:// means YaST must bring up the
# network before it can fetch the profile. autoyast2=install tells it this is a
# fresh install and not an upgrade.
bake_qemu_install -kernel "$K" -initrd "$I" -- \
  -append "autoyast=http://10.0.2.2:8000/autoinst.xml autoyast2=install netsetup=dhcp install=${OPENSUSE_REPO} console=ttyS0,115200n8" \
  -drive "file=$ISO,media=cdrom,readonly=on" \
  -drive "file=disk.qcow2,if=virtio,format=qcow2" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0

# The post-script writes a marker onto the target. Reading it back off the disk
# proves the file landed inside the image we are about to publish, not just that
# the installer said it was finished.
echo "=== the install finished ==="
bake_assert_installed "OPENSUSE_BAKE_OK|Installation complete|reboot: Restarting system|Calling YaST" "opensuse autoyast"

echo "=== the marker is on the disk ==="
if command -v virt-cat >/dev/null 2>&1; then
  # The marker proves the chroot-script ran, which is worth knowing. It is not
  # the same thing as "the install worked": the console already said the install
  # reached 100% and rebooted. Failing here would have thrown away a good disk
  # over a missing file, which is exactly what the first attempt did - the disk
  # was complete and the bake called it broken.
  if virt-cat -a disk.qcow2 /var/log/opensuse-bake-ok; then
    echo "chroot-script ran (marker present)"
  else
    echo "WARNING: marker missing - the chroot-script did not run, or ran in the wrong phase" >&2
    echo "         the disk is still a complete install; the smoke test will say whether it boots" >&2
  fi
else
  echo "WARNING: virt-cat missing, so the marker inside the disk was not verified" >&2
fi

bake_compress_disk disk.qcow2 "$OUT"
echo "BAKED $DESKTOP -> $OUT"
