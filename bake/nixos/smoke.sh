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

# systemd colourises its output, so a phrase can arrive with escapes around
# it and a plain grep misses depending on where they land. Strip every
# control byte once and match on that. [:cntrl:] rather than an explicit
# range: a literal \033 range in this file has been mangled into real
# control bytes twice already, which quietly turned the script binary.
clean() { tr -d "[:cntrl:]" < "$1" 2>/dev/null || cat "$1"; }

mkfifo smoke.in
(
  # Hold the monitor open, poll for the boot to reach its target, screenshot,
  # then power down. A fixed sleep is what made the first real run fail: the
  # disk was healthy and still starting services when the timer fired.
  exec 3> smoke.in
  deadline=$(( $(date +%s) + WAIT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if clean smoke.log | grep -aqE "Reached target (Multi-User System|Graphical Interface)|Started (gdm|sddm|cosmic-greeter)|labwc"; then
      echo "boot reached its target" >&2
      break
    fi
    sleep 5
  done
  # Let the compositor paint before the screenshot, or the framebuffer still
  # holds the boot console.
  sleep 20
  echo "screendump /tmp/screen.ppm" >&3 || true
  sleep 10
  echo "system_powerdown" >&3 || true
  sleep 60
  echo "quit" >&3 || true
  exec 3>&-
) &
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
chk "graphical target reached"   "Reached target Graphical Interface|Started .*labwc|graphical.target"
case "$DESKTOP" in
  gnome)  chk "gdm started"      "gdm" ;;
  kde)    chk "sddm started"     "sddm" ;;
  cosmic) chk "cosmic session"   "cosmic" ;;
  labwc)  chk "labwc session"    "labwc" ;;
esac
chk "a user session existed"    "Session .* of User docker|User Manager for UID 1000|session opened for user docker"

# The screenshot is the only check that separates "the session started" from
# "something is on the screen". A compositor that fails to paint still reaches
# graphical.target, and the sandbox is then useless while every grep passes.
echo
echo "=== screenshot ==="
if [ -s /tmp/screen.ppm ]; then
  cp /tmp/screen.ppm screen.ppm
  if python3 "$(dirname "${BASH_SOURCE[0]}")/ppm2png.py" screen.ppm screen.png; then
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
