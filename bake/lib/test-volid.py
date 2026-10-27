"""Prove the volume-label reader against a synthetic ISO header.

archive detection is the one thing in bake-cachyos.sh that reads raw bytes, and
getting it wrong produces an empty device name at boot rather than an error here:

    :: Mounting '' to '/run/archiso/bootmnt'
    ERROR: '' device did not show up after 30 seconds...
"""

import pathlib
import subprocess
import sys
import tempfile


def make_fake_iso(label: str) -> pathlib.Path:
    data = bytearray(17 * 2048)
    pvd = bytearray(2048)
    pvd[0] = 1
    pvd[1:6] = b"CD001"
    pvd[6] = 1
    pvd[40:72] = label.encode().ljust(32)
    data[16 * 2048:17 * 2048] = pvd
    path = pathlib.Path(tempfile.mkdtemp()) / "fake.iso"
    path.write_bytes(data)
    return path


READER = """
import sys
with open(sys.argv[1], "rb") as f:
    f.seek(16 * 2048)
    pvd = f.read(2048)
if pvd[0] != 1 or pvd[1:6] != b"CD001":
    sys.exit(1)
print(pvd[40:72].decode("ascii", "replace").rstrip())
"""


def main() -> int:
    for label in ("COS_202608", "ARCH_202610", "EOS_202608"):
        iso = make_fake_iso(label)
        out = subprocess.run(
            [sys.executable, "-c", READER, str(iso)],
            capture_output=True, text=True,
        )
        got = out.stdout.strip()
        status = "ok  " if got == label else "FAIL"
        print(f"  {status} {label!r} -> {got!r}")
        if got != label:
            return 1

    # A non-ISO file must fail rather than return junk.
    junk = pathlib.Path(tempfile.mkdtemp()) / "junk.bin"
    junk.write_bytes(b"\0" * (17 * 2048))
    out = subprocess.run(
        [sys.executable, "-c", READER, str(junk)], capture_output=True,
    )
    if out.returncode == 0:
        print("  FAIL a non-ISO file was accepted")
        return 1
    print("  ok   a non-ISO file is rejected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
