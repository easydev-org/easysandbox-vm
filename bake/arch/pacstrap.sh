#!/bin/sh
# Build an Arch desktop disk with pacstrap, in the live environment.
#
# WHY THIS IS THE POINT OF ARCH
#
# The Arch ISO ships NO desktop at all. EndeavourOS hardcodes Plasma in its
# packages.x86_64; Debian nails a desktop to each ISO. Here the desktop is whatever
# DESKTOP names and the package list is chosen at bake time.
#
# WHY PACSTRAP AND NOT archinstall
#
# archinstall takes a JSON configuration whose profile_config names a desktop, but
# that schema changes between releases (4.5 is current), its disk_config carries
# object ids that must stay internally consistent, and a drift between the ISO's
# archinstall and this file would fail in ways that read like an installer bug
# rather than a version mismatch. pacstrap takes package names, and the list IS the
# specification.
#
# Runs as root in the live environment; prints to /dev/ttyS0 so the bake can watch.
set -eu

say() { echo "PACSTRAP: $*" > /dev/ttyS0 2>/dev/null || echo "PACSTRAP: $*"; }

DESKTOP="${DESKTOP:-kde}"
HOSTNAME="${HOSTNAME_TARGET:-arch-sandbox}"

say "starting, desktop=$DESKTOP"

# 1. Partition.
#
# Three partitions, and the middle one is not optional:
#
#   grub-install: error: will not proceed with blocklists.
#   warning: this GPT partition label contains no BIOS Boot Partition
#
# On GPT under BIOS, GRUB has nowhere to put its second stage - the space after the
# MBR belongs to the GPT itself. It needs a 1 MB ef02 partition and refuses to fall
# back to blocklists. The smoke test boots under BIOS, so without this the disk has
# no boot loader at all.
#
#   1  EFI system  512M  ef00
#   2  BIOS boot     1M  ef02
#   3  root        rest  8300
say "partitioning /dev/vda"
sgdisk --zap-all /dev/vda
sgdisk --new=1:0:+512M --typecode=1:ef00 --change-name=1:EFI /dev/vda
sgdisk --new=2:0:+1M   --typecode=2:ef02 --change-name=2:BIOSBOOT /dev/vda
sgdisk --new=3:0:0     --typecode=3:8300 --change-name=3:root /dev/vda
partprobe /dev/vda 2>/dev/null || true
sleep 2
ls -la /dev/vda* > /dev/ttyS0 2>&1 || true

mkfs.fat -F32 -n EFI /dev/vda1
mkfs.ext4 -F -L archroot /dev/vda3

mount /dev/vda3 /mnt
mkdir -p /mnt/boot
mount /dev/vda1 /mnt/boot
say "mounted: $(mount | grep ' /mnt' | tr '\n' ' ')"

# 2. Repositories, before pacstrap.
#
# pacstrap regenerates /mnt/etc and leaves its pacman.d without mirrorlists, and
# pacman reads the LIVE configuration anyway - it is only given -r /mnt. So the live
# mirrorlist has to work first, and that is verified rather than assumed.
#
# grep -c already prints 0 when nothing matches; adding "|| echo 0" appends a SECOND
# zero, so a comparison against 0 is false. That cost a round on the EndeavourOS
# bake: the file was never written and the log still reported "entries: 0".
server_count() { grep -c '^Server' "$1" 2>/dev/null; }

say "checking the live repositories"
if [ "$(server_count /etc/pacman.d/mirrorlist)" = 0 ]; then
  say "  the live mirrorlist is empty; writing one"
  printf '%s\n' \
    'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' \
    'Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch' \
    > /etc/pacman.d/mirrorlist
fi
say "  live mirrorlist entries: $(server_count /etc/pacman.d/mirrorlist)"
if pacman -Sy --noconfirm > /dev/ttyS0 2>&1; then
  say "  live pacman -Sy worked"
else
  say "  LIVE PACMAN -SY FAILED - pacstrap cannot work"
  exit 1
fi

# 3. The package list, chosen here from DESKTOP.
#
# Arch ships no desktop, so this is the only place one is named. The base block is
# what Arch's own installation guide installs; the desktop block is what Debian's
# task-*-desktop would pull in.
say "choosing packages for desktop=$DESKTOP"
BASE="base linux linux-firmware intel-ucode
  btrfs-progs dosfstools e2fsprogs exfatprogs f2fs-tools ntfs-3g xfsprogs
  networkmanager wpa_supplicant
  sudo nano vim less man-db man-pages which
  grub efibootmgr
  pipewire pipewire-alsa pipewire-pulse wireplumber
  noto-fonts noto-fonts-emoji ttf-dejavu ttf-liberation
  xdg-utils xdg-user-dirs zenity wl-clipboard"

case "$DESKTOP" in
  kde)
    DE="plasma-meta plasma-nm plasma-pa dolphin konsole kate
      sddm sddm-kcm kde-gtk-config breeze-gtk xdg-desktop-portal-kde" ;;
  gnome)
    DE="gnome gnome-tweaks gdm xdg-desktop-portal-gnome" ;;
  xfce)
    DE="xfce4 xfce4-goodies lightdm lightdm-gtk-greeter xdg-desktop-portal-gtk" ;;
  cosmic)
    DE="cosmic-session cosmic-greeter xdg-desktop-portal-cosmic" ;;
  *)
    say "unknown DESKTOP '$DESKTOP' (kde|gnome|xfce|cosmic)"
    exit 2 ;;
