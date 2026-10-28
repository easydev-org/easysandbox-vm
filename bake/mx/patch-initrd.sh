#!/bin/bash
# Unpack MX's initrd, change the hardcoded CONSOLE, repack.
#
# WHY THIS IS NECESSARY
#
# mx-iso-template initrd/init, line 423:
#
#   exec $LIVE_BIN/switch_root $NEW_ROOT /usr/bin/env CONSOLE=/dev/tty1 $INIT_COMMAND "$@"
#
# CONSOLE is fixed to /dev/tty1 at the handover to the real system. The parameter
# parser does accept console= and CONSOLE= (lines 881 and 883), but the value goes
# into MY_TTY, which is only used by chvt for the tsplash screen - it never moves the
# console output. So after switch_root the serial port stays silent and the bake sits
# at '[H[J' until its watchdog kills it.
#
# The patch honours a CONSOLE= given on the kernel command line and otherwise keeps
# MX's /dev/tty1. One line, and it reverses nothing MX does by default.
set -Eeuo pipefail

INITRD="$1"
[ -s "$INITRD" ] || { echo "no initrd at $INITRD" >&2; exit 2; }

echo "size: $(stat -c%s "$INITRD")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "=== unpacking ==="
# antiX/MX's initrd is a gzip-compressed cpio. Nothing here pipes an error to
# /dev/null: this script exists because a discarded message cost rounds elsewhere.
if ! gzip -dc "$INITRD" > initrd.cpio 2> gunzip.err; then
  echo "gzip failed:" >&2
  cat gunzip.err >&2
  exit 1
fi
echo "uncompressed: $(stat -c%s initrd.cpio) bytes"

mkdir root
if ! ( cd root && cpio -idmu --quiet < ../initrd.cpio ); then
  echo "cpio unpack failed" >&2
  exit 1
fi
echo "unpacked files: $(find root -type f | wc -l)"
[ -f root/init ] || { echo "no root/init after unpack" >&2; exit 1; }

echo "=== patching init ==="
# Print the line before touching it, so the log proves what was changed.
if ! grep -n 'CONSOLE=/dev/tty1' root/init; then
  echo "the hardcoded CONSOLE line is not there - this initrd differs from the source tree" >&2
  exit 1
fi

# Resolved relative to this script, not to an absolute path: the bake runs from a
# checkout whose directory differs from this machine's.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$HERE/patch-init.py" "$PWD/root/init"

echo "=== repacking ==="
if ! ( cd root && find . -print0 | cpio --null -o -H newc --quiet ) > new.cpio; then
  echo "cpio pack failed" >&2
  exit 1
fi
if ! gzip -9 -c new.cpio > "$INITRD.patched"; then
  echo "gzip pack failed" >&2
  exit 1
fi
echo "new size: $(stat -c%s "$INITRD.patched")"
mv "$INITRD.patched" "$INITRD"
echo "PATCHED $INITRD"
