#!/usr/bin/env bash
set -Eeuo pipefail

: "${KEY:=""}"
: "${HOST:=""}"
: "${WIDTH:=""}"
: "${HEIGHT:=""}"
: "${VERIFY:=""}"
: "${DOMAIN:=""}"
: "${REGION:=""}"
: "${EDITION:=""}"
: "${MANUAL:=""}"
: "${REMOVE:=""}"
: "${VERSION:=""}"
: "${COMMAND:=""}"
: "${KEYBOARD:=""}"
: "${LANGUAGE:=""}"
: "${USERNAME:=""}"
: "${PASSWORD:=""}"
: "${SHORTCUT:=""}"
: "${DOMAIN_OU:=""}"
: "${WORKGROUP:=""}"
: "${AUTOLOGIN:=""}"

# Sanitize variables
KEY=$(strip "$KEY")
HOST=$(strip "$HOST")
WIDTH=$(strip "$WIDTH")
HEIGHT=$(strip "$HEIGHT")
DOMAIN=$(strip "$DOMAIN")
REGION=$(strip "$REGION")
EDITION=$(strip "$EDITION")
KEYBOARD=$(strip "$KEYBOARD")
LANGUAGE=$(strip "$LANGUAGE")
USERNAME=$(strip "$USERNAME")
DOMAIN_OU=$(strip "$DOMAIN_OU")
WORKGROUP=$(strip "$WORKGROUP")

printVersion() {

  local id="$1"
  local desc="$2"

  case "${id,,}" in
    "tiny11"* ) desc="Tiny 11" ;;
    "tiny10"* ) desc="Tiny 10" ;;
    "core11"* ) desc="Core 11" ;;
    "reactos"* ) desc="ReactOS" ;;
    "win7"* ) desc="Windows 7" ;;
    "win8"* ) desc="Windows 8" ;;
    "win10"* ) desc="Windows 10" ;;
    "win11"* ) desc="Windows 11" ;;
    "winxp"* ) desc="Windows XP" ;;
    "win9x"* ) desc="Windows ME" ;;
    "win98"* ) desc="Windows 98" ;;
    "win95"* ) desc="Windows 95" ;;
    "winnt4"* ) desc="Windows NT 4" ;;
    "win2k"* ) desc="Windows 2000" ;;
    "winvista"* ) desc="Windows Vista" ;;
    "win2019-hv"* ) desc="Hyper-V Server" ;;
    "win2003"* ) desc="Windows Server 2003" ;;
    "win2008"* ) desc="Windows Server 2008" ;;
    "win2012"* ) desc="Windows Server 2012" ;;
    "win2016"* ) desc="Windows Server 2016" ;;
    "win2019"* ) desc="Windows Server 2019" ;;
    "win2022"* ) desc="Windows Server 2022" ;;
    "win2025"* ) desc="Windows Server 2025" ;;
  esac

  if [ -z "$desc" ]; then
    desc="Windows"
    isPlatform "x64" || desc+=" for ${PLATFORM}"
  fi

  echo "$desc"
  return 0
}

printVariant() {

  local id="$1"
  local desc="$2"
  local show_eval="${3:-N}"

  desc=$(printVersion "$id" "$desc") || return 1

  case "${id,,}" in
    *"-iot" | *"-iot-eval" )
      desc+=" IoT" ;;
    *"-ltsc" | *"-ltsc-eval" )
      desc+=" LTSC" ;;
    *"-enterprise" | *"-enterprise-eval" )
      desc+=" Enterprise" ;;
  esac

  if enabled "$show_eval" && [[ "${id,,}" == *"-eval" ]]; then
    desc+=" (Evaluation)"
  fi

  echo "$desc"
  return 0
}

getRequiredMemory() {

  local id="${1,,}"

  case "$id" in
    "win11"* )
      echo "2G" ;;
    "tiny11"* | "core11"* )
      echo "2G" ;;
    "win10"* | "tiny10"* )
      echo "2G" ;;
    "win2025"* | "win2022"* | "win2019"* | "win2016"* )
      echo "2G" ;;
    "win81"* | "win7x64"* )
      echo "2G" ;;
    "win7x86"* | "winvista"* | "win2012"* )
      echo "1G" ;;
    "win2008"* | "win2003"* )
      echo "512M" ;;
    "winxpx64"* )
      echo "256M" ;;
    "win9"* | "winnt4"* | "winxpx86"* | "win2k"* )
      echo "130M" ;;
    "reactos"* )
      echo "130M" ;;
    * )
      echo "130M" ;;
  esac

  return 0
}

getRequiredDisk() {

  local id="${1,,}"

  case "$id" in
    "win11"* )
      echo "32G" ;;
    "tiny11"* )
      echo "8G" ;;
    "core11"* )
      echo "4G" ;;
    "win10"* )
      echo "16G" ;;
    "tiny10"* )
      echo "10G" ;;
    "win2025"* | "win2022"* | "win2019"* | "win2016"* | "win2012"* )
      echo "32G" ;;
    "win81"* | "win7"* | "winvista"* )
      echo "16G" ;;
    "win2008"* )
      echo "10G" ;;
    "win2003"* )
      echo "4G" ;;
    "winxp"* )
      echo "2G" ;;
    "win2k"* )
      echo "1G" ;;
    "win9x"* )
      echo "512M" ;;
    "win98"* )
      echo "256M" ;;
    "win95"* )
      echo "100M" ;;
    "winnt4"* )
      echo "128M" ;;
    "reactos"* )
      echo "512M" ;;
    * )
      echo "100M" ;;
  esac

  return 0
}

isLegacy() {

  local id="$1"

  case "${id,,}" in
    "win9"* | "winnt4" | "win2k"* | "winxp"* | "win2003"* | \
    "winvista"* | "win7"* | "win2008"* | "reactos" )
      return 0 ;;
  esac

  return 1
}

supportsUnattended() {

  local id="$1"

  case "${id,,}" in
    "winnt4" | "reactos" )
      return 1 ;;
  esac

  return 0
}

supportsBootKey() {

  local id="$1"

  case "${id,,}" in
    "win9"* | "winnt4" | "reactos" )
      return 1 ;;
    "win"* | "tiny"* | "core"* )
      return 0 ;;
  esac

  return 0
}

getSize() {

  getValue "$1" "$2" "$3" "size"
}

isCompatible() {
  return 0
}

return 0
