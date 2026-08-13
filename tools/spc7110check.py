"""Run the SPC7110 check program that Momotarou Dentetsu Happy carries.

The cartridge has a hardware self-test in its own ROM -- SPC7110 CHECK
PROGRAM V3.0 -- and the game's boot code runs it whenever the save RAM does
not hold the string "SPC7110 CHECK OK".  It was written by the people who
made the chip, against the chip, which puts it a long way above anything
written here: it is the only thing on this machine that can say the SPC7110
emulation is *wrong* rather than merely unchanged.

It has two modes, chosen at its prompt:

  A   mode 1, nine tests of the chip: REG.INIT, S-RAM DATA BUS, S-RAM ADDR
      BUS, S-RAM R/W, D-PORT ACC, MUL, DIV, C-LENGTH, D-PORT B+o+s
  B   mode 2, S-RAM BACKUP: the battery RAM has to read $ff before it has
      been written, which is what an undriven RAM does and what a cartridge
      that has just been made contains

Each test writes a byte into a table in work RAM -- zero for pass -- and the
program reads that table back to decide whether to write the signature.  This
reads the same table, so the verdict here is the cartridge's own and not a
guess made from the pixels.

    python tools/spc7110check.py [rom]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.romarg import from_argv
from snes.system import System, BUTTONS

# Where the check program keeps its results: a count, then one byte per test.
COUNT_ADDR = 0x7E8AE6
# The signature goes at the top of the save RAM.  It is read out of the RAM
# itself rather than through the window at $6000, because the check program
# closes that window ($4830 bit 7) before it finishes.
SIGNATURE_OFFSET = 0x1FF0
SIGNATURE = b"SPC7110 CHECK OK"

PROMPT_FRAMES = 400                   # by here it is waiting for a button
RUN_FRAMES = 4000                     # by here it has printed COMPLETE


def run_mode(rom, button):
    machine = System(rom_data=rom)
    if machine.bus.board.name != "SPC7110":
        raise SystemExit("this cartridge has no SPC7110 on it (board: %s)"
                         % machine.bus.board.name)
    for _ in range(PROMPT_FRAMES):
        machine.run_frame()
    machine.set_pad(0, BUTTONS[button])
    for _ in range(20):
        machine.run_frame()
    machine.set_pad(0, 0)
    for _ in range(RUN_FRAMES):
        machine.run_frame()
    return machine


def verdict(machine):
    """The program's own pass/fail: every slot in the table has to be zero."""
    count = machine.bus.read(COUNT_ADDR)
    slots = [machine.bus.read(COUNT_ADDR + 1 + i) for i in range(max(count - 1, 0))]
    return count, slots


def report(name, machine):
    count, slots = verdict(machine)
    bad = [(i, v) for i, v in enumerate(slots) if v]
    print("%-16s %d tests, %s" % (name, len(slots),
                                  "all OK" if not bad else "FAILED"))
    for i, v in bad:
        print("    test %d reported $%02X" % (i + 1, v))
    return not bad and len(slots) > 0


def main():
    rom = open(from_argv(), "rb").read()

    ok = True
    machine = run_mode(rom, "A")
    ok &= report("mode 1", machine)

    machine = run_mode(rom, "B")
    ok &= report("mode 2", machine)

    # Passing is what makes the program write the signature the game's boot
    # code looks for, so the signature is the end-to-end check.
    written = bytes(machine.cart.sram_data[
        SIGNATURE_OFFSET:SIGNATURE_OFFSET + len(SIGNATURE)])
    if written == SIGNATURE:
        print("signature       written: %r" % written.decode("ascii"))
    else:
        print("signature       NOT written (%r)" % written)
        ok = False

    print()
    print("the cartridge's own check program %s" % ("passes" if ok else "FAILS"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
