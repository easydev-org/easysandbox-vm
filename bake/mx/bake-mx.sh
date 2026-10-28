#!/usr/bin/env bash
# Bake an MX Linux desktop disk with its own installer in unattended mode.
#
# WHY THIS ONE IS EASY, AFTER ENDEAVOURS WAS NOT
#
# MX ships gazelle-installer (minstall), and its manpage documents exactly what
# this bake needs:
#
#   --auto           Install automatically using the configuration file
#   -c, --config <f> Load a configuration file
#   -f, --poweroff   Shut down automatically when done
#   --tui            Text interface (ncurses)
#
# and app.cpp checks for --tui BEFORE constructing a QApplication, so nothing here
# needs a display server. It runs on the serial console, which is where the harness
# reads and writes.
#
# That is the difference from Calamares, which took five rounds and installed
# nothing: no configuration file, no command-line switch, only a window.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/qemu-bake.sh
. "$HERE/../lib/qemu-bake.sh"

OUT="${OUT:?set OUT to the qcow2 to produce}"
MX_VERSION="${MX_VERSION:-25.3}"
MX_EDITION="${MX_EDITION:-Xfce}"
# The real name is MX-25.3_Xfce_x64.iso, from the release index at
# sourceforge.net/projects/mx-linux/files/Final/ - "MX-25.3 is the current release".
# SourceForge serves it through a redirect, so -L is required and the landed file
# has to be the 2.9 GB image rather than an HTML page; the size check below is what
# catches that.
#
# The two ISP mirrors tried first both 404 on this path, so the download goes
# through SourceForge's redirect and the size check is the guard.
ISO_URL="${ISO_URL:-https://sourceforge.net/projects/mx-linux/files/Final/${MX_EDITION}/MX-${MX_VERSION}_${MX_EDITION}_x64.iso/download}"
DISK_SIZE="${DISK_SIZE:-24G}"
QEMU_MAX="${QEMU_MAX:-3600}"
# 6144: without -m qemu starts with 128 MB, and MX's initramfs would not load - the
# EndeavourOS bake reported that as "initramfs: Bad file number" for a whole round.
QEMU_SMP="${QEMU_SMP:-4}"
QEMU_MEM="${QEMU_MEM:-6144}"

WORK="$(dirname "$OUT")"
mkdir -p "$WORK" && cd "$WORK"

echo "=== ISO ==="
ISO="$WORK/mx.iso"
if [ ! -s "$ISO" ]; then
  # SourceForge redirects to a mirror; -L is required and the downloaded file has to
  # be an ISO rather than a HTML landing page, so the size is checked.
  curl -fsSL --retry 3 --retry-delay 2 -o "$ISO" "$ISO_URL"
fi
ls -la "$ISO"
if [ "$(stat -c%s "$ISO")" -lt 500000000 ]; then
  echo "the ISO is under 500 MB - that is a redirect page, not an image" >&2
  head -c 400 "$ISO" >&2
  exit 2
fi

echo "=== install disk ==="
qemu-img create -f qcow2 disk.qcow2 "$DISK_SIZE" > /dev/null
ls -la disk.qcow2

# Extract the kernel and initrd so the boot needs no keystrokes.
#
# The Tab-at-the-menu route is what the Arch bake tried first, and ISOLINUX's line
# editor dropped characters from a fast serial write - the kernel command line came
# out as "console=ttyS0,root" and the serial console never came up. Passing
# -kernel/-initrd puts the command line under our control instead.
#
# MX's isolinux config carries no console= parameter, so without this the kernel
# talks to tty1 and the run stops at:
#
#   Initializing gfx code...
#   <18 console lines total, then nothing for six minutes>
echo "=== kernel and initrd ==="
rm -rf x && mkdir -p x
# 7z's output is kept rather than discarded, so a failed extraction says why. The
# first version piped it to /dev/null with "|| true" - the same mistake that cost
# two rounds on the EndeavourOS bake.
echo "  extracting with 7z:"
# The paths are /antiX/vmlinuz and /antiX/initrd.gz, NOT boot/*. From MX's own
# iso-template, iso-template/boot/isolinux/isolinux.cfg:
#
#   LABEL live
#       KERNEL /antiX/vmlinuz
#       INITRD /antiX/initrd.gz
#
# The first attempt asked for boot/vmlinuz and 7z answered "No files to process" -
# the log said everything except what was wrong.
#
# That same file explains the hang: "UI gfxboot gfx-cpio readme.msg" - MX's boot menu
# is a graphical gfxboot menu that draws to the VGA console and leaves the serial
# port silent right after "Initializing gfx code...". Unlike archiso it enables no
# serial console of its own, so -kernel/-initrd is not merely preferred, it is the
# only way in.
7z x -y -o"x" "$ISO" "antiX/vmlinuz" "antiX/initrd.gz" 2>&1 | tail -12
echo "  extracted tree:"
find "$PWD/x" -type f 2>/dev/null | head -10 || echo "  (nothing)"
K=$(find "$PWD/x" -name 'vmlinuz*' -type f 2>/dev/null | head -1)
I=$(find "$PWD/x" -name 'initrd*' -type f 2>/dev/null | head -1)
DIRECT_BOOT=0
if [ -n "${K:-}" ] && [ -s "${K:-}" ] && [ -n "${I:-}" ] && [ -s "${I:-}" ]; then
  I_SIZE=$(stat -c%s "$I")
  echo "kernel: $K"
  echo "initrd: $I ($I_SIZE bytes)"
  if [ "$I_SIZE" -lt 136314880 ]; then
    DIRECT_BOOT=1
    echo "small enough for -kernel/-initrd"
  else
    echo "too large for -kernel/-initrd: falling back to the boot menu"
  fi
