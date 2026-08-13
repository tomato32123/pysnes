"""The SPC7110: the multiplier, the divider, the data port, and the decompressor.

Four devices share the chip, and three of them can be tested the way a game
uses them -- write the operands, read the result -- from an ordinary test
cartridge whose header says an SPC7110 is on the board.

The fourth, the decompressor, cannot: it needs compressed data, and nothing
that could be written here would prove anything, because the same
understanding would have produced both the packer and the unpacker.  What is
checked instead is the probability ladder it runs on, which is transcribed
hardware design data and so can only be wrong by a typo.

The real verification for this chip is elsewhere and is much better than
anything in this file: Momotarou Dentetsu Happy carries an SPC7110 CHECK
PROGRAM in its own ROM, written by the people who made the chip, and it
reports OK on every one of its nine tests.  `tools/spc7110check.py` runs it.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.testrom import assemble_image, WRAM_BASE, RESULT_ADDR, DONE_ADDR
from snes.system import System
from snes import spc7110

SPC7110_CHIPSET = 0xF5
IMAGE = 0x300000                     # 3 MB: 1 MB program, 2 MB data
FAILURES = []


def build(source, data_rom=b"", data_at=0):
    """A HiROM cartridge with an SPC7110 on it.

    The image is a program megabyte followed by the data ROM, which is the
    wiring of every SPC7110 board: the console addresses the first and can
    only reach the second through the chip.
    """
    image, _labels = assemble_image(source, chipset=SPC7110_CHIPSET)
    rom = bytearray(b"\x00" * IMAGE)
    # This is a HiROM board: bank $00's $8000-$ffff is the image's second
    # 32 KB, not its first.  Putting the assembled bank there also puts the
    # header at $ffc0 and the vectors at $ffe0, where the loader looks.
    rom[0x8000:0x8000 + len(image)] = image
    rom[0x100000 + data_at:0x100000 + data_at + len(data_rom)] = data_rom
    return bytes(rom)


def run(source, data_rom=b"", max_frames=30):
    machine = System(rom_data=build(source, data_rom))
    if machine.bus.board.name != "SPC7110":
        raise AssertionError("board is %s" % machine.bus.board.name)
    for _ in range(max_frames):
        machine.run_frame()
        if machine.bus.read(WRAM_BASE + DONE_ADDR):
            break
    else:
        raise AssertionError("the program never finished")
    return machine


def result(machine, index, n=1):
    v = 0
    for i in range(n):
        v |= machine.bus.read(WRAM_BASE + RESULT_ADDR + index + i) << (8 * i)
    return v


def check(name, got, want):
    if got != want:
        FAILURES.append("%s: got $%X, want $%X" % (name, got, want))


def test_the_multiplier():
    """$4820/$4821 times $4824/$4825, and writing the multiplier's high half
    is what starts it.  Signed and unsigned are the same registers with
    $482e's low bit deciding, which is the part a game can get wrong."""
    machine = run("""
        sep #$20
        stz $482e                       ; unsigned
        lda #$34
        sta $4820
        lda #$12                        ; multiplicand $1234
        sta $4821
        lda #$78
        sta $4824
        lda #$56                        ; multiplier $5678 -- and go
        sta $4825
        lda $4828
        sta result+0
        lda $4829
        sta result+1
        lda $482a
        sta result+2
        lda $482b
        sta result+3

        lda #$01
        sta $482e                       ; signed
        lda #$ff
        sta $4820
        lda #$ff                        ; -1
        sta $4821
        lda #$00
        sta $4824
        lda #$80                        ; -32768
        sta $4825
        lda $4828
        sta result+4
        lda $4829
        sta result+5
        lda $482a
        sta result+6
        lda $482b
        sta result+7
    """)
    check("$1234 * $5678", result(machine, 0, 4), 0x1234 * 0x5678)
    check("-1 * -32768", result(machine, 4, 4), 32768)


