"""Drive byuu's SNES Test Programs and write down what they measure.

There are ten of these in the library -- DMA, HDMA, IRQ, NMI, OAM,
offset-per-tile, dot timing, VRAM and VRAM timing -- and every one of them
measures the console's own behaviour and prints numbers.  They are not
pass/fail tests and no expected values ship with them, so nothing here
can say whether the numbers are right.

What can be done is to record them.  These are exactly the readings that
a reference emulator would produce differently if this one were wrong, so
a table of ours, taken deliberately and kept, turns "we have no reference"
from a permanent excuse into a job that takes an afternoon the day one
arrives: run the same ROMs there, diff the tables, and every difference is
a located defect.

The readings are ours and unverified.  That is written at the top of the
file this produces, because a number in a repository acquires authority it
has not earned unless something says otherwise.

    python tools/snestest.py [--write]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.system import System
from tools.cputest import screen_lines

DIR = ("/home/moto/Projects/rom/testroms/higan/jonasquinn-test-roms/"
       "snestest_082506")
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "docs", "snestest-readings.txt")

ROMS = ["test_dma.smc", "test_dot_timing.smc", "test_hdma.smc", "test_irq.smc",
        "test_nmi.smc", "test_oam.smc", "test_opt.smc", "test_vram.smc",
        "test_vram_timing.smc"]

# Every button in turn: these programs put their measurements behind a menu
# and there is no telling which key each one wants.
BUTTONS = [0x1000, 0x80, 0x8000, 0x40, 0x4000, 0x20, 0x10, 0x2000]


def readings(path):
    machine = System(path)
    for _ in range(300):
        machine.run_frame()
    for button in BUTTONS:
        machine.set_pad(0, button)
        for _ in range(10):
            machine.run_frame()
        machine.set_pad(0, 0)
        for _ in range(60):
            machine.run_frame()
    return [l for l in screen_lines(machine) if l.strip()]


def main():
    write = "--write" in sys.argv
    lines = ["These are this emulator's own readings of byuu's SNES Test",
             "Programs.  They are NOT verified against anything: no expected",
             "values ship with these ROMs and there is no reference emulator",
             "on this machine.  They are recorded so that the day there is",
             "one, the same ROMs can be run there and the tables diffed --",
             "every difference being a located defect rather than a suspicion.",
             ""]
    for name in ROMS:
        path = os.path.join(DIR, name)
        if not os.path.exists(path):
            lines.append("%s -- not here" % name)
            continue
        try:
            got = readings(path)
        except Exception as exc:
            lines.append("%s -- would not run: %s" % (name, exc))
            continue
        lines.append("== %s" % name)
        if not got:
            # Its tile numbers are not character codes, so the screen cannot
            # be turned into text here.  That is not the same as it having
            # nothing to say, and must not be filed as though it were.
            lines.append("   screen could not be read as text")
        lines.extend("   " + l for l in got)
        lines.append("")
        print("  %-22s %d lines" % (name, len(got)))

    if write:
        with open(OUT, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        print("\nwritten to %s" % os.path.relpath(OUT))
    else:
        print("\npass --write to record them")
    return 0


if __name__ == "__main__":
    sys.exit(main())
