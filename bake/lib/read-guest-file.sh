#!/usr/bin/env bash
# Read a file out of a qcow2 image WITHOUT booting it.
#
# This replaces `virt-cat`, which needs libguestfs-tools: an appliance VM, a
# kernel, and a few hundred megabytes of dependencies, for one job - proving that
# a marker the installer wrote really landed on the finished disk.
#
# The qemux/qemu base image already carries everything required:
#
#   qemu-img   (qemu-utils)  exports a slice of the image as raw
#   debugfs    (e2fsprogs)   reads ext2/3/4 without mounting anything
#
# Both were confirmed present by .github/workflows/probe-qemu-image.yml, so no
# package has to be added at all.
#
# Usage: read-guest-file.sh <disk.qcow2> <path-inside-guest>
#
# Prints the file on stdout. Exits non-zero with a reason on stderr if it cannot
# be read - a caller must never read empty output as "the file was empty".
set -Eeuo pipefail

DISK="${1:?usage: read-guest-file.sh <disk.qcow2> <path-inside-guest>}"
WANT="${2:?usage: read-guest-file.sh <disk.qcow2> <path-inside-guest>}"

command -v qemu-img >/dev/null || { echo "read-guest-file: qemu-img missing" >&2; exit 2; }
command -v debugfs >/dev/null || { echo "read-guest-file: debugfs missing (e2fsprogs)" >&2; exit 2; }
[ -s "$DISK" ] || { echo "read-guest-file: $DISK is not a file" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The first 512 bytes of the disk are the MBR. The bake scripts all create a DOS
# label with one ext4 root and no LVM or LUKS, so partition 1 is the filesystem.
qemu-img dd -f qcow2 -O raw "$DISK" "$work/mbr" bs=512 count=1 >/dev/null 2>&1 \
  || { echo "read-guest-file: cannot read the MBR of $DISK" >&2; exit 1; }

PART=$(python3 - "$work/mbr" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
if len(data) < 512 or data[510:512] != b"\x55\xaa":
    print("no MBR signature", file=sys.stderr)
    sys.exit(1)
for i in range(4):
    e = data[446 + i * 16: 446 + (i + 1) * 16]
    if not any(e):
        continue
    start, count = struct.unpack_from("<II", e, 8)
    if count:
        print(start, count)
        break
else:
    print("no populated partition entry", file=sys.stderr)
    sys.exit(1)
PY
) || { echo "read-guest-file: cannot parse the partition table" >&2; exit 1; }

START=${PART% *}
COUNT=${PART#* }
echo "read-guest-file: partition 1 at sector $START, $COUNT sectors" >&2

# Export just that partition. skip is in the units given by bs, so with bs=512
# the skip is simply the start sector - no arithmetic and no rounding to get
# wrong.
qemu-img dd -f qcow2 -O raw "$DISK" "$work/part.img" \
  bs=512 skip="$START" count="$COUNT" >/dev/null 2>&1 \
  || { echo "read-guest-file: cannot export partition 1" >&2; exit 1; }

if debugfs -R "cat $WANT" "$work/part.img" 2>/dev/null; then
  exit 0
fi

# Say which of the two it was: no such file, or not an ext filesystem.
if debugfs -R "stat $WANT" "$work/part.img" >/dev/null 2>&1; then
  echo "read-guest-file: $WANT exists but could not be printed" >&2
else
  echo "read-guest-file: no $WANT in partition 1" >&2
fi
exit 1
