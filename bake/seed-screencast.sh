#!/bin/bash
# Seed the portal's ScreenCast permission + a persistent restore_token.
#
# Without this, the FIRST ScreenCast Start pops a "Share your screen" dialog and
# blocks forever in a headless guest. The grant + token were captured by hand
# once per desktop (see bake/README); replaying the token makes every later Start
# succeed with no interaction, no matter how easystream is upgraded.
#
#   $1 = gnome | kde   (default gnome)
#
# GNOME and KDE store DIFFERENT tables/tokens in the same PermissionStore db, so
# each flavor gets its own captured file.
set -e
FLAVOR="${1:-gnome}"
DB=/home/docker/.local/share/flatpak/db
mkdir -p "$DB" /home/docker/.config

case "$FLAVOR" in
  kde)
    B64='R1ZhcmlhbnQAAAAAAAAAABgAAABYAAAAAAAAKAIAAAAAAAAAAQAAAGp/mnz/////WAAAAAQASABcAAAAuAAAAJkrlHz/////iwIAAAQASACQAgAA0AIAAG1haW4AAAAoAwAAAAAAAAABAAAAAQAAAKaVJ7T/////uAAAACQAdgDgAAAAkAEAANWhjlz/////kAEAACQAdgC4AQAAaAIAAAUVAAD/////aAIAAAAAdgBoAgAAiwIAADY2MWQ5YmM0LTUyNDktNGJkZi05OTBiLTc5N2RhYTNkZmFlMgAAAABLREUAAQAAAAAAAAMAAAAOAG8AdQB0AHAAdQB0AHMAAAAJAAAAAAEAAAAKAAAAAAYAMAB4ADAAAAAMAHIAZQBnAGkAbwBuAAAAEwAAAAAAAAAAAP//////////AAAADgB3AGkAbgBkAG8AdwBzAAEAAAAAAAAZUUxpc3Q8V2luZG93UmVzdG9yZUluZm8+AAAAAAAAYXkEAChzdXYpAHllcwAEAQedACh2YXtzYXN9KWNiYzEzMDMzLTM2NzYtNDgzNi05MjNkLWY1NzFkNzEzYjQ0YQAAAABLREUAAQAAAAAAAAMAAAAOAG8AdQB0AHAAdQB0AHMAAAAJAAAAAAEAAAAKAAAAAAYAMAB4ADAAAAAMAHIAZQBnAGkAbwBuAAAAEwAAAAAAAAAAAP//////////AAAADgB3AGkAbgBkAG8AdwBzAAEAAAAAAAAZUUxpc3Q8V2luZG93UmVzdG9yZUluZm8+AAAAAAAAYXkEAChzdXYpAHllcwAEAQedACh2YXtzYXN9KQBhe3N2fXNjcmVlbmNhc3QAeWVzAAQLEQYAKHZhe3Nhc30pYXBwcwAAAAAoAgAAAAAAAAABAAAAMA0vmv/////QAgAACgB2AOACAADlAgAABRUAAP/////lAgAAAAB2AOgCAABdAwAAc2NyZWVuY2FzdAAAAAAAAAABAGFzAAAANjYxZDliYzQtNTI0OS00YmRmLTk5MGItNzk3ZGFhM2RmYWUyADY2MWQ5YmM0LTUyNDktNGJkZi05OTBiLTc5N2RhYTNkZmFlMgBjYmMxMzAzMy0zNjc2LTQ4MzYtOTIzZC1mNTcxZDcxM2I0NGEAJUpvAGFz'
    TOK='cbc13033-3676-4836-923d-f571d713b44a'
    ;;
  *)
    B64='R1ZhcmlhbnQAAAAAAAAAABgAAABYAAAAAAAAKAIAAAAAAAAAAQAAAGp/mnz/////WAAAAAQASABcAAAAnAAAAJkrlHz/////UwEAAAQASABYAQAAmAEAAG1haW4AAAAoAgAAAAAAAAABAAAAppUntP////+cAAAAJAB2AMAAAAAsAQAABRUAAP////8sAQAAAAB2ADABAABTAQAANjYxZDliYzQtNTI0OS00YmRmLTk5MGItNzk3ZGFhM2RmYWUyR05PTUUAAAABAAAAAAAAAKmzjwUDXgYAor+RCANeBgAAAAAAAQAAAFJIVDpRRU1VIE1vbml0b3I6MHgwMDAwMDAwMAAAcyYAKHh4YSh1dXYpKQYAKHN1dikAeWVzAAQBB1kAKHZhe3Nhc30pAAAAAABhe3N2fXNjcmVlbmNhc3QAeWVzAAQLEQYAKHZhe3Nhc30pYXBwcwAAAAAoAgAAAAAAAAABAAAAMA0vmv////+YAQAACgB2AKgBAACtAQAABRUAAP////+tAQAAAAB2ALABAADZAQAAc2NyZWVuY2FzdAAAAAAAAAABAGFzAAAANjYxZDliYzQtNTI0OS00YmRmLTk5MGItNzk3ZGFhM2RmYWUyACUAYXM='
    TOK='661d9bc4-5249-4bdf-990b-797daa3dfae2'
    ;;
esac

printf '%s' "$B64" | base64 -d > "$DB/screencast"
printf '%s\n' "$TOK" > /home/docker/.config/screencast-token
chown -R docker:docker /home/docker/.local/share/flatpak /home/docker/.config
chmod 664 "$DB/screencast" /home/docker/.config/screencast-token
echo "seeded $FLAVOR: $DB/screencast + ~/.config/screencast-token ($TOK)"
