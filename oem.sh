#!/bin/bash
# The REAL launch logic, served by the container's nginx (/oem.sh) and run by
# the golden disk's bootstrap.sh loader on every boot. Changing it is an IMAGE
# change — the golden disk is never re-baked for a launch change.
#
# ORDER: D-Bus session -> GNOME Wayland -> easystream (captures the screen and
# injects input, so it comes LAST) -> easyworker.
#
# NOTE: this is the GNOME flavor. The KDE image ships its own copy.
set -Eeuo pipefail
exec > >(tee -a /var/log/oem.log /dev/ttyS0) 2>&1

# The container as seen from the guest. QEMU user-net rewrites dots in the
# hostname it advertises, so `host.lan` may only resolve as `host-lan`; try
# every candidate and fall back to the default gateway (the container itself).
GW="$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
HOST=""
for H in "${DESKTOP_HOST:-host.lan}" host.lan host-lan "${GW:-172.30.0.1}"; do
  if curl -fsS -m 5 -o /dev/null "http://${H}:8090/env" 2>/dev/null; then HOST="${H}:8090"; break; fi
done
: "${HOST:=${GW:-172.30.0.1}:8090}"
USER=docker
RUN_DIR=/run/user/1000

echo "=== oem: host=${HOST} ==="

# --- guest binaries (boot-fetch: a worker/easystream upgrade is an image change)
for i in $(seq 1 30); do
  if curl -fsS -m 60 -o /usr/local/bin/easyworker "http://${HOST}/worker" \
  && curl -fsS -m 60 -o /usr/local/bin/easystream   "http://${HOST}/easystream"; then
    chmod 755 /usr/local/bin/easyworker /usr/local/bin/easystream
    echo "FETCH-OK"; break
  fi
  echo "fetch retry $i"; sleep 3
done
ls -la /usr/local/bin/easyworker /usr/local/bin/easystream || true

# --- per-pod env (WORKER_TOKEN, SANDBOX_PROXY) -------------------------------
curl -fsS -m 10 -o /run/shm/env "http://${HOST}/env" 2>/dev/null || true
if [ -s /run/shm/env ]; then set -a; . /run/shm/env; set +a; fi
# Lock the daemon: control needs the token (defaulting to the worker's own
# token), view stays open. Without it easystream runs unauthenticated and any
# process that reached :48079/:48078 could drive the guest.
: "${EAZYSTREAM_CONTROL_TOKEN:=${WORKER_TOKEN:-}}"
: "${EAZYSTREAM_VIEW_TOKEN:=}"
export EAZYSTREAM_CONTROL_TOKEN EAZYSTREAM_VIEW_TOKEN

# --- the desktop session (Wayland) -------------------------------------------
install -d -o "$USER" -g "$USER" -m 700 "$RUN_DIR"

echo "=== waiting for the display manager to bring up the Wayland session ==="
# The display manager (GDM for GNOME, SDDM for Plasma) starts the session: it
# assigns a logind seat and hands over DRM master, which mutter/kwin need to
# drive /dev/dri/card0. Starting the session by hand left it "headlessly" with
# no seat, so nothing reached the GPU and VNC showed only the text console.
# This waits for EITHER manager, so one oem.sh serves both flavors.
# Bounded wait: if the desktop never comes up we still start easystream and the
# worker, so the sandbox is reachable (and diagnosable) instead of hanging here
# forever with nothing listening.
sock=""
for _ in $(seq 1 90); do
  sock="$(ls "$RUN_DIR" 2>/dev/null | grep '^wayland' | head -1 || true)"
  [ -n "$sock" ] && break
  sleep 2
done
echo "=== display manager: wayland socket = ${sock:-NONE} ==="
if [ -z "$sock" ]; then
  echo "--- no session yet; diagnostics ---"
  loginctl list-sessions --no-legend 2>&1 | head -6
  systemctl is-active sddm gdm 2>&1 | head -2
  pgrep -a kwin_wayland 2>&1 | head -2
  pgrep -a gnome-shell 2>&1 | head -2
  journalctl -b --no-pager 2>/dev/null | grep -aiE 'sddm|plasma|kwin|gdm' | tail -12
  # `systemctl enable` during the bake runs before the unit exists, so the
  # display manager may be installed but not started. Start it explicitly (and
  # enable it for next boot) rather than depending on the bake.
  for dm in sddm gdm; do
    if systemctl list-unit-files "$dm.service" >/dev/null 2>&1 \
       && systemctl cat "$dm.service" >/dev/null 2>&1; then
      echo "--- starting $dm ---"
      systemctl enable "$dm.service" 2>&1 | tail -1
      systemctl start "$dm.service" 2>&1 | tail -2
    fi
  done
  for _ in $(seq 1 45); do
    sock="$(ls "$RUN_DIR" 2>/dev/null | grep '^wayland' | head -1 || true)"
    [ -n "$sock" ] && break
    sleep 2
  done
  echo "=== after starting the DM: wayland socket = ${sock:-NONE} ==="
