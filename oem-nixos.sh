#!/bin/bash
# NixOS + labwc guest launch logic, served by the container at :8090/oem.sh.
#
# WHY THIS IS A SEPARATE FILE FROM ../oem.sh
#
# The Debian/KDE oem.sh assumes a lot that does not exist here: it writes to
# /usr/local/bin, waits for GDM/SDDM to hand over a seat, and seeds an
# xdg-desktop-portal RemoteDesktop grant so the consent dialog can be skipped.
# None of that applies:
#
#   * labwc runs on the wlroots HEADLESS backend, started by this script.
#   * capture is zwlr_screencopy and input is zwlr_virtual_pointer — direct
#     wlroots protocols. easystream probes for those and never touches the
#     portal, so there is no dialog and no grant to seed.
set -uo pipefail
exec > >(tee -a /var/log/oem.log /dev/ttyS0) 2>&1

USER=docker
RUN_DIR=/run/user/1000
STATE=/var/lib/easystream

# The container as seen from the guest. qemu user networking exposes the host as
# 10.0.2.2; the other names cover a bridged setup.
GW="$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
HOST=""
for H in "${DESKTOP_HOST:-10.0.2.2}" 10.0.2.2 host.lan host-lan "${GW:-172.30.0.1}"; do
  if curl -fsS -m 5 -o /dev/null "http://${H}:8090/env" 2>/dev/null; then HOST="${H}:8090"; break; fi
done
: "${HOST:=${GW:-10.0.2.2}:8090}"
echo "=== oem(nixos): host=${HOST} ==="

# --- guest binaries ---------------------------------------------------------
# Kept in /var/lib/easystream rather than /usr/local/bin: NixOS does not put
# /usr/local on PATH for services, and a system activation may reset it.
mkdir -p "$STATE"
for i in $(seq 1 30); do
  if curl -fsS -m 60 -o "$STATE/easyworker" "http://${HOST}/worker" \
  && curl -fsS -m 60 -o "$STATE/easystream" "http://${HOST}/easystream"; then
    chmod 755 "$STATE/easyworker" "$STATE/easystream"
    echo "FETCH-OK"; break
  fi
  echo "fetch retry $i"; sleep 3
done
ls -la "$STATE/easyworker" "$STATE/easystream" 2>&1 || true

# --- per-pod env ------------------------------------------------------------
curl -fsS -m 10 -o /run/easystream-env "http://${HOST}/env" 2>/dev/null || true
if [ -s /run/easystream-env ]; then set -a; . /run/easystream-env; set +a; fi
# Control needs the token; view stays open only if EAZYSTREAM_VIEW_TOKEN is set.
: "${EAZYSTREAM_CONTROL_TOKEN:=${WORKER_TOKEN:-}}"
: "${EAZYSTREAM_VIEW_TOKEN:=}"
export EAZYSTREAM_CONTROL_TOKEN EAZYSTREAM_VIEW_TOKEN

# --- desktop session: labwc on the wlroots headless backend -----------------
# No display manager on purpose. labwc needs neither a logind seat nor DRM
# master: the headless backend makes its own virtual output, which is exactly
# what screencopy reads and the virtual pointer drives. Starting the compositor
# directly also means a crash lands in this log instead of being swallowed by a
# login manager.
# The user's GROUP is not called docker on NixOS: isNormalUser makes the primary
# group 'users' (gid 100), so "install -g docker" failed with
# "invalid group 'docker'" and the runtime dir was never created.
install -d -o "$USER" -g users -m 700 "$RUN_DIR"

echo "=== starting labwc (headless) ==="
pkill -u "$USER" -f labwc 2>/dev/null || true
sleep 1
setsid su -l "$USER" -c \
  "export PATH=/run/current-system/sw/bin:/run/wrappers/bin:/usr/bin:/bin \
          XDG_RUNTIME_DIR=$RUN_DIR XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=wlroots \
          WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_LIBINPUT_NO_DEVICES=1; \
   exec labwc" >/var/log/labwc.log 2>&1 &

sock=""
for _ in $(seq 1 60); do
  sock="$(ls "$RUN_DIR" 2>/dev/null | grep '^wayland-' | head -1 || true)"
  [ -n "$sock" ] && break
  sleep 1
done
echo "=== WAYLAND=${sock:-NONE} ==="
if [ -z "$sock" ]; then
  echo "labwc did not create a socket; log:"
  tail -20 /var/log/labwc.log 2>&1 || true
  # Keep going: easystream and the worker still start, so the sandbox stays
  # reachable and the failure is visible instead of the VM looking dead.
else
  export WAYLAND_DISPLAY="$sock"
fi

