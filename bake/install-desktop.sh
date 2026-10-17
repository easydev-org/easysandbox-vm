#!/usr/bin/env bash
# Install the NATIVE Debian desktop + wire the golden disk's bootstrap.
#   $1 = gnome | kde
set -Eeuxo pipefail
exec > >(tee -a /var/log/install-desktop.log /dev/ttyS0) 2>&1
export DEBIAN_FRONTEND=noninteractive

FLAVOR="${1:-gnome}"
case "$FLAVOR" in
  gnome) PKGS="gnome-core" ;;
  kde)   PKGS="kde-plasma-desktop xdg-desktop-portal-kde sddm" ;;
  *) echo "unknown flavor $FLAVOR" >&2; exit 2 ;;
esac

[ -f /var/lib/desktop-done ] && exit 0

rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true
apt-get -o Acquire::Retries=10 update
# PKGS is a space-separated list and is expanded UNQUOTED on purpose:
# quoting it makes apt treat the whole string as ONE package name
# ("Unable to locate package kde-plasma-desktop xdg-...").
for i in 1 2 3 4 5; do
  apt-get -o Acquire::Retries=10 install -y --no-install-recommends \
    $PKGS \
    at-spi2-core libatk-adaptor dbus pipewire pipewire-bin pipewire-pulse wireplumber \
    pulseaudio-utils \
    xdg-desktop-portal xdg-desktop-portal-gnome xdg-desktop-portal-gtk \
    fonts-dejavu fonts-noto-cjk curl ca-certificates wl-clipboard git \
    libxcb-xtest0 libxcb1 libx11-6 libxtst6 libx264-164 libyuv0 libgbm1 \
    linux-image-amd64 firmware-linux-free \
  && break || { echo "apt retry $i"; sleep 5; }
done

# --- make the FULL kernel the one that boots ---------------------------------
# linux-image-cloud-amd64 carries no DRM/KMS driver for an emulated GPU, so the
# guest has no /dev/dri and GNOME falls back to llvmpipe (a black VNC screen).
# `apt purge` refuses to remove the RUNNING kernel, so instead we delete its boot
# files and point GRUB at the full kernel: after this the cloud kernel cannot be
# selected.
CLOUD="$(ls /boot/vmlinuz-*cloud* 2>/dev/null | head -1 || true)"
if [ -n "$CLOUD" ]; then
  CVER="${CLOUD#/boot/vmlinuz-}"
  echo "=== removing the cloud kernel boot files: $CVER ===" | tee /dev/ttyS0
  rm -f "/boot/vmlinuz-$CVER" "/boot/initrd.img-$CVER" "/boot/config-$CVER" "/boot/System.map-$CVER"
fi
FULL="$(ls -1 /boot/vmlinuz-*-amd64 2>/dev/null | grep -v cloud | head -1 || true)"
if [ -n "$FULL" ]; then
  FVER="${FULL#/boot/vmlinuz-}"
  echo "=== pinning GRUB to $FVER ===" | tee /dev/ttyS0
  sed -i "s/^GRUB_DEFAULT=.*/GRUB_DEFAULT=\"Advanced options for Debian GNU\/Linux>Debian GNU\/Linux, with Linux $FVER\"/" /etc/default/grub
  grep -q '^GRUB_DEFAULT=' /etc/default/grub || echo "GRUB_DEFAULT=\"Advanced options for Debian GNU/Linux>Debian GNU/Linux, with Linux $FVER\"" >> /etc/default/grub
fi
update-grub 2>&1 | tail -5 | tee /dev/ttyS0
echo "=== DIAG /boot ==="; ls -1 /boot/vmlinuz-* | tee /dev/ttyS0
echo "=== DIAG grub default entry ==="; grep -m2 menuentry /boot/grub/grub.cfg | tee /dev/ttyS0

# --- gnome-shell session mode --------------------------------------------------
if [ "$FLAVOR" = gnome ]; then
  mkdir -p /usr/share/gnome-shell/modes
  printf '%s\n' '{' '  "name": "GNOME",' '  "sessionType": "wayland",' '  "isDefault": true' '}' \
    > /usr/share/gnome-shell/modes/user.json
fi


# The portal's PermissionStore mmaps ~/.local/share/flatpak/db; the dir must
# exist or every grant fails ("mmap() failed: No such device").
# The portal's PermissionStore mmaps ~/.local/share/flatpak/db; the dir
# must exist or every grant fails ("mmap() failed: No such device").
# Create it AS docker and make sure .local itself is docker-owned: a
# root-owned ~/.local makes gnome-shell fail ("Permission denied" on
# ~/.local/share/gnome-shell), which broke the whole session.
install -d -o docker -g docker /home/docker/.local/share/flatpak
chown -R docker:docker /home/docker/.local /home/docker/.cache /home/docker/.config 2>/dev/null || true

mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/desktop.service \
       /etc/systemd/system/multi-user.target.wants/desktop.service

touch /var/lib/desktop-done
echo "DESKTOP-INSTALL-DONE ($FLAVOR)"

# --- run the session via GDM ---------------------------------------------------
# We tried starting gnome-session by hand, but then mutter gets no logind seat
# ("No seat assigned, running headlessly") and never becomes DRM master, so
# nothing is drawn to the GPU and VNC shows only the text console. GDM assigns
# the seat and hands over DRM master correctly, and it can log in automatically.
if [ "$FLAVOR" = gnome ]; then
  mkdir -p /usr/share/wayland-sessions
  cat > /usr/share/wayland-sessions/gnome.desktop <<'DESK'
[Desktop Entry]
Name=GNOME
Comment=GNOME on Wayland
Exec=gnome-session --session gnome
Type=Application
DesktopNames=GNOME
DESK
fi

if [ "$FLAVOR" = gnome ]; then
  # Auto-login as docker on the Wayland session.
  mkdir -p /etc/gdm3
  cat > /etc/gdm3/daemon.conf <<'GDMCONF'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=docker
WaylandEnable=true
TimedLoginEnable=false
GDMCONF
  systemctl enable gdm.service 2>/dev/null || true
  systemctl unmask gdm.service 2>/dev/null || true
else
  # KDE: SDDM is the display manager, and like GDM it assigns the logind seat
  # and hands over DRM master (which kwin needs to draw to the GPU).
  mkdir -p /etc/sddm.conf.d
  cat > /etc/sddm.conf.d/autologin.conf <<'SDDMCONF'
[Autologin]
User=docker
Session=plasma
Relogin=false
[General]
DisplayServer=wayland
SDDMCONF
  mkdir -p /usr/share/wayland-sessions
  cat > /usr/share/wayland-sessions/plasma.desktop <<'PLASMA'
[Desktop Entry]
Name=Plasma
Comment=KDE Plasma on Wayland
Exec=/usr/bin/startplasma-wayland
Type=Application
DesktopNames=KDE
PLASMA
  systemctl enable sddm.service 2>/dev/null || true
fi

# --- seed the ScreenCast grant + persistent token ------------------------------
# The golden disk must ship the portal permission and the restore_token, or the
# first ScreenCast Start blocks on a dialog nobody can click. Fetched from the
# artifact store so it can be updated without re-baking.
curl -fsS -o /usr/local/bin/seed-screencast.sh \
  http://172.18.41.95/artifacts/generic/golden-linux-desktop/scripts/seed-screencast.sh || true
if [ -s /usr/local/bin/seed-screencast.sh ]; then
  chmod 755 /usr/local/bin/seed-screencast.sh
  /usr/local/bin/seed-screencast.sh "$FLAVOR" | tee /dev/ttyS0
fi
