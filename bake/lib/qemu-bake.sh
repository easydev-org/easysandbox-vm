#!/usr/bin/env bash
# The parts of a disk bake that do not depend on which distribution is being
# installed: booting a VM on KVM, keeping the console visible while it runs,
# judging the result, and producing a compressed qcow2.
#
# WHAT IS DELIBERATELY NOT HERE
#
# How the install happens. NixOS gets a shell over the serial console and types
# `nixos-install`; Ubuntu boots with `autoinstall ds=nocloud-net;...` and the
# installer fetches its own configuration. Trying to put both behind one
# interface would mean an option for every difference - the shell snippet, the
# kernel command line, who decides the disk layout, how completion is reported -
# and the "shared" function would be a list of branches. The per-distribution
# script keeps that logic; this file keeps the around-it.
#
# Callers source this file and then use:
#
#   bake_require <VAR>...            fail early if a setting is missing
#   bake_qemu_install <args...>      run qemu, tee the console, heartbeat
#   bake_assert_installed <pattern>  judge the console log
#   bake_compress_disk <in> <out>    compressed qcow2
#
# Contract: BAKE_WORKDIR is the working directory, console.log lives there.

set -Eeuo pipefail

# How long to let qemu run. The guest is asked to power itself off, but the host
# must never depend on that: twice on the NixOS side it did not, and the run sat
# until an outer timeout. This is the backstop, not the mechanism.
QEMU_MAX="${QEMU_MAX:-3600}"

bake_require() {
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || { echo "bake: $v is not set" >&2; exit 2; }
  done
}

# bake_qemu_install [-kernel K] [-initrd I] -- <qemu arguments...>
#
# Runs qemu with the console tee'd to console.log and a heartbeat on stderr, so
# a long quiet stretch is visible in CI instead of looking like a deadlock. That
# heartbeat is not decoration: a 14-minute silent apt in another step is exactly
# how a working run got mistaken for a hung one.
bake_qemu_install() {
  local kernel="" initrd=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -kernel)  kernel="$2"; shift 2 ;;
      -initrd)  initrd="$2"; shift 2 ;;
      --)       shift; break ;;
      *)        break ;;
    esac
  done

  local -a cmd=(qemu-system-x86_64 -enable-kvm -cpu host)
  [ -n "${QEMU_SMP:-}" ] && cmd+=(-smp "$QEMU_SMP")
  [ -n "${QEMU_MEM:-}" ] && cmd+=(-m "$QEMU_MEM")
  [ -n "${kernel}" ] && cmd+=(-kernel "$kernel")
  [ -n "${initrd}" ] && cmd+=(-initrd "$initrd")
  cmd+=("$@")
  cmd+=(-nographic -no-reboot)

  local hb_start hb_pid
  hb_start=$(date +%s)
  (
    while true; do
      sleep 60
      local now lines
      now=$(date +%s)
      lines=$(wc -l < console.log 2>/dev/null || echo 0)
      echo "[heartbeat] $(( (now-hb_start)/60 ))m elapsed, ${lines} console lines, last: $(tail -1 console.log 2>/dev/null | tr -d '\r' | cut -c1-90)" >&2
    done
  ) &
  hb_pid=$!

  # tee, not ">": a long install that writes only to a file is indistinguishable
  # from a hung job in the Actions log.
  local rc=0
  timeout "$QEMU_MAX" "${cmd[@]}" < "${BAKE_STDIN:-/dev/null}" \
    2>&1 | tee console.log || rc=$?
  kill "$hb_pid" 2>/dev/null || true

  # qemu's own exit status is not the install's: -no-reboot turns the guest's
  # reboot into an exit, and a failed install reboots too. Judge the log.
  echo "qemu exited rc=$rc (this is not the install status)"
  return 0
}

# bake_assert_installed <extended-regexp> <what>
#
# Fails with the first error in context rather than the last 60 lines: a schema
# violation or an assertion sits near the top, and the tail is only the shell
# prompt coming back.
bake_assert_installed() {
  local pattern="$1" what="${2:-the install}"
  if grep -aqE "$pattern" console.log; then
    echo "installed: ${what} (console matched /$pattern/)"
    return 0
  fi
  echo "=== ${what} DID NOT COMPLETE ===" >&2
  local first
  first=$(grep -anE "ERROR|Traceback|error:|failed|FAILED" console.log | head -1 | cut -d: -f1 || true)
  if [ -n "$first" ]; then
    sed -n "$((first>8?first-8:1)),$((first+40))p" console.log >&2
  else
    tail -80 console.log >&2
  fi
  return 1
}

# bake_compress_disk <qcow2-in> <qcow2-out>
#
# qcow2 is sparse by default but not compressed, and a freshly installed system
# is highly compressible. Compression also matters downstream: these disks get
# copied as the starting point of every derive run and pulled as registry
# layers, so the decompression cost is paid back immediately.
bake_compress_disk() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  qemu-img convert -O qcow2 -c -o compression_type=zstd "$src" "$dst"
  ls -la "$dst"
  echo "compressed $(basename "$src") -> $(basename "$dst") ($(du -h "$dst" | cut -f1))"
}
