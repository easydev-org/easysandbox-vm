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

# No initrd patching. The serial console question is answered from the command line
# instead, by telling the initrd which program to hand over to.

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

  # 2. Log in as demo.
  #
  # The login banner says it outright, once systemd's getty is up:
  #
  #   Welcome to MX 25.3_Xfce (Infinity) 64-bit! Powered by Debian.
  #   For command line install, login as demo (password=demo).
  #   Enter the command /usr/bin/minstall-launcher.
  #
  # The previous attempt sent 'root' with an empty password, which produced
  # 'Login incorrect' on every line and left the shell reading the following
  # commands as further login attempts.
  for _ in $(seq 1 14); do
    printf 'demo\n'
    sleep 2
    printf 'demo\n'
    sleep 13
  done

  printf 'echo MX_BEGIN; id; ls /dev/vda; command -v minstall\n'; sleep 3
  # Short commands, sent one at a time.
  #
  # The Arch bake showed a long line arriving faster than the live shell could echo
  # it, coming back mangled ("root@archiso ~ # :(e") and exiting 127 - command not
  # found, because the command never arrived intact. One line each, with a pause.
  send() { printf '%s\n' "$1"; sleep "${2:-3}"; }

  # Into /home/demo, which the logged-in user owns - fetching to /root as demo would
  # fail on permissions before the installer is ever reached.
  send 'curl -fsS -o /home/demo/minstall.conf http://10.0.2.2:8000/minstall.conf; echo CURL_RC=$?' 6
  send 'sudo -n true 2>/dev/null && echo SUDO_NOPASSWD || echo SUDO_NEEDS_PASSWORD' 4
  send 'wc -l /home/demo/minstall.conf' 4
  send 'command -v minstall; command -v minstall-launcher' 3
  # A liveness probe, before the long command.
  #
  # The previous run could not be told apart from a hung one: thirty minutes of
  # silence looked identical either way, and it had to be cancelled blind. If the
  # serial console is alive this line comes back in seconds; if it is not, the log
  # says so immediately instead of half an hour later.
  send 'echo MX_CONSOLE_ALIVE $(id -u) $(ls /antiX 2>/dev/null | head -1)' 4
  # --tui first, so no display server is wanted; --auto to accept the file;
  # --poweroff so qemu stops when the install ends. The status is echoed on the same
  # line, or $? would belong to the sleep in between.
  # Run the installer in the background and report on it, rather than starting it
  # and going quiet.
  #
  # THROUGH sudo: its manpage says "minstall must be run as root", and the config
  # sits in demo's home. -S feeds the password on stdin because there is no terminal
  # to prompt on. The installer writes /var/log/minstall.log on the live system and
  # copies it to the target, so the markers below read THAT file rather than the
  # screen.
  #
  # WHY MARKERS INSTEAD OF STREAMING THE SCREEN
  #
  # Streaming a curses TUI does not survive log-stream: every line carries a
  # 31-character timestamp, its render() drops whole lines to fit 65535 characters,
  # and a redrawing TUI produces either megabytes per line or thousands of
  # meaningless ones. Seven attempts at filtering it came to nothing.
  #
  # Four echo lines say what the screen could not: whether the installer started,
  # whether it is progressing, and how it ended.
  # A pseudo-terminal, not a redirect.
  #
  # The previous attempt sent the TUI's output to a file:
  #
  #   minstall --tui ... > /tmp/mx-install.out 2>&1 &
  #
  # and the installer started, wrote 119 lines to its own log, and then sat there
  # for fourteen minutes with the count frozen. A curses interface needs a terminal;
  # with stdout on a regular file there is nothing for it to draw on, so it waits.
  #
  # script(1) gives it one: the command runs under a pty and everything it draws is
  # written to /tmp/mx-install.out as text. -q quiet, -f flush, -c the command.
  # The disk has to look like a disk before the installer will offer it.
  #
  # minstall stopped at 'Scanning disk drives...' for twenty-five minutes while its
  # own log showed why: it runs lsblk and parted, and the only device either of them
  # reports is /dev/sr0, the CD. /dev/vda exists - a plain 'ls /dev/vda' in the same
  # session printed it - but with no partition table on it parted has nothing to
  # describe, so nothing is listed and the drive menu stays empty.
  #
  # sgdisk writes a GPT label. It is the live system's own tool, it is instant, and
  # it leaves the disk empty of partitions for the installer to create.
  send 'echo demo | sudo -S sgdisk --zap-all /dev/vda; echo ZAP_RC=$?' 8
  send 'echo demo | sudo -S parted -lm' 6
  send 'echo demo | sudo -S lsblk -o NAME,SIZE,TYPE' 4

  send 'echo demo | sudo -S script -q -f -c "minstall --tui --auto --poweroff --config /home/demo/minstall.conf; echo MINSTALL_RC=\$?" /tmp/mx-install.out > /dev/null 2>&1 &' 3
  send 'sleep 5; echo MINSTALL_STARTED; pgrep -c minstall || echo MINSTALL_NOT_RUNNING' 8

  # The progress markers. Each one is a line the job log will show, whatever the
  # installer is doing to the screen.
  # Watch until the installer finishes, or until the bake gives up.
  #
  # 60 iterations x 25 seconds is twenty-five minutes of markers; MX installs XFCE
  # from a local ISO in about that. Each marker is one short line, so the 64 KB
  # budget log-stream gives a check run covers every one of them with room to spare -
  # which is the whole difference from streaming the screen.
  for i in $(seq 1 60); do
    send 'if [ -f /tmp/mx-rc ]; then echo MINSTALL_FINISHED $(cat /tmp/mx-rc); else echo MINSTALL_RUNNING-\$i log=$(sudo -n wc -l < /var/log/minstall.log 2>/dev/null || echo 0) out=$(wc -l < /tmp/mx-install.out 2>/dev/null || echo 0); fi' 4
    sleep 21
  done

  # Whatever the installer said at the end, keep it.
  send 'cat /tmp/mx-rc 2>/dev/null || echo MINSTALL_STILL_RUNNING' 3
  send 'tail -25 /tmp/mx-install.out' 4
  send 'sudo -n tail -25 /var/log/minstall.log' 4
} > serial.in &

