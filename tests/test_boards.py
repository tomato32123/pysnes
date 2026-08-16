"""Which chip the loader decides is on a cartridge.

`snes/boards.py` is seventy lines of pure decision and nothing named it in a
test.  Getting it wrong is silent: the console comes up around the wrong
board, and a game either misbehaves in a way nobody traces back here or --
worse -- looks fine because the chip it wanted is barely used at the start.

The awkward part is the $Fx chipset byte, which says only "something
unusual" and is shared by four chips; $FFBF picks between them.  The
comment in that file records which real cartridges carry which subtype, and
that knowledge is worth pinning down rather than leaving in a comment: the
$F6 pair is the case that matters, because the chipset byte alone would call
both of them SPC7110 and one of them is an ST01x.

These use real headers where the library has them and a forged one
otherwise, so the file's logic is checked on this machine either way.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes import boards
from tools.romarg import find_named

FAILURES = []


def check(name, got, want):
    if got != want:
        FAILURES.append("%s: got %r, want %r" % (name, got, want))


class FakeCart(object):
    """Just enough of a cartridge for the decision under test."""

    def __init__(self, chipset, subtype=None):
        self.coprocessor = chipset
        self.header_offset = 0
        self.rom_data = bytearray(64)
        if subtype is not None:
            self.rom_data[0x0F] = subtype


def main():
    # The plain cases: the chipset byte alone decides.
    check("no coprocessor", boards.coprocessor(FakeCart(0x00)), None)
    check("SA-1", boards.coprocessor(FakeCart(0x35)), "SA-1")
    check("SuperFX", boards.coprocessor(FakeCart(0x13)), "SuperFX")
    check("DSP", boards.coprocessor(FakeCart(0x03)), "DSP")
    check("OBC1", boards.coprocessor(FakeCart(0x25)), "OBC1")

    # $Fx: the chipset byte is not enough and $FFBF settles it.  Both of
    # these are $F6, which CHIPSET alone does not even list.
    check("$F6 with subtype $00 is an SPC7110",
          boards.coprocessor(FakeCart(0xF6, 0x00)), "SPC7110")
    check("$F6 with subtype $01 is an ST01x",
          boards.coprocessor(FakeCart(0xF6, 0x01)), "ST01x")
    check("$F3 with subtype $10 is a CX4",
          boards.coprocessor(FakeCart(0xF3, 0x10)), "CX4")
    check("$F9 with subtype $00 is an SPC7110",
          boards.coprocessor(FakeCart(0xF9, 0x00)), "SPC7110")

    # An $Fx byte whose subtype means nothing falls back to the table, which
    # is how $F3 alone still reads as a CX4.
    check("$F3 with an unknown subtype falls back",
          boards.coprocessor(FakeCart(0xF3, 0x7F)), "CX4")

    # And the real cartridges, where this machine has them.  These are the
    # ones the comment in boards.py was written from.
    from snes.cart import Cart
    real = [("Rockman_X_2_(J).smc", "CX4"),
            ("Momotarou Dentetsu Happy (Japan).sfc", "SPC7110"),
            ("Tengai Makyou Zero (Japan).sfc", "SPC7110"),
            ("Exhaust Heat II - F1 Driver e no Michi (Japan).sfc", "ST01x"),
            ("Hayazashi Nidan Morita Shougi (Japan).sfc", "ST01x"),
            ("Star_Fox_1.2_Super_FX_21_MHz_Mode_v1.4.sfc", "SuperFX"),
            ("Metal Combat - Falcon's Revenge (USA).sfc", "OBC1")]
    seen = 0
    for name, want in real:
        path = find_named(name)
        if path is None:
            continue
        seen += 1
        with open(path, "rb") as fh:
            cart = Cart(path, fh.read())
        check("%s" % name[:40], boards.coprocessor(cart), want)
    print("  %d of %d named cartridges were on this machine" % (seen, len(real)))

    print()
    if FAILURES:
        print("%d failure(s):" % len(FAILURES))
        for line in FAILURES:
            print("  " + line)
        return 1
    print("all board-selection tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
