"""Change the one hardcoded CONSOLE in MX's initrd init.

The target, from mx-iso-template initrd/init:

    exec $LIVE_BIN/switch_root $NEW_ROOT /usr/bin/env CONSOLE=/dev/tty1 $INIT_COMMAND "$@"

Two edits:

  1. that line, so CONSOLE comes from CONSOLE_OVERRIDE when it is set;
  2. just after the MY_TTY resolution, so CONSOLE_OVERRIDE is built from the
     CONSOLE= the kernel command line carried.

Both anchors are asserted. If either is missing the script exits non-zero rather
than writing a half-patched init - a live system that boots to a console nobody can
reach is worse than one that fails loudly here.
"""

import pathlib
import sys

OLD_EXEC = (
    'exec $LIVE_BIN/switch_root $NEW_ROOT /usr/bin/env CONSOLE=/dev/tty1 '
    '$INIT_COMMAND "$@"'
)

NEW_EXEC = (
    '# Patched by the bake: CONSOLE_OVERRIDE is set from the CONSOLE= the kernel\n'
    '# command line carried. MX hardcodes /dev/tty1 here, which leaves a serial\n'
    '# console silent after switch_root no matter what console= says.\n'
    'exec $LIVE_BIN/switch_root $NEW_ROOT /usr/bin/env '
    'CONSOLE="${CONSOLE_OVERRIDE:-/dev/tty1}" $INIT_COMMAND "$@"'
)

ANCHOR = "MY_TTY=${CMD_MY_TTY:-$MY_TTY}"

INSERT = """\

    # The bake passes CONSOLE=/dev/ttyS0; CMD_MY_TTY has had the "tty" stripped, so
    # the device path is rebuilt here and handed to switch_root below. Without a
    # CONSOLE= the value stays /dev/tty1, which is MX's own default.
    CONSOLE_OVERRIDE=/dev/tty1
    if [ -n "$CMD_MY_TTY" ]; then
        CONSOLE_OVERRIDE=/dev/tty$CMD_MY_TTY
    fi
    echo "CONSOLE_OVERRIDE=$CONSOLE_OVERRIDE" >> "$MY_LOG" 2>/dev/null || true
"""


def main(path_str: str) -> int:
    path = pathlib.Path(path_str)
    text = path.read_text()

    if OLD_EXEC not in text:
        print("the hardcoded CONSOLE line was not found", file=sys.stderr)
        return 1
    if ANCHOR not in text:
        print("the MY_TTY assignment was not found", file=sys.stderr)
        return 1
    if "CONSOLE_OVERRIDE" in text:
        print("already patched")
        return 0

    text = text.replace(OLD_EXEC, NEW_EXEC, 1)
    text = text.replace(ANCHOR, ANCHOR + INSERT, 1)
    path.write_text(text)
    print("patched", path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1]))
