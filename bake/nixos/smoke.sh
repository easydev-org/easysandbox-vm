#!/usr/bin/env bash
# Boot the disk that was just baked and prove it is a usable sandbox.
#
# "installation finished" only means nixos-install wrote a filesystem. It says
# nothing about whether the disk boots: GRUB is installed by a separate step,
# and an unusable bootloader, a wrong kernel path or a broken initrd all report
# success at install time. The BOOT_MODE=legacy bug is the same shape - the
# guest ran for fifteen minutes and was then killed by the boot watchdog, with
# nothing wrong in the install log.
#
# So boot it the way the container will: from the disk, through GRUB, no
# -kernel override. Then require real evidence that userspace and the desktop
# session came up.
set -Eeuo pipefail

DESKTOP="${DESKTOP:?set DESKTOP}"
DISK="${DISK:?set DISK to the qcow2 to test}"
WAIT="${WAIT:-400}"

echo "=== smoke test: $DESKTOP ($DISK) ==="
ls -la "$DISK"

rm -f smoke.log smoke.in

# Two details that matter, both learned the hard way on the first run:
#
# * append=on. "-serial file:smoke.log" truncates when QEMU opens it, so the
#   boot messages - the only ones worth checking - were gone by the time the
#   guest shut down and the file was inspected. The first run grepped a log
#   that contained nothing but the shutdown sequence and reported that the
#   kernel never started, while it plainly had: sessions for the docker user
#   had already been created and torn down.
#
# * keep the fifo open with a background writer. Written the other way round
#   QEMU sees EOF on the monitor immediately and quits before booting.
mkfifo smoke.in
(
  # Hold the monitor open, screenshot, then power the guest down at the deadline
  # so the run cannot hang the job even if the boot never completes.
  #
  # screendump is the whole reason this test can answer "is there a picture":
  # the serial log proves systemd reached a target, not that a compositor ever
  # painted. QEMU writes the framebuffer straight to a PPM, no VNC stack and no
  # client needed, and ppm2png.py turns it into something a human can look at.
  exec 3> smoke.in
  # Poll the console instead of sleeping a fixed time. A fixed sleep is what
  # made the first real run fail: the disk had reached "Finished File System
  # Check on /dev/disk/by-label/nixos" and was still starting services when the
  # timer fired and powered it off, so the log ended at shutdown and every
  # check for a later target missed.
  deadline=$(( $(date +%s) + WAIT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if grep -aqE "Reached target (Multi-User System|Graphical Interface)|Started (gdm|sddm|cosmic-greeter)" smoke.log 2>/dev/null; then
      echo "boot reached its target" >&2
      break
    fi
    sleep 5
  done
  # Give the compositor a moment to actually paint before the screenshot, or
  # the framebuffer is still the boot console.
  sleep 15
  echo "screendump /tmp/screen.ppm" >&3 || true
  sleep 10
  echo "system_powerdown" >&3 || true
  sleep 60
  echo "quit" >&3 || true
  exec 3>&-
) &
HOLD=$!

timeout $((WAIT + 180)) qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 6144 \
  -drive file="$DISK",if=virtio,format=qcow2 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -display none -monitor stdio \
  -chardev file,id=ser0,path=smoke.log,append=on \
  -serial chardev:ser0 \
  < smoke.in > /dev/null 2>&1 || echo "qemu exited rc=$?"
kill "$HOLD" 2>/dev/null || true

echo "=== what the disk printed ($(wc -c < smoke.log) bytes) ==="

# systemd colourises its output with ANSI escapes, so "Reached target
# Multi-User System" arrives as [0;1;39mReached target [0m... and a
# plain grep for the phrase depends on where the escapes happen to fall. Strip
# them once, then match against the clean copy.
# systemd colourises its output, so a phrase can arrive split by escape
# sequences. Drop every control byte except newline, then match on that.
tr -d '\000-\011\013-\037' < smoke.log > smoke.clean 2>/dev/null || cp smoke.log smoke.clean

fail=0
chk() {
  local what="$1" pat="$2"
  if grep -aqE "$pat" smoke.clean; then echo "  OK    $what"
  else echo "  FAIL  $what   (no match for: $pat)"; fail=1; fi
}

echo "=== checks ==="
# Each is a distinct failure mode, so a red build names the broken stage
# instead of just saying "did not boot".
chk "GRUB started"               "Welcome to GRUB|Booting .NixOS."
chk "kernel started"             "Linux version|Booting the kernel"
chk "systemd reached userspace"  "Reached target Basic System|Reached target Local File Systems"
chk "multi-user reached"         "Reached target Multi-User System|Reached target multi-user"
chk "graphical target reached"   "Reached target Graphical Interface|Started .*labwc|Started graphical"
case "$DESKTOP" in
  gnome)  chk "gdm started"          "gdm" ;;
  kde)    chk "sddm started"         "sddm" ;;
  cosmic) chk "cosmic session"       "cosmic" ;;
  labwc)  chk "labwc or a getty"     "labwc|getty" ;;
esac
chk "session for the docker user" "Session .* of User docker|User Manager for UID 1000"

# The screenshot is the only check that can distinguish "the session started"
# from "something is on the screen". A compositor that fails to paint still
# reaches graphical.target, so the greps above pass and the sandbox is useless.
# This is also the artefact a human wants when a desktop change is proposed:
# upload it and the UI is visible in the build.
echo
echo "=== screenshot ==="
if [ -s /tmp/screen.ppm ]; then
  cp /tmp/screen.ppm screen.ppm
  python3 "$(dirname "${BASH_SOURCE[0]}")/ppm2png.py" screen.ppm screen.png     && echo "  OK    framebuffer has content"     || { echo "  FAIL  framebuffer is blank"; fail=1; }
else
  # The monitor only runs screendump at the deadline, so a guest that died
  # earlier leaves no PPM at all - which is itself the diagnosis.
  echo "  FAIL  no screenshot (guest exited before the deadline)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "=== SMOKE FAILED ==="
  echo "--- first 60 lines (boot) ---"; head -60 smoke.log
  echo "--- last 40 lines ---"; tail -40 smoke.log
  exit 1
fi

echo "SMOKE OK: $DESKTOP boots to a graphical session"
