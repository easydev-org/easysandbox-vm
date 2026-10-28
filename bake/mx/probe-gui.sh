#!/usr/bin/env bash
# Does MX's graphical installer draw in this qemu, and can OCR read it?
#
# The precondition for the OCR driver. Two questions, both answered with evidence:
#
#   1. With -display none plus a real VGA device and a usb-tablet, does the guest
#      put a picture in the framebuffer? A screenshot is taken and its colour
#      statistics decide - two colours and 99% one of them is a console, not a GUI.
#
#   2. Can tesseract read anything off it? If the picture is there but no words come
#      out, the OCR driver has nothing to act on and the approach stops here.
#
# qemu is started by hand rather than through bake_qemu_install because the QMP
# socket and the usb-tablet are the point of this probe, and the lib's helper
# assumes -nographic with a serial console only.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${OUTDIR:-$PWD/out}"
mkdir -p "$WORK" && cd "$WORK"

MX_VERSION="${MX_VERSION:-25.3}"
MX_EDITION="${MX_EDITION:-Xfce}"
ISO_URL="${ISO_URL:-https://sourceforge.net/projects/mx-linux/files/Final/${MX_EDITION}/MX-${MX_VERSION}_${MX_EDITION}_x64.iso/download}"
SCREEN_W="${SCREEN_W:-1280}"
SCREEN_H="${SCREEN_H:-800}"

log() { echo "[probe $(date -u +%H:%M:%S)] $*" | tee -a probe.log; }

log "=== ISO ==="
ISO="$WORK/mx.iso"
if [ ! -s "$ISO" ]; then
  curl -fsSL --retry 3 --retry-delay 2 -o "$ISO" "$ISO_URL"
fi
ls -la "$ISO"
[ "$(stat -c%s "$ISO")" -gt 500000000 ] || { log "ISO looks like a redirect page"; exit 2; }

log "=== kernel and initrd from /antiX/ ==="
rm -rf x && mkdir -p x
7z x -y -o"x" "$ISO" "antiX/vmlinuz" "antiX/initrd.gz" 2>&1 | tail -3
K=$(find "$PWD/x" -name 'vmlinuz*' -type f | head -1)
I=$(find "$PWD/x" -name 'initrd*' -type f | head -1)
log "kernel: $K"
log "initrd: $I ($(stat -c%s "$I") bytes)"

log "=== install disk with a GPT label ==="
# minstall does not offer a disk that has no partition table: parted reports
# nothing for it, so the drive list stays empty. This is the fault that cost
# twenty-five minutes of a previous run.
qemu-img create -f qcow2 disk.qcow2 24G > /dev/null
if command -v sgdisk >/dev/null 2>&1; then
  sgdisk --zap-all disk.qcow2 2>/dev/null || log "  (sgdisk on the image file did not work - will do it in the guest)"
fi
ls -la disk.qcow2

log "=== serve nothing: this probe only looks ==="

log "=== qemu with a real display device and a usb-tablet ==="
MON="$PWD/monitor.sock"
QMP="$PWD/monitor.sock.qmp"
rm -f "$MON" "$QMP" serial.in && mkfifo serial.in

  # usb-tablet is an absolute pointing device, and the OCR driver depends on
  # absolute events: QMP's input-send-event takes abs axes on a 0..32767 scale, while
  # a relative mouse would make every click land somewhere else. It needs a USB bus
  # to attach to:
  #
  #   qemu-system-x86_64: -device usb-tablet: No 'usb-bus' bus found for device 'usb-tablet'
  #
  # so an xhci controller comes first, the same arrangement dockur-macos uses.

qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 6144 \
  -kernel "$K" -initrd "$I" \
  -append "console=ttyS0,115200n8 init=/lib/systemd/systemd" \
  -drive "file=$ISO,media=cdrom,readonly=on" \
  -drive "file=$PWD/disk.qcow2,if=virtio,format=qcow2" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -display none \
  -vga std \
  -device qemu-xhci,id=xhci \
  -device usb-tablet,bus=xhci.0 \
  -monitor "unix:$MON,server=on,wait=off" \
  -qmp "unix:$QMP,server=on,wait=off" \
  -serial stdio \
  < serial.in > console.log 2>&1 &
QPID=$!
log "qemu pid $QPID"

# Log in and start the graphical installer, then look.
{
  for _ in $(seq 1 12); do
    printf 'demo\n'; sleep 2; printf 'demo\n'; sleep 13
  done
  printf 'echo PROBE_LOGIN_OK $(id -u)\n'; sleep 3
  # The launcher is what MX's own banner tells a CLI user to run.
  printf 'command -v minstall-launcher; command -v minstall; ls /usr/bin/*install* 2>/dev/null\n'; sleep 4
  printf 'echo demo | sudo -S nohup minstall-launcher > /tmp/launcher.out 2>&1 &\n'; sleep 8
  printf 'sleep 20; echo LAUNCHER_STARTED; pgrep -a -f minstall | head -5\n'; sleep 25
} > serial.in &

# Screenshots through QMP, at the moments that matter.
sleep 200

python3 - "$QMP" "$PWD" <<'PYSHOT'
import json, socket, sys, time

qmp_path, outdir = sys.argv[1], sys.argv[2]

class QMP:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(30)
        self.sock.connect(path)
        self.buf = b""
        self._read()
        self.execute("qmp_capabilities")

    def _read(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("QMP closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def execute(self, command, **arguments):
        payload = {"execute": command}
        if arguments:
            payload["arguments"] = arguments
        self.sock.sendall((json.dumps(payload) + "\n").encode())
        while True:
            msg = self._read()
            if "return" in msg or "error" in msg:
                return msg

q = QMP(qmp_path)
print("qmp connected", flush=True)
for name in ("shot-a", "shot-b", "shot-c", "shot-d"):
    path = "%s/%s.ppm" % (outdir, name)
    reply = q.execute("screendump", filename=path)
    print("screendump %s -> %s" % (name, reply.get("return", reply)), flush=True)
    time.sleep(30)

PYSHOT

log "=== stopping qemu ==="
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true

log "=== what came out ==="
for f in shot-*.ppm; do
  [ -f "$f" ] || continue
  log "$(ls -la "$f" | awk '{print $5, $9}')"
  python3 "$HERE/../nixos/ppm2png.py" "$f" "${f%.ppm}.png" desktop || log "  ppm2png failed"
done
ls -la shot-*.png 2>/dev/null || log "no PNGs"

if command -v tesseract >/dev/null 2>&1; then
  for f in shot-*.ppm; do
    [ -f "$f" ] || continue
    log "--- OCR $f ---"
    tesseract "$f" stdout --psm 3 2>/dev/null | tr -s ' \n' ' \n' | head -12 || true
  done
else
  log "tesseract is not installed - OCR cannot be part of this approach here"
fi

log "PROBE DONE"
