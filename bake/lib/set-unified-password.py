"""Make every bake create the same account: docker / admin.

WHY ONE PASSWORD

Each distribution's configuration set its own - arch and endeavouros used
`docker:docker`, preseed and autoinstall carried a $6$ hash of `docker`, NixOS had
`admin` already. Remembering which disk wants what is a small annoyance that grows into a
real one when a dozen disks exist: the password becomes part of the interface, and an
interface with a per-item exception is worse than one without.

The username is `docker` everywhere already; only the password changes.

Two forms are written, because the installers take it two ways:

  plaintext      arch, endeavouros, fedora, mx   (chpasswd, --plaintext, minstall.conf)
  $6$ hash       debian, ubuntu                  (preseed, autoinstall)

The hash is generated once here with a fixed salt so the same value appears in both
files and a person can check it with `openssl passwd -6 -salt dockerbake admin`.
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from mkpasswd import sha512_crypt  # noqa: E402

PASSWORD = "admin"
USER = "docker"

# Fixed salt: the hash in the preseed and the autoinstall file should be the same
# string, so that one openssl invocation verifies both.
SALT = "dockerbake"
HASH = sha512_crypt(PASSWORD, salt=SALT)

# (path, old, new) - each anchored on enough context to be unambiguous.
EDITS = [
    # Plaintext, chpasswd.
    ("bake/arch/pacstrap.sh",
     "echo 'docker:docker' | chpasswd",
     "echo 'docker:admin' | chpasswd"),
    ("bake/endeavouros/pacstrap.sh",
     "echo 'docker:docker' | chpasswd",
     "echo 'docker:admin' | chpasswd"),
    # anaconda.
    ("bake/fedora/ks.cfg",
     "user --name=docker --groups=wheel,video,render,audio,input --plaintext --password=docker",
     "user --name=docker --groups=wheel,video,render,audio,input --plaintext --password=admin"),
    # minstall.
    ("bake/mx/minstall.conf",
     "UserPass = docker",
     "UserPass = admin"),
    ("bake/mx/minstall.conf",
     "RootPass = docker",
     "RootPass = admin"),
]


def main() -> int:
    print("hash for %s: %s" % (PASSWORD, HASH))
    changed = 0

    for rel, old, new in EDITS:
        path = pathlib.Path(rel)
        if not path.exists():
            print("  missing: %s" % rel)
            continue
        text = path.read_text()
        if new in text and old not in text:
            print("  already: %s" % rel)
            continue
        if old not in text:
            print("  NO MATCH: %s (%r)" % (rel, old[:60]))
            continue
        path.write_text(text.replace(old, new, 1))
        changed += 1
        print("  plaintext: %s" % rel)

    # The $6$ strings, whatever their current salt or digest.
    for rel, prefix in (
        ("bake/debian/preseed.cfg",
         "d-i passwd/user-password-crypted password "),
        ("bake/ubuntu/user-data",
         '    password: "'),
    ):
        path = pathlib.Path(rel)
        if not path.exists():
            print("  missing: %s" % rel)
            continue
        lines = path.read_text().splitlines(keepends=True)
        for i, line in enumerate(lines):
            if not line.startswith(prefix):
                continue
            if rel.endswith("user-data"):
                lines[i] = '%s%s"\n' % (prefix, HASH)
            else:
                lines[i] = "%s%s\n" % (prefix, HASH)
            changed += 1
            print("  hash: %s" % rel)
            break
        else:
            print("  NO MATCH: %s (%r)" % (rel, prefix))
        path.write_text("".join(lines))

    print("edits: %d" % changed)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
