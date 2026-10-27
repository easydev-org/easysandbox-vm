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

echo CACHYOS_BAKE_OK > /var/log/cachyos-bake-ok
