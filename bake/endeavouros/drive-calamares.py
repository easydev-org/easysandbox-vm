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

    def click(self, x: int, y: int):
        """Click at a framebuffer coordinate.

        The keyboard alone could not open Calamares: Escape, Tab, Return left the
        Welcome window exactly as it was, because whether Tab reaches its first
        button depends on which widget already holds focus and nothing on screen
        says. A coordinate does not depend on either.
        """
        self.send(f"mouse_move {x} {y}")
        time.sleep(0.3)
        self.send("mouse_button 1")
        time.sleep(0.2)
        self.send("mouse_button 0")
        time.sleep(0.5)

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
            # Tiny files are black screens, and a black screen is "stable" too -
            # which is how the first run typed Escape/Tab/Return at a GRUB menu it
            # could not see and then at a blank framebuffer, and reported success
            # with a 196 KiB disk. Anything under 40 KiB is not a desktop.
            if size and size == last and size > 40000:
                return png
            last = size
            time.sleep(settle)
        return png

    def wait_for_desktop(self, seconds: int = 260, settle: int = 15) -> Path:
        """Wait until the framebuffer has real content and stops changing.

        The probe showed GRUB at 640x480 drawing a static menu, then tty1, then
        the KDE desktop at about 120s. A static GRUB menu is as "stable" as a
        desktop, so file size alone cannot tell them apart - but a desktop
        screenshot is hundreds of kilobytes and a boot menu is a few.
        """
        deadline = time.time() + seconds
        last, last_size = None, 0
        while time.time() < deadline:
            png = self.shot("waiting-for-desktop")
            size = png.stat().st_size if png.exists() else 0
            if size > 40000 and last is not None and abs(size - last_size) < 2000:
                return png
            last, last_size = png, size
            time.sleep(settle)
        return last


def main() -> int:
    mon_path, workdir = sys.argv[1], Path(sys.argv[2])
    mon = Monitor(mon_path, workdir)
    log = open(workdir / "installer.log", "w", buffering=1)

    def say(msg: str):
        print(msg, flush=True)
        log.write(msg + "\n")

    say("waiting for the live desktop and the Welcome window")
    # The probe put GRUB at 60s and the desktop at 120s. The first run typed at a
    # GRUB menu because a static boot menu looks exactly as "stable" as a desktop,
    # so the wait is on size and steadiness together.
    mon.wait_for_desktop(seconds=280, settle=15)

    say("opening the installer: clicking 'Start the Installer'")
    mon.shot("before-start")
    # A coordinate, not Tab, and definitely not Escape.
    #
    # The first attempt sent Escape, Tab, Return. Escape closed the Welcome
    # window - that is what Escape means to a KDE dialog - and the following keys
    # landed on the bare desktop. The screenshot after it is the TITAN NOVA
    # wallpaper with no window at all.
    #
    # The framebuffer here is 640x480, not the 1280x800 every other bake gets:
    # EndeavourOS's live session does not set a larger mode. So the Welcome
    # window's left column - where "Start the Installer" is the first entry -
    # sits around x=200, y=230 on this screen.
    mon.click(int(sys.argv[3]) if len(sys.argv) > 3 else 200,
              int(sys.argv[4]) if len(sys.argv) > 4 else 230)
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
