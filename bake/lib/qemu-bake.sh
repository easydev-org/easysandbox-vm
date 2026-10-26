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

# How long the console may go without a single new byte before the guest is
# declared dead. Ten minutes is deliberately generous: an Ubuntu install goes
# quiet while apt unpacks, and a NixOS install goes quiet while it downloads.
# The case this exists for is not slow - it is stopped: anaconda rejected a
# kickstart, exited at 10:01, and qemu sat there for the remaining 30 minutes of
# QEMU_MAX with nothing to do, looking identical to a working install.
BAKE_STALL_SECONDS="${BAKE_STALL_SECONDS:-600}"

# bake_qemu_install [-kernel K] [-initrd I] -- <qemu arguments...>
#
# Runs qemu with the console tee'd to console.log, a heartbeat on stderr, and a
# watchdog that ends the run when the guest has plainly died.
#
# The heartbeat is not decoration: a 14-minute silent apt in another step is how
# a working run got mistaken for a hung one. And the watchdog is the other half
# of the same problem - a dead guest and a slow guest both look quiet, so silence
# is only acted on after BAKE_STALL_SECONDS, and the first thing it prints is the
# last line the guest managed.
#
# Exit status: qemu's own is NOT the install's (see below), so this returns 0
# whether the guest finished or was declared dead. The caller judges console.log.
#
# Whether the guest stalled is recorded in the file `.bake-stalled` in the work
# directory rather than in a variable. The watchdog runs in a subshell, and an
# export there does not survive back into this function, let alone into a caller
# that sourced this file - the first version exported it and the flag was always
# empty. A file works across every process boundary involved.
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

  : > console.log
  # Clear a marker left by a previous run in the same directory, or a stale one
  # makes this run look stalled when it is not.
  rm -f .bake-stalled

  # A fifo between qemu and tee, rather than `qemu | tee`. The pipe form gives
  # $! as tee's pid, which cannot be killed to stop qemu; the fifo keeps the
  # two separate so the watchdog has something real to signal.
  rm -f .console.pipe && mkfifo .console.pipe
  tee console.log < .console.pipe &
  local tee_pid=$!

  timeout "$QEMU_MAX" "${cmd[@]}" < "${BAKE_STDIN:-/dev/null}" \
    > .console.pipe 2>&1 &
  local qemu_pid=$!

  local hb_start=$SECONDS hb_pid wd_pid
  (
    while kill -0 "$qemu_pid" 2>/dev/null; do
      sleep 60
      local lines
      lines=$(wc -l < console.log 2>/dev/null || echo 0)
      echo "[heartbeat] $(( (SECONDS-hb_start)/60 ))m elapsed, ${lines} console lines, last: $(tail -1 console.log 2>/dev/null | tr -d '\r' | cut -c1-90)" >&2
    done
  ) &
  hb_pid=$!

  # The watchdog. Polls the log size; a run of polls with no growth longer than
  # BAKE_STALL_SECONDS kills qemu and says why.
  (
    last=-1; stalled=0; interval=20
    polls=$(( BAKE_STALL_SECONDS / interval ))
    while kill -0 "$qemu_pid" 2>/dev/null; do
      sleep "$interval"
      now=$(stat -c%s console.log 2>/dev/null || echo 0)
      if [ "$now" = "$last" ]; then
        stalled=$((stalled + 1))
        if [ "$stalled" -ge "$polls" ]; then
          echo "=== GUEST STOPPED: console.log unchanged for $((stalled * interval))s ===" >&2
          echo "=== last line the guest produced: ===" >&2
          tail -20 console.log 2>/dev/null | tr -d '\r' | sed 's/^/    /' >&2
          echo "=== killing qemu; a guest that has stopped will not recover ===" >&2
          # The marker goes down BEFORE the kill. Killing qemu makes the main
          # flow's `wait` return, and the main flow then kills this watchdog - so
          # a marker written afterwards is a marker that never gets written. The
          # first version did exactly that and the flag was always absent.
          : > .bake-stalled
          kill -TERM "$qemu_pid" 2>/dev/null || true
          sleep 5
          kill -KILL "$qemu_pid" 2>/dev/null || true
          break
        fi
      else
        stalled=0
        last=$now
      fi
    done
  ) &
  wd_pid=$!

  # tee, not ">": a long install that writes only to a file is indistinguishable
  # from a hung job in the Actions log.
  local rc=0
  wait "$qemu_pid" || rc=$?
  kill "$hb_pid" "$wd_pid" 2>/dev/null || true
  wait "$tee_pid" 2>/dev/null || true
  rm -f .console.pipe

  # Deliberately left in place: bake_assert_installed reads it, and the caller
  # may read it too. A stale one from a previous run is cleared on entry.
  if [ -f .bake-stalled ]; then
    echo "the guest stopped producing output; see the last lines above" >&2
  fi

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

  if [ -f .bake-stalled ]; then
    # The watchdog already printed the last lines, and they are the useful part:
    # the guest stopped rather than installed-slowly, so scanning for the first
    # error in a 1000-line log is the wrong shape of answer.
    echo "=== ${what} DID NOT COMPLETE: the guest stopped producing output ===" >&2
    echo "=== it did not finish and it did not fail; it stopped ===" >&2
    tail -40 console.log 2>/dev/null | tr -d '\r' >&2
    return 1
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
