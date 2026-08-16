"""Check how long after a DMA an interrupt waits, against documented hardware.

`dma_irq_test` by Sour (the author of Mesen-S) arms an H/V IRQ, starts a
manual DMA through $420B, and then runs a row of instructions.  What it
reports is how many of them finished before the interrupt was taken.  Its
README carries the numbers a real console gives, which makes this one of the
very few things here that can say whether the emulator's *timing* is right
rather than its arithmetic.

The expected column below is transcribed from that README, not from anything
worked out here.

    python tools/dmairqtest.py [rom]
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.romarg import ROMS
from snes.system import System

DEFAULT_ROM = (ROMS + "/testroms/higan/Sour/SnesTests/"
               "dma_irq_test/dma_irq_test.sfc")

# From dma_irq_test/README.md.  $FFFF is the test's way of saying the
# interrupt never arrived, which is the right answer when it is masked.
EXPECTED = [
    ("IRQ - INC A", 0x0002),
    ("IRQ - LDA IMM8", 0x0002),
    ("IRQ - LDA16+INC", 0x0001),
    ("IRQ - INC+LDA16", 0x0002),
    ("IRQ - CLI+INC", 0x0001),
    # The README says $FFFF here and the built cartridge cannot print it.
    # Its own source zeroes the high byte of every result before writing the
    # low one, so no emulator and no console can produce $FFFF for this row;
    # what the cartridge shows is $00FF.  The README's changelog says the
    # tests were changed after it was written and these two lines were not.
    # Held as the value the cartridge actually reports, with the README's
    # claim recorded beside it, because a check that is permanently red is a
    # check people stop reading.
    ("IRQ - SEI+INC", 0x00FF, "README says $FFFF; the cartridge cannot print it"),
    ("IRQ - SEI+CLI+INC", 0x0001),
    ("NMI - INC A", 0x0002),
    ("NMI - LDA IMM16", 0x0001),
    ("NMI - CLI+INC", 0x0001),
    ("W16:IRQ - INC A", 0x0001),
    ("W16:IRQ - LDA IMM8", 0x0001),
    ("W16:IRQ - LDA16+INC", 0x0001),
    ("W16:IRQ - INC+LDA16", 0x0001),
]

FRAMES = 600


def screen_lines(machine):
    """The test's screen, read out of the tile map as text."""
    vram = bytes(machine.ppu.vram_bytes)
    dump = [l for l in machine.ppu.dump().splitlines() if "BG map" in l][0]
    base = int(re.search(r"'(0x[0-9a-f]+)'", dump).group(1), 16) * 2
    out = []
    for r in range(28):
        row = vram[base + r * 64: base + r * 64 + 64: 2]
        out.append("".join(chr(c) if 32 <= c < 127 else " " for c in row).rstrip())
    return out


def measured(machine):
    """{label: value} for every line that carries a hex result."""
    found = {}
    for line in screen_lines(machine):
        m = re.match(r"\s*(.+?)\s+\$([0-9A-F]{4})\s*$", line)
        if m:
            found[m.group(1).strip()] = int(m.group(2), 16)
    return found


def main():
    rom = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_ROM
    machine = System(rom)
    for _ in range(FRAMES):
        machine.run_frame()
    got = measured(machine)

    print("%-24s %8s %8s" % ("test", "hardware", "ours"))
    bad = 0
    for row in EXPECTED:
        label, want = row[0], row[1]
        note = row[2] if len(row) > 2 else None
        have = got.get(label)
        if have is None:
            print("  %-22s %8s %8s   not on screen" % (label, "$%04X" % want, "-"))
            bad += 1
            continue
        mark = "" if have == want else "   <-"
        if have != want:
            bad += 1
        print("  %-22s %8s %8s%s%s" % (label, "$%04X" % want, "$%04X" % have,
                                       mark, ("   (" + note + ")") if note else ""))

    print()
    print("%d of %d match the console" % (len(EXPECTED) - bad, len(EXPECTED)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
