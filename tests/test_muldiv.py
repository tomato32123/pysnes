"""The multiply and divide unit, held here rather than only in a test ROM.

Jonas Quinn's mul_behavior found what was wrong with this and is the
better oracle, but it lives outside the repository and is not run by the
suite.  These pin the behaviours it established so that a change here
fails in a second rather than the next time someone remembers to run it.

Every expectation below is one that ROM asserts.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.testrom import run

FAILURES = []


def check(what, got, want, fmt="$%04X"):
    if got != want:
        FAILURES.append("%s: got %s, want %s" % (what, fmt % got, fmt % want))


def wram(machine, addr, n=2):
    b = machine.bus.peek_range(addr, n)
    return b[0] | (b[1] << 8) if n == 2 else b[0]


MULTIPLY = """
        sep #$20
        lda #$A3
        sta $4202               ; multiplicand
        lda #$81
        sta $4203               ; starts the multiply

        ; eight steps have to pass before the product is there; the reads
        ; below take longer than that between them.
        nop
        nop
        nop
        nop
        nop
        nop
        rep #$20
        lda $4216
        sta $7E0010             ; the product
        lda $4214
        sta $7E0012             ; what the division registers hold after it
        sep #$20
spin:   bra spin
"""


def test_the_product_appears_and_the_divide_registers_hold_the_operand():
    machine = run(MULTIPLY, max_frames=4).machine
    check("product of $A3 and $81", wram(machine, 0x7E0010), 0x5223)
    # One unit does both sums: after eight steps of shifting, the second
    # operand has moved down into the low byte of the division result.
    check("RDDIV after the multiply", wram(machine, 0x7E0012), 0x0081)


INTERRUPTED = """
        sep #$20
        lda #$A3
        sta $4202
        lda #$81
        sta $4203               ; starts the multiply
        lda #$00
        sta $4203               ; and this cuts it short
        nop
        nop
        nop
        nop
        rep #$20
        lda $4216
        sta $7E0010
        lda $4214
        sta $7E0012
        sep #$20
spin:   bra spin
"""


def test_a_write_during_a_multiply_clears_what_it_has_accumulated():
    """The value written is ignored and the run carries on, so what comes
    out is the second half of the sum on its own."""
    machine = run(INTERRUPTED, max_frames=4).machine
    got = wram(machine, 0x7E0010)
    if got == 0x5223:
        FAILURES.append("the write did not interrupt anything: still $5223")
    elif got == 0x0000:
        FAILURES.append("the run stopped instead of carrying on: $0000")
    # The operand registers are not disturbed by the ignored write.
    check("RDDIV is still the first operand", wram(machine, 0x7E0012), 0x0081)


DIVIDE = """
        sep #$20
        rep #$20
        lda #$1234
        sta $4204               ; dividend
        sep #$20
        lda #$07
        sta $4206               ; divisor, starts the divide
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        rep #$20
        lda $4214
        sta $7E0010             ; quotient
        lda $4216
        sta $7E0012             ; remainder
        sep #$20
spin:   bra spin
"""


def test_the_divide_still_works():
    machine = run(DIVIDE, max_frames=4).machine
    check("quotient of $1234 by 7", wram(machine, 0x7E0010), 0x1234 // 7)
    check("remainder", wram(machine, 0x7E0012), 0x1234 % 7)


def main():
    tests = [(n, f) for n, f in sorted(globals().items())
             if n.startswith("test_") and callable(f)]
    for name, fn in tests:
        before = len(FAILURES)
        fn()
        print("  %-62s %s" % (name, "ok" if len(FAILURES) == before else "FAIL"))
    print()
    if FAILURES:
        print("%d failure(s):" % len(FAILURES))
        for f in FAILURES:
            print("  " + f)
        return 1
    print("the multiply and divide unit behaves as the test ROM requires")
    return 0


if __name__ == "__main__":
    sys.exit(main())
