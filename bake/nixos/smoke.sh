#!/usr/bin/env bash
# Boot a baked disk and prove it is a usable sandbox.
#
# "installation finished" only means nixos-install wrote a filesystem. It says
# nothing about whether the disk boots: GRUB is installed by a separate step,
# and a bad bootloader, a wrong kernel path or a broken initrd all report
# success at install time. The BOOT_MODE=legacy bug is the same shape - the
# guest ran for fifteen minutes and was then killed by the boot watchdog, with
# nothing wrong in the install log.
#
# So boot it the way the container will: from the disk, through GRUB, no
# -kernel override. Then require real evidence that userspace and the desktop
# session came up, and take a screenshot, because no log can show a blank screen.
set -Eeuo pipefail

DESKTOP="${DESKTOP:?set DESKTOP}"
DISK="${DISK:?set DISK to the qcow2 to test}"
WAIT="${WAIT:-600}"

echo "=== smoke test: $DESKTOP ($DISK) ==="
ls -la "$DISK"

rm -f smoke.log smoke.clean smoke.in

# systemd colourises its output, and the escapes sit INSIDE the phrases
# the checks look for, so "Reached target Multi-User System" is never
# contiguous. tr -d [:cntrl:] is not enough: it removes the ESC but leaves
# the printable "[0;1;39m" behind, which made two runs report a healthy
# disk as unbootable. Delete the whole sequence.
ANSI="$(printf '\033')[][0-9;]*[A-Za-z]"
clean() { sed -E "s/${ANSI}//g" "$1" 2>/dev/null || cat "$1"; }

mkfifo smoke.in
{
  # A block whose stdout IS the fifo - the shape that works. An earlier version
  # opened the fifo with 'exec 3> smoke.in' before qemu started, and opening a
  # fifo for writing blocks until a reader appears. So the poll loop below never
  # ran once, the guest was never asked for a screenshot, and the run sat until
  # a fixed timeout and powered off mid-boot. That is why the console log
  # stopped at 24 KiB and never reached multi-user.
  deadline=$(( $(date +%s) + WAIT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if clean smoke.log | grep -aqE "Reached target (Multi-User System|Graphical Interface)|Started (gdm|sddm|cosmic-greeter)|greetd"; then
      echo "boot reached its target" >&2
      break
    fi
    sleep 5
  done
  # Let the compositor paint before the screenshot, or the framebuffer still
  # holds the boot console.
  sleep 20
  printf "screendump /tmp/screen.ppm\n"
  sleep 10
  printf "system_powerdown\n"
  sleep 60
  printf "quit\n"
} > smoke.in &
HOLD=$!

# -boot c and no -kernel: this is the production path. The serial goes to a
# chardev with append=on because "-serial file:" truncates on open, which
# threw away the boot messages on an earlier attempt.
timeout $((WAIT + 200)) qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 6144 \
  -drive file="$DISK",if=virtio,format=qcow2 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -display none -monitor stdio \
  -chardev file,id=ser0,path=smoke.log \
  -serial chardev:ser0 \
  < smoke.in > /dev/null 2>&1 || echo "qemu exited rc=$?"
kill "$HOLD" 2>/dev/null || true

clean smoke.log > smoke.clean
echo "=== console: $(wc -c < smoke.clean) bytes ==="

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
chk "kernel/initrd started"      "Booting initrd of|Linux version|Booting the kernel"
chk "root filesystem found"      "Found device /dev/disk/by-label/nixos|Finished File System Check"
chk "systemd reached userspace"  "Reached target Basic System|Reached target Local File Systems"
chk "multi-user reached"         "Reached target Multi-User System|Reached target multi-user"
# What "the desktop started" means differs by flavour, and pretending otherwise
# fails correct disks. gnome/kde/cosmic run a display manager and must reach the
# graphical target. labwc does NOT: nothing starts a session on a bare labwc disk
# (oem-nixos.sh does, and it needs the sandbox container), so that disk ends at a
# getty and requiring graphical.target would report a good image as broken -
# which is exactly what happened on the first two runs.
# Every flavour now runs a display manager, including labwc (greetd, added
# because a bare labwc disk sat at a text console - NixOS installs the package
# but nothing starts a session). So all four must reach the graphical target.
chk "graphical target reached" "Reached target Graphical Interface|graphical.target"
case "$DESKTOP" in
  gnome)  chk "gdm started"       "gdm" ;;
  kde)    chk "sddm started"      "sddm" ;;
  cosmic) chk "cosmic-greeter"    "cosmic-greeter|greetd" ;;
  labwc)  chk "greetd and labwc"  "greetd" ;;
esac
chk "a user session existed"    "Session .* of User docker|User Manager for UID 1000|session opened for user docker"

# The screenshot is the only check that separates "the session started" from
# "something is on the screen". A compositor that fails to paint still reaches
# graphical.target, and the sandbox is then useless while every grep passes.
echo
echo "=== screenshot ==="
if [ -s /tmp/screen.ppm ]; then
  cp /tmp/screen.ppm screen.ppm
  # What counts as a picture depends on the flavour. labwc has no session of its
  # own - oem-nixos.sh starts it, and that needs the sandbox container - so a
  # bare labwc disk legitimately shows a text console and "desktop" would fail a
  # correct disk. gh, kde and cosmic run a display manager and must show one.
  # Every flavour has a display manager now, so every flavour must paint a real
  # desktop - a text console is a failure everywhere.'
  expect=desktop
  # if, not "[ ... ] && expect=text": under set -e a false test makes that
  # AND-list return 1 and kills the script - so every non-labwc flavour would
  # abort here, right before the check that matters.
  #if [ "$DESKTOP" = labwc ]; then expect=text; fi
  if python3 "$(dirname "${BASH_SOURCE[0]}")/ppm2png.py" screen.ppm screen.png "$expect"; then
    echo "  OK    framebuffer has content"
  else
    echo "  FAIL  framebuffer is blank"; fail=1
  fi
else
  echo "  FAIL  no screenshot (guest gone before the deadline)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "=== SMOKE FAILED ==="
  echo "--- boot, first 40 lines ---"; head -40 smoke.clean
  echo "--- tail 30 ---"; tail -30 smoke.clean
  exit 1
fi

echo "SMOKE OK: $DESKTOP boots to a graphical session with a picture"
