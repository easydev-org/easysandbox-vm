"""Point every bake's ISO download at ghcr.

Each bake downloads its own image:

    [ -s "$ISO" ] || curl -fsSL --retry 3 --retry-delay 2 -o "$ISO" "$ISO_URL"

and $ISO_URL is whichever host the distribution recommends. Replacing that with
bake_fetch_iso removes the host from the picture entirely.

The first argument of bake_fetch_iso is the tag publish-isos.yml pushed under, which
is not always the directory name - mx and endeavouros are spelled the same, but the
tag for arch is "arch" while the directory is also arch. The mapping is explicit
below rather than derived, because deriving it is how a tag silently becomes wrong.
"""

import pathlib
import re

# directory -> (tag in ghcr, what to call the downloaded file)
TAG = {
    "arch": ("arch", "arch.iso"),
    "cachyos": ("cachyos", "cachyos.iso"),
    "debian": ("debian", "debian.iso"),
    "endeavouros": ("endeavouros", "endeavouros.iso"),
    "fedora": ("fedora", "fedora.iso"),
    "mx": ("mx", "mx.iso"),
    "nixos": ("nixos", "nixos.iso"),
    "ubuntu": ("ubuntu", "ubuntu.iso"),
}

# The download line, in each of the shapes it appears in.
PATTERNS = [
    # [ -s "$ISO" ] || curl ... -o "$ISO" "$ISO_URL"
    re.compile(r'^\[ -s "\$ISO" \] \|\| curl [^\n]*"\$ISO_URL"$', re.M),
    # [ -s nixos.iso ] || curl ... -o nixos.iso "$ISO_URL"
    re.compile(r'^\[ -s nixos\.iso \] \|\| curl [^\n]*nixos\.iso "\$ISO_URL"$', re.M),
]


def main() -> int:
    changed = 0
    for distro, (tag, filename) in sorted(TAG.items()):
        for path in pathlib.Path("bake").glob(f"{distro}/*.sh"):
            text = path.read_text()
            if "bake_fetch_iso" in text:
                print(f"  already done: {path}")
                continue
            original = text
            for pat in PATTERNS:
                text = pat.sub(
                    f'. "$HERE/../lib/iso.sh"\n'
                    f'bake_fetch_iso "{tag}" "${{ISO:-{filename}}}"',
                    text, count=1,
                )
            if text == original:
                continue
            path.write_text(text)
            changed += 1
            print(f"  ghcr: {path}")
    print(f"files changed: {changed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
