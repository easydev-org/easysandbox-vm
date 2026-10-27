#!/usr/bin/env bash
# Install a CachyOS desktop sandbox disk from the official live ISO, headlessly.
#
# HOW THIS ONE DIFFERS FROM THE OTHER FOUR
#
# NixOS, Ubuntu, Fedora, Debian and openSUSE each have an installer that is told
# what to do on the KERNEL COMMAND LINE and runs by itself. CachyOS's Calamares
# has no such mode - its command line has five options and none of them is
# unattended - but CachyOS also ships a CLI installer, `cachyos-installer`, which
# takes a JSON config with "headless_mode": true.
#
# So this bake boots the live ISO, waits for its shell, installs that package,
# and runs it against a config served over the same HTTP server as everything
# else. It is one of the two of five where the bake types into the guest - the
# same shape as NixOS, and for the same reason: the unattended entry point is a
# program inside the image rather than a kernel argument.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/qemu-bake.sh
. "$HERE/../lib/qemu-bake.sh"

DESKTOP="${DESKTOP:?set DESKTOP to kde | gnome | xfce | cosmic}"
OUT="${OUT:?set OUT to the qcow2 to produce}"
CACHYOS_VERSION="${CACHYOS_VERSION:-260809}"
ISO_URL="${ISO_URL:-https://mirror.cachyos.org/ISO/desktop/${CACHYOS_VERSION}/cachyos-desktop-linux-${CACHYOS_VERSION}.iso}"
DISK_SIZE="${DISK_SIZE:-24G}"
QEMU_SMP="${QEMU_SMP:-4}"
QEMU_MEM="${QEMU_MEM:-6144}"

BAKE_WORKDIR="$(dirname "$OUT")"
mkdir -p "$BAKE_WORKDIR" && cd "$BAKE_WORKDIR"
export BAKE_WORKDIR

echo "=== ISO ==="
ISO="$(basename "$ISO_URL")"
[ -s "$ISO" ] || curl -fsSL --retry 3 --retry-delay 2 -o "$ISO" "$ISO_URL"
ls -la "$ISO"

echo "=== kernel and initrd ==="
rm -rf x && mkdir -p x
# Arch-based lives carry their kernel under arch/boot/x86_64/.
7z x -y -o"x" "$ISO" "arch/boot/x86_64/vmlinuz-linux-cachyos" \
                      "arch/boot/x86_64/initramfs-linux-cachyos.img" > /dev/null 2>&1 || true
K="$PWD/x/arch/boot/x86_64/vmlinuz-linux-cachyos"
I="$PWD/x/arch/boot/x86_64/initramfs-linux-cachyos.img"
if [ ! -s "$K" ] || [ ! -s "$I" ]; then
  7z x -y -o"x" "$ISO" "arch/boot/*" > /dev/null 2>&1 || true
  K=$(find "$PWD/x" -name 'vmlinuz*' -type f | head -1)
  I=$(find "$PWD/x" -name 'initramfs*' -type f | head -1)
fi
[ -s "${K:-}" ] && [ -s "${I:-}" ] || { echo "PAIR_FAIL: kernel/initrd not found in the ISO" >&2; exit 2; }
ls -la "$K" "$I"

# The archiso kernel arguments, read out of the ISO's own boot config.
#
# Booting archiso with -kernel and only console= drops you into the initramfs
# rescue shell - the prompt reads '[rootfs ~]#', there is no pacman and no curl,
# and every command typed at it fails with 127. That is exactly what happened
# first. The live image needs:
#
#   archisobasedir=arch archisolabel=<the ISO's own label>
#
# and both are written in the image's grub/syslinux configuration. Reading them
# from there means they cannot drift from the ISO, the same reason the NixOS bake
# reads its kernel and initrd paths out of the image instead of hard-coding them.
echo "=== archiso boot parameters, from the ISO ==="
# 7z does not expand globs inside quotes, so loader/entries/*.conf would be taken
# as a literal path. Extract the whole loader/ and boot/ trees instead - they are
# a few hundred kilobytes and this runs once.
for p in "boot/grub" "loader" "syslinux" "boot/syslinux"; do
  7z x -y -o"x" "$ISO" "$p" > /dev/null 2>&1 || true
done
# Every file that might carry the kernel command line, collected without naming
# them: a missing one must not kill the script under set -e.
FOUND=$(find "$PWD/x" -type f \( -name '*.cfg' -o -name '*.conf' \) 2>/dev/null || true)
echo "config files extracted: $(echo "$FOUND" | grep -c . || true)"
ARCHISO_LINE=""
if [ -n "$FOUND" ]; then
  ARCHISO_LINE=$(cat $FOUND 2>/dev/null \
    | grep -oE "archisobasedir=[^ ]+|archisolabel=[^ \"']+|cow_spacesize=[^ ]+" \
    | sort -u | tr '\n' ' ' || true)
fi
echo "from the ISO's boot config: ${ARCHISO_LINE:-<none found>}"

# The label is NOT in the boot config - it is the ISO9660 volume label, and the
# boot configs reference it by a variable the bootloader fills in. Without it
# archiso prints
#
#   :: Mounting '' to '/run/archiso/bootmnt'
#   ERROR: '' device did not show up after 30 seconds...
#
# and drops to the same rescue shell. The label sits in the Primary Volume
# Descriptor: sector 16 (offset 16*2048 = 32768), 32 bytes at offset 40.
if ! echo "$ARCHISO_LINE" | grep -q 'archisolabel='; then
  echo "reading the volume label out of the ISO9660 header"
  VOLID=$(python3 - "$ISO" <<'PY'
import sys
with open(sys.argv[1], "rb") as f:
    f.seek(16 * 2048)
    pvd = f.read(2048)
if pvd[0] != 1 or pvd[1:6] != b"CD001":
    sys.exit(1)
print(pvd[40:72].decode("ascii", "replace").rstrip())
PY
  ) || { echo "could not read the volume label" >&2; exit 2; }
  echo "volume label: $VOLID"
  ARCHISO_LINE="archisobasedir=arch archisolabel=${VOLID} ${ARCHISO_LINE}"
