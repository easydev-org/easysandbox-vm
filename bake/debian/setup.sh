#!/bin/sh
# Runs inside the freshly installed Debian, via preseed's late_command.
#
# It is a separate file, fetched over HTTP, because preseed is a one-instruction-
# per-line format: `d-i preseed/late_command string ...` cannot span lines with
# shell continuations, and the backslash would be taken literally. Everything
# beyond a trivially short command has to live somewhere else, and a served file
# is the simplest place.
#
# Args: $1 = desktop task name (task-gnome-desktop, task-kde-desktop, ...)
set -eu

TASK="${1:?setup.sh needs the desktop task name}"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y "$TASK"
# A GTK client, installed but NOT started - same rule as every other disk here.
apt-get install -y --no-install-recommends zenity wl-clipboard

# The serial console must log in by itself, the same thing NixOS gets from
# services.getty.autologinUser and Ubuntu from a serial-getty override. Without
# it the harness types into a login prompt and fails on "no screenshot" while the
# guest is perfectly healthy.
mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d
cat > /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin docker --keep-baud 115200,38400,9600 %I $TERM
EOF
systemctl enable serial-getty@ttyS0.service

# Graphical autologin. Both files are written because the task installed decides
# which display manager exists; having the other file present is harmless.
mkdir -p /etc/gdm3
cat > /etc/gdm3/custom.conf <<'EOF'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=docker
WaylandEnable=true
EOF
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf <<'EOF'
[Autologin]
User=docker
Session=plasma
EOF

usermod -aG video,render,audio,input docker 2>/dev/null || true
systemctl set-default graphical.target

echo DEBIAN_BAKE_OK > /var/log/debian-bake-ok
