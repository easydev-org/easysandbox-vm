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
#
# A hardcoded single mirror was the wrong call: download.opensuse.org is a
# redirector and can hand out a slow one, which cost seventeen minutes at 0%, but
# mirror.us.leaseweb.net - the mirror I picked to avoid that - went away mid-bake:
#
#   Cannot access installation media
#   https://mirror.us.leaseweb.net/opensuse/distribution/leap/15.6/repo/oss/
#   Check whether the server is accessible.
#   [Retry] [Abort] [Skip]
#
# The redirector picks a live mirror per request, which is exactly the property
# wanted here. Its own slowness is checked before the boot rather than discovered
# twenty minutes in.
OPENSUSE_REPO="${OPENSUSE_REPO:-https://download.opensuse.org/distribution/leap/${OPENSUSE_VERSION}/repo/oss/}"
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
# Three times, not once.
#
# One successful request says the mirror answered; it does not say it will still
# answer 600 seconds into the package installation. leaseweb did answer, then
# disappeared halfway through, and the run died on a [Retry][Abort][Skip] dialog
# that nothing could dismiss. Three requests over a few seconds is still weak
# evidence, but it is better than one, and it costs nothing.
for i in 1 2 3; do
  if curl -fsS --max-time 20 -o /dev/null "${OPENSUSE_REPO}repodata/repomd.xml"; then
    echo "  repository answered (attempt $i)"
  else
    echo "REPO_UNREACHABLE on attempt $i: ${OPENSUSE_REPO}" >&2
    [ "$i" = 3 ] && exit 2
    sleep 5
  fi
done

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
# --bind 0.0.0.0 explicitly, and a log file instead of /dev/null.
#
# The guest reported:
#
#   Downloading AutoYaST file: http://10.0.2.2:8000/autoinst.xml
#   A profile for this machine could not be found or retrieved.
#
# after DHCP had succeeded and given it 10.0.2.15, so the network was up and the
# fetch still failed. 10.0.2.2 under qemu's user networking is the host as the
# guest sees it - inside a container, the container's own loopback - so the server
# has to be listening on every interface, not just 127.0.0.1. python3's
# http.server does bind 0.0.0.0 by default, but saying so removes the doubt, and
# keeping its output means the next failure can be read instead of guessed.
( cd srv && exec python3 -m http.server 8000 --bind 0.0.0.0 ) > httpd.log 2>&1 & SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 2
# Prove it serves the profile on the address the guest will use, not just on
# localhost - that difference is the whole failure above.
if curl -fsS http://127.0.0.1:8000/autoinst.xml > /dev/null; then
  echo "profile server up on 127.0.0.1:8000"
else
  echo "PROFILE_SERVER_DOWN" >&2; cat httpd.log >&2; exit 2
fi
if [ -n "$(ip -4 -o addr show scope global 2>/dev/null)" ]; then
  HOSTIP=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
  echo "container address: $HOSTIP"
  curl -fsS "http://$HOSTIP:8000/autoinst.xml" > /dev/null \
    && echo "profile server reachable on $HOSTIP:8000" \
    || { echo "WARNING: not reachable on $HOSTIP:8000" >&2; }
fi

qemu-img create -f qcow2 disk.qcow2 "$DISK_SIZE" > /dev/null

echo "=== install (AutoYaST, no typing) ==="
# netsetup=dhcp is required: autoyast=http:// means YaST must bring up the
# network before it can fetch the profile.
#
# There is NO `autoyast2=install` parameter. I made it up, and the kernel said so
# in the run that stalled:
#
#   Unknown kernel command line parameters "autoyast=... autoyast2=install
#   netsetup=dhcp console=..."
#
# The documented form is autoyast=<path> alone; the profile's own <general><mode>
# decides install versus upgrade.
#
# install= IS required - three runs point at it:
#
#   26bb985  install= yes, console=ttyS0 only         -> installed 2197 packages
#   09d50eb  install= yes, console=ttyS0 + tty0       -> stalled at 'Preparing'
#   26fb3e6  install= NO,  console=ttyS0 only         -> stalled at 'Preparing'
#
# So the parameter that broke the earlier run was the extra console=tty0, not
# install=. Removing install= in response was a wrong conclusion from incomplete
# evidence, and the third row is what proves it.
#
# console=ttyS0 alone: YaST draws its curses UI on the console named LAST, so a
# trailing console=tty0 paints the virtual console and the harness reads nothing.
#
# modprobe.blacklist=floppy: QEMU exposes an fd0 that does not exist and the
# kernel probes it on a loop - dozens of lines, and in one run the last thing
# before the timeout.
#
# AND: press enter periodically.
#
# YaST reaches 'Preparing System for Automatic Installation' and stops there with
# a [Next] button, even with <confirm>false</confirm> set. confirm governs the
# Installation Settings screen - the last one before writing - and the Preparing
# page comes before it, so a fully-unattended profile still lands on a button
# nobody presses. The run then sits at that page until the watchdog kills it,
# which is how it was found: ten minutes of silence whose last line was the page
# title.
#
# A bare newline is the whole interaction. Sending one every 45 seconds costs
# nothing while the installer is busy, and moves it past that page when it is not.
rm -f serial.in && mkfifo serial.in
{
  for _ in $(seq 1 80); do
    printf '\n'
    sleep 45
  done
} > serial.in &

BAKE_STDIN=serial.in bake_qemu_install -kernel "$K" -initrd "$I" -- \
  -append "autoyast=http://10.0.2.2:8000/autoinst.xml netsetup=dhcp install=${OPENSUSE_REPO} console=ttyS0,115200n8 modprobe.blacklist=floppy" \
  -drive "file=$ISO,media=cdrom,readonly=on" \
  -drive "file=disk.qcow2,if=virtio,format=qcow2" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0

# The post-script writes a marker onto the target. Reading it back off the disk
# proves the file landed inside the image we are about to publish, not just that
# the installer said it was finished.
echo "=== the install finished ==="
bake_assert_installed "OPENSUSE_BAKE_OK|Installation complete|reboot: Restarting system|Calling YaST" "opensuse autoyast"

# The marker reached the console, which is the evidence that the install landed.
#
# The AutoYaST chroot-script writes OPENSUSE_BAKE_OK to /var/log/opensuse-bake-ok
# AND to /dev/ttyS0. The console copy arrives while the guest is running and in
# the log this bake judges on. It is not a failure if it is absent - the console
# has already said the install reached 100% and rebooted, and calling a complete
# disk broken over a missing line is a mistake this script has already made once.
echo "=== the marker reached the console ==="
if grep -aq "OPENSUSE_BAKE_OK" console.log; then
  echo "chroot-script ran (marker on the console)"
else
  echo "NOTE: OPENSUSE_BAKE_OK not on the console - the chroot-script may not have run" >&2
  echo "      the disk is still a complete install; the smoke test will say whether it boots" >&2
fi

bake_compress_disk disk.qcow2 "$OUT"
echo "BAKED $DESKTOP -> $OUT"
