"""Run gilyon's 65C816 and SPC700 test ROMs and read their verdicts.

The ROM works through 1610 tests of the instruction set: every opcode
except STP and WAI, in every addressing mode it has, with the awkward
cases picked deliberately -- wrapping at the edge of a bank, at the edge
of the direct page, and in emulation mode where several instructions stop
behaving like the 6502 ones they resemble.  When one fails it stops and
prints the number, and the descriptions its own generator writes say what
that test did and what it expected.

It sat in the library for a long time being recorded as "flat", because a
batch run that presses no buttons never sees past its first screen and a
screen of white text on black is two colours.  It had been failing at
test 27 the whole time.

The screen is read rather than a hash of it compared: the ROM's tile
numbers are ASCII, so the tilemap is the text.

    python tools/cputest.py [rom]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.romarg import ROMS
from snes.system import System

ROOT = ROMS + "/testroms/higan/gilyon"
DEFAULT_ROMS = [os.path.join(ROOT, "cputest.sfc"), os.path.join(ROOT, "spctest.sfc")]
FRAMES = 4000


def screen_lines(machine):
    """The picture as text.  Tile number is character code in this ROM."""
    vram = bytes(machine.ppu.vram_bytes)
    out = []
    for row in range(28):
        line = "".join(
            chr(vram[(row * 32 + col) * 2])
            if 32 <= vram[(row * 32 + col) * 2] < 127 else " "
            for col in range(32))
        out.append(line.rstrip())
    return out


def verdict(rom):
    """(ok, the lines it printed) for one ROM."""
    machine = System(rom)
    for _ in range(FRAMES):
        machine.run_frame()
    lines = [l for l in screen_lines(machine) if l.strip()]
    text = " ".join(lines)
    if "Success" in text:
        return True, lines
    return False, lines


def main():
    roms = sys.argv[1:] or DEFAULT_ROMS
    bad = 0
    for rom in roms:
        name = os.path.basename(rom)
        if not os.path.exists(rom):
            print("  %-14s is not here" % name)
            bad += 1
            continue
        ok, lines = verdict(rom)
        print("  %-14s %s" % (name, "ok" if ok else "FAILED"))
        for line in lines:
            print("      %s" % line)
        if not ok:
            bad += 1
    print()
    if bad:
        # The number on screen is hex, and so are the numbers in the
        # tests.txt each ROM's generator writes, so it looks up as printed.
        print("%d of %d report a failure -- look the number up in the "
              "tests.txt that ROM's generator writes" % (bad, len(roms)))
        return 1
    print("every test in both ROMs passes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
