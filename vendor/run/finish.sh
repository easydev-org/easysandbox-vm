#!/usr/bin/env bash
set -Eeuo pipefail

# progress.sh was removed with the image-extraction code it only served, so
# there is no progress helper left to stop here.

if [[ "${DISPLAY,,}" == "web" ]]; then

  [ ! -f "$INFO" ] && error "File $INFO not found."
  rm -f "$INFO"

  [ ! -f "$PAGE" ] && error "File $PAGE not found."
  rm -f "$PAGE"

else

  if [[ "${DISPLAY,,}" == "vnc" ]]; then
    html "You can now connect to VNC on port $VNC_PORT." "0"
  else
    html "The virtual machine was booted successfully." "0"
  fi

fi

if enabled "$DEBUG"; then
  echo
  printf "QEMU arguments:\n\n    %s\n\n" "${ARGS// -/$'\n    -'}"
fi

# Must always remain the very last command
enableTrap

return 0
