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
# Log to the serial console AND a file, but only if the console is writable:
# under systemd-run (and any non-console invocation) /dev/ttyS0 does not exist,
# and 'tee ... /dev/ttyS0' then fails on every write, which aborts the whole
# script through pipefail before it has fetched anything.
if [ -w /dev/ttyS0 ]; then
  exec > >(tee -a /var/log/oem.log /dev/ttyS0) 2>&1
else
  exec >>/var/log/oem.log 2>&1
fi

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
  && curl -fsS -m 60 -o "$STATE/easystream" "http://${HOST}/easystream-nixos"; then
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

# --- desktop session ---------------------------------------------------------
#
# The NixOS image may boot with EITHER a compositor already running from greetd
# (Cosmic) or nothing at all (labwc's headless backend, which nothing else
# starts). Reuse what is there; only start labwc when the seat is empty.
#
# Forcing labwc unconditionally was wrong once Cosmic became the declared
# desktop: it would fight greetd's session and leave two compositors on the same
# seat.
sock=""
for _ in $(seq 1 30); do
  sock="$(ls "$RUN_DIR" 2>/dev/null | grep '^wayland-' | head -1 || true)"
  [ -n "$sock" ] && break
  sleep 1
done

# Which desktop is on the seat? xdg-desktop-portal selects its backend by
# matching each .portal file UseIn= against XDG_CURRENT_DESKTOP. Get this
# wrong and the portal exposes only FileChooser/Settings, so easystream
# reports capture=None while the compositor is working perfectly.
DESKTOP=wlroots
if pgrep -f cosmic-comp >/dev/null 2>&1; then
  DESKTOP=COSMIC
elif pgrep -f kwin_wayland >/dev/null 2>&1; then
  DESKTOP=KDE
fi

if [ -n "$sock" ]; then
  echo "=== reusing the running compositor (socket $sock, desktop $DESKTOP) ==="
else
  echo "=== no session yet, starting labwc (headless) ==="
  pkill -u "$USER" -f labwc 2>/dev/null || true
  sleep 1
  setsid su -l "$USER" -c \
    "export PATH=/run/current-system/sw/bin:/run/wrappers/bin:/usr/bin:/bin \
            XDG_RUNTIME_DIR=$RUN_DIR XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=$DESKTOP \
            WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_LIBINPUT_NO_DEVICES=1; \
     exec labwc" >/var/log/labwc.log 2>&1 &
  for _ in $(seq 1 60); do
    sock="$(ls "$RUN_DIR" 2>/dev/null | grep '^wayland-' | head -1 || true)"
    [ -n "$sock" ] && break
    sleep 1
  done
fi


# Tell the portal which desktop it is on, then restart it so it reloads its
# backends. Without the restart it keeps the environment it was started with,
# which is whatever greetd had (often nothing).
if [ -n "${sock:-}" ]; then
  su -l "$USER" -c "export XDG_RUNTIME_DIR=$RUN_DIR;     systemctl --user set-environment XDG_CURRENT_DESKTOP=$DESKTOP XDG_SESSION_TYPE=wayland;     systemctl --user restart xdg-desktop-portal.service xdg-permission-store.service"     >/dev/null 2>&1 || true
  sleep 3
fi

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

# --- audio: give the graph a recordable source ------------------------------
# easystream opens an audio stream at startup and reports
#   audio: pipewire present but produced no data
# when the session graph has no sink to capture. A null sink solves it: it is a
# node that always produces silence, so a recording stream can always connect.
#
# Created with pw-cli as the SESSION user: PipeWire belongs to the session, and as
# root there is no XDG_RUNTIME_DIR/PIPEWIRE_REMOTE to reach and the call simply
# blocks. Best-effort throughout — audio must never stop the desktop.
echo "=== audio: pipewire null sink (vsink) ==="
# Say it out loud when the CLI is absent. Silently producing nothing here is how
# the sandbox ended up with 'no working capture backend' and no clue why: pw-cli
# ships in the pipewire PACKAGE, not in services.pipewire, so it was not on PATH.
if ! su -l "$USER" -c "PATH=/run/current-system/sw/bin:/run/wrappers/bin:\$PATH; command -v pw-cli" >/dev/null 2>&1; then
  echo "audio: pw-cli NOT FOUND - no sink will be created (see environment.systemPackages)"
fi
timeout 25 su -l "$USER" -c \
  "export XDG_RUNTIME_DIR=$RUN_DIR PATH=/run/current-system/sw/bin:/run/wrappers/bin:/usr/bin:/bin; \
   pw-cli create-node adapter \
     '{ factory.name=support.null-audio-sink node.name=vsink \
        media.class=Audio/Sink object.linger=true audio.position=[FL FR] ' 2>&1 | tail -2; \
   pw-cli ls Node 2>/dev/null | grep -c vsink || true" \
  2>&1 | tail -3 || echo "audio: sink setup failed (continuing without audio)"

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
# --- no compatibility shim needed --------------------------------------------
#
# There used to be a resolve_libs step here that scanned /nix/store for every
# soname easystream asks for and symlinked the best match into a private
# directory exposed through LD_LIBRARY_PATH. It was a workaround for running a
# binary built ELSEWHERE: an Ubuntu build asks for libx264.so.164 and
# libopus.so.0 by names nixpkgs may not provide.
#
# That is no longer the case. oem-nixos.sh now fetches the binary that
# easystream CI built INSIDE nixpkgs (flake.nix, /easystream-nixos), so its
# sonames and glibc are exactly the ones this system ships. nix-ld already
# resolves them from /run/current-system/sw/share/nix-ld/lib.
#
# Keeping the shim would actively break things: the compat directory shadowed
# the system glibc through LD_LIBRARY_PATH, so a libopus picked from an older
# store generation pulled in glibc 2.42 while everything else was 2.44, and the
# loader failed with
#   version GLIBC_2.43 not found (required by libopus.so.0)
# Deleting it is the fix, not a simplification.

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
