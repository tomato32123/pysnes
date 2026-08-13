"""Read the screen of every test ROM here, and say which ones report failure.

Today a 65C816 test ROM was found in the library that had been printing
"Failed" at test 27 for months.  Nothing was wrong with the ROM or with
the way it was run -- it simply was never read.  The batch runner recorded
it as "flat", which is what white text on black looks like when you count
colours, and that was that.

So this reads them.  Every ROM under the test-ROM tree is booted, given a
button press in case it waits for one, and its screen is turned back into
text -- for the ROMs whose tile numbers are character codes, which is most
of the ones that print anything.  Any screen carrying a word that sounds
like a verdict is reported, failures first.

What it deliberately does not do is decide that silence is a pass.  A ROM
whose screen cannot be read as text is listed as unreadable, because "we
could not tell" and "it is fine" are different answers and only one of
them is honest.

    python tools/verdicts.py [dir]
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.system import System

DEFAULT_DIR = "/home/moto/Projects/rom/testroms"
FRAMES = 1200
PAD_A = 0x80
PAD_START = 0x1000

# Words a test ROM uses to say how it went.  The bad ones are checked first
# so that a screen saying both -- a results table with one NG in it -- is
# reported as a failure rather than as a pass.
BAD = re.compile(r"\b(FAIL(ED|URE)?|NG|ERROR|BAD|WRONG|MISMATCH)\b", re.I)
GOOD = re.compile(r"\b(PASS(ED)?|SUCCESS|ALL OK|OK|CORRECT|DONE|COMPLETE)\b", re.I)


def screen_text(machine):
    """The tilemap as text, for the ROMs whose tile numbers are ASCII.

    Returns None when the screen does not look like text -- too few
    printable characters to be a report, which is the honest answer for a
    ROM that draws a picture instead.
    """
    vram = bytes(machine.ppu.vram_bytes)
    lines = []
    printable = 0
    for row in range(28):
        chars = []
        for col in range(32):
            code = vram[(row * 32 + col) * 2]
            if 32 <= code < 127:
                chars.append(chr(code))
                if code != 32:
                    printable += 1
            else:
                chars.append(" ")
        lines.append("".join(chars).rstrip())
    if printable < 12:
        return None
    return [l for l in lines if l.strip()]


def look(path):
    machine = System(path)
    for i in range(FRAMES):
        # A ROM that waits for a button never says anything to a runner
        # that never presses one, which is exactly how today's went unread.
        if i == 400:
            machine.set_pad(0, PAD_A)
        elif i == 410:
            machine.set_pad(0, 0)
        elif i == 700:
            machine.set_pad(0, PAD_START)
        elif i == 710:
            machine.set_pad(0, 0)
        machine.run_frame()
    return screen_text(machine)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DIR
    roms = []
    for dirpath, _dirs, files in os.walk(root):
        for name in sorted(files):
            if name.lower().endswith((".smc", ".sfc", ".swc", ".fig")):
                roms.append(os.path.join(dirpath, name))
    roms.sort()

    failing, passing, quiet, broken = [], [], [], []
    for path in roms:
        name = os.path.relpath(path, root)
        try:
            lines = look(path)
        except Exception as exc:
            broken.append((name, "%s: %s" % (type(exc).__name__, exc)))
            continue
        if lines is None:
            quiet.append(name)
            continue
        text = " ".join(lines)
        if BAD.search(text):
            failing.append((name, lines))
        elif GOOD.search(text):
            passing.append((name, lines))
        else:
            quiet.append(name)

    if failing:
        print("== screens that report a failure ==")
        for name, lines in failing:
            print("  %s" % name)
            for line in lines[:8]:
                print("      %s" % line)
        print()
    print("== screens that report success ==")
    for name, lines in passing:
        print("  %-52s %s" % (name[:52], lines[0][:40]))
    print()
    print("%d report failure, %d report success, %d say nothing readable, "
          "%d would not run" % (len(failing), len(passing), len(quiet),
                                len(broken)))
    for name, why in broken:
        print("  would not run: %s -- %s" % (name, why))
    return 1 if failing else 0


if __name__ == "__main__":
    sys.exit(main())
