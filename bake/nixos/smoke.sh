#!/usr/bin/env bash
# Boot the disk that was just baked and prove it is a usable sandbox.
#
# "installation finished" only means nixos-install wrote a filesystem. It says
# nothing about whether the disk boots: GRUB is installed by a separate step,
# and an unusable bootloader, a wrong kernel path or a broken initrd all report
# success at install time. The BOOT_MODE=legacy bug is the same shape - the
# guest ran for fifteen minutes and was then killed by the boot watchdog, with
# nothing wrong in the install log.
#
# So boot it the way the container will: from the disk, through GRUB, no
# -kernel override. Then require real evidence that userspace and the desktop
# session came up.
set -Eeuo pipefail

DESKTOP="${DESKTOP:?set DESKTOP}"
DISK="${DISK:?set DISK to the qcow2 to test}"
WAIT="${WAIT:-420}"

echo "=== smoke test: $DESKTOP ($DISK) ==="
ls -la "$DISK"

rm -f smoke.in smoke.log
mkfifo smoke.in
# The guest is shut down from the monitor rather than from inside: it may not
# have a usable console login, and a hung script must not hold the runner.
(
  sleep "$WAIT"
  printf "system_powerdown\n"
  sleep 30
  printf "quit\n"
) > smoke.in &

# -boot c and no -kernel: this is the production path. serial is on because
# the kernel cmdline baked into the disk says console=ttyS0.
timeout $((WAIT + 120)) qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 6144 \
  -drive file="$DISK",if=virtio,format=qcow2 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -display none -monitor stdio -serial file:smoke.log \
  < smoke.in > /dev/null 2>&1 || echo "qemu exited rc=$?"

echo "=== what the disk printed ==="
wc -l smoke.log || true

# Checks, in the order they would fail if the disk were broken. Each one is a
# distinct failure mode, so a red build says WHICH part is wrong instead of
# just "did not boot".
fail=0
chk() {
  local what="$1" pat="$2"
  if grep -aqE "$pat" smoke.log; then echo "  OK    $what"
  else echo "  FAIL  $what   (no match for: $pat)"; fail=1; fi
}

echo "=== checks ==="
# 1. GRUB ran. Without this nothing below can be trusted.
chk "GRUB started"                    "Welcome to GRUB|Booting .NixOS."
# 2. The kernel and initrd on the disk are loadable.
chk "kernel started"                  "Linux version|Booting the kernel"
# 3. systemd reached userspace at all.
chk "systemd reached multi-user"      "Reached target Multi-User System|Reached target multi-user"
# 4. The graphical target is what a desktop sandbox needs.
chk "graphical target reached"        "Reached target Graphical Interface|graphical.target"
# 5. A display manager actually spawned a session, per desktop.
case "$DESKTOP" in
  gnome)  chk "gdm started"           "Started .*gdm|gdm.service" ;;
  kde)    chk "sddm started"          "Started .*sddm|sddm.service" ;;
  cosmic) chk "cosmic-greeter started" "cosmic-greeter|Started .*greetd" ;;
  labwc)  chk "labwc or getty present" "Started .*getty|labwc" ;;
esac
# 6. logind is what makes a Wayland session possible in the first place.
chk "systemd-logind running"          "systemd-logind"

if [ "$fail" -ne 0 ]; then
  echo
  echo "=== SMOKE FAILED: last 80 lines of the console ==="
  tail -80 smoke.log || true
  exit 1
fi

echo "SMOKE OK: $DESKTOP boots to a graphical session"
