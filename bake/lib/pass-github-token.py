"""Pass GITHUB_TOKEN into every bake command.

bake_fetch_iso pulls the install image from ghcr, and the iso package is private -
the same as the runner image itself. Without a token the registry answers 401 and the
bake stops at its first step, which is a failure that says nothing about the cache:

  [iso] could not get a registry token

The token goes in as an environment variable on the log-stream step rather than on the
command line, because the command line is echoed into the check run's output.
"""

import pathlib
import re

# Each workflow's bake step passes inputs to its script in a command block; the token
# belongs in the same place the other exports are.
MARKER = "            set -euo pipefail\n"
EXPORT = '            export GITHUB_TOKEN="${{ github.token }}"\n'


def main() -> int:
    changed = 0
    for path in sorted(pathlib.Path(".github/workflows").glob("bake-*.yml")):
        text = path.read_text()
        if "export GITHUB_TOKEN=" in text:
            print(f"  already done: {path.name}")
            continue
        if MARKER not in text:
            print(f"  no command block found: {path.name}")
            continue
        text = text.replace(MARKER, MARKER + EXPORT, 1)
        path.write_text(text)
        changed += 1
        print(f"  token passed: {path.name}")
    print(f"workflows changed: {changed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