if [ "${DIRECT_BOOT:-0}" = 1 ]; then
  echo "booting with -kernel/-initrd; the command line is ours"
  # MX's initrd finds the live media by scanning for the antiX directory, so the ISO
  # stays attached as a CD and the initrd finds it there. The command line is
  # deliberately minimal: console=ttyS0 for the harness, and quiet to keep the log
  # readable. MX's own %OPTIONS% carries boot= and other live-boot parameters, but
  # those are filled in by its build script and the initrd defaults work without
  # them - if the guest drops to a shell instead, this is the first line to look at.
# init= instead of patching the initrd.
#
# MX's initrd/init hands over to the real system with CONSOLE fixed to /dev/tty1:
#
#   exec $LIVE_BIN/switch_root $NEW_ROOT /usr/bin/env CONSOLE=/dev/tty1 $INIT_COMMAND "$@"
#
# Three things were tried in that order:
#
#   1. CONSOLE=/dev/ttyS0 on the command line - no effect. Line 883 does parse it,
#      but the value lands in MY_TTY, which is only used by chvt for tsplash.
#   2. Patching the initrd - abandoned. Its archive is an UNCOMPRESSED cpio called
#      initrd.gz, and the bake image has no cpio binary, so this meant writing a cpio
#      reader by hand. That is the same shape of mistake as reimplementing virt-cat.
#   3. This: the initrd already honours init= from the command line -
#
#        init=*) INIT_PROG=$value ; export INIT_PROG
#
#      and INIT_PROG is what $INIT_COMMAND ends up holding at the switch_root. So the
#      handover can be pointed at systemd directly, and systemd's getty generator
#      starts serial-getty@ttyS0 by itself for every console= on the command line.
#      No initrd surgery, no cpio.
#
# If MX's live system needs its own /sbin/init to set up the squashfs overlay this
# will fail loudly rather than half-work: systemd would come up without a root
# filesystem it recognises.
  BAKE_STDIN=serial.in QEMU_MAX="$QEMU_MAX" bake_qemu_install \
    -kernel "$K" -initrd "$I" -- \
    -append "console=ttyS0,115200n8 init=/lib/systemd/systemd" \
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
# The installer ran under script(1) with its output in /tmp/mx-install.out, so the
# exit status never reached the console - it went into /tmp/mx-rc on the guest. What
# DID reach the console are the markers, and those are what this reads now.
#
# The previous check grepped console.log for MINSTALL_RC, found nothing because the
# status was redirected to a file, and declared failure within seconds of boot.
started=$(grep -ac "MINSTALL_STARTED" console.log || true)
finished=$(grep -ao "MINSTALL_FINISHED [0-9]*" console.log | tail -1 || true)
echo "markers: started=${started:-0} finished=${finished:-<none>}"

if echo "${finished:-}" | grep -q "MINSTALL_FINISHED 0"; then
  echo "installer reported success"
else
  echo "=== INSTALL DID NOT REPORT SUCCESS ===" >&2
  echo "markers seen: started=${started:-0} finished=${finished:-<none>}" >&2
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