def test_the_divider():
    """A 32-bit dividend over a 16-bit divisor, quotient in $4828-$482b and
    remainder in $482c/$482d.  Dividing by zero is not defined anywhere, so
    what the chip does with it -- quotient zero, dividend left in the
    remainder -- is behaviour rather than arithmetic."""
    machine = run("""
        sep #$20
        stz $482e
        lda #$e8
        sta $4820
        lda #$03
        sta $4821
        lda #$00
        sta $4822
        sta $4823                       ; dividend 1000
        lda #$07
        sta $4826
        lda #$00
        sta $4827                       ; divisor 7 -- and go
        lda $4828
        sta result+0
        lda $4829
        sta result+1
        lda $482c
        sta result+2
        lda $482d
        sta result+3

        lda #$22
        sta $4820
        lda #$11
        sta $4821
        stz $4822
        stz $4823                       ; dividend $1122
        stz $4826
        stz $4827                       ; divisor 0
        lda $4828
        sta result+4
        lda $482c
        sta result+5
        lda $482d
        sta result+6
    """)
    check("1000 / 7", result(machine, 0, 2), 1000 // 7)
    check("1000 %% 7", result(machine, 2, 2), 1000 % 7)
    check("quotient of x/0", result(machine, 4), 0)
    check("remainder of x/0", result(machine, 5, 2), 0x1122)


def test_the_data_port_walks_the_data_rom():
    """$4811-$4813 are a cursor into the data ROM and $4810 reads through it,
    stepping on every read.  This is how a game reads a table the console
    cannot address at all."""
    data = bytes(range(0x10))
    machine = run("""
        sep #$20
        lda #$01
        sta $4834                       ; a 2 MB data ROM
        stz $4818                       ; step by one, no adjustment
        stz $4811
        stz $4812
        stz $4813                       ; cursor at the start -- this reads
        lda $4810
        sta result+0
        lda $4810
        sta result+1
        lda $4810
        sta result+2
        lda $4810
        sta result+3
    """, data_rom=data)
    for i in range(4):
        check("data port byte %d" % i, result(machine, i), data[i])


def test_the_window_registers_choose_a_megabyte():
    """$4831-$4833 say which megabyte of the data ROM each quarter of the
    address space shows.  Momotarou Dentetsu Happy has 2 MB of data and the
    console has room for one, so this is the only way it reaches the rest."""
    data = bytearray(0x200000)
    data[0x000000] = 0xA0                # megabyte 0
    data[0x100000] = 0xA1                # megabyte 1
    machine = run("""
        sep #$20
        lda #$01
        sta $4834                       ; 2 MB
        lda #$00
        sta $4831
        lda $d00000
        sta result+0
        lda #$01
        sta $4831                       ; the same address, the other megabyte
        lda $d00000
        sta result+1
    """, data_rom=bytes(data))
    check("window showing megabyte 0", result(machine, 0), 0xA0)
    check("window showing megabyte 1", result(machine, 1), 0xA1)


def test_the_probability_ladder_is_a_ladder():
    """The 53 states are transcribed, so the failure to look for is a typo.

    Every state names a next state on each symbol, and the probability of the
    more probable symbol never rises as a context climbs: a run of agreement
    can only make the coder more confident, never less.  Disagreement moves
    the other way, back down the ladder.  A transposed pair breaks one or the
    other.

    The three states whose two successors are the same state are the entry to
    a ladder rather than a rung of one, and neither rule applies to them.
    """
    ladder = spc7110.tables()
    if len(ladder) != 53:
        FAILURES.append("the ladder has %d states, want 53" % len(ladder))
        return
    for i, (prob, mps, lps) in enumerate(ladder):
        if not 0 < prob <= 0x5A:
            FAILURES.append("state %d: probability $%02X is out of range" % (i, prob))
        if not 0 <= mps < 53 or not 0 <= lps < 53:
            FAILURES.append("state %d: next states %d/%d are out of range"
                            % (i, mps, lps))
            continue
        if mps == lps:
            continue                     # the entry to a ladder
        # Agreement moves towards certainty; disagreement moves away from it.
        if ladder[mps][0] > prob:
            FAILURES.append("state %d: agreeing raises the probability, $%02X -> $%02X"
                            % (i, prob, ladder[mps][0]))
        if ladder[lps][0] < prob:
            FAILURES.append("state %d: disagreeing lowers the probability, $%02X -> $%02X"
                            % (i, prob, ladder[lps][0]))


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in tests:
        before = len(FAILURES)
        try:
            fn()
        except Exception as exc:
            FAILURES.append("%s raised %s: %s" % (fn.__name__, type(exc).__name__, exc))
        print("  %-52s %s" % (fn.__name__, "ok" if len(FAILURES) == before else "FAIL"))
    print()
    if FAILURES:
        print("%d failure(s):" % len(FAILURES))
        for f in FAILURES:
            print("  " + f)
        return 1
    print("all SPC7110 tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
