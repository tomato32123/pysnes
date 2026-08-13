"""Run gilyon's 65C816 test ROM and read its verdict off the screen.

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
from snes.system import System

DEFAULT_ROM = "/home/moto/Projects/rom/testroms/higan/gilyon/cputest.sfc"
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


def main():
    rom = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_ROM
    if not os.path.exists(rom):
        print("no ROM at %s" % rom)
        return 1
    machine = System(rom)
    for _ in range(FRAMES):
        machine.run_frame()

    lines = [l for l in screen_lines(machine) if l.strip()]
    for line in lines:
        print("  %s" % line)
    print()

    text = " ".join(lines)
    if "Success" in text:
        print("all 1610 tests pass")
        return 0
    if "Failed" in text:
        # The number is in hex, and so are the numbers in the tests.txt the
        # ROM's generator writes, so it can be looked up as printed.
        print("a test failed -- look its number up in the tests.txt that "
              "make_cpu_tests.py writes")
        return 1
    print("the ROM did not reach a verdict in %d frames" % FRAMES)
    return 1


if __name__ == "__main__":
    sys.exit(main())
