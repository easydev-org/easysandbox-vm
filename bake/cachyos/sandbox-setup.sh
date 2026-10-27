#!/bin/sh
# Runs after cachyos-installer has installed the system, via its post_install
# hook. Everything here has to land on the TARGET, so every write goes through
# arch-chroot /mnt.
#
# The installer logs
#
#   [exec] cmd := /bin/sh -c /run/sandbox-setup.sh &>>/tmp/cachyos-install.log
#
# which is two facts worth stating: the shell is /bin/sh, not bash, and the
# working root is the LIVE environment. The first version of this script wrote
# /etc/default/grub directly and edited the installer's own file, which is thrown
# away with the ISO - so the installed system booted with no console= parameter
# and the smoke test read 'Welcome to GRUB!' and then nothing at all.
set -eu

TARGET=/mnt
in_target() { arch-chroot "$TARGET" /bin/sh -c "$*"; }

# Everything this script prints goes to the installer's log file, not to the
# console - it is invoked as
#   /bin/sh -c /run/sandbox-setup.sh &>>/tmp/cachyos-install.log
# so a diagnosis written with echo never reaches anyone. That is how the previous
# two rounds failed silently: the script "succeeded" and the disk still booted
# without console=ttyS0.
say() { echo "SETUP: $*" > /dev/ttyS0 2>/dev/null || true; }

say "starting, TARGET=$TARGET"
# Where IS the installed system?
#
# arch-chroot /mnt failed at every step in the last run, and 'boot partition
# state:' printed nothing at all - /mnt was not mounted. cachyos-installer
# unmounts the target after installing and then runs this hook, so there may be
# nothing at /mnt to chroot into: the hook runs after the filesystem work is
# done, not during it.
#
# So find it rather than assume. Any mount whose filesystem has /etc/default/grub
# is the installed system, wherever the installer happens to have left it.
say "looking for the installed system:"
for m in $(awk '$2 ~ /^\/mnt/ {print $2}' /proc/mounts 2>/dev/null | sort -u); do
  has_grub="no"
  [ -f "$m/etc/default/grub" ] && has_grub="yes"
  say "  mounted at $m (has /etc/default/grub: $has_grub)"
done

# NOT /run/archiso/airootfs.
#
# That was on the candidate list and it is the ISO's own squashfs - read-only,
# and it has /etc/default/grub because the live environment has GRUB's package.
# The previous run took it:
#
#   SETUP:   using /run/archiso/airootfs instead of /mnt
#
# and then edited the installer's own files while reporting success at each step.
# A target has to be a real mounted filesystem, so this checks /proc/mounts rather
# than just looking for a file.
find_target() {
  awk '$2 ~ /^\/mnt/ {print $2}' /proc/mounts 2>/dev/null | while read -r m; do
    [ -f "$m/etc/default/grub" ] && [ -d "$m/var" ] && { echo "$m"; break; }
  done
}
if [ ! -f "$TARGET/etc/default/grub" ]; then
  alt=$(find_target)
  if [ -n "$alt" ]; then
    TARGET="$alt"
    say "  using $TARGET (a real mount under /mnt)"
  fi
fi

# Still nothing: mount it ourselves.
#
# cachyos-installer finishes the filesystem work, unmounts the target, and only
# then runs this hook - so /mnt is empty by the time we get here. (The previous
# run proves it: 'looking for the installed system:' found nothing and every
# arch-chroot call failed.) Mounting the target again is the only way to edit
# anything on it.
MOUNTED_HERE=0
if [ ! -f "$TARGET/etc/default/grub" ]; then
  say "target is not mounted; mounting /dev/vda1 read-write"
  mkdir -p "$TARGET"
  # btrfs first, with the default subvolume. settings.json asks for ext4, but if
  # that ever changes a bare mount would give the top-level subvolume, where
  # /etc/default/grub does not exist - and the failure would look like "the
  # install produced nothing".
  for spec in "/dev/vda1" "/dev/vda1 -o subvol=@" "/dev/vda2" "/dev/vda2 -o subvol=@"; do
    set -- $spec
    dev="$1"; shift
    if mount "$dev" "$@" "$TARGET" 2>/dev/null; then
      if [ -f "$TARGET/etc/default/grub" ]; then
        MOUNTED_HERE=1
        say "  mounted $dev $* at $TARGET"
        break
      fi
      umount "$TARGET" 2>/dev/null || true
    fi
  done
  [ "$MOUNTED_HERE" = 1 ] || say "  every mount attempt failed"
fi
if [ ! -f "$TARGET/etc/default/grub" ]; then
  say "NO TARGET with /etc/default/grub - cannot edit the installed system"
fi

# 1. The serial console must log in by itself.
#
# The harness types into ttyS0. Without an autologin there it types into a login
# prompt and fails on "no screenshot" while the guest is perfectly healthy - the
# same thing that happened in the live environment before the bake learnt to send
# 'root' first.
say "writing the serial getty autologin"
if in_target 'mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d'; then
  say "  mkdir ok"
else
  say "  MKDIR FAILED"
fi
if in_target 'cat > /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin docker --keep-baud 115200,38400,9600 %I \$TERM
EOF'; then
  say "  autologin.conf written"
else
  say "  AUTOLOGIN WRITE FAILED"
fi
in_target 'systemctl enable serial-getty@ttyS0.service' || true

