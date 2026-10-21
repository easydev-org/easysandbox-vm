#!/bin/bash
# Grant the portal's RemoteDesktop + ScreenCast permission ahead of time, so a
# remote viewer never meets a consent dialog it cannot click.
#
# WHY THIS IS NEEDED
#
# easystream drives the desktop through xdg-desktop-portal. The handshake is
#
#   RemoteDesktop.CreateSession
#   RemoteDesktop.SelectDevices      <- input devices
#   ScreenCast.SelectSources         <- what to capture
#   RemoteDesktop.Start              <- both at once
#
# and Start shows a GTK consent dialog unless it already holds a grant
# ("Allow Remote Interaction" + "Remember This Selection"). In a headless guest
# nobody can click it, Start blocks until it times out, and the session never
# starts — which is what made every earlier run end in "no video frames".
#
# HOW THE GRANT IS CREATED
#
# The dialog can be accepted exactly once (see bake/README: the button is not the
# default widget, the widgets' AT-SPI extents are all 0,0 so pointer clicks land
# in the corner, and the focus chain runs
#     Allow Remote Interaction -> (spacer) -> Cancel -> Share
# so focus must be watched through AT-SPI and Share activated with Space).
# Accepting it makes the portal write a restore_token into the "remote-desktop"
# table; replaying that token makes Start return in ~0.1s with no dialog at all.
#
# The token is written through the PermissionStore D-Bus API rather than by
# copying the database file. The file is a GVariant blob whose layout is private
# to xdg-desktop-portal: the previous disk carried a hand-copied blob from an
# older portal, and the new portal segfaulted reading it. Going through the API
# lets the portal serialise it in whatever format it currently expects.
#
#   $1 = gnome | kde   (default gnome)
#   $2 = restore token to install (UUID)
set -e

FLAVOR="${1:-gnome}"
TOKEN="${2:-}"

if [ -z "$TOKEN" ]; then
  echo "usage: $0 <gnome|kde> <restore-token-uuid>" >&2
  exit 2
fi

USER_NAME=docker
UID_NUM=$(id -u "$USER_NAME")
RUN_DIR="/run/user/$UID_NUM"

# The store is per-session-user and lives behind the session bus, so this has to
# run as the desktop user with its runtime dir.
as_user() {
  sudo -u "$USER_NAME" env \
    XDG_RUNTIME_DIR="$RUN_DIR" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$RUN_DIR/bus" \
    "$@"
}

echo "waiting for the session bus and PermissionStore ($FLAVOR)…"
for _ in $(seq 1 60); do
  if as_user busctl --user --no-pager status \
       org.freedesktop.impl.portal.PermissionStore >/dev/null 2>&1; then
    break
  fi
  # Activation is lazy: name the service so the daemon starts.
  as_user busctl --user --no-pager call \
    org.freedesktop.impl.portal.PermissionStore \
    /org/freedesktop/impl/portal/PermissionStore \
    org.freedesktop.impl.portal.PermissionStore List s remote-desktop \
    >/dev/null 2>&1 || true
  sleep 1
done

# Writing the PERMISSION alone is not enough. What Start consumes is the entry's
# DATA, which the portal looks up by this token on SelectDevices:
#
#   (suv) "GNOME" 1 (xxuba(uuv)) creation_time device_types clipboard a(uuv)streams
#
# where each stream is (id, type=1 MONITOR, "vendor:product:serial"). If the data
# is missing, lookup returns NULL, restore_from_data() fails, and the dialog comes
# back — so the whole entry is written here, not just the a{sas} map.
#
# The app id key is left as "" because that is what the capturing client had (an
# unsandboxed test process, whose app id xdp-app-info-host.c derives from its
# systemd user unit and which had none). The portal matches permissions by the
# CALLER's app id at runtime, so a non-empty key here only works when easystream's
# unit is named app-easystream.service. Keeping "" matches the unrestricted case.
APP_ID="${APP_ID:-}"

# Monitor match string: the portal backend builds it as "vendor:product:serial"
# from Mutter's DisplayConfig (displaystatetracker.c:317). It must match the
# guest's monitor or find_monitor_by_string() fails and Start prompts again.
MATCH_STRING="${MATCH_STRING:-RHT:QEMU Monitor:0x00000000}"
NOW_US=$(( $(date +%s) * 1000000 ))

as_user busctl --user --no-pager call \
  org.freedesktop.impl.portal.PermissionStore \
  /org/freedesktop/impl/portal/PermissionStore \
  org.freedesktop.impl.portal.PermissionStore \
  Set sbsa{sas}v \
  remote-desktop true "$TOKEN" \
  1 "$APP_ID" 1 yes \
  "(suv)" "GNOME" 1 \
  "(xxuba(uuv))" "$NOW_US" "$NOW_US" 3 false \
  1 0 1 "s" "$MATCH_STRING"

echo "granted remote-desktop token $TOKEN (app id '${APP_ID}')"

# easystream reads this at startup and passes it as restore_token.
printf '%s\n' "$TOKEN" > "/home/$USER_NAME/.config/remote-desktop-token"
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.config/remote-desktop-token"
chmod 664 "/home/$USER_NAME/.config/remote-desktop-token"

as_user busctl --user --no-pager call \
  org.freedesktop.impl.portal.PermissionStore \
  /org/freedesktop/impl/portal/PermissionStore \
  org.freedesktop.impl.portal.PermissionStore GetPermission sss \
  remote-desktop "$TOKEN" "$APP_ID" || true
