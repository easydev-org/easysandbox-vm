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
say "boot partition state:"
mount | grep -E "^/dev/.+ on /mnt" | while read -r line; do say "  $line"; done

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

# 4. The marker, to the console as well as to the disk.
echo CACHYOS_BAKE_OK > "$TARGET/var/log/cachyos-bake-ok"
echo CACHYOS_BAKE_OK > /dev/ttyS0 || true
