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


def looks_like_calamares(png: Path) -> str:
    """Guess from the picture what a click did: 'calamares', 'console', 'welcome', 'unknown'.

    There is no way to ask the guest what is on screen - this bake has no serial
    console and no agent - so the picture has to answer. Two coarse signals are
    enough for the one decision that matters:

      * the mirror updater opens a terminal, which is nearly all one colour with a
        little text: high dominant share, low colour count;
      * Calamares is a sidebar plus a content area: many colours, no dominant one.

    Deliberately blunt. It is not identifying the page - only telling 'the
    installer opened' from 'a terminal opened' from 'nothing happened', and those
    are three different pictures.
    """
    ppm = png.with_suffix(".ppm")
    if not ppm.exists():
        return "unknown"
    try:
        data = ppm.read_bytes()
    except OSError:
        return "unknown"
    parts = data.split(b"\n", 3)
    if len(parts) < 4 or parts[0] != b"P6":
        return "unknown"
    try:
        w, h = (int(v) for v in parts[1].split())
    except ValueError:
        return "unknown"
    pixels = parts[3]
    total = w * h
    if total == 0 or len(pixels) < total * 3:
        return "unknown"

    counts: dict[bytes, int] = {}
    step = max(1, total // 60000)          # sample; counting a million is pointless
    seen = 0
    for i in range(0, total, step):
        px = pixels[i * 3:i * 3 + 3]
        counts[px] = counts.get(px, 0) + 1
        seen += 1
    if not seen:
        return "unknown"
    dominant = 100.0 * max(counts.values()) / seen
    distinct = len(counts)

    if dominant > 55 and distinct < 500:
        return "console"
    if distinct > 3000 and dominant < 40:
        return "calamares"
    return "welcome"


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
    # The buttons in the Welcome window's left column are 39 PIXELS APART:
    #
    #   Start the Installer                     467, 292
    #   Update Mirrors (Arch, reflector-simple) 467, 331
    #   Update Mirrors (Arch, rate-mirrors)     467, 371
    #
    # The last attempt clicked (474, 290) - two pixels off - and opened Update
    # Mirrors instead. The screenshot afterwards is a Konsole window ranking
    # mirrors and Calamares never started. So a coordinate alone is not enough:
    # the click has to be checked, and a wrong one retried.
    #
    # Tried from the top of the column upwards. A click that lands too low opens a
    # mirror updater, which is harmless and closes with Return; one that lands too
    # high hits nothing.
    started = False
    for y in (292, 275, 310):
        say(f"clicking (467,{y}) for Start the Installer")
        mon.click(467, y)
        time.sleep(8)
        png = mon.shot(f"after-click-{y}")
        verdict = looks_like_calamares(png)
        say(f"  verdict: {verdict}")
        if verdict == "calamares":
            started = True
            break
        if verdict == "console":
            say("  a terminal opened instead; closing it and trying the next spot")
            mon.key("ret")
            time.sleep(4)

    if not started:
        say("could not open Calamares by clicking; stopping so the screenshots can be read")
        mon.send("quit")
        mon.sock.close()
        log.close()
        return 1

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
