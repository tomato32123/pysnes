"""Check when the colour-halve happens, against a measurement on a console.

Colour math on this machine can add two pixels and halve the result, and
the order of those two steps is visible only in the lowest bit: halving
after adding gives a result one level brighter than halving before, and
only when both inputs have their lowest bit set.

byuu measured which way a console does it, with a ROM written for the
purpose and a copier, and wrote the answer down beside it: the halve
happens *after* the add.  The ROM proves it by painting the screen with
two colours chosen so that the two orders disagree -- if halving came
first the whole screen would be one colour, and if it comes second the
screen is split.  Two captures ship with it, one for each outcome.

So this is a hardware oracle with an exact expected value, sitting in the
library unread until now.  What it checks is one line of arithmetic, and
that line is easy to write the wrong way round.

    python tools/colourmath.py [rom]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.system import System

DEFAULT_ROM = ("/home/moto/Projects/rom/testroms/higan/jonasquinn-test-roms/"
               "color_halve_proof/demo.smc")
FRAMES = 300

# From the capture that matches a console: the top of the screen is one
# level darker than the bottom, and these are the two values.
TOP = (0, 0, 57)
BOTTOM = (0, 0, 66)
SPLIT = 128


def pixel(machine, x, y):
    fb = machine.framebuffer
    i = (y * 512 + x * 2 + 1) * 4
    return (fb[i + 2], fb[i + 1], fb[i])


def main():
    rom = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_ROM
    if not os.path.exists(rom):
        print("no ROM at %s" % rom)
        return 1
    machine = System(rom)
    for _ in range(FRAMES):
        machine.run_frame()

    bad = 0
    for y, want, where in ((10, TOP, "above the split"),
                           (SPLIT - 1, TOP, "the last line above it"),
                           (SPLIT, BOTTOM, "the first line below it"),
                           (200, BOTTOM, "below the split")):
        got = pixel(machine, 128, y)
        ok = got == want
        if not ok:
            bad += 1
        print("  row %3d %-24s %s  %s" % (y, where, got, "ok" if ok else
                                          "want %s" % (want,)))
    print()
    if bad:
        print("the halve is not where the console puts it")
        return 1
    print("the halve happens after the add, as it does on a console")
    return 0


if __name__ == "__main__":
    sys.exit(main())
