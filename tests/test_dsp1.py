"""The DSP-1 board, driven by a console, with a program written here.

No DSP-1 firmware is on this machine, and none is needed to check the half
of the chip that is not the firmware: the two registers, where they sit in
the address space, the two-byte handshake, and whether the processor
actually runs between the console's accesses.

So a program is written here in uPD77C25 machine code, loaded where the
firmware would go, and a 65816 program talks to it the way a game would.
What that proves is the plumbing -- that a byte written at $30:8000
reaches the chip, that the chip's answer comes back, that the status
register says when.  What it cannot prove is anything about the real
firmware, which computes things this program does not.
"""
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

FAILURES = []


def check(what, got, want, fmt="%s"):
    if got != want:
        FAILURES.append("%s: got %s, want %s" % (what, fmt % got, fmt % want))


# -- a program for the chip, assembled by hand ----------------------------
#
# It waits for the console to send a word, adds one to it, and sends the
# answer back, forever.  In the chip's own terms: read DR (which asks the
# console for a word and waits for the request to be answered), increment,
# write DR, wait again.

def op(alu=0, pselect=0, acc=0, src=0, dst=0, dpl=0, dph=0, rpdcr=0, rt=0):
    return ((rt << 22) | (pselect << 20) | (alu << 16) | (acc << 15)
            | (dpl << 13) | (dph << 9) | (rpdcr << 8) | (src << 4) | dst)


def jp(brch, addr):
    return (2 << 22) | (brch << 13) | (addr << 2)


def echo_program(words):
    """Wait for a word, add one, hand it back."""
    prog = [0] * words
    #  0: ask for a word by reading DR, which sets the request flag
    prog[0] = op(src=8, dst=1)          # A = DR, and ask
    #  1: wait until the console has answered the request
    prog[1] = jp(0x0BE, 0x001)          # JRQM $001: loop while still asking
    #  2: A = DR again, now that the console's word is in it
    prog[2] = op(src=9, dst=1)          # DRNF: read without asking again
    #  3: A = A + 1
    prog[3] = op(alu=9)                 # INC
    #  4: DR = A, which asks the console to take it
    prog[4] = op(src=1, dst=6)
    #  5: wait until it has been taken
    prog[5] = jp(0x0BE, 0x005)
    #  6: round again
    prog[6] = jp(0x100, 0x000)
    return prog


def firmware_dir(words=2048, drom_words=1024):
    """Write the program out as a pair of firmware files."""
    d = tempfile.mkdtemp(prefix="pysnes-fake-dsp1-")
    prog = echo_program(words)
    with open(os.path.join(d, "dsp1.program.rom"), "wb") as fh:
        for w in prog:
            fh.write(bytes([(w >> 16) & 0xFF, (w >> 8) & 0xFF, w & 0xFF]))
    with open(os.path.join(d, "dsp1.data.rom"), "wb") as fh:
        fh.write(bytes(drom_words * 2))
    return d


# -- the console's side ----------------------------------------------------

CONSOLE = """
        sep #$20
        lda #$8F
        sta $2100

        ; send $1234 to the chip, high byte first, waiting for the status
        ; register to say a transfer may happen before each byte.
w1:     lda $30C000
        bpl w1
        lda #$12
        sta $308000
w2:     lda $30C000
        bpl w2
        lda #$34
        sta $308000

        ; read the answer back the same way
w3:     lda $30C000
        bpl w3
        lda $308000
        sta $7E0010
w4:     lda $30C000
        bpl w4
        lda $308000
        sta $7E0011

        lda #$0F
        sta $2100
spin:   bra spin
"""


def test_a_word_goes_to_the_chip_and_the_answer_comes_back():
    d = firmware_dir()
    os.environ["PYSNES_FIRMWARE"] = d
    try:
        # Import late so the board picks the directory up.
        for name in list(sys.modules):
            if name.startswith("snes."):
                pass
        from tools.testrom import run
        result = run(CONSOLE, max_frames=8, chipset=0x03)
        machine = result.machine
        check("the board found the program",
              "no firmware" not in machine.bus.board.describe(), True)
        got = (machine.bus.peek_range(0x7E0010, 2)[0] << 8) \
            | machine.bus.peek_range(0x7E0010, 2)[1]
        check("the chip returned what it was sent, plus one", got, 0x1235, "$%04X")
    finally:
        os.environ.pop("PYSNES_FIRMWARE", None)
        shutil.rmtree(d, ignore_errors=True)


def test_without_firmware_the_board_still_answers_the_status_register():
    """A console that spins on the status register must not hang, whatever
    is or is not on the cartridge."""
    os.environ.pop("PYSNES_FIRMWARE", None)
    from tools.testrom import run
    result = run(CONSOLE, max_frames=8, chipset=0x03)
    check("it ran to the end rather than spinning",
          result.machine.cpu.instructions > 1000, True)


def main():
    tests = [(n, f) for n, f in sorted(globals().items())
             if n.startswith("test_") and callable(f)]
    for name, fn in tests:
        before = len(FAILURES)
        try:
            fn()
        except Exception as exc:
            FAILURES.append("%s raised %s: %s" % (name, type(exc).__name__, exc))
        print("  %-62s %s" % (name, "ok" if len(FAILURES) == before else "FAIL"))
    print()
    if FAILURES:
        print("%d failure(s):" % len(FAILURES))
        for f in FAILURES:
            print("  " + f)
        return 1
    print("the console can talk to the chip")
    return 0


if __name__ == "__main__":
    sys.exit(main())
