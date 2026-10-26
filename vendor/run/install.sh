#!/usr/bin/env bash
set -Eeuo pipefail

startLinux() {

  # This image boots a PRE-BAKED Linux disk (see bake/). Upstream would
  # download an ISO and install; we never do. Require the disk and boot it.
  # The disk already carries the desktop, cloud-init is spent, and
  # desktop.service fetches the guest binaries from nginx on every boot.
  if ! hasData; then
    error "No guest disk found at ${DISK_FILE:-/storage/data.qcow2} — refusing to start (this image boots a pre-baked disk and never installs)."
    exit 69
  fi

  cleanupTemp || return $?

  # BOOT must be DEFINED but EMPTY. In the upstream install flow BOOT is the
  # installation MEDIA (an ISO) attached as a separate device; here the disk is
  # the data disk (DISK1_FILE -> /storage/data.qcow2), and pointing BOOT at the
  # same file made QEMU attach it TWICE and fight its own write lock. disk.sh
  # tests `[ -s "$BOOT" ]`, so empty skips the boot device — but `set -u` means
  # it must not be unset.
  BOOT=""
  export BOOT

  # `set -u` safety: upstream sets DETECTED in normalizeDetected(), which only
  # the INSTALL path runs and we do not — yet power.sh reads it. Do not call
  # those functions here: they mutate globals and call error/exit, so running
  # them in a subshell fails the whole script. The guest is a plain Debian
  # cloud image, so the value is simply "debian".
  DETECTED="debian"
  export DETECTED

  html "Starting $APP..."

  reserveSambaPorts || return $?
  return 0
}

configureMachine() {

  local iso="$1"
  local dir="$2"
  local boot="$3"

  local desc
  desc=$(printVariant "$DETECTED" "$DETECTED") || return 78

  if ! checkMemory "$DETECTED"; then

    if ! isCustomImage; then
      useOriginalImage "$iso" || {
        error "Failed to preserve the original installation image!"
        return 79
      }
    fi

    return 79
  fi

  setDiskMinimum "$DETECTED" || return 79

  if ! setMachine "$DETECTED" "$iso" "$dir" "$desc"; then
    error "Failed to configure the virtual machine for $desc!"
    return 80
  fi

  if ! restoreMachineState; then
    error "Failed to restore the saved machine state!"
    return 82
  fi

  if ! supportsUnattended "$DETECTED"; then

    skipUnattended "$dir" "$iso" "$boot" "N" || {
      error "Failed to fall back to manual installation!"
      return 83
    }
  
    handled=1
    return 0

  fi

  return 0
}

finishInstall() {

  local iso="$1"
  local aborted="$2"
  local boot="$3"

  local base file bios target

  if ! hasImage "$iso"; then
    error "Failed to find ISO file: $iso" && return 1
  fi

  if [[ "$iso" == "$STORAGE/"* ]]; then
    if ! setOwner "$iso"; then
      warn "failed to set the owner for \"$iso\" !"
    fi
  fi

  file="$(stateFile "ver")"
  cp -f /etc/version "$file" || {
    error "Failed to save the Windows installation version!"
    return 1
  }

  if ! setOwner "$file"; then
    warn "Failed to set the owner for \"$file\" !"
  fi

  if [[ "$boot" == "$STORAGE/"* ]]; then
    if [[ "$aborted" != [Yy1]* ]] || ! isCustomImage; then

      base=$(basename "$boot")
      writeState "base" "$base" || {
        error "Failed to save the Windows installation source!"
        return 1
      }

    fi
  fi

  if isPlatform "x64"; then
    if isLegacyBoot; then

      writeState "mode" "$BOOT_MODE" || {
        error "Failed to save the Windows boot mode!"
        return 1
      }

    else

      # Aborted Win11 installs boot without any answer file present,
      # so enable Secure Boot and TPM to satisfy its hardware checks.
      if enabled "$aborted" || enabled "$MANUAL"; then

        if [[ "${DETECTED,,}" == "win11"* ]]; then

          BOOT_MODE="windows_secure"
          writeState "mode" "$BOOT_MODE" || {
            error "Failed to save the Windows boot mode!"
            return 1
          }

        fi
      fi

    fi
  fi

  reserveSambaPorts || {
    error "Failed to reserve Samba ports!"
    return 1
  }

  if [ -n "$SYSTEM" ]; then

    if [[ "$SYSTEM" == "$TMP/"* ]]; then

      if ! mv -f -- "$SYSTEM" "$(stateFile "img")"; then
        error "Failed to finalize the Windows system image!"
        return 1
      fi

      BOOT="$(stateFile "img")"

    else

      if ! hasImage "$SYSTEM"; then
        error "Failed to find the Windows system image!"
        return 1
      fi

      writeState "system" "$SYSTEM" || {
        error "Failed to save the Windows system image!"
        return 1
      }

      BOOT="$SYSTEM"
    fi

    if ! setOwner "$BOOT"; then
      warn "failed to set the owner for \"$BOOT\" !"
    fi

  fi

  if [ -n "${BIOS:-}" ]; then

    bios="$(stateFile "bios")"
    target="${bios}.tmp"

    if ! cp -f -- "$BIOS" "$target"; then
      rm -f -- "$target"
      error "Failed to copy the BIOS file!"
      return 1
    fi

    if ! mv -f -- "$target" "$bios"; then
      rm -f -- "$target"
      error "Failed to finalize the BIOS file!"
      return 1
    fi

    BIOS="$bios"

    if ! setOwner "$BIOS"; then
      warn "failed to set the owner for \"$BIOS\" !"
    fi

  fi

  if ! rm -rf -- "$TMP"; then
    error "Failed to remove directory \"$TMP\" !"
    return 1
  fi

  return 0
}