fi
echo "kernel arguments: ${ARCHISO_LINE}"

echo "=== installer config (desktop=$DESKTOP) ==="
rm -rf srv && mkdir -p srv
sed -e "s|@DESKTOP@|$DESKTOP|g" "$HERE/settings.json" > srv/settings.json
grep -q "@DESKTOP@" srv/settings.json && { echo "SUBSTITUTION LEFT A PLACEHOLDER" >&2; exit 1; } || true
python3 -c "import json;json.load(open('srv/settings.json'))" \
  || { echo "settings.json is not valid JSON" >&2; exit 1; }
cp "$HERE/sandbox-setup.sh" srv/sandbox-setup.sh
sh -n srv/sandbox-setup.sh
python3 -c "
import json
d=json.load(open('srv/settings.json'))
print('headless:', d.get('headless_mode'), '| desktop:', d.get('desktop'), '| device:', d.get('device'))
"

echo "=== serve config over user-net ==="
( cd srv && python3 -m http.server 8000 >/dev/null 2>&1 ) & SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 2
curl -fsS http://127.0.0.1:8000/settings.json > /dev/null && echo "config server up"

qemu-img create -f qcow2 disk.qcow2 "$DISK_SIZE" > /dev/null

# The live ISO autologins to a shell on the graphical console. The commands go
# over the serial console: fetch the CLI installer, install it, copy the config
# and the post script in, run it, then power off. ONE command line ending in
# poweroff, the same shape the NixOS bake uses, because a sequence that depends
# on the host noticing a marker and typing again is a sequence that hangs when it
# misses.
# The live environment is already root - its prompt is '[rootfs ~]#' - and it
# has no `sudo` at all. The first attempt typed `sudo pacman ...` and got
# 'sh: sudo: not found', exit 127, twice. Every command here runs as root
# directly.
#
# `curl` is not guaranteed either; the fetch falls back to `wget`, and if both
# are missing it says so rather than failing quietly three steps later.
echo "=== install (CLI installer, headless) ==="
rm -f serial.in && mkfifo serial.in
{
  # The live environment takes a while to reach its shell; too early and the
  # commands are typed at the bootloader.
  sleep 75
  printf 'echo BAKE_BEGIN; id\n'; sleep 2
  printf 'command -v curl || command -v wget || echo NO_FETCHER\n'; sleep 2
  # ONE line: F has to be set in the same shell that uses it.
  printf 'F="curl -fsS -o"; command -v curl >/dev/null || F="wget -qO"; '
  printf '$F /tmp/settings.json http://10.0.2.2:8000/settings.json && $F /run/sandbox-setup.sh http://10.0.2.2:8000/sandbox-setup.sh || echo FETCH_FAIL\n'
  sleep 4
  printf 'chmod +x /run/sandbox-setup.sh 2>/dev/null; ls -la /run/sandbox-setup.sh /tmp/settings.json\n'; sleep 2
  # The CLI installer is in the CachyOS repo, not on the ISO: pacman fetches it.
  printf 'pacman -Sy --noconfirm cachyos-cli-installer 2>&1; echo PACMAN_RC=$?\n'; sleep 120
  printf 'command -v cachyos-installer || ls /usr/bin/cachyos* 2>&1\n'; sleep 3
  printf 'echo === INSTALLING ===\n'; sleep 2
  printf 'cachyos-installer --config /tmp/settings.json 2>&1; echo INSTALL_RC=$?; sync; poweroff -f\n'
} > serial.in &

# systemd.autologin=ttyS0: the live ISO logs liveuser in on tty1 and leaves the
# serial console at a login prompt. Without this the bake types into a password
# prompt and every command is swallowed - the run reached 'CachyOS login:' and
# then sat there while the heartbeats ticked. The value names the tty the harness
# actually reads and writes.
BAKE_STDIN=serial.in bake_qemu_install -kernel "$K" -initrd "$I" -- \
  -append "${ARCHISO_LINE} console=ttyS0,115200n8 modprobe.blacklist=floppy systemd.autologin=ttyS0" \
  -drive "file=$ISO,media=cdrom,readonly=on" \
  -drive "file=disk.qcow2,if=virtio,format=qcow2" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0

echo "=== result ==="
# Judge on the exit status the guest printed, not on a phrase: a failed install
# still prints plenty of text.
rc=$(grep -ao "INSTALL_RC=[0-9]*" console.log | tail -1 | cut -d= -f2)
echo "cachyos-installer exit status: ${rc:-<never returned>}"
if [ "${rc:-1}" != "0" ]; then
  echo "=== INSTALL FAILED (rc=${rc:-none}) ===" >&2
  first=$(grep -anE "error|ERROR|failed|FAILED" console.log | head -1 | cut -d: -f1 || true)
  if [ -n "$first" ]; then sed -n "$((first>8?first-8:1)),$((first+40))p" console.log >&2
  else tail -80 console.log >&2; fi
  exit 1
fi

echo "=== the marker is on the disk ==="
if command -v virt-cat >/dev/null 2>&1; then
  bake_guest_cat disk.qcow2 /var/log/cachyos-bake-ok || { echo "marker not readable" >&2; exit 1; }
else
  echo "WARNING: virt-cat missing, so the marker inside the disk was not verified" >&2
fi

bake_compress_disk disk.qcow2 "$OUT"
echo "BAKED $DESKTOP -> $OUT"
