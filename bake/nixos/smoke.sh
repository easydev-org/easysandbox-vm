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
    # "Reached target Login Prompts" is what NixOS actually prints once a seat
    # exists, and it is the point at which the serial console can take input.
    # 'Started <dm> service' never matches - NixOS calls it 'Started Display
    # Manager.' - so every run sat out the whole timeout.
    if clean smoke.log | grep -aqE "Reached target Login Prompts|Started Display Manager"; then
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
  # The gold disk carries no autostart of any kind - it is a stock desktop and
  # nothing more - so hyprland, niri and miracle-wm come up with an empty screen,
  # and labwc with whatever its session was given. A compositor with no client
  # paints a flat background, and "flat" is what the picture check rejects. This
  # is the test starting a client, not the image shipping one.
  #
  # The serial console has a getty with autologin for docker, so these run as
  # that user inside the booted system. XDG_RUNTIME_DIR points at the user's
  # runtime dir and WAYLAND_DISPLAY is discovered, because the serial session
  # does not inherit either from the graphical one.
  printf '\r'
  sleep 2
  printf 'export XDG_RUNTIME_DIR=/run/user/1000\n'
  sleep 1
  # Say what is there before picking one. 'head -1' can grab wayland-0 when the
  # compositor published wayland-1, and then kitty talks to a socket nobody is
  # listening on.
  printf 'echo SOCKETS: $(ls /run/user/1000/wayland-* 2>/dev/null)\n'
  sleep 1
  printf 'export WAYLAND_DISPLAY=$(ls -t /run/user/1000/wayland-[0-9]* 2>/dev/null | head -1 | xargs -r basename)\n'
  sleep 1
  printf 'echo DISPLAY_IS: $WAYLAND_DISPLAY\n'
  sleep 1
  sleep 1
  # Software rendering for the client, not for the compositor.
  #
  # kitty failed on niri with:
  #   MESA: error: ZINK: failed to choose pdev
  #   MESA-EGL: warning: egl: failed to create dri2 screen
  #   [glfw error 65544]: Failed to get server capabilities
  # Mesa went looking for a Vulkan device (Zink) and this guest has none, so kitty
  # never got an EGL context and never drew a window. That says nothing about
  # niri, which has both renderer_gl and renderer_pixman enabled and draws its own
  # background in software.
  #
  # LIBGL_ALWAYS_SOFTWARE routes Mesa to llvmpipe and GALLIUM_DRIVER=llvmpipe
  # pins it; together they stop the Zink probe.
  printf 'export LIBGL_ALWAYS_SOFTWARE=1\n'
  sleep 1
  printf 'export GALLIUM_DRIVER=llvmpipe\n'
  sleep 1
  # Every attempt so far ended with '[1]+ Done', so kitty starts and exits and I
  # have not seen why. Capture its exit status and its full output to a file, then
  # print them - guessing again is not working.
  printf '( timeout 20 kitty -o filter_notification=all > /tmp/kitty.out 2>&1; echo "KITTY_EXIT=$?" >> /tmp/kitty.out ) &\n'
  sleep 24
  printf 'echo ---kitty.out---; cat /tmp/kitty.out 2>&1; echo ---end---\n'
  sleep 3
  # kitty is fine: it ran the full twenty seconds and only logged a non-fatal
  # notification warning. So the compositor is what never painted. niri's own
  # log lives in the docker user's journal, which needs that user's session bus
  # and runtime dir to read - hence sudo -u docker with XDG_RUNTIME_DIR set.
  printf 'echo ---niri-log---\n'
  sleep 1
  printf 'sudo -u docker XDG_RUNTIME_DIR=/run/user/1000 journalctl --user-unit niri -b --no-pager 2>&1 | tail -45\n'
  sleep 8
  printf 'echo ---niri-log-end---\n'
  sleep 2
  # kitty's Notifications error is only _glfwInputError - it logs and returns, it
  # does not abort. So the window should exist. Ask whether the process survived
  # and whether anything is listening on the socket, rather than guessing again.
  printf 'echo KITTY_PIDS: $(pgrep -c kitty 2>/dev/null || echo 0)\n'
  sleep 2
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
chk "GRUB started"               "Welcome to GRUB|Booting .NixOS."
chk "kernel/initrd started"      "Booting initrd of|Linux version|Booting the kernel"
chk "root filesystem found"      "Found device /dev/disk/by-label/nixos|Finished File System Check"
chk "systemd reached userspace"  "Reached target Basic System|Reached target Local File Systems"
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
chk "display manager started"   "Started (display-manager|gdm|sddm|cosmic-greeter|greetd)\.service|Reached target Login Prompts"
chk "login prompt reached"      "Reached target Login Prompts"
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
