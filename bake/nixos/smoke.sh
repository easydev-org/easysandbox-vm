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
# DISK may be a file or a directory. Accepting a directory removes a mistake that
# has now been made twice: the caller resolves the qcow2, forgets to export it
# through sudo, and the script dies on a required variable while the file sits
# right there. If a directory is given, the first qcow2 under it is used.
if [ -d "${DISK:-}" ]; then
  resolved=$(find "$DISK" -name '*.qcow2' | head -1)
  [ -n "$resolved" ] || { echo "no qcow2 under $DISK" >&2; exit 2; }
  DISK="$resolved"
fi
DISK="${DISK:?set DISK to the qcow2 to test, or to a directory containing one}"
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
  # Keep both renderers off Vulkan, because QEMU has none:
  #
  #   Mesa  would try Zink (GL on Vulkan); llvmpipe is the software path.
  #   GTK4  would try GSK's Vulkan backend and fail: on Fedora the client wrote
  #           (zenity:2684): Gdk-WARNING: Vulkan: Unable to open device
  #                            (VK_ERROR_INCOMPATIBLE_DRIVER)
  #         and never mapped a window. GSK_RENDERER=cairo forces CPU.
  #
  # Do NOT add GDK_DEBUG=gl-disable-vulkan: that value does not exist, and GTK
  # rejects the whole variable at startup -
  #
  #   Unrecognized value "gl-disable-vulkan". Try GDK_DEBUG=help
  #
  # - which killed the client outright. A dead client looks exactly like a
  # client that never drew, and it took reading the console to tell them apart.
  printf 'export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe GSK_RENDERER=cairo\n'

  sleep 1
  # Which client to start is asked of the console, not assumed. No disk in this
  # family autostarts anything - they are stock desktops - so starting a client
  # is the harness's job, and starting one that is not installed is a silent
  # no-op that then reads as "the desktop is empty".
  #
  # zenity first because it is GTK and publishes an AT-SPI tree, so /a11y/apps
  # has something in it; kitty is the fallback, and it is what the NixOS disks
  # carry. Both are installed and left unstarted by their disk.
  #
  # `zenity --progress` READS ITS PERCENTAGES FROM STDIN. Redirecting stdin from
  # /dev/null makes it read EOF immediately, decide the job is over, and exit
  # before it ever draws a window - silently, with no error, which is why the
  # process appeared in pgrep for a moment and then vanished:
  #
  #     [1] 2658                                    <- started
  #     [1]+  Done   setsid zenity --progress ...   <- already gone
  #     CLIENT_RUNNING pid=2660                     <- pgrep matched the wrong pid
  #
  # So stdin is held open by a sleep. `--pulsate` means it never needs a number,
  # and `--no-cancel` keeps the Cancel button off the dialog.
  printf 'if command -v zenity >/dev/null 2>&1; then setsid sh -c "sleep 100000 | zenity --progress --text=easyworker --pulsate --no-cancel --width=420" > /dev/ttyS0 2>&1 < /dev/null & elif command -v kitty >/dev/null 2>&1; then setsid sh -c "sleep 100000 | kitty -o filter_notification=all" > /dev/ttyS0 2>&1 < /dev/null & fi\n'

  # Wait for the client to be alive AND STILL ALIVE a moment later.
  #
  # A single `pgrep` is not enough, and it lied once: the client started, was
  # caught by pgrep in the same instant, and then died from a bad environment
  # variable. The check printed CLIENT_RUNNING for a process that no longer
  # existed, and the console said `[1]+ Done` two lines later.
  #
  # So: find the process, then require it to still be there after two seconds.
  # A client that exits immediately (bad flag, missing socket, renderer failure)
  # fails this; one that is merely slow to draw passes and gets the settle time
  # below. Whether a WAYLAND window is mapped cannot be asked from the console -
  # xdotool only sees X11 - so the settle time is generous on purpose. Fedora's
  # GNOME loads a welcome tour and shell extensions at first login and needs far
  # more than Ubuntu's.
  # pgrep -x matches the exact process NAME, and it still picked the wrong pid
  # once (2660, not the zenity at 2658). Using pgrep -x with a trailing space in
  # the reported form is not the fix - deciding on the COMMAND is. `-x zenity`
  # is exact already; what was wrong was believing a single pgrep when the
  # process was about to exit. The two-second re-check below is the real guard,
  # and it now runs against a pid that pgrep resolved fresh each iteration.
  printf 'for i in $(seq 1 20); do p=$(pgrep -x zenity | head -1); [ -z "$p" ] && p=$(pgrep -x kitty | head -1); if [ -n "$p" ]; then sleep 2; if kill -0 "$p" 2>/dev/null; then echo CLIENT_RUNNING pid=$p; break; fi; fi; sleep 1; done\n'
  sleep 2
  # Is there a session FOR THE USER, or only the greeter?
  #
  # A colour count cannot tell a desktop from a greeter: both have wallpaper, both
  # are colourful, both leave a low dominant share. A process name is not enough
  # either, and that was the next mistake - SDDM's greeter runs kwin_wayland of
  # its own to draw the login screen, so 'a desktop shell is running' matched on a
  # machine where plasmashell had never started and /run/user/1000/wayland-* did
  # not exist at all.
  #
  # The session's own socket is the honest answer: it exists only once the display
  # manager has logged a user in and started their compositor.
  printf 'echo --- session ---; ls /run/user/1000/wayland-* 2>&1 | head -3; echo "WAYLAND_SOCKETS=$(ls /run/user/1000/wayland-* 2>/dev/null | wc -l)"; '
  # kwin_wayland is deliberately NOT in this list: SDDM's greeter runs its own
  # kwin_wayland to draw the login screen, so it is true on a machine with no
  # session at all - which is exactly how it passed once already.
  printf 'pgrep -x plasmashell >/dev/null 2>&1 || pgrep -x gnome-shell >/dev/null 2>&1 || pgrep -x sway >/dev/null 2>&1 || pgrep -x labwc >/dev/null 2>&1 || pgrep -x Hyprland >/dev/null 2>&1 || pgrep -x cosmic-session >/dev/null 2>&1 || pgrep -x miracle-wm >/dev/null 2>&1 || pgrep -x xfce4-session >/dev/null 2>&1 && echo SESSION_SHELL=yes || echo SESSION_SHELL=no; '
  printf 'echo --- end ---\n'
  sleep 3
  sleep 25
  printf 'echo TERMINAL_STARTED\n'

  # What the client actually resolved, printed from inside the guest.
  #
  # Two rounds were lost to guessing why no window appeared while the process was
  # demonstrably alive: first a bad GDK_DEBUG value that killed it, then a stdin
  # EOF that ended it. Both times the picture was the only evidence and it could
  # not say which. This prints the environment the client inherited and whether
  # it is still alive after the settle, so the next failure names itself.
  printf 'echo --- client env ---; echo XDG=$XDG_RUNTIME_DIR; echo WL=$WAYLAND_DISPLAY; ls -l /run/user/1000/wayland-* 2>&1 | head -3; echo --- procs ---; ps -eo pid,comm,args | grep -E "zenity|kitty" | grep -v grep; echo --- done ---\n'
  sleep 6

  # Ask the accessibility bus whether the client is really there.
  #
  # The process check above can only say a process exists. This says a WINDOW
  # exists - the client registered with AT-SPI, which is both what the harness
  # needs to drive it and the only claim a process list cannot fake. It is also
  # distribution-neutral: the bus is at the same address everywhere because
  # easystream finds it the same way.
  #
  # Absence is not fatal here (the caller decides), but printing it means a
  # missing window is visible in the log instead of only in the picture.
  printf 'if command -v gdbus >/dev/null 2>&1; then a=$(gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.a11y.Bus.GetAddress 2>/dev/null | tr -d "()," | tr -d "\\x27"); echo A11Y_BUS=$a; else echo A11Y_BUS=no-gdbus; fi\n'
  sleep 3
  # Does the accessibility bus actually know about the client? This is the real
  # question the sandbox cares about - a process that exists but registered no
  # accessible is not something the worker can drive. The bus address comes from
  # the probe above and is the same on every distribution.
  printf 'a=$(gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.a11y.Bus.GetAddress 2>/dev/null | tr -d "()," | tr -d "\\x27"); if [ -n "$a" ]; then echo A11Y_ADDR=$a; DBUS_SESSION_BUS_ADDRESS="$a" gdbus call --session --dest org.a11y.atspi.Registry --object-path /org/a11y/atspi/registry --method org.a11y.atspi.Registry.GetRegisteredEvents >/dev/null 2>&1 && echo A11Y_OK || echo A11Y_NO; else echo A11Y_NO_BUS; fi\n'
  sleep 4

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
  sleep 8
  # Ask qemu to leave as well. system_powerdown is a request to the guest and a
  # guest that ignores it - or has no ACPI, or is wedged in a session - leaves
  # qemu running until the outer timeout, which is WAIT+200 seconds. That is how
  # a job whose checks had all passed at 21:06 was still 'in progress' at 21:30.
  # `quit` is the monitor's own exit and needs no cooperation from the guest.
  printf "quit\n"
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
# tidy. These were rewritten after an Ubuntu disk passed the screenshot - 2917
# colours, a real desktop - while four greps failed, because Ubuntu boots
# through SeaBIOS rather than GRUB/UEFI and never prints the NixOS wording:
#
#   NixOS    Welcome to GRUB / Booting `NixOS' / by-label/nixos
#   Ubuntu   SeaBIOS / Booting from Hard Disk / Linux version / by-uuid
#
# A harness that only knows one distribution reports the other as unbootable.
chk "bootloader started"         "Welcome to GRUB|Booting .(NixOS|Ubuntu)|GRUB loading|SeaBIOS|Booting from Hard Disk|iPXE"
# Debian with GRUB_CMDLINE_LINUX starting with console= prints 'Loading Linux
# 6.12.107+deb13-amd64 ...' from GRUB and then the kernel's own messages without
# the 'Linux version' banner - the banner goes to the console that console= names
# LAST, and Debian's initrd quietens the rest. The line that is always there is
# GRUB's, so that is the one to match.
chk "kernel/initrd started"      "Booting initrd of|Linux version|Booting the kernel|Loading Linux|Loading initial ramdisk|Reached target Initrd Root Device|Reached target Initrd Root File System"
# Debian's ext4 fsck says '/dev/vda1: clean, 141978/1490944 files'. No by-uuid,
# no 'EXT4-fs ... mounted' - the filesystem is reported by fsck before anything
# else speaks, and that is the earliest proof root is readable.
chk "root filesystem found"      "Found device /dev/disk/by-label/nixos|Found device /dev/disk/by-uuid|by-uuid|Mounted /|Finished File System Check|EXT4-fs .*mounted|/dev/vd[a-z][0-9]+: clean|clean, .* files, .* blocks"
chk "systemd reached userspace"  "Reached target Basic System|Reached target Local File Systems|Reached target Local Encrypted Volumes|Reached target .*System"
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
# CachyOS prints none of these: its Arch kernel does not announce a version on
# the serial console, and SDDM under Plymouth does not announce itself either. What
# it does print, and what proves the graphical session came up, is the slice for
# the display manager and Plymouth's own target - both of which only exist when a
# graphical boot is happening.
chk "display manager started"   "Started (display-manager|gdm3?|sddm|lightdm|cosmic-greeter|greetd)[ .]|Reached target Login Prompts|GNOME Display Manager|Reached target Graphical Interface|Started Show Plymouth Boot Screen|Plymouth"
# Ubuntu autologins through gdm and arrives at graphical.target without ever
# printing "Login Prompts"; both are accepted.
chk "login prompt reached"      "Reached target Login Prompts|Reached target Graphical Interface|gdm-autologin|automatic login"
# Each distribution announces this differently, and the third form is what Fedora
# actually prints - `fedora login: docker (automatic login)` on the serial
# console, with no systemd-logind "Session N of User" line at all (that only
# appears when the session ENDS, as "Stopped session-1.scope - Session 1 of User
# root"). The other two forms are what NixOS and Ubuntu print.
chk "a user session existed"    "Session .* of User docker|User Manager for UID 1000|session opened for user docker|New session .* of user docker|login: docker \(automatic login\)|login: docker"
# The client the harness started has to still be running at screenshot time.
#
# This is the check whose absence made a green run misleading: on Fedora the
# client died from a bad GDK_DEBUG value, the picture still had 8869 colours
# because GNOME draws its own wallpaper and welcome tour, and the run passed
# while the thing the test exists to show was not on the screen. A screenshot
# check alone cannot catch that on a desktop that paints itself; it can only
# catch it on a compositor with no wallpaper.
chk "the client is running"      "CLIENT_RUNNING pid="
# A session for the user, not a greeter.
#
# Two weaker versions of this check have already passed on machines with no
# session at all:
#
#   * a colour count - a greeter has wallpaper and is full of colours;
#   * a process name - SDDM's greeter runs kwin_wayland to draw its login screen,
#     so 'kwin_wayland is running' was true with /run/user/1000/wayland-* absent.
#
# The socket is the thing that only exists once a user has actually been logged
# in and their compositor started.
chk "a session for the user"      "WAYLAND_SOCKETS=[1-9]"
chk "a session shell is running"  "SESSION_SHELL=yes"

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
