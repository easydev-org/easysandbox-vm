#!/usr/bin/env bash
# Boot EndeavourOS and photograph Calamares, without trying to install anything.
#
# WHY A PROBE AND NOT A SCRIPT
#
# EndeavourOS ships Calamares and nothing else: packages.x86_64 has one installer
# line, 'calamares', and no archinstall. Calamares has no unattended mode - its
# command line has five options, none of them automatic, and a source search for
# 'automatic', 'noninteractive', 'skip' returns nothing. So the only way in is the
# keyboard, and to drive a keyboard you have to know what is on the screen.
#
# WHY THE ISO IS BOOTED AS A CD
#
# The first attempt pulled the kernel and initrd out of the ISO and passed them
# with -kernel/-initrd, the way the CachyOS bake does. That failed immediately:
#
#   qemu: initrd is too large, cannot support.(max: 134053887, need 246610177)
#
# EndeavourOS's initramfs is 246 MB; qemu's -initrd path caps around 134 MB. This
# is an archiso-wide problem, not an EndeavourOS one - the initramfs outgrew what
# -kernel loading allows. Letting the ISO boot itself passes the initrd to the
# kernel through ISOLINUX, where there is no such limit. The cost is that the
# kernel command line belongs to the ISO, so this probe cannot add console=ttyS0.
# It does not need to: it photographs the framebuffer, and the framebuffer is the
# thing that matters.
#
# It installs nothing and sends no keys. Four screenshots are taken over four
# minutes.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENDEAVOUROS_VERSION="${ENDEAVOUROS_VERSION:-2026.08.15}"
ISO_URL="${ISO_URL:-https://mirrors.gigenet.com/endeavouros/iso/EndeavourOS_Titan-Nova-${ENDEAVOUROS_VERSION}.iso}"
OUTDIR="${OUTDIR:-$PWD}"
mkdir -p "$OUTDIR" && cd "$OUTDIR"

echo "=== ISO ==="
ISO="$(basename "$ISO_URL")"
[ -s "$ISO" ] || curl -fsSL --retry 3 --retry-delay 2 -o "$ISO" "$ISO_URL"
ls -la "$ISO"

echo "=== volume label (for the record) ==="
python3 - "$ISO" <<'PY' || true
import sys
with open(sys.argv[1], "rb") as f:
    f.seek(16 * 2048)
    pvd = f.read(2048)
if pvd[0] == 1 and pvd[1:6] == b"CD001":
    print("volume label:", pvd[40:72].decode("ascii", "replace").rstrip())
PY

echo "=== boot from CD, photograph four times ==="
MON="$OUTDIR/mon.sock"
rm -f "$MON"

# The install target has to exist before Calamares looks for one, even though this
# probe never installs: an empty disk is what makes the partition page usable if a
# later step wants to go that far.
qemu-img create -f qcow2 "$OUTDIR/disk.qcow2" 24G > /dev/null

# No -kernel, no -initrd: the ISO's own bootloader loads them, and there is no
# 134 MB ceiling on that path.
#
# The screen is forced to the same size the other bakes get. Without this the
# EndeavourOS live session stays at 640x480 while every other distribution comes up
# at 1280x800, and a probe that measures a different screen from the bake is
# measuring the wrong thing.
qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 6144 \
  -device "VGA,edid=on,xres=${SCREEN_W:-1280},yres=${SCREEN_H:-800}" \
  -drive "file=$ISO,media=cdrom,readonly=on" \
  -drive "file=$OUTDIR/disk.qcow2,if=virtio,format=qcow2" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -display none \
  -monitor "unix:$MON,server=on,wait=off" \
  -serial "file:$OUTDIR/console.log" \
  > "$OUTDIR/qemu.log" 2>&1 &
QEMU_PID=$!

python3 - "$MON" "$OUTDIR" <<'PY'
import socket, sys, time

mon, outdir = sys.argv[1], sys.argv[2]
deadline = time.time() + 60
s = None
while time.time() < deadline:
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(mon)
        break
    except OSError:
        s = None
        time.sleep(1)
if s is None:
    sys.exit("monitor socket never appeared")

# The live ISO boots to a desktop and starts Calamares by itself after a delay.
# Four samples over four minutes, so an installer that appears late is not missed.
for at in (60, 120, 180, 240):
    time.sleep(60)
    s.sendall(f"screendump {outdir}/shot-{at:03d}.ppm\n".encode())
    time.sleep(2)
    print(f"screendump at {at}s requested", flush=True)
s.sendall(b"quit\n")
s.close()
PY

wait "$QEMU_PID" 2>/dev/null || true

echo "=== screenshots ==="
for f in shot-*.ppm; do
  [ -f "$f" ] || continue
  ls -la "$f"
  python3 "$HERE/../nixos/ppm2png.py" "$f" "${f%.ppm}.png" desktop || true
done
ls -la shot-*.png 2>/dev/null || echo "no PNGs produced"
