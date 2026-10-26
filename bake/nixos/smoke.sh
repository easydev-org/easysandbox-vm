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
    # Wait for the point at which the serial console can take input. NixOS
    # prints "Reached target Login Prompts" and 'Started Display Manager.';
    # Ubuntu prints "Started gdm.service" / "Reached target Graphical
    # Interface". A harness that only knew the NixOS wording sat out the whole
    # timeout on Ubuntu and then powered off a healthy guest.
    if clean smoke.log | grep -aqE \
         "Reached target Login Prompts|Started Display Manager|Reached target Graphical Interface|Started gdm3?\.service|Started sddm\.service|Started lightdm\.service"; then
      echo "boot reached its target" >&2
      break
    fi
    sleep 5
  done
  # Let the compositor paint before the screenshot, or the framebuffer still
  # holds the boot console.
  sleep 20
  # Open a terminal in the session before photographing it.
  #
  #
  # The gold disk carries no autostart of any kind - it is a stock desktop - so
  # the window managers come up with an empty screen, and an empty screen is
  # what the picture check rejects. Starting a client is the test's job.
  #
  # The serial getty autologins as docker, so this runs inside the booted
  # system. Set the runtime dir and the Wayland socket explicitly: the serial
  # session inherits neither from the graphical one.
  printf '\r'

  sleep 2
  printf 'export XDG_RUNTIME_DIR=/run/user/1000\n'

  sleep 1
  # Newest socket, not first by name: the compositor may publish wayland-1.
  printf 'export WAYLAND_DISPLAY=$(ls -t /run/user/1000/wayland-[0-9]* 2>/dev/null | head -1 | xargs -r basename)\n'

  sleep 1
  # Mesa would otherwise try Zink (GL on Vulkan) and this guest has no Vulkan;
  # llvmpipe is the software path that actually works here.
  printf 'export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe\n'

  sleep 1
  # Which client to start is the image's business, so ask the console what it
  # has rather than assuming kitty. The NixOS disks carry kitty and nothing that
  # autostarts; the Ubuntu disk carries zenity and autostarts it from
  # ~/.config/autostart. Trying to start a binary that is not installed is a
  # silent no-op that then reads as "the desktop is empty".
  #
  # zenity is preferred when present because it is GTK and therefore publishes
  # an AT-SPI tree; kitty is the fallback for the NixOS disks.
  printf 'if command -v zenity >/dev/null 2>&1; then setsid zenity --progress --text=easyworker --pulsate --no-cancel --width=420 > /dev/ttyS0 2>&1 < /dev/null & elif command -v kitty >/dev/null 2>&1; then setsid kitty -o filter_notification=all > /dev/ttyS0 2>&1 < /dev/null & fi\n'

  sleep 8
  printf 'echo TERMINAL_STARTED\n'

  sleep 2
  # Ctrl-A c switches the muxed stdio from the guest console to the QEMU monitor,
  # takes the screenshot, and switches back. Without the switch these lines are
  # typed at the guest's login prompt, which is why an earlier version produced a
  # screenshot of the boot console and never a screendump at all.
  printf '\001c'
  sleep 2
  printf "screendump /tmp/screen.ppm\n"
  sleep 8
  # system_powerdown is a monitor command too, so stay in the monitor for it.
  # Sent after switching back to the guest console it would be typed at a login
  # prompt and the machine would never shut down.
  printf "system_powerdown\n"
  # Hold the fifo open for the rest of the run. Closing it early sends EOF to
  # qemu's stdin, and with -nographic that stdin IS the guest serial port - so
  # qemu exits on the spot. That is why the console log stopped at 18 KiB in the
  # middle of initrd: the guest had barely started when the writer went away.
  sleep 3600
} > smoke.in &
HOLD=$!

# -boot c and no -kernel: this is the production path.
#
# Serial and monitor share stdio, the arrangement the bake and derive both use:
# -nographic gives '-serial mon:stdio', where console input goes to the guest and
# a monitor command is reached with Ctrl-A c. Writing the console to a chardev
# file instead LOST most of the boot log - the copy that came back had the first
# few hundred lines and then jumped straight to shutdown, with the multi-user and
# graphical targets missing from the middle - so every check failed against a
# truncated file rather than against a broken disk.
timeout $((WAIT + 200)) qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 6144 \
  -drive file="$DISK",if=virtio,format=qcow2 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  ${QEMU_VGA:+-vga "$QEMU_VGA"} \
  -nographic -no-reboot \
  < smoke.in > smoke.log 2>&1 || echo "qemu exited rc=$?"
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
# Each check matches what the distributions actually print, not what seemed
# tidy. Ubuntu does not say "Booting NixOS", its root is a UUID rather than a
# by-label/nixos device, and it announces systemd differently - so a harness
# written only for NixOS reports a perfectly good Ubuntu disk as unbootable.
chk "bootloader started"         "Welcome to GRUB|Booting .(NixOS|Ubuntu)|GRUB loading"
chk "kernel/initrd started"      "Booting initrd of|Linux version|Booting the kernel"
chk "root filesystem found"      "Found device /dev/disk/by-label/nixos|Found device /dev/disk/by-uuid|Mounted /|Finished File System Check"
chk "systemd reached userspace"  "Reached target Basic System|Reached target Local File Systems|Reached target Local Encrypted Volumes"
# "Reached target Multi-User System" and "Reached target Graphical Interface"
# are NOT printed by NixOS: systemd only announces targets it is asked to, and
# these are satisfied implicitly. Checking for them reported a healthy disk as
# broken for many runs.
#
# Nor is the DM's own unit name reliable: NixOS wires whichever one is enabled
# to display-manager.service, and gdm in particular does not show up as
# 'gdm.service' in the console at all - the GNOME disk passed every other check
# and failed only this one, with the screenshot showing a working desktop.
# Match the unit NixOS actually starts, whichever DM is behind it.
# Ubuntu prints 'Started gdm.service' / 'Started sddm.service' with a dot and a
# space; NixOS prints almost none of them. Both forms are allowed here.
chk "display manager started"   "Started (display-manager|gdm3?|sddm|lightdm|cosmic-greeter|greetd)[ .]|Reached target Login Prompts|GNOME Display Manager"
chk "login prompt reached"      "Reached target Login Prompts|Reached target Graphical Interface"
chk "a user session existed"    "Session .* of User docker|User Manager for UID 1000|session opened for user docker|New session .* of user docker"

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
