#!/usr/bin/env bash
# Exercise the stall watchdog without KVM, without an ISO and without a guest.
#
# What is under test is the part that has no business needing a virtual machine:
# does the runner notice that the console stopped growing, kill the process, set
# BAKE_STALLED, and report the last line. Fedora's first run spent 30 minutes in
# exactly this state, so it is worth a test that takes seconds.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./qemu-bake.sh
. "$HERE/qemu-bake.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

fail=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok    $1"
  else echo "  FAIL  $1  (got '$2', want '$3')"; fail=1; fi
}

# Stand in for qemu: write a few lines, then hang forever, exactly like a guest
# whose installer rejected its kickstart and exited.
cat > fake-qemu <<'EOF'
#!/usr/bin/env bash
echo "kicking off"
echo "line 18: install has been removed."
echo "line 48: Unknown command: @workstation-product-environment"
echo "     Pane is dead (status 1)"
sleep 100000
EOF
chmod +x fake-qemu

echo "=== test: a guest that stops is noticed ==="
# 40s stall, 10s poll -> the watchdog needs 4 quiet polls.
start=$SECONDS
BAKE_STALL_SECONDS=40 QEMU_MAX=300 \
  bash -c '
    set -Eeuo pipefail
    . "'"$HERE"'/qemu-bake.sh"
    # Replace qemu-system-x86_64 by putting the fake first in PATH.
    mkdir -p bin && cp fake-qemu bin/qemu-system-x86_64
    PATH="$PWD/bin:$PATH"
    bake_qemu_install -- -append nothing
    [ -f .bake-stalled ] && echo "STALL_MARKER=present" || echo "STALL_MARKER=absent"
    bake_assert_installed "FEDORA_BAKE_OK" "fedora kickstart" || echo "assert_failed=1"
  ' > out.txt 2>&1 || true
elapsed=$((SECONDS - start))
cat out.txt | sed 's/^/    /'

check "finished quickly, not after QEMU_MAX" \
  "$( [ "$elapsed" -lt 120 ] && echo yes || echo no )" "yes"
check "watchdog reported the stall" \
  "$(grep -c 'GUEST STOPPED' out.txt || true)" "1"
check "the last lines the guest produced are shown" \
  "$( [ "$(grep -c 'Pane is dead' out.txt || true)" -ge 1 ] && echo yes || echo no )" "yes"
check "the stall marker was left for the caller" \
  "$(grep -c 'STALL_MARKER=present' out.txt || true)" "1"
check "the assertion says it stopped, not that it failed" \
  "$(grep -c 'it stopped' out.txt || true)" "1"
check "no install pattern matched a dead guest" \
  "$(grep -c 'assert_failed=1' out.txt || true)" "1"

echo
if [ "$fail" = 0 ]; then echo "PASS"; else echo "FAIL"; exit 1; fi
