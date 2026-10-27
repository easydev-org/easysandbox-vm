#!/bin/sh
# Runs inside the newly installed CachyOS, via the installer's post_install hook.
#
# This is the same work every other distribution's bake does in its own way: a
# serial console that logs in by itself, and a GTK client installed but not
# started. The installer handles autologin for the graphical session itself
# (autologin: true in settings.json), so only the serial console is left.
set -eu

# The harness drives the guest over ttyS0. Without this it types into a login
# prompt and fails on "no screenshot" while the guest is perfectly healthy.
mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d
cat > /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin docker --keep-baud 115200,38400,9600 %I $TERM
EOF

# No live systemd here either - this runs at the end of the installation - so the
# symlink is written directly, which is what `systemctl enable` would produce.
mkdir -p /etc/systemd/system/getty.target.wants
ln -sf /usr/lib/systemd/system/serial-getty@.service \
       /etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service

# A GTK client, installed but NOT started. zenity because it publishes an AT-SPI
# tree; xterm and foot do not, and /a11y/apps would be empty without one.
pacman -S --noconfirm --needed zenity wl-clipboard

# The installed system has to keep talking to the serial console.
#
# Without this the smoke test reads SeaBIOS, 'Booting from Hard Disk...', 'Welcome
# to GRUB!' and then nothing: the kernel's messages go to tty0 and the harness
# sees a guest that appears to hang. That is exactly what the first smoke run
# looked like, and it is the same failure Debian's disk had.
#
# GRUB_TERMINAL=serial as well, so the boot menu itself comes over the wire and
# the timeout does not wait for a key on a screen nobody can see.
if [ -f /etc/default/grub ]; then
  sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT="|GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200n8 |' /etc/default/grub
  sed -i 's|^GRUB_CMDLINE_LINUX="|GRUB_CMDLINE_LINUX="console=ttyS0,115200n8 |' /etc/default/grub
  sed -i 's|^#\?GRUB_TERMINAL=.*|GRUB_TERMINAL=serial|' /etc/default/grub
  grep -q '^GRUB_SERIAL_COMMAND' /etc/default/grub || \
    echo 'GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0"' >> /etc/default/grub
  sed -i 's|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=0|' /etc/default/grub
  grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
fi

# Disk and console. The console copy is the one the bake judges on: reading the
# file back out of a finished qcow2 needs virt-cat, and that needs guestfs-tools,
# which will not install on the qemux/qemu base (its udev pins libsystemd-shared
# older than the one that image ships).
echo CACHYOS_BAKE_OK > /var/log/cachyos-bake-ok
echo CACHYOS_BAKE_OK > /dev/ttyS0 || true
