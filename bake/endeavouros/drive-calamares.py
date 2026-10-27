"""Drive EndeavourOS's Calamares through the QEMU monitor, one keystroke at a time.

WHY THIS IS A LOOP OF SMALL STEPS AND NOT A KEY SEQUENCE

Calamares has no unattended mode and no machine-readable interface. The only way
to install is to press keys at its window, and the only way to know whether a key
did what was intended is to look at the screen afterwards. A fixed sequence -
"Tab Tab Return, wait, Tab Tab Return" - would be a guess that fails silently:
every page looks the same kind of grey, and a wrong number of Tabs lands on a
different button without any error.

So each step here is: send keys, take a screenshot, keep it. The screenshots are
called step-NN-description.png and they come back as an artifact. When something
goes wrong the answer is in the last picture rather than in a guess.

WHAT THE PROBE SHOWED

  60s   tty1 with liveuser logged in
  120s  KDE desktop, EndeavourOS Welcome window open, no Calamares yet

Calamares is not started by the ISO. The Welcome window's first button is
"Start the Installer", and that is where this begins.
"""

import re
import socket
import subprocess
import sys
import time
from pathlib import Path


class Monitor:
    """The QEMU monitor: keystrokes in, screenshots out."""

    def __init__(self, path: str, workdir: Path):
        self.workdir = workdir
        deadline = time.time() + 90
        self.sock = None
        while time.time() < deadline:
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(path)
                s.settimeout(10)
                self.sock = s
                break
            except OSError:
                time.sleep(1)
        if self.sock is None:
            raise SystemExit(f"monitor socket {path} never appeared")
        time.sleep(1)
        self._drain()
        self.step = 0

    def _drain(self):
        try:
            while self.sock.recv(65536):
                pass
        except (socket.timeout, OSError):
            pass

    def send(self, line: str):
        self.sock.sendall((line + "\n").encode())
        time.sleep(0.35)

    def key(self, name: str, times: int = 1):
        for _ in range(times):
            self.send(f"sendkey {name}")
            time.sleep(0.15)

    def shot(self, tag: str) -> Path:
        self.step += 1
        ppm = self.workdir / f"step-{self.step:02d}-{tag}.ppm"
        self.send(f"screendump {ppm}")
        time.sleep(1.5)
        png = ppm.with_suffix(".png")
        try:
            subprocess.run(
                [sys.executable, str(Path(__file__).parent.parent / "nixos" / "ppm2png.py"),
                 str(ppm), str(png), "desktop"],
                check=True, capture_output=True,
            )
        except subprocess.CalledProcessError:
            pass
        print(f"  shot {self.step:02d} {tag}", flush=True)
        return png

    def wait_for_stable(self, tag: str, seconds: int = 20, settle: int = 3):
        """Screenshot every `settle` seconds until two pictures match in size.

        File size is a crude fingerprint, but it is enough to tell 'still
        animating' from 'waiting for me', and it needs nothing from inside the
        guest.
        """
        deadline = time.time() + seconds
        last = None
        while time.time() < deadline:
            png = self.shot(tag)
            size = png.stat().st_size if png.exists() else 0
            if size and size == last:
                return png
            last = size
            time.sleep(settle)
        return png


def main() -> int:
    mon_path, workdir = sys.argv[1], Path(sys.argv[2])
    mon = Monitor(mon_path, workdir)
    log = open(workdir / "installer.log", "w", buffering=1)

    def say(msg: str):
        print(msg, flush=True)
        log.write(msg + "\n")

    say("waiting for the live desktop and the Welcome window")
    # The probe put the desktop at 120s and stable by 180s. Waiting longer costs
    # nothing; starting early types into a tty that is still booting.
    mon.wait_for_stable("live-desktop", seconds=200, settle=20)

    say("opening the installer: the Welcome window's first button")
    mon.shot("before-start")
    # Alt+F2 would be a shell shortcut; the Welcome window's button is reachable
    # by Tab. Escape first, so any focus the window manager gave the desktop is
    # dropped and the Tab order starts at the window's first control.
    mon.key("esc")
    time.sleep(1)
    mon.key("tab")
    time.sleep(0.5)
    mon.key("ret")
    mon.wait_for_stable("after-start", seconds=90, settle=15)

    say("does Calamares own the screen now?")
    mon.shot("calamares-first-page")

    # Everything past this point is unknown until a screenshot says otherwise, so
    # the driver stops here and hands over: the next round is written against what
    # the last picture shows, not against a guess about page order.
    say("stopping here on purpose: the screenshots say what page Calamares is on")
    say("the disk is left running so the run can be inspected")
    mon.send("quit")
    mon.sock.close()
    log.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