# --- session D-Bus ----------------------------------------------------------
# easystream reaches the AT-SPI registry over the session bus. As root there is
# no DBUS_SESSION_BUS_ADDRESS, so take the one the user session already has.
SESSION_DBUS=""
for pid in $(pgrep -u "$USER" dbus-daemon 2>/dev/null) $(pgrep -u "$USER" labwc 2>/dev/null); do
  a="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' | head -1)"
  [ -n "$a" ] && { SESSION_DBUS="$a"; break; }
done
[ -z "$SESSION_DBUS" ] && SESSION_DBUS="unix:path=$RUN_DIR/bus"
echo "=== easystream: session bus = ${SESSION_DBUS} ==="

# --- easystream LAST --------------------------------------------------------
# It captures the screen and injects input, so everything above must exist.
#
# Kill any leftover instance first: the old one holds 48078 for a moment after
# being signalled, the new HTTP thread then fails to bind, and the daemon keeps
# running with no way in while the process list looks perfectly healthy.
pkill -f "easystream serve" 2>/dev/null || true
for _ in $(seq 1 20); do
  pgrep -f "easystream serve" >/dev/null 2>&1 || break
  sleep 0.25
done
pkill -9 -f "easystream serve" 2>/dev/null || true
for _ in $(seq 1 20); do
  ss -lnt 2>/dev/null | grep -q ":48078 " || break
  sleep 0.25
done

# --- make the prebuilt binaries resolvable ----------------------------------
# nix-ld supplies the interpreter and the libraries listed in configuration.nix,
# but it cannot invent a SONAME that nixpkgs does not use. easystream is linked
# against Debian-style versioned names (libyuv.so.0, libx264.so.164) while nixpkgs
# often ships the same library unversioned (libyuv.so), so the loader reports
# "cannot open shared object file" for a library that IS installed.
#
# Instead of chasing these one bake at a time, resolve them here: read the
# sonames easystream actually needs, and for any still missing, find the closest
# matching library in the store and link it under the name the loader asked for.
resolve_libs() {
  local bin="$1" missing=""
  command -v readelf >/dev/null 2>&1 || return 0
  for so in $(readelf -d "$bin" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do
    # Already resolvable? Nothing to do.
    if ldconfig -p 2>/dev/null | grep -q "$so" || [ -e "/lib/$so" ] || [ -e "/lib64/$so" ]; then
      continue
    fi
    # Strip the version suffix to find the real file: libyuv.so.0 -> libyuv
    base="$(printf '%s' "$so" | sed -E 's/\.so.*$//')"
    real="$(find /nix/store -maxdepth 3 -name "${base}.so*" -type f 2>/dev/null | head -1)"
    if [ -n "$real" ]; then
      mkdir -p /lib
      ln -sf "$real" "/lib/$so" 2>/dev/null && echo "lib-compat: $so -> $real"
    else
      missing="$missing $so"
    fi
  done
  [ -n "$missing" ] && echo "lib-compat: STILL MISSING:$missing"
}

echo "=== resolving shared libraries for the prebuilt binaries ==="
resolve_libs "$STATE/easystream"
resolve_libs "$STATE/easyworker"

setsid su -l "$USER" -c \
  "export DBUS_SESSION_BUS_ADDRESS='$SESSION_DBUS' WAYLAND_DISPLAY='${WAYLAND_DISPLAY:-wayland-0}' \
          XDG_RUNTIME_DIR=$RUN_DIR EAZYSTREAM_HTTP_PORT=48078 \
          EAZYSTREAM_CONTROL_TOKEN='$EAZYSTREAM_CONTROL_TOKEN' EAZYSTREAM_VIEW_TOKEN='$EAZYSTREAM_VIEW_TOKEN'; \
   exec $STATE/easystream serve" >/var/log/easystream.log 2>&1 &
EPID=$!
sleep 4
if ! kill -0 "$EPID" 2>/dev/null; then
  echo "!!! easystream EXITED; log:"
  cat /var/log/easystream.log 2>&1 || true
elif ! grep -q "easystream http on" /var/log/easystream.log 2>/dev/null; then
  echo "!!! easystream alive but HTTP did not bind; log:"
  cat /var/log/easystream.log 2>&1 || true
fi

# --- easyworker -------------------------------------------------------------
echo "=== easyworker ==="
WORKER_PORT=48080 WORKER_TOKEN="${WORKER_TOKEN:-}" setsid "$STATE/easyworker" \
  >/var/log/easyworker.log 2>&1 &
WPID=$!
sleep 3
if ! kill -0 "$WPID" 2>/dev/null; then
  echo "!!! easyworker EXITED; log:"
  cat /var/log/easyworker.log 2>&1 || true
fi

echo "=== ps ==="
ps -ef 2>/dev/null | grep -E 'easystream|easyworker|labwc' | grep -v grep || echo "(none)"
echo "=== easystream.log ==="
tail -20 /var/log/easystream.log 2>&1 || true
echo "=== listening ==="
ss -lntp 2>/dev/null | grep -E '48078|48080' || echo "(none)"

wait