# 2. The installed system has to keep talking to that console.
#
# Without console=ttyS0 the kernel's messages go to tty0 and the serial port only
# carries what the bootloader prints. GRUB_TERMINAL=serial also sends the menu
# over the wire, so nothing waits for a key on a screen nobody can see.
say "editing /etc/default/grub inside the target"
in_target 'sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"console=ttyS0,115200n8 |" /etc/default/grub' \
  && say "  CMDLINE_LINUX_DEFAULT edited" || say "  CMDLINE_LINUX_DEFAULT EDIT FAILED"
in_target 'sed -i "s|^GRUB_CMDLINE_LINUX=\"|GRUB_CMDLINE_LINUX=\"console=ttyS0,115200n8 |" /etc/default/grub' \
  && say "  CMDLINE_LINUX edited" || say "  CMDLINE_LINUX EDIT FAILED"
in_target 'sed -i "s|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=0|" /etc/default/grub' || true

# grub-mkconfig is the step that can fail silently: it needs /proc and /sys and
# the module directory of the kernel it is generating for, and in a chroot that
# has been set up by an installer those may not all be there.
say "running grub-mkconfig"
if in_target 'grub-mkconfig -o /boot/grub/grub.cfg'; then
  say "  grub-mkconfig exited 0"
else
  say "  GRUB-MKCONFIG FAILED (exit $?)"
fi

# Prove the argument landed, rather than assuming grub-mkconfig did what it was
# told. This is what was missing when the first version "succeeded" and the disk
# still had no console=.
if in_target 'grep -q "console=ttyS0" /boot/grub/grub.cfg'; then
  say "grub.cfg carries console=ttyS0 - good"
else
  say "grub.cfg has NO console=ttyS0 - writing a drop-in instead"
  # The last resort: a drop-in that grub reads regardless of how grub.cfg was
  # generated. If grub-mkconfig is failing inside this chroot, this still lands.
  in_target 'mkdir -p /etc/default/grub.d'
  in_target 'printf "%s\n" "GRUB_CMDLINE_LINUX_DEFAULT=\"console=ttyS0,115200n8\"" "GRUB_TERMINAL=serial" "GRUB_TIMEOUT=0" > /etc/default/grub.d/99-sandbox.cfg'
  in_target 'grub-mkconfig -o /boot/grub/grub.cfg' || true
  if in_target 'grep -q "console=ttyS0" /boot/grub/grub.cfg'; then
    say "drop-in worked, grub.cfg now carries console=ttyS0"
  else
    say "STILL no console=ttyS0 - this disk will not log to the serial console"
  fi
fi

# 3. A GTK client, installed but NOT started - the same rule as every other disk
#    here. zenity publishes an AT-SPI tree; xterm and foot do not, and
#    /a11y/apps would be empty without one.
in_target 'pacman -S --noconfirm --needed zenity wl-clipboard'

# 3b. No screen locker.
#
# The screenshot after a successful boot was a lock screen: '8:14 AM', 'Tuesday,
# October 27, 2026', 'Show On-Screen Keyboard', and nothing else. Autologin had
# worked - 'a user session existed' passed - and then the session locked itself
# immediately, so the desktop was never on screen and the client window was
# behind a password prompt.
#
# KDE ships a screen locker that defaults to locking at session start when the
# session was created without a normal login. Turning it off is the difference
# between a disk that boots to a desktop and one that boots to a picture of a
# clock.
in_target 'mkdir -p /home/docker/.config'
in_target 'cat > /home/docker/.config/kscreenlockerrc <<EOF
[Daemon]
Autolock=false
LockOnResume=false
EOF'
in_target 'chown -R 1000:1000 /home/docker/.config'

# 3c. SDDM autologin, written the way cachyos-installer writes it.
#
# The installer's own gucc/src/autologin.cpp does exactly this for sddm:
#
#   set_config_values("/etc/sddm.conf", "Autologin", {{"User", username}});
#
# so [Autologin] User= and NOTHING else - no Session= line. That is deliberate on
# its part: leaving Session out means SDDM uses the session it considers default,
# which for this image is Plasma on Wayland. Naming a session would pin the disk
# to one compositor, and this repo does not want X11 at all.
#
# settings.json has "autologin": true, but it only takes effect when the installer
# is also told which display manager it installed, and that is not one of the
# documented keys. Writing the file here does not depend on that.
in_target 'cat > /etc/sddm.conf <<EOF
[Autologin]
User=docker
EOF'

# The graphical session has to be the default target, or SDDM never starts and the
# only thing on screen is its own greeter - which looks exactly like a lock screen
# and passes a colour-count check.
in_target 'systemctl set-default graphical.target' || true

# 4. The marker, to the console as well as to the disk.
echo CACHYOS_BAKE_OK > "$TARGET/var/log/cachyos-bake-ok"
echo CACHYOS_BAKE_OK > /dev/ttyS0 || true

# Leave the filesystem the way we found it. The installer unmounted everything
# before running this hook, and an install that is still holding a mount when
# qemu powers off can leave the image dirty - which the smoke test would then
# report as a filesystem problem.
if [ "$MOUNTED_HERE" = 1 ]; then
  sync
  if umount "$TARGET" 2>/dev/null; then
    say "unmounted $TARGET"
  else
    say "WARNING: could not unmount $TARGET"
  fi
fi