esac

PKGS=$(printf '%s %s' "$BASE" "$DE" | tr -s ' \n' ' ')
say "  package count: $(echo "$PKGS" | wc -w)"

# 4. Install.
#
# -C pins the configuration to the live one: a repository list that exists only in
# the new root is no use, because pacman reads the live configuration and is only
# given -r /mnt.
say "pacstrap (this is the long part)"
# shellcheck disable=SC2086
if ! pacstrap -C /etc/pacman.conf -K /mnt $PKGS > /dev/ttyS0 2>&1; then
  say "PACSTRAP FAILED"
  exit 1
fi
say "pacstrap done"

genfstab -U /mnt >> /mnt/etc/fstab
cat /mnt/etc/fstab > /dev/ttyS0 2>&1 || true

echo "$HOSTNAME" > /mnt/.hostname-target
say "entering the chroot"
arch-chroot /mnt /bin/sh -s <<'CHROOT'
set -eu
say() { echo "CHROOT: $*" > /dev/ttyS0 2>/dev/null || echo "CHROOT: $*"; }

HOSTNAME=$(cat /.hostname-target); rm -f /.hostname-target
echo "$HOSTNAME" > /etc/hostname
printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s.localdomain %s\n' \
  "$HOSTNAME" "$HOSTNAME" > /etc/hosts

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc --utc 2>/dev/null || true
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

say "creating the user"
useradd -m -G wheel,video,render,audio,input --shell /bin/bash docker
echo 'docker:admin' | chpasswd
echo 'root:docker' | chpasswd
sed -i 's/^# *%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

say "installing the bootloader"
# grub-install's own words are echoed. Reporting only "FAILED" cost two rounds on
# the EndeavourOS bake: the answer was the missing ef02 partition and the message
# had been thrown away.
if grub-install --target=i386-pc --recheck --boot-directory=/boot /dev/vda > /tmp/grub.log 2>&1; then
  say "  grub-install i386-pc done"
else
  say "  grub-install i386-pc FAILED; its own words:"
  while IFS= read -r line; do say "    $line"; done < /tmp/grub.log
fi
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=arch \
  --boot-directory=/boot > /dev/ttyS0 2>&1 || say "  (efi install skipped - no EFI)"

printf 'GRUB_DEFAULT=0\nGRUB_TIMEOUT=0\nGRUB_DISTRIBUTOR="Arch"\nGRUB_CMDLINE_LINUX_DEFAULT=""\nGRUB_CMDLINE_LINUX="console=ttyS0,115200n8"\nGRUB_TERMINAL=console\nGRUB_DISABLE_OS_PROBER=true\n' \
  > /etc/default/grub

if grub-mkconfig -o /boot/grub/grub.cfg > /dev/ttyS0 2>&1; then
  say "  grub-mkconfig done"
else
  say "  GRUB-MKCONFIG FAILED"
fi
if grep -q 'console=ttyS0' /boot/grub/grub.cfg 2>/dev/null; then
  say "  grub.cfg carries console=ttyS0"
else
  say "  WARNING: grub.cfg has no console=ttyS0"
fi

mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d
printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin docker --keep-baud 115200,38400,9600 %%I $TERM\n' \
  > /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf
systemctl enable serial-getty@ttyS0.service

say "finding the display manager"
DM=""
for c in plasmalogin sddm gdm lightdm greetd cosmic-greeter; do
  [ -x "/usr/bin/$c" ] && { DM="$c"; break; }
done
say "  display manager: ${DM:-NONE}"

mkdir -p /etc/sddm.conf.d
printf '[Autologin]\nUser=docker\nSession=plasma\n' > /etc/sddm.conf.d/autologin.conf
printf '[Autologin]\nUser=docker\nSession=plasma\n' > /etc/plasmalogin.conf

# Enabling is a separate step from configuring, and it is the one that was missing
# on the EndeavourOS disk: the target came up, found nothing to start, and went down.
if [ -n "$DM" ]; then
  systemctl enable "$DM" > /dev/ttyS0 2>&1 || say "  ENABLE FAILED for $DM"
  systemctl set-default graphical.target
  ln -sf "/usr/lib/systemd/system/$DM.service" /etc/systemd/system/display-manager.service 2>/dev/null || true
  say "  display-manager.service -> $(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)"
fi

systemctl enable NetworkManager > /dev/ttyS0 2>&1 || true

mkdir -p /home/docker/.config
printf '[Daemon]\nAutolock=false\nLockOnResume=false\n' > /home/docker/.config/kscreenlockerrc
chown -R 1000:1000 /home/docker/.config

echo ARCH_BAKE_OK > /var/log/arch-bake-ok
echo ARCH_BAKE_OK > /dev/ttyS0 || true
say "chroot finished"
CHROOT

say "unmounting"
sync
umount -R /mnt
say "done"