else
  echo "could not extract the pair: falling back to the boot menu"
fi

# MX's initrd fixes CONSOLE to /dev/tty1 at the switch_root, so the serial console
# goes silent after the initrd is done - see patch-initrd.sh for the line and the
# reasoning. The initrd is patched here rather than at the boot menu because there is
# no menu parameter that reaches that line.
if [ "${SKIP_INITRD_PATCH:-0}" != 1 ]; then
  echo "=== patching the initrd's hardcoded CONSOLE ==="
  if bash "$HERE/patch-initrd.sh" "$I"; then
    echo "initrd patched"
  else
    echo "INITRD PATCH FAILED - the serial console will go silent after switch_root" >&2
  fi
fi

echo "=== serve the installer configuration ==="
rm -rf srv && mkdir -p srv
cp "$HERE/minstall.conf" srv/minstall.conf
( cd srv && exec python3 -m http.server 8000 --bind 0.0.0.0 ) > httpd.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 2
curl -fsS http://127.0.0.1:8000/minstall.conf > /dev/null || { echo "server down" >&2; exit 2; }
echo "server up"

echo "=== boot the live ISO and run the installer unattended ==="
rm -f serial.in && mkfifo serial.in
{
  # 1. console=ttyS0 at the boot menu.
  #
  # MX's ISO boots through ISOLINUX and its syslinux config carries no console=
  # parameter, so the kernel talks to tty1 and the serial port goes quiet:
  #
  #   Initializing gfx code...
  #   <18 console lines total, then nothing for five minutes>
  #
  # DIRECT_BOOT means -kernel/-initrd was used and the command line is already ours,
  # so nothing is typed. Otherwise Tab at the ISOLINUX menu, ONE CHARACTER AT A TIME:
  # the line editor drops whatever arrives too fast, which is how the Arch bake's
  # command line came out as "console=ttyS0,root" with 115200n8 missing.
  if [ "${DIRECT_BOOT:-0}" != 1 ]; then
    sleep 5
    printf '\011'
    sleep 2
    # The leading space matters: without it the parameter is glued to the last
    # token on the line, and the kernel sees an initrd path of
    # "...initramfs-linux.imgconsole=ttyS0". That is exactly what the previous
    # run produced.
    for ch in ' ' c o n s o l e = t t y S 0 , 1 1 5 2 0 0 n 8; do
      printf '%s' "$ch"
      sleep 0.12
    done
    sleep 2
    printf '\n'
    sleep 3
  fi

  # 2. Log in.
  #
  # MX's live session autologins as demo on tty1; ttyS0 gets a login prompt. Sending
  # root repeatedly is harmless at a shell prompt and removes the guess about how
  # long boot takes - a fixed sleep typed into a kernel that was still starting, on
  # the EndeavourOS bake, and the run sat at the prompt until the watchdog killed it.
  for _ in $(seq 1 14); do
    printf 'root\n'
    sleep 2
    printf '\n'
    sleep 13
  done

  printf 'echo MX_BEGIN; id; ls /dev/vda; command -v minstall\n'; sleep 3
  # Short commands, sent one at a time.
  #
  # The Arch bake showed a long line arriving faster than the live shell could echo
  # it, coming back mangled ("root@archiso ~ # :(e") and exiting 127 - command not
  # found, because the command never arrived intact. One line each, with a pause.
  send() { printf '%s\n' "$1"; sleep "${2:-3}"; }

  send 'curl -fsS -o /root/minstall.conf http://10.0.2.2:8000/minstall.conf; echo CURL_RC=$?' 6
  send 'wc -l /root/minstall.conf' 3
  send 'command -v minstall' 3
  # --tui first, so no display server is wanted; --auto to accept the file;
  # --poweroff so qemu stops when the install ends. The status is echoed on the same
  # line, or $? would belong to the sleep in between.
  send 'minstall --tui --auto --poweroff --config /root/minstall.conf; echo MINSTALL_RC=$?' 5
  send 'sync' 2
} > serial.in &

