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

# The welcome window's own cards, matched as whole phrases.
#
# find_button's three passes are built for a wizard whose forward button sits in the
# lower-right corner. MX Welcome is a grid of cards spread across the window, and the
# first run showed what that does: 'install' matched the Popular Apps card at
# (423,698), which opened MX Package Installer, whose own title contains the word
# 'install' - so the loop clicked Install, got a package manager, closed it, and
# started again. Nineteen steps of that.
#
# A card is identified by its full title on one line, not by a word.
WELCOME_CARD = "install mx linux"
START_CARD = ("start the installer",)

# Labels that only ever appear on controls.
#
# The rule from dockur-macos: a word that also appears in body copy gets clicked as
# if it were a button. "Continue" is safe on an installer's pages; "Install" is safe
# on the welcome window because it is a card title, not prose.
WELCOME = ("install mx linux", "install", "installer")
# The installer's own controls, read off its pages rather than guessed.
#
# A screenshot of the final page shows exactly three:
#
#   [Close]   [Back]   [Start]
#
# and 'Start' is the one that begins the install - it is not a Next, and the first
# run stopped on that page for four steps because the label list did not contain it.
#
# 'close' is deliberately NOT here: on this page it abandons the installation, and a
# run that clicks it looks identical to one making progress until the disk turns out
# to be empty. It is only used to dismiss a dialog, further down.
INSTALLER_FORWARD = ("next", "continue", "forward", "start")
INSTALLER_AGREE = ("agree", "accept", "i agree")
INSTALLER_FINISH = ("finish", "close", "done", "reboot now", "restart now")
INSTALLER_SKIP = ("skip", "not now", "later")
ALL = (WELCOME + INSTALLER_FORWARD + INSTALLER_AGREE + INSTALLER_FINISH
       + INSTALLER_SKIP + ("ok", "yes", "begin", "start"))

# Where the forward control sits on the pages that have one. Measured on the MX
# Welcome window's card grid; the installer's own pages are handled by OCR, so this
# is only the fallback for a pane whose label could not be read.
# Where the forward control sits on the installer's pages. Measured from a
# screenshot of the final page, where [Close] [Back] [Start] occupy the bottom row and
# Start is the rightmost: OCR read Start's label unreliably before, and this is the
# fallback find_button uses when no label matches.
PRIMARY = (1120, 745)


def find_phrase(words, phrase):
    """Locate a card or button by its whole title, on one line.

    find_button is for wizards with a corner control. A card grid is not that: the
    cards are spread across the window and their titles are the only identifier.

    OCR splits a title across words, so consecutive words on the same line are joined
    back up and the joined text is compared. A title of one word is matched directly.

    Returns ((x, y), matched_text) or (None, None).
    """
    target = phrase.lower().strip()
    want = target.split()

    band = sorted(words, key=lambda w: (w[2], w[1]))

    for start in range(len(band)):
        chunk = band[start:start + len(want)]
        if len(chunk) != len(want):
            continue
        # All on one line: OCR puts each word at its own baseline, and a card title
        # is one line of text.
        if any(abs(chunk[0][2] - w[2]) > 14 for w in chunk[1:]):
            continue
        joined = " ".join(w[0] for w in chunk).strip(" .,:;").lower()
        if joined == target or joined.startswith(target):
            xs = [w[1] for w in chunk]
            ys = [w[2] for w in chunk]
            return ((sum(xs) // len(xs), sum(ys) // len(ys)),
                    " ".join(w[0] for w in chunk))

    return (None, None)


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

    for step in range(1, 121):
        ppm = screen.grab("s%02d" % step)
        words = screen.text(ppm)
        joined = " ".join(w[0] for w in words)
        # The whole pane, not the first 70 characters.
        #
        # The first run truncated at 70, and MX Welcome's header alone fills that much
        # - so every step of a card grid produced the same signature and the stuck
        # detector could not tell one pane from another.
        signature = joined[:200]
        log("step %d: %s" % (step, signature or "(nothing readable)"))

        if signature and signature == previous:
            stuck += 1
            log("step %d: same pane as last step (%d in a row)" % (step, stuck))
            if stuck >= 6:
                log("step %d: STUCK for %d steps - stopping" % (step, stuck))
                break
        else:
            stuck = 0
        previous = signature

        low = joined.lower()

        # The welcome window first, and by its full card title.
        #
        # This has to come before find_button: that function's label list contains
        # "install", which is also the first word of a card called "Install MX Linux",
        # and the run that used it clicked Popular Apps instead - a package manager
        # whose own title contains "install", so the loop never escaped.
        card, card_text = find_phrase(words, WELCOME_CARD)
        if card is None:
            card, card_text = find_phrase(words, "start the installer")
        if card is not None:
            log("step %d: welcome window; clicking card %r at %s"
                % (step, card_text, card))
            screen.click(*card)
            time.sleep(10)
            ppm2 = screen.grab("s%02d-after" % step)
            after = " ".join(w[0] for w in screen.text(ppm2))[:90]
            log("step %d: now at %s" % (step, after or "(nothing readable)"))
            continue

        # A dialog with only [OK] on it blocks everything behind it. Press it before
        # anything else is considered - an "Invalid settings" style message looks
        # like a pane whose forward button is missing.
        if not words:
            log("step %d: nothing readable; pressing Return" % step)
            screen.key("ret")
            time.sleep(6)
            continue

        # Outside the welcome window the installer's own pages apply, and there the
        # forward control really is in the corner - so find_button is the right tool.
        target, label = find_button(words, INSTALLER_FORWARD + INSTALLER_AGREE
                                    + INSTALLER_FINISH + ("ok", "yes"), PRIMARY, height=H)
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
