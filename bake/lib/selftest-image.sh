#!/usr/bin/env bash
# Prove this image can do what the bake harness needs, from inside the image.
#
# Runs in CI as `docker run <image> bash bake/lib/selftest-image.sh`. Everything
# checked here is something a bake invokes directly; a base image that loses one
# of them should fail loudly at build time rather than twenty minutes into a bake.
#
# The two checks that need a real VM are the interesting ones:
#
#   * -nographic puts the guest's serial port on stdio. The image is built for a
#     noVNC display, so this is not obvious.
#   * the QEMU monitor answers `screendump`, which is the only way the harness
#     photographs the desktop - every "PICTURE OK" line depends on it.
set -Eeuo pipefail

fail=0

echo "=== tools ==="
qemu-system-x86_64 --version | head -1
qemu-img --version | head -1
7z 2>/dev/null | sed -n 2p
debugfs -V 2>&1 | head -1 || true
python3 --version
echo

echo "=== every tool the bake scripts call ==="
for t in qemu-system-x86_64 qemu-img 7z virt-cat python3 curl wget \
         jq mkfifo timeout setsid xxd; do
  printf '  %-18s ' "$t"
  if command -v "$t" >/dev/null 2>&1; then echo present; else echo MISSING; fail=1; fi
done
echo

echo "=== kvm ==="
if [ -w /dev/kvm ]; then ls -l /dev/kvm; else echo "  /dev/kvm not writable"; fail=1; fi
echo

echo "=== a guest boots, and the monitor can photograph it ==="
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
qemu-img create -f qcow2 "$work/d.qcow2" 64M >/dev/null

# -monitor stdio CANNOT be combined with -nographic: -nographic already gives
# stdio to the guest's serial port, so the monitor would receive nothing and
# screendump would never run. A socket keeps them separate - which is also how
# bake/lib/qemu-bake.sh drives the monitor.
qemu-system-x86_64 -enable-kvm -m 512 -display none \
  -drive file="$work/d.qcow2",if=virtio,format=qcow2 \
  -monitor "unix:$work/mon.sock,server=on,wait=off" \
  -nographic > "$work/boot.log" 2>&1 &
QEMU_PID=$!

python3 - "$work" <<'PY'
import socket, sys, time
work = sys.argv[1]
deadline = time.time() + 30
s = None
while time.time() < deadline:
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(f"{work}/mon.sock")
        break
    except OSError:
        s = None
        time.sleep(0.5)
if s is None:
    sys.exit("monitor socket never appeared")
time.sleep(2)
s.sendall(f"screendump {work}/s.ppm\n".encode())
time.sleep(3)
s.sendall(b"quit\n")
s.close()
PY

wait "$QEMU_PID" 2>/dev/null || true

if [ -s "$work/s.ppm" ]; then
  echo "  ok    screendump produced $(stat -c%s "$work/s.ppm") bytes"
  printf '  magic: '; head -c 2 "$work/s.ppm"; echo "   (P6 = binary PPM framebuffer)"
else
  echo "  FAIL  no screendump"
  tail -20 "$work/boot.log" || true
  fail=1
fi

echo "=== the serial port reached stdio ==="
# The guest has no boot sector, so the firmware's own messages are the evidence
# that -nographic is wiring the serial port to stdout.
if grep -qiE "seabios|ipxe|booting|no bootable" "$work/boot.log"; then
  echo "  ok    firmware output arrived on stdio ($(grep -c . "$work/boot.log") lines)"
else
  echo "  FAIL  nothing from the guest reached stdio"
  head -20 "$work/boot.log" || true
  fail=1
fi

echo
if [ "$fail" = 0 ]; then
  echo "SELFTEST OK: this image can run a bake"
else
  echo "SELFTEST FAILED"
fi
exit "$fail"
