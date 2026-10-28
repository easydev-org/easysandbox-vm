"""Walk MX's graphical installer with OCR and the pointer.

    drive-mx.py <qmp.socket> <workdir>

WHAT THIS IS DRIVING

MX's live desktop opens a "MX Welcome" window; the first card in it, "Install MX
Linux", starts the installer. A probe of this exact image captured that window at
1280x800 - four screenshots, 537 KB each - so the layout below is measured, not
guessed:

    MX Welcome  MX-25.3 "Infinity"
    [About this system] [Manual] [About]
    User demo, password: demo. Superuser root, password: root.

    Install MX Linux | FAQ
    Forums           | Users Manual
    ...

THE LOOP, AND WHY IT LOOKS LIKE THIS

Every step reads the screen, and the pane's text is remembered. If two consecutive
steps read the same thing, the run is stuck - dockur-macos records what that costs
without: it clicked the word "later" inside a sentence for nineteen consecutive
steps, and every log line looked like progress.

There is also a hard stop. A step limit turns "it is doing something" into "it has
done sixty things", which is a number this project can act on.
"""

import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from ocr import Screen, find_button  # noqa: E402

W, H = 1280, 800

# Labels that only ever appear on controls.
#
# The rule from dockur-macos: a word that also appears in body copy gets clicked as
# if it were a button. "Continue" is safe on an installer's pages; "Install" is safe
# on the welcome window because it is a card title, not prose.
WELCOME = ("install mx linux", "install", "installer")
INSTALLER_FORWARD = ("next", "continue", "forward")
INSTALLER_AGREE = ("agree", "accept", "i agree")
INSTALLER_FINISH = ("finish", "close", "done", "reboot now", "restart now")
INSTALLER_SKIP = ("skip", "not now", "later")
ALL = (WELCOME + INSTALLER_FORWARD + INSTALLER_AGREE + INSTALLER_FINISH
       + INSTALLER_SKIP + ("ok", "yes", "begin", "start"))

# Where the forward control sits on the pages that have one. Measured on the MX
# Welcome window's card grid; the installer's own pages are handled by OCR, so this
# is only the fallback for a pane whose label could not be read.
PRIMARY = (964, 206)


def main():
    qmp_socket, workdir = sys.argv[1], sys.argv[2]
    log_path = os.path.join(workdir, "drive.log")

    def log(msg):
        line = "[drive %s] %s" % (time.strftime("%H:%M:%S"), msg)
        print(line, flush=True)
        with open(log_path, "a") as fh:
            fh.write(line + "\n")

    screen = Screen(qmp_socket, workdir=workdir, width=W, height=H)
    log("qmp connected")

    # The desktop appears a few seconds after login; OCR on a half-drawn frame
    # returns half the words.
    time.sleep(20)

    previous = None
    stuck = 0

    for step in range(1, 61):
        ppm = screen.grab("s%02d" % step)
        words = screen.text(ppm)
        joined = " ".join(w[0] for w in words)
        signature = joined[:70]
        log("step %d: %s" % (step, signature or "(nothing readable)"))

        if signature and signature == previous:
            stuck += 1
            log("step %d: same pane as last step (%d in a row)" % (step, stuck))
            if stuck >= 4:
                log("step %d: STUCK for %d steps - stopping" % (step, stuck))
                break
        else:
            stuck = 0
        previous = signature

        low = joined.lower()

        # A dialog with only [OK] on it blocks everything behind it. Press it before
        # anything else is considered - an "Invalid settings" style message looks
        # like a pane whose forward button is missing.
        if not words:
            log("step %d: nothing readable; pressing Return" % step)
            screen.key("ret")
            time.sleep(6)
            continue

        target, label = find_button(words, ALL, PRIMARY, height=H)
        if target is None:
            log("step %d: no control found; pressing Return" % step)
            screen.key("ret")
            time.sleep(6)
            continue

        log("step %d: clicking %r at %s" % (step, label, target))
        screen.click(*target)
        time.sleep(6)

        # The welcome window is gone once the installer owns the screen, and the
        # installer's own pages say so with their titles.
        ppm2 = screen.grab("s%02d-after" % step)
        after = " ".join(w[0] for w in screen.text(ppm2))[:70]
        log("step %d: now at %s" % (step, after or "(nothing readable)"))

        if any(k in after.lower() for k in
               ("partition", "install", "summary", "user", "location",
                "keyboard", "timezone", "filesystem", "mount")):
            log("step %d: the installer is showing its own pages" % step)

    screen.close()
    log("driver finished")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
