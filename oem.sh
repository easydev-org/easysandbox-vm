#!/bin/bash
# The REAL launch logic, served by the container's nginx (/oem.sh) and run by
# the golden disk's bootstrap.sh loader on every boot. Changing it is an IMAGE
# change — the golden disk is never re-baked for a launch change.
#
# ORDER: D-Bus session -> GNOME Wayland -> easystream (captures the screen and
# injects input, so it comes LAST) -> agent-worker.
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
  if curl -fsS -m 60 -o /usr/local/bin/agent-worker "http://${HOST}/worker" \
  && curl -fsS -m 60 -o /usr/local/bin/easystream   "http://${HOST}/easystream"; then
    chmod 755 /usr/local/bin/agent-worker /usr/local/bin/easystream
    echo "FETCH-OK"; break
  fi
  echo "fetch retry $i"; sleep 3
done
ls -la /usr/local/bin/agent-worker /usr/local/bin/easystream || true

# --- per-pod env (WORKER_TOKEN, SANDBOX_PROXY) -------------------------------
curl -fsS -m 10 -o /run/shm/env "http://${HOST}/env" 2>/dev/null || true
if [ -s /run/shm/env ]; then set -a; . /run/shm/env; set +a; fi

# --- the desktop session (Wayland) -------------------------------------------
install -d -o "$USER" -g "$USER" -m 700 "$RUN_DIR"

echo "=== waiting for GDM to bring up the GNOME Wayland session ==="
# GDM (enabled on the golden disk) starts the session: it assigns a logind seat
# and hands over DRM master, which mutter needs to drive /dev/dri/card0. Starting
# gnome-session by hand left it "headlessly" with no seat, so nothing reached the
# GPU and VNC showed only the text console.
for _ in $(seq 1 120); do
  if ls "$RUN_DIR" 2>/dev/null | grep -q '^wayland'; then break; fi
  sleep 2
done

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
echo "=== easystream ==="
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
  "export DBUS_SESSION_BUS_ADDRESS='$SESSION_DBUS' WAYLAND_DISPLAY='$WAYLAND_DISPLAY' EAZYSTREAM_HTTP_PORT=48078; \
   exec easystream serve" >/var/log/easystream.log 2>&1 &
EPID=$!
sleep 3
if ! kill -0 "$EPID" 2>/dev/null; then
  echo "!!! easystream EXITED immediately; log:"
  cat /var/log/easystream.log 2>&1 || true
fi

echo "=== agent-worker ==="
WORKER_PORT=48080 WORKER_TOKEN="${WORKER_TOKEN:-}" agent-worker >/var/log/agent-worker.log 2>&1 &
WPID=$!
sleep 3
if ! kill -0 "$WPID" 2>/dev/null; then
  echo "!!! agent-worker EXITED immediately; log:"
  cat /var/log/agent-worker.log 2>&1 || true
fi
echo "=== ps ==="
ps -ef 2>/dev/null | grep -E 'easystream|agent-worker' | grep -v grep || echo "(neither running)"
echo "=== easystream.log ==="
cat /var/log/easystream.log 2>&1 | tail -20 || true
echo "=== listening ports ==="
ss -lntp 2>/dev/null | grep -E '48078|48080' || netstat -lntp 2>/dev/null | grep -E '48078|48080' || echo "(no ss/netstat)"

wait