if [ "${DIRECT_BOOT:-0}" = 1 ]; then
  echo "booting with -kernel/-initrd; the command line is ours"
  # MX's initrd finds the live media by scanning for the antiX directory, so the ISO
  # stays attached as a CD and the initrd finds it there. The command line is
  # deliberately minimal: console=ttyS0 for the harness, and quiet to keep the log
  # readable. MX's own %OPTIONS% carries boot= and other live-boot parameters, but
  # those are filled in by its build script and the initrd defaults work without
  # them - if the guest drops to a shell instead, this is the first line to look at.
# The command line needs CONSOLE= as well as console=, and that is not obvious.
#
# MX's initrd/init parses the kernel command line and then does, at the point where
# it hands over to the real system:
#
#   exec $LIVE_BIN/switch_root $NEW_ROOT /usr/bin/env CONSOLE=/dev/tty1 $INIT_COMMAND "$@"
#
# CONSOLE is hardcoded to /dev/tty1 there. The parameter list a few hundred lines
# earlier does accept it:
#
#   console=*) CMD_MY_TTY=${value#tty}
#   CONSOLE=*) CMD_MY_TTY=${value#tty}
#
# but MY_TTY turns out to be used only for chvt, the tsplash screen switching, so it
# does not move the console output. Passing CONSOLE=/dev/ttyS0 here is the cheap
# experiment: if switch_root's env is what decides, the serial console comes back;
# if it does not, the next step is to unpack the initrd and change that line, which
# is a much bigger hammer.
  BAKE_STDIN=serial.in QEMU_MAX="$QEMU_MAX" bake_qemu_install \
    -kernel "$K" -initrd "$I" -- \
    -append "console=ttyS0,115200n8 CONSOLE=/dev/ttyS0" \
    -drive "file=$ISO,media=cdrom,readonly=on" \
    -drive "file=$WORK/disk.qcow2,if=virtio,format=qcow2" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -device "VGA,edid=on,xres=${SCREEN_W:-1280},yres=${SCREEN_H:-800}"
else
  echo "booting the CD; console=ttyS0 goes in at the ISOLINUX menu"
  BAKE_STDIN=serial.in QEMU_MAX="$QEMU_MAX" bake_qemu_install \
    -drive "file=$ISO,media=cdrom,readonly=on" \
    -drive "file=$WORK/disk.qcow2,if=virtio,format=qcow2" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -device "VGA,edid=on,xres=${SCREEN_W:-1280},yres=${SCREEN_H:-800}"
fi

echo "=== result ==="
rc=$(grep -ao "MINSTALL_RC=[0-9]*" console.log | tail -1 | cut -d= -f2)
echo "minstall exit status: ${rc:-<never returned>}"

# The installer's own log is on the target as well; keep the live copy if it exists.
if grep -q "MINSTALL_RC=0" console.log; then
  echo "installer reported success"
else
  echo "=== INSTALL DID NOT REPORT SUCCESS (rc=${rc:-none}) ===" >&2
  first=$(grep -anE "error|ERROR|failed|Failed|cannot" console.log | head -1 | cut -d: -f1 || true)
  if [ -n "$first" ]; then
    sed -n "$((first>20?first-20:1)),$((first+50))p" console.log >&2
  else
    tail -70 console.log >&2
  fi
  exit 1
fi

echo "=== the disk ==="
qemu-img info disk.qcow2
DISK_BYTES=$(stat -c%s disk.qcow2)
echo "disk.qcow2 is ${DISK_BYTES} bytes"
if [ "$DISK_BYTES" -lt 1000000000 ]; then
  echo "=== THE DISK IS EMPTY (${DISK_BYTES} bytes) ===" >&2
  exit 1
fi

bake_compress_disk disk.qcow2 "$OUT"
echo "BAKED mx -> $OUT"
