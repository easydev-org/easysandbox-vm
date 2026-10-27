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
#
# -x, and everything duplicated to the console. The late_command's only report on
# failure is an exit code: the first attempt said `failed with exit code 100` and
# nothing else, while the reason sat in a hundred lines of output nobody saw.
#
# No process substitution - this runs under dash, which has no `>(...)`.
#
# The console redirect is guarded: inside `in-target`'s chroot /dev/ttyS0 may not
# exist, and a failed `exec` under `set -e` would abort before anything runs.
set -eux
if [ -w /dev/ttyS0 ]; then exec >>/dev/ttyS0 2>&1; fi

TASK="${1:?setup.sh needs the desktop task name}"

export DEBIAN_FRONTEND=noninteractive

# The installed system's sources.list has ONLY the CD-ROM entry: the netinst
# installed the base system from the ISO, so that is all apt knows about.
#
#   E: The repository 'cdrom://[Debian GNU/Linux 13.7.0 ...] trixie Release'
#      does not have a Release file.
#
# apt-get update therefore fails, and under set -e the script dies with exit
# code 100. Replace it with the network mirror - which is also where the desktop
# packages come from, so this is required either way.
rm -f /etc/apt/sources.list
cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF

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
# `systemctl enable` needs a live systemd, and inside late_command's in-target
# chroot there is none - it exits 1 and, under `set -e`, kills the script. That
# is the most likely source of the bare `exit code 100` from the first attempt.
# systemctl with `--root=/` operates on the filesystem directly and needs no
# daemon; the symlink it writes is exactly what enable would have written.
systemctl --root=/ enable serial-getty@ttyS0.service || \
  ln -sf /lib/systemd/system/serial-getty@.service \
         /etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service 2>/dev/null || true

# Graphical autologin.
#
# Debian 13 ships /etc/gdm3/daemon.conf, NOT custom.conf - custom.conf is the
# Ubuntu spelling (and the one every guide on the internet shows). Writing the
# wrong file leaves GDM at its login screen with no error at all, which is
# exactly what happened: the disk booted to a perfect Debian 13 greeter with a
# "docker" user card and never logged in.
#
# Both are written, because Ubuntu reads one and Debian the other and this script
# is only run on Debian - but writing both costs nothing and means a future
# Debian that goes back to custom.conf still works.
mkdir -p /etc/gdm3
cat > /etc/gdm3/daemon.conf <<'EOF'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=docker
WaylandEnable=true
EOF
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

# The installed system has to keep talking to the serial console.
#
# Every other distribution sets this: Fedora passes it to anaconda's bootloader
# line, Ubuntu writes GRUB_CMDLINE_LINUX, openSUSE uses the bootloader append.
# Debian's preseed has no equivalent, and without it the guest boots with its
# kernel messages on tty0 - so the console log the harness reads contains GRUB
# and a login prompt and nothing in between. That is what a screenshot of a
# 640x480 black screen looks like from the log side: four checks failed for lack
# of output while gdm was in fact running.
#
# GRUB_TERMINAL=serial as well, so the boot menu itself comes over the wire.
if [ -f /etc/default/grub ]; then
  sed -i 's|^GRUB_CMDLINE_LINUX="|GRUB_CMDLINE_LINUX="console=ttyS0,115200n8 |' /etc/default/grub
  sed -i 's|^#\?GRUB_TERMINAL=.*|GRUB_TERMINAL=serial|' /etc/default/grub
  grep -q '^GRUB_SERIAL_COMMAND' /etc/default/grub || \
    echo 'GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0"' >> /etc/default/grub

  # update-grub has to actually succeed, and it needs /proc and /sys to see the
  # disks it is writing a menu for. Inside late_command's chroot those are
  # usually mounted already, but a silent failure here is invisible: the disk
  # boots with the kernel arguments from the INSTALLER's command line baked into
  # nothing, and the console log of the smoke run is 248 lines of SeaBIOS with no
  # kernel output at all. That is what this looked like.
  mountpoint -q /proc || mount -t proc proc /proc 2>/dev/null || true
  mountpoint -q /sys  || mount -t sysfs sysfs /sys 2>/dev/null || true
  if ! update-grub; then
    echo "WARNING: update-grub failed; the installed system will not log to ttyS0" >&2
  fi
  # Prove it landed rather than assume it did.
  if grep -q "console=ttyS0" /boot/grub/grub.cfg 2>/dev/null; then
    echo "grub.cfg carries console=ttyS0"
  else
    echo "WARNING: /boot/grub/grub.cfg has no console=ttyS0" >&2
  fi
fi

# Same reason as above: no daemon in the chroot, so write the symlink directly.
systemctl --root=/ set-default graphical.target || \
  ln -sf /lib/systemd/system/graphical.target /etc/systemd/system/default.target 2>/dev/null || true

# To the disk AND to the serial console.
#
# The disk copy is what a human would find if they mounted the image. The console
# copy is what the harness can see, and it is the one that matters: reading a file
# back out of a finished qcow2 needs virt-cat, virt-cat needs guestfs-tools, and
# guestfs-tools will not install on this base image because its udev dependency is
# pinned to a libsystemd-shared older than the one qemux/qemu ships.
#
# Printing it from inside the guest is the same evidence with none of that: the
# guest says so while it is running, on the console the bake is already reading.
MARKER=DEBIAN_BAKE_OK
echo "$MARKER" > /var/log/debian-bake-ok
echo "$MARKER" > /dev/ttyS0 || true