skipUnattended() {

  local dir="$1"
  local iso="$2"
  local boot="$3"
  local aborted="${4:-Y}"

  local efi efi32 efi64

  # Standalone ESD files and nested archives are not directly bootable media,
  # so they cannot use the manual-install fallback.
  if needsExtraction "$iso"; then
    error "Failed to boot \"$iso\" because it is not a directly bootable ISO image!"
    return 1
  fi

  # When automatic preparation fails, inspect extracted media to determine
  # whether it can still be booted manually using legacy firmware.
  if enabled "$aborted" && isPlatform "x64" && [ -d "$dir" ]; then

    efi=$(find "$dir" -maxdepth 1 -type d -iname efi -print -quit) || return 1
    efi32=$(find "$dir" -maxdepth 3 -type f -ipath '*/efi/boot/bootia32.efi' -print -quit) || return 1
    efi64=$(find "$dir" -maxdepth 3 -type f -ipath '*/efi/boot/bootx64.efi' -print -quit) || return 1

    if [ -z "$efi" ] || { [ -n "$efi32" ] && [ -z "$efi64" ]; }; then

      writeState "mode" "windows_legacy" || return 1
      restoreBootMode || return 1

    fi

  fi

  # Preserve custom media in place. Downloaded or reused media must be moved
  # back to persistent storage before the manual fallback is started.
  useOriginalImage "$iso" || return 1

  finishInstall "$BOOT" "$aborted" "$boot" && return 0
  return 1
}

cleanupTemp() {

  TMP="$STORAGE/tmp"

  if ! rm -rf -- "$TMP"; then
    error "Failed to remove directory \"$TMP\" !"
    return 50
  fi

  local setup="$STORAGE/setup.img"

  if ! rm -f -- "$setup" "${setup}.tmp"; then
    error "Failed to remove setup image \"$setup\" !"
    return 50
  fi

  return 0
}

isCustomImage() {

  [ -n "${CUSTOM:-}" ]
}

isPlatform() {

  local platform="$1"

  [[ "${PLATFORM,,}" == "${platform,,}" ]]
}

isLegacyBoot() {

  [[ "${BOOT_MODE,,}" == "windows_legacy" ]]
}

hasMarker() {

  [ -f "$(stateFile "$1")" ]
}

hasBootMarker() {

  [ -f "$(stateFile "boot")" ]
}

createMarker() {

  local marker
  marker="$(stateFile "$1")"

  if ! touch "$marker"; then
    warn "failed to create marker \"$marker\" !"
    return 1
  fi

  if ! setOwner "$marker"; then
    rm -f "$marker"
    warn "failed to set the owner for \"$marker\" !"
    return 1
  fi

  return 0
}

hasImage() {

  local iso="$1"

  [ -f "$iso" ] && [ -s "$iso" ]
}

getSystemImage() {

  local image

  image=$(readState "system") || return 1

  if [ -n "$image" ]; then
    # Older development builds stored only the basename in windows.system.
    [[ "$image" == /* ]] || image="$STORAGE/$image"
    hasImage "$image" || return 1

    echo "$image"
    return 0
  fi

  image="$(stateFile "img")"
  hasImage "$image" || return 1

  echo "$image"
  return 0
}

hasSystemImage() {

  getSystemImage >/dev/null
}

hasCompletedInstall() {

  hasSystemImage && return 0
  hasData && hasBootMarker
}

needsExtraction() {

  local iso="$1"

  enabled "${UNPACK:-}" || [[ "${iso,,}" == *.esd ]]
}

useOriginalImage() {

  local iso="$1"

  if isCustomImage; then
    BOOT="$iso"
  elif [[ "$iso" != "$BOOT" ]]; then
    if ! mv -f -- "$iso" "$BOOT"; then
      error "Failed to move ISO file: $iso"
      return 1
    fi
  fi

  # Keep SYSTEM pointing at the same image when preserving it changes its path.
  if [[ "${SYSTEM:-}" == "$iso" ]]; then
    SYSTEM="$BOOT"
  fi

  return 0
}

removeImage() {

  local iso="$1"

  isCustomImage && return 0

  if ! rm -f -- "$iso" 2>/dev/null; then
    warn "failed to remove image \"$iso\"!"
    return 1
  fi

  return 0
}

checkMemory() {

  local id="$1"
  local required name

  required=$(getRequiredMemory "$id") || return
  RAM_MINIMUM="$required"

  name=$(printVersion "$id" "") || return
  checkMemoryRequirement "$name" || return

  return 0
}

setDiskMinimum() {

  local id="$1"
  local required

  required=$(getRequiredDisk "$id") || return
  DISK_MINIMUM="$required"

  return 0
}

reserveSambaPorts() {

  disabled "${SAMBA:-Y}" && return 0
  disabled "${NETWORK:-Y}" && return 0
  enabled "${DHCP:-N}" && return 0

  # NAT can fall back to user-mode networking after this point,
  # so always protect the Samba listeners for non-DHCP networking.
  HOST_PORTS="${HOST_PORTS:+$HOST_PORTS,}139/tcp,445/tcp"

  return 0
}

startLinux

return 0
