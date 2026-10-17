#!/bin/bash
# Debian desktop guest LOADER. Fetches oem.sh from the container and runs it.
# DIAGNOSTIC BUILD: dumps the guest's network state to the serial console so we
# can see why it cannot reach the container.
set -uo pipefail

BOOT=/usr/local/bin/oem.sh
DL=/usr/local/bin/oem.sh.dl
LOG=/var/log/bootstrap.log
say() { echo "$(date) bootstrap: $*" | tee -a "$LOG" >/dev/ttyS0; }

{
  echo "=== DIAG: whoami/host ==="
  hostname; uname -a
  echo "=== DIAG: ip tools present? ==="
  command -v ip || echo "NO ip"
  command -v curl || echo "NO curl"
  echo "=== DIAG: ip addr ==="
  ip addr 2>&1 || true
  echo "=== DIAG: ip route ==="
  ip route 2>&1 || true
  echo "=== DIAG: resolv.conf ==="
  cat /etc/resolv.conf 2>&1 || true
  echo "=== DIAG: /etc/hosts ==="
  cat /etc/hosts 2>&1 || true
  echo "=== DIAG: getent host.lan / host-lan ==="
  getent hosts host.lan 2>&1 || echo "host.lan UNRESOLVED"
  getent hosts host-lan 2>&1 || echo "host-lan UNRESOLVED"
  echo "=== DIAG: curl to candidates (verbose-ish) ==="
  for H in host.lan host-lan 172.30.0.1 10.0.2.2; do
    printf '  -> %s: ' "$H"
    curl -sS -m 8 -o /dev/null -w '%{http_code} %{errormsg}\n' "http://${H}:8090/env" 2>&1 || echo " (curl failed)"
  done
  echo "=== DIAG: end ==="
} >/dev/ttyS0 2>&1

for i in $(seq 1 20); do
  for H in host.lan host-lan 172.30.0.1; do
    if curl -fsS -m 15 -o "$DL" "http://${H}:8090/oem.sh" 2>/dev/null && [ -s "$DL" ]; then
      chmod 755 "$DL"; mv -f "$DL" "$BOOT"
      say "fetched oem.sh from ${H}"; exec "$BOOT"
    fi
  done
  say "retry $i failed"
  sleep 2
done
say "FAILED"
exit 1
