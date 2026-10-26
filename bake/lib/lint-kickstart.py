"""Catch the two kickstart mistakes that Fedora's first bake hit.

anaconda's parser lives inside the ISO, so a kickstart can only be fully checked
by booting it. These two are checkable as text, and they are the two that
actually happened:

  * `install` - removed in Fedora 44, but still present in most documentation:
        line 18: install has been removed.
  * package and group names outside %packages - they are then read as kickstart
        commands, and the install dies:
        line 48: Unknown command: @workstation-product-environment
        line 56: Unknown command: zenity

Usage: lint-kickstart.py <path>
"""

import re
import sys

# A directive with arguments: `lang en_US.UTF-8`, `autopart --type=plain`.
DIRECTIVE = re.compile(r"^[a-z][a-z0-9-]*\s")

# ...and the ones that take none. These are valid statements whose whole line is
# a single word, which is exactly the shape a misplaced package name has, so the
# list has to be explicit rather than inferred.
NOARG = {
    "zerombr", "text", "skipx", "poweroff", "reboot", "shutdown", "autostep",
    "eula", "graphical", "cmdline", "logging", "firstboot", "upgrade",
    "ignoredisk", "mediacheck", "selinux", "services", "sshpw", "timezone",
}

# Directives removed from recent anaconda. `install` is the one that bit us.
REMOVED = {"install"}

# Sections whose bodies are shell, not kickstart. Everything between the opening
# line and its %end is skipped outright - a heredoc's `EOF` inside %post is not a
# kickstart token, and reading it as one is a false positive.
SHELL_SECTIONS = {"%pre", "%post", "%onerror", "%traceback", "%packages"}


def main(path):
    problems = []
    in_packages = False
    section = None          # which %section we are inside, if any

    for n, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = raw.rstrip("\n")
        s = line.strip()

        # Section handling first. Once inside %packages the body is package names
        # and that is the ONE section whose contents are checked; the others are
        # skipped whole.
        if line.startswith("%"):
            name = line.split()[0]
            if name == "%end":
                in_packages = False
                section = None
                continue
            if name in SHELL_SECTIONS:
                section = name
                in_packages = name == "%packages"
                continue
            # A directive that happens to start with % (%include, %ksappend).
            continue
        if section is not None:
            # Inside a section: only %packages contents are of interest, and they
            # are skipped here because package lines are not validated as text.
            continue
        if s.startswith("#") or not s:
            continue

        if s.split()[0] in REMOVED:
            problems.append((n, s, f"'{s.split()[0]}' was removed; anaconda rejects it"))
            continue

        # Outside every section: anything that is a bare package-looking token
        # rather than a directive with arguments is a package name in the wrong
        # place. The no-argument directives are listed, because their whole line
        # is one word - the same shape as the mistake.
        if DIRECTIVE.match(s):
            continue
        if s in NOARG:
            continue
        if s.startswith("-"):
            continue
        if re.fullmatch(r"@?[A-Za-z0-9][A-Za-z0-9._+*/-]*", s):
            problems.append((n, s, "package or group outside %packages; anaconda reads it as a command"))

    if problems:
        for n, s, why in problems:
            print(f"{path}:{n}: '{s}' - {why}", file=sys.stderr)
        return 1

    print(f"{path}: ok")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: lint-kickstart.py <kickstart>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
