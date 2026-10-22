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

# Writing the PERMISSION alone is not enough. Start consumes the entry's DATA,
# which the portal looks up by this token on SelectDevices and passes on to the
# backend as restore_data. The two backends want DIFFERENT structures, so the
# payload is built per flavour: a GNOME payload on a KDE guest is rejected and the
# consent dialog comes straight back.
#
# The app id key is "" because that is what the capturing client had: an
# unsandboxed process, whose app id xdp-app-info-host.c derives from its systemd
# user unit. The portal matches permissions by the CALLER's app id at runtime, and
# "" is the unrestricted case.
APP_ID="${APP_ID:-}"

if [ "$FLAVOR" = "kde" ]; then
  # KDE's RestoreData (restoredata.h) is (sua{sv}): session, version, payload.
  # remotedesktop.cpp restores only when session is "KDE", version is 1, AND
  # payload devices / screenShareEnabled equal what THIS call asks for. The device
  # mask is 3 (keyboard|pointer); screen sharing is on because SelectSources asked
  # for a monitor. Any mismatch silently falls through to the dialog.
  as_user busctl --user --no-pager call \
    org.freedesktop.impl.portal.PermissionStore \
    /org/freedesktop/impl/portal/PermissionStore \
    org.freedesktop.impl.portal.PermissionStore \
    Set sbsa{sas}v \
    remote-desktop true "$TOKEN" \
    1 "$APP_ID" 1 yes \
    "(suv)" "KDE" 1 \
    "(sua{sv})" "KDE" 1 \
    2 "devices" "u" 3 "screenShareEnabled" "b" true
else
  # GNOME's REMOTE_DESKTOP_RESTORE_VARIANT_TYPE is (xxuba(uuv)):
  #   creation_time, device_types, clipboard_enabled, a(uuv) streams
  # with each stream (id, type=1 MONITOR, "vendor:product:serial").
  #
  # That match string is built by the backend as vendor:product:serial from
  # vendor/product/serial (displaystatetracker.c:317). If it does not match the
  # guest's monitor, find_monitor_by_string() fails and Start prompts again.
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
fi

echo "granted remote-desktop token $TOKEN ($FLAVOR, app id '${APP_ID}')"

# easystream reads this at startup and passes it as restore_token.
printf '%s\n' "$TOKEN" > "/home/$USER_NAME/.config/remote-desktop-token"
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.config/remote-desktop-token"
chmod 664 "/home/$USER_NAME/.config/remote-desktop-token"

as_user busctl --user --no-pager call \
  org.freedesktop.impl.portal.PermissionStore \
  /org/freedesktop/impl/portal/PermissionStore \
  org.freedesktop.impl.portal.PermissionStore GetPermission sss \
  remote-desktop "$TOKEN" "$APP_ID" || true
