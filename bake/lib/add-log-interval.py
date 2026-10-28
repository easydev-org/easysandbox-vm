"""Give every log-stream step an explicit interval.

WHY THIS MATTERS MORE THAN IT LOOKS

GitHub serves a running job's Actions log from an internal store, and the public
endpoints answer 404 or 403 until the job finishes - dockur-macos measured that
repeatedly, including 302s to blobs that did not exist yet. A check run's
output.text has no such restriction: a plain authenticated GET reads it live, and
log-stream is what keeps that field current.

Without an interval of its own, the field barely moved: reading it during a bake
returned the first line and nothing else, which looked like truncation and was
actually a stale snapshot. That is why a 30-minute MX run could not be told apart
from a hung one, and why it had to be cancelled blind.

`interval: "10"` makes the run observable - the same setting dockur's workflow uses
for its 20-minute Setup Assistant drive.
"""

import pathlib
import re

INTERVAL = '          interval: "10"\n'


def main() -> int:
    changed = 0
    for path in sorted(pathlib.Path(".github/workflows").glob("*.yml")):
        text = path.read_text()
        if "log-stream@main" not in text:
            continue
        if 'interval:' in text:
            print(f"  skipped (already set): {path.name}")
            continue

        # Insert after each `name:` line inside a log-stream step's `with:` block.
        # The name line is the reliable neighbour: every step here has one, and
        # interval belongs beside it.
        lines = text.splitlines(keepends=True)
        out = []
        in_stream = False
        for line in lines:
            out.append(line)
            if "log-stream@main" in line:
                in_stream = True
                continue
            if in_stream and re.match(r"^\s+name:\s", line):
                out.append(INTERVAL)
                in_stream = False
        new = "".join(out)
        if new != text:
            path.write_text(new)
            changed += 1
            print(f"  interval added: {path.name}")
    print(f"workflows changed: {changed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
