#!/usr/bin/env bash
# NixOS guest loader.
#
# The disk carries NO easystream and NO oem.sh: both are fetched from the sandbox
# container's nginx at boot, exactly like the Debian/KDE desktops do. That way
# upgrading the daemon is an image change, never a golden-disk rebake.
#
# WHAT DIFFERS FROM THE DEBIAN LOADER
#
# * The container is reached at 10.0.2.2 (qemu user networking's host address),
#   not host.lan: NixOS's minimal image has no avahi/mDNS and no search domain.
# * Everything is written under /var/lib/easystream, because /usr/local is read-only
#   on NixOS after activation.
# * The serial console is the only output the bake can see, so progress goes there.
set -uo pipefail

STATE=/var/lib/easystream
BOOT="$STATE/oem.sh"
LOG=/var/log/bootstrap.log
say() { echo "$(date) bootstrap: $*" | tee -a "$LOG" >/dev/ttyS0; }

mkdir -p "$STATE"

# qemu user networking always exposes the host as 10.0.2.2. Keep a couple of
# fallbacks so the same disk also works behind a different NAT.
CANDIDATES="${HOST_GW:-10.0.2.2} host.lan 172.30.0.1"

say "waiting for the sandbox container"
for i in $(seq 1 40); do
  for H in $CANDIDATES; do
    if curl -fsS -m 8 -o /dev/null "http://${H}:8090/env" 2>/dev/null; then
      say "container reachable at ${H}"
      export HOST="${H}:8090"
      break 2
    fi
  done
  sleep 3
done

if [ -z "${HOST:-}" ]; then
  say "FAILED: no sandbox container reachable"
  exit 1
fi

for i in $(seq 1 10); do
  if curl -fsS -m 20 -o "$BOOT.dl" "http://${HOST}/oem.sh" && [ -s "$BOOT.dl" ]; then
    chmod 755 "$BOOT.dl"
    mv -f "$BOOT.dl" "$BOOT"
    say "fetched oem.sh"
    # oem.sh is the SHARED loader served to every distro and starts with
    # #!/bin/bash, which does not exist on NixOS. Run it through this shell's own
    # interpreter instead of relying on its shebang: patching the shared file
    # would be wrong, and a bash -c wrapper keeps it as one process.
    exec "$(command -v bash)" "$BOOT"
  fi
  say "oem.sh fetch retry $i"
  sleep 3
done

say "FAILED: could not fetch oem.sh"
exit 1