fi

for _ in $(seq 1 120); do
  ls "$RUN_DIR" 2>/dev/null | grep -q '^wayland' && break
  sleep 1
done
sock="$(ls "$RUN_DIR" 2>/dev/null | grep '^wayland' | head -1 || true)"
echo "=== WAYLAND=${sock:-NONE} ==="
pgrep -a gnome-shell || echo "(no gnome-shell)"
if [ -z "$sock" ]; then
  echo "NO WAYLAND SOCKET — dumping the session log:"
  journalctl -b --no-pager -n 60 2>/dev/null | tail -60 || true
  echo "--- DRM devices ---"
  ls -la /dev/dri 2>&1 || echo "no /dev/dri"
  echo "--- gnome-shell modes dir ---"
  ls -la /usr/share/gnome-shell/modes/ 2>&1 || echo "NO modes dir"
  for f in /usr/share/gnome-shell/modes/*; do echo "### $f"; cat "$f" 2>&1; done
  echo "--- gnome-shell version ---"
  gnome-shell --version 2>&1 || true
  echo "--- gnome-shell direct run ---"
  runuser -u "$USER" -- env XDG_RUNTIME_DIR="$RUN_DIR" XDG_SESSION_TYPE=wayland \
    XDG_CURRENT_DESKTOP=GNOME GNOME_SHELL_SESSION_MODE=user \
    timeout 10 gnome-shell --wayland 2>&1 | tail -20 || true
  echo "--- mutter headless attempt ---"
  runuser -u "$USER" -- env XDG_RUNTIME_DIR="$RUN_DIR" XDG_SESSION_TYPE=wayland \
    MUTTER_DEBUG_DUMMY_MODE_SPECS=1024x768 \
    timeout 10 gnome-shell --wayland 2>&1 | tail -12 || true
  sleep infinity
fi
export WAYLAND_DISPLAY="$sock"

# --- easystream LAST (it captures the screen and injects input) --------------
# Give the guest a RECORDABLE audio source before easystream starts (it probes
# the backend by reading a frame at startup).
#
# PipeWire here, not PulseAudio: the guest has a real GPU and a running
# PipeWire/WirePlumber session, so a null sink is driven by the graph. (In a
# container the opposite is true — no GPU means PipeWire's null sink stays
# suspended, which is why the containers use PulseAudio.)
echo "=== audio: pipewire null sink (vsink) ==="
# Run it AS THE SESSION USER, and with a timeout:
#   * PipeWire/WirePlumber belong to the session, so as root pactl has no
#     XDG_RUNTIME_DIR/PIPEWIRE_REMOTE to reach and simply BLOCKS. With `set -e`
#     that hung oem.sh and the container restart-looped (observed: five
#     'audio: pipewire null sink' lines in a row and never reaching easystream).
#   * best-effort: audio must never break the sandbox.
# `pw-cli` creates the node directly in the PipeWire graph. `pactl` needs the
# pipewire-pulse compatibility socket, which was not there ("pa_context_connect
# failed: Connection refused"); pw-cli talks to PipeWire itself.
timeout 20 su -l "$USER" -c "
  export XDG_RUNTIME_DIR=$RUN_DIR
  pw-cli create-node adapter \
    '{ factory.name=support.null-audio-sink node.name=vsink \
       media.class=Audio/Sink object.linger=true audio.position=[FL FR] }' 2>&1 | tail -2
  pw-cli ls Node 2>/dev/null | grep -c vsink || true
" 2>&1 | tail -4 || echo "audio: sink setup failed (continuing without audio)"

# --- portal RemoteDesktop grant ----------------------------------------------
# easystream starts its session with RemoteDesktop.Start, and the portal answers
# that with a GTK consent dialog unless it already holds a grant. There is nobody
# to click it in a headless guest, so Start blocks and the sandbox streams
# nothing at all (no video, no input).
#
# The grant is a restore_token in the portal's "remote-desktop" table. Installing
# it here, once per boot, keeps the disk free of any assumption about the portal
# version: the PermissionStore owns its own on-disk format, and a hand-copied
# blob from an older portal is exactly what made xdg-desktop-portal segfault
# earlier. The token is stable, so a re-run is harmless.
#
# Idempotent and best-effort: a missing token must not stop the desktop.
echo "=== portal remote-desktop grant ==="
# The script is kept in the artifact store rather than baked into the image so it
# can be corrected without rebuilding: it has to track the portal's restore-token
# semantics, which is exactly the part that keeps changing.
if [ ! -s /usr/local/bin/seed-remote-desktop.sh ]; then
  curl -fsS -m 20 -o /usr/local/bin/seed-remote-desktop.sh \
    "http://${HOST_GW:-172.18.41.95}/artifacts/generic/golden-linux-desktop/scripts/seed-remote-desktop.sh" \
    >/dev/null 2>&1 || true
  [ -s /usr/local/bin/seed-remote-desktop.sh ] && \
    chmod 755 /usr/local/bin/seed-remote-desktop.sh
fi
if [ -x /usr/local/bin/seed-remote-desktop.sh ]; then
  timeout 90 /usr/local/bin/seed-remote-desktop.sh "${FLAVOR:-gnome}" \
    "${RD_TOKEN:-72ee70ad-e3d9-4fc2-802d-b8bcedc3e28a}" 2>&1 | tail -4 \
    || echo "grant: seeding failed (continuing; input will prompt)"
else
  echo "grant: /usr/local/bin/seed-remote-desktop.sh missing"
fi

echo "=== easystream ==="
# Kill any instance left over from a previous launch before starting a new one.
#
# Without this the new daemon binds est (48079) but loses the race for the HTTP
# port (48078) — "Address already in use" — because the old one is still shutting
# down. The http thread dies, est keeps running, and the sandbox streams nothing
# and answers nothing, while the process list looks healthy.
pkill -f "easystream serve" 2>/dev/null || true
for _ in $(seq 1 20); do
  pgrep -f "easystream serve" >/dev/null 2>&1 || break
  sleep 0.25
done
pkill -9 -f "easystream serve" 2>/dev/null || true
# Wait for the port itself, not just the process: a listening socket can outlive
# the process that held it for a moment, and that is enough to fail the bind.
for _ in $(seq 1 20); do
  ss -lnt 2>/dev/null | grep -q ":48078 " || break
  sleep 0.25
done

# easystream needs the SESSION D-Bus to reach the AT-SPI registry. It is started
# from this root shell, which has no DBUS_SESSION_BUS_ADDRESS, so it tried to
# autolaunch one and failed ("Unable to autolaunch a dbus-daemon without a
# $DISPLAY for X11"). Take the address from the running session instead.
SESSION_DBUS=""
for pid in $(pgrep -u "$USER" gnome-shell 2>/dev/null) $(pgrep -u "$USER" dbus-daemon 2>/dev/null); do
  a="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' | head -1)"
  [ -n "$a" ] && { SESSION_DBUS="$a"; break; }
done
[ -z "$SESSION_DBUS" ] && SESSION_DBUS="unix:path=$RUN_DIR/bus"
echo "=== easystream: session bus = ${SESSION_DBUS} ==="
# Run it AS THE SESSION USER: the D-Bus daemon authenticates peers with EXTERNAL
# (their uid), and the AT-SPI registry belongs to $USER. As root, easystream's
# requests were rejected ("Did not receive a reply ... timeout expired").
setsid su -l "$USER" -c \
  "export DBUS_SESSION_BUS_ADDRESS='$SESSION_DBUS' WAYLAND_DISPLAY='$WAYLAND_DISPLAY' EAZYSTREAM_HTTP_PORT=48078 \
          EAZYSTREAM_CONTROL_TOKEN='$EAZYSTREAM_CONTROL_TOKEN' EAZYSTREAM_VIEW_TOKEN='$EAZYSTREAM_VIEW_TOKEN'; \
   exec easystream serve" >/var/log/easystream.log 2>&1 &
EPID=$!
sleep 4
if ! kill -0 "$EPID" 2>/dev/null; then
  echo "!!! easystream EXITED immediately; log:"
  cat /var/log/easystream.log 2>&1 || true
elif ! grep -q "easystream http on" /var/log/easystream.log 2>/dev/null; then
  # The process is alive but its HTTP listener failed to bind, which leaves a
  # daemon that streams nothing useful and answers no /desktop/ requests. That is
  # what "Address already in use" produced: an old instance still held 48078 when
  # this one started, the http thread died, and est kept running with no way in.
  echo "!!! easystream alive but HTTP did not bind; log:"
  cat /var/log/easystream.log 2>&1 || true
fi

echo "=== easyworker ==="
WORKER_PORT=48080 WORKER_TOKEN="${WORKER_TOKEN:-}" easyworker >/var/log/easyworker.log 2>&1 &
WPID=$!
sleep 3
if ! kill -0 "$WPID" 2>/dev/null; then
  echo "!!! easyworker EXITED immediately; log:"
  cat /var/log/easyworker.log 2>&1 || true
fi
echo "=== ps ==="
ps -ef 2>/dev/null | grep -E 'easystream|easyworker' | grep -v grep || echo "(neither running)"
echo "=== easystream.log ==="
cat /var/log/easystream.log 2>&1 | tail -20 || true
echo "=== listening ports ==="
ss -lntp 2>/dev/null | grep -E '48078|48080' || netstat -lntp 2>/dev/null | grep -E '48078|48080' || echo "(no ss/netstat)"

wait
