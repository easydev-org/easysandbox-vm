"""Check a preseed for the mistakes that only show up mid-install.

debian-installer's preseed is one instruction per line:

    <owner> <question> <type> <value>

and a trailing backslash is a literal character, NOT a line continuation. A
multi-line value therefore becomes a short value plus a pile of lines the parser
does not understand - which is reported far downstream, usually as a question
that was never answered, so the install stops and waits for input nobody can
give.

Usage: lint-preseed.py <preseed>
"""

import re
import sys

KNOWN_TYPES = {"string", "boolean", "select", "multiselect", "password", "note", "error", "title", "text"}


def main(path):
    problems = []
    seen_questions = set()

    for n, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = raw.rstrip("\n")
        s = line.strip()

        if not s or s.startswith("#"):
            continue

        # A line that does not start with an owner/command is either a
        # continuation (which preseed does not have) or garbage.
        if not re.match(r"^(d-i|d-i\s|tasksel|popularity-contest|#)", s):
            problems.append((n, s, "not a preseed instruction; a continuation line cannot exist in this format"))
            continue

        if line.endswith("\\"):
            problems.append((n, s[-40:], "line ends with a backslash, which preseed takes literally, not as a continuation"))

        parts = s.split(None, 3)
        if parts[0] in ("d-i", "tasksel", "popularity-contest"):
            if len(parts) < 3:
                problems.append((n, s, "too few fields"))
                continue
            qtype = parts[2]
            if qtype not in KNOWN_TYPES:
                problems.append((n, s, f"unknown question type '{qtype}'"))
            # Same question twice: the later one wins silently, which makes a
            # duplicate look like the first was ignored.
            name = (parts[0], parts[1])
            if name in seen_questions:
                problems.append((n, s, "question already set earlier in this file"))
            seen_questions.add(name)

    if problems:
        for n, s, why in problems:
            print(f"{path}:{n}: {why}\n    {s}", file=sys.stderr)
        return 1

    print(f"{path}: ok ({len(seen_questions)} questions)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: lint-preseed.py <preseed>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
