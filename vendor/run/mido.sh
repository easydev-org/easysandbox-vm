#!/usr/bin/env bash
set -Eeuo pipefail

getCatalog() {

  local id="$1"
  local ret="$2"
  local source="${3:-microsoft}"

  local file="catalog.cab"
  local url="" name="" edition=""

  if [[ "${id,,}" == "win11"* ]] && ! isCompatible; then
    # ARMv8.0 cannot run Windows 11 builds 24H2 and up.
    getWorCatalog "$1" "$2" "22631.2861" && return 0
  fi

  if [[ "${source,,}" == "wor" ]]; then
    getWorCatalog "$1" "$2" && return 0
  fi

  case "${id,,}" in
    "win11${PLATFORM,,}" )
      edition="Professional"
      name="Windows 11 Pro"
      url="https://go.microsoft.com/fwlink?linkid=2156292" ;;
    "win10${PLATFORM,,}" )
      edition="Professional"
      name="Windows 10 Pro"
      url="https://go.microsoft.com/fwlink/?LinkId=841361" ;;
    "win11${PLATFORM,,}-enterprise" | "win11${PLATFORM,,}-enterprise-eval")
      edition="Enterprise"
      name="Windows 11 Enterprise"
      url="https://go.microsoft.com/fwlink?linkid=2156292" ;;
    "win10${PLATFORM,,}-enterprise" | "win10${PLATFORM,,}-enterprise-eval" )
      edition="Enterprise"
      name="Windows 10 Enterprise"
      url="https://go.microsoft.com/fwlink/?LinkId=841361" ;;
  esac

  case "${ret,,}" in
    "url" ) echo "$url" ;;
    "file" ) echo "$file" ;;
    "name" ) echo "$name" ;;
    "edition" ) echo "$edition" ;;
    *) echo "";;
  esac

  return 0
}

getWorCatalog() {

  local id="$1"
  local ret="$2"
  local build="${3:-}"

  local file="catalog.xml"
  local name="" filter="" url=""
  local version="" edition="" arch=""

  case "${PLATFORM,,}" in
    "x64" ) arch="x64" ;;
    "arm64" ) arch="ARM64" ;;
  esac

  case "${id,,}" in
    "win11${PLATFORM,,}" )
      version="11"
      filter="Professional"
      name="Windows 11 Pro" ;;
    "win10${PLATFORM,,}" )
      version="10"
      filter="Professional"
      name="Windows 10 Pro" ;;
    "win11${PLATFORM,,}-enterprise" | "win11${PLATFORM,,}-enterprise-eval")
      version="11"
      filter="Enterprise"
      name="Windows 11 Enterprise" ;;
    "win10${PLATFORM,,}-enterprise" | "win10${PLATFORM,,}-enterprise-eval" )
      version="10"
      filter="Enterprise"
      name="Windows 10 Enterprise" ;;
  esac

  if [ -n "$version" ] && [ -n "$arch" ]; then
    url="https://worproject.com/dldserv/esd/getcatalog.php?ver=${version}&arch=${arch}&edition=${filter}"
    [ -n "$build" ] && url+="&build=${build}"
  fi

  case "${ret,,}" in
    "url" ) echo "$url" ;;
    "file" ) echo "$file" ;;
    "name" ) echo "$name" ;;
    "edition" ) echo "$edition" ;;
    *) echo "";;
  esac

  return 0
}

isCompressed() {

  local url="${1%%[\?#]*}"
  local file

  file=$(basename "$url")
  printf -v file '%b' "${file//%/\\x}"

  # The ReactOS latest-build endpoint returns an archive without a filename
  # extension, so recognize its path explicitly.
  case "${file,,}" in
    *.7z | *.zip | *.rar | *.tar | *.cab | *.cpio | \
    *.lzh | *.lha | *.xar )
      return 0 ;;
  esac

  case "${url,,}" in
    */latest-x86-gcc-lin-rel ) return 0 ;;
  esac

  return 1
}

return 0
