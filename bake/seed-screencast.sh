#!/bin/bash
# Seed the portal's ScreenCast permission + a persistent restore_token.
#
# Without this, the FIRST ScreenCast Start pops a "Share your screen" dialog and
# blocks forever in a headless guest. The grant + token were captured by hand
# once; replaying the token makes every later Start succeed with no interaction,
# no matter how easystream is upgraded.
set -e
DB=/home/docker/.local/share/flatpak/db
mkdir -p "$DB" /home/docker/.config
# The PermissionStore table (screencast) that the portal reads.
echo 'R1ZhcmlhbnQAAAAAAAAAABgAAABYAAAAAAAAKAIAAAAAAAAAAQAAAGp/mnz/////WAAAAAQASABcAAAAnAAAAJkrlHz/////UwEAAAQASABYAQAAmAEAAG1haW4AAAAoAgAAAAAAAAABAAAAppUntP////+cAAAAJAB2AMAAAAAsAQAABRUAAP////8sAQAAAAB2ADABAABTAQAANjYxZDliYzQtNTI0OS00YmRmLTk5MGItNzk3ZGFhM2RmYWUyR05PTUUAAAABAAAAAAAAAKmzjwUDXgYAor+RCANeBgAAAAAAAQAAAFJIVDpRRU1VIE1vbml0b3I6MHgwMDAwMDAwMAAAcyYAKHh4YSh1dXYpKQYAKHN1dikAeWVzAAQBB1kAKHZhe3Nhc30pAAAAAABhe3N2fXNjcmVlbmNhc3QAeWVzAAQLEQYAKHZhe3Nhc30pYXBwcwAAAAAoAgAAAAAAAAABAAAAMA0vmv////+YAQAACgB2AKgBAACtAQAABRUAAP////+tAQAAAAB2ALABAADZAQAAc2NyZWVuY2FzdAAAAAAAAAABAGFzAAAANjYxZDliYzQtNTI0OS00YmRmLTk5MGItNzk3ZGFhM2RmYWUyACUAYXM=' | base64 -d > "$DB/screencast"
# The token easystream replays on every SelectSources.
printf '%s\n' '661d9bc4-5249-4bdf-990b-797daa3dfae2' > /home/docker/.config/screencast-token
chown -R docker:docker /home/docker/.local/share/flatpak /home/docker/.config
chmod 664 "$DB/screencast" /home/docker/.config/screencast-token
echo "seeded $DB/screencast + ~/.config/screencast-token"
