#!/bin/sh
# Build an EndeavourOS desktop disk with pacstrap, in the live environment.
#
# WHY NOT CALAMARES
#
# EndeavourOS ships Calamares and nothing else, and Calamares has no unattended
# mode - no profile, no command-line switch, only its window. Five rounds of
# driving that window with the keyboard went: initrd too large for -kernel, Escape
# closing the Welcome dialog, a 640x480 framebuffer, and finally a button 39 pixels
# from the one being aimed at. Each round cost fifteen minutes and none of them
# installed anything.
#
# pacstrap is what Calamares itself calls to do the installing. The live ISO has
# it, along with pacman and the EndeavourOS repositories, so the package set can be
# taken from the ISO's own packages.x86_64 - the same 238 packages the installer
# would have used - and the disk comes out an EndeavourOS system without a single
# keystroke aimed at a window.
#
# WHAT THIS IS NOT
#
# It is not the installer's output byte for byte: Calamares also writes its own
# bookkeeping and branding tweaks. What it is, is the same repositories, the same
# package list, the same kernel, and a desktop that boots - which is what the disks
# in this repository are for.
#
# Runs as root in the live environment. Prints to /dev/ttyS0 so the bake can watch.
set -eu

say() { echo "PACSTRAP: $*" > /dev/ttyS0 2>/dev/null || echo "PACSTRAP: $*"; }

PKGLIST="${PKGLIST:-/root/eos-packages.txt}"
DESKTOP="${DESKTOP:-kde}"
HOSTNAME="${HOSTNAME_TARGET:-endeavouros-sandbox}"

say "starting, desktop=$DESKTOP, package list=$PKGLIST"

# 1. Partition the disk.
#
# One GPT disk, one EFI partition, one root. EndeavourOS's default is the same
# shape. sgdisk is in the live environment.
say "partitioning /dev/vda"
sgdisk --zap-all /dev/vda
sgdisk --new=1:0:+512M --typecode=1:ef00 --change-name=1:EFI /dev/vda
sgdisk --new=2:0:0 --typecode=2:8300 --change-name=2:root /dev/vda
partprobe /dev/vda 2>/dev/null || true
sleep 2
ls -la /dev/vda* > /dev/ttyS0 2>&1 || true

mkfs.fat -F32 -n EFI /dev/vda1
mkfs.ext4 -F -L endeavouros /dev/vda2

# 2. Mount.
mount /dev/vda2 /mnt
mkdir -p /mnt/boot
mount /dev/vda1 /mnt/boot
say "mounted: $(mount | grep ' /mnt' | tr '\n' ' ')"

# 3. The package list.
#
# The one from the ISO's own archiso profile, minus the live-only entries:
# calamares and its helpers install a second installer onto the disk, which is the
# opposite of what this bake wants, and the live user's tools belong to the ISO.
say "writing the package list"
FILTERED=/root/eos-packages-filtered.txt
grep -v '^#' "$PKGLIST" | grep -v '^[[:space:]]*$' \
  | grep -vxE 'calamares|ckbcomp|welcome|eos-quickstart|eos-apps-info|eos-log-tool' \
  > "$FILTERED"
say "packages to install: $(wc -l < "$FILTERED")"

# 4. Install.
#
# pacstrap takes the list from a file with -I in newer pacman; older ones need the
# names on the command line. Both are tried rather than assuming a version.
say "pacstrap (this is the long part)"
if ! pacstrap -K -I "$FILTERED" /mnt > /dev/ttyS0 2>&1; then
  say "pacstrap -I failed; retrying with the names on the command line"
  # shellcheck disable=SC2046
  pacstrap -K /mnt $(cat "$FILTERED") > /dev/ttyS0 2>&1 || {
    say "PACSTRAP FAILED"
    exit 1
  }
fi
say "pacstrap done"

# 5. fstab and chroot setup.
genfstab -U /mnt >> /mnt/etc/fstab
cat /mnt/etc/fstab > /dev/ttyS0 2>&1 || true

# The EndeavourOS repositories are on the live ISO's mirrorlist; carry them over.
if [ -f /etc/pacman.d/endeavouros-mirrorlist ]; then
  cp /etc/pacman.d/endeavouros-mirrorlist /mnt/etc/pacman.d/endeavouros-mirrorlist
fi

# The chroot script needs the hostname from this shell. A quoted heredoc gives the
# chroot script its own scope, so the value is written to a file and read back
# inside rather than relying on expansion that will not happen.
echo "$HOSTNAME" > /mnt/.hostname-target

say "entering the chroot"
arch-chroot /mnt /bin/sh -s <<'CHROOT'
set -eu
say() { echo "CHROOT: $*" > /dev/ttyS0 2>/dev/null || echo "CHROOT: $*"; }

HOSTNAME=$(cat /.hostname-target)
rm -f /.hostname-target
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
EOF

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc --utc 2>/dev/null || true
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

say "creating the user"
useradd -m -G wheel,video,render,audio,input --shell /bin/bash docker
echo 'docker:docker' | chpasswd
echo 'root:docker' | chpasswd
sed -i 's/^# *%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Bootloader. systemd-boot is the simplest thing that works with an EFI partition
# and needs no configuration beyond what is written here.
say "installing the bootloader"
bootctl --esp-path=/boot install 2>&1 || true
mkdir -p /boot/loader/entries
cat > /boot/loader/loader.conf <<EOF
default endeavouros.conf
timeout 0
console-mode max
EOF
cat > /boot/loader/entries/endeavouros.conf <<'EOF'
title   EndeavourOS
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=LABEL=endeavouros rw console=ttyS0,115200n8
EOF

# The kernel and initramfs live in /boot under systemd-boot's layout.
cp /boot/vmlinuz-linux /boot/initramfs-linux.img /boot/ 2>/dev/null || true

# Serial console that logs in by itself: the harness types into ttyS0.
mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d
cat > /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin docker --keep-baud 115200,38400,9600 %I $TERM
EOF
systemctl enable serial-getty@ttyS0.service

# Graphical autologin. plasmalogin is what CachyOS used; sddm is the older name
# for the same job. Both are written because either may be installed.
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf <<'EOF'
[Autologin]
User=docker
Session=plasma
EOF
cat > /etc/plasmalogin.conf 2>/dev/null <<'EOF'
[Autologin]
User=docker
Session=plasma
EOF

# No screen locker: a disk that boots to a clock instead of a desktop passes a
# colour-count check and is useless.
mkdir -p /home/docker/.config
cat > /home/docker/.config/kscreenlockerrc <<'EOF'
[Daemon]
Autolock=false
LockOnResume=false
EOF
chown -R 1000:1000 /home/docker/.config

# A GTK client, installed but NOT started.
pacman -S --noconfirm --needed zenity wl-clipboard 2>&1 || true

systemctl set-default graphical.target
echo ENDEAVOUROS_BAKE_OK > /var/log/endeavouros-bake-ok
echo ENDEAVOUROS_BAKE_OK > /dev/ttyS0 || true
say "chroot finished"
CHROOT

say "unmounting"
sync
umount -R /mnt
say "done"
