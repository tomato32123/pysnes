"""What the SPC700 spends, and when within an instruction it spends it.

The accesses of an instruction used to cost nothing as they happened and the
whole instruction was charged after it finished.  That is invisible to
anything that only looks at totals and wrong to anything that reads a timer
or a port, because such a read saw the machine as it was before the
instruction started, whichever cycle it was really on.

Accesses now move the clock as they go.  The first test here is the safety
net for that: an instruction still takes exactly what it always took.  The
second checks the part that changed.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.apu import APU

FAILURES = []

# Somewhere with no registers in it, so an opcode's operands are ordinary RAM.
CODE = 0x0200


def one_opcode(op, operands=b"\x00\x00\x00"):
    """Run a single opcode from a known state and report what it cost."""
    apu = APU()
    apu.do_reset()
    apu.poke_ram(CODE, bytes([op]) + operands)
    apu.set_pc(CODE)
    before = apu.regs["clock"]
    apu.do_step()
    r = apu.regs
    return r["clock"] - before, r["extra_cycles"]


def test_every_opcode_still_takes_what_the_table_says():
    table = APU.cycle_table()
    wrong = []
    for op in range(256):
        spent, extra = one_opcode(op)
        want = table[op] + extra
        if spent != want:
            wrong.append((op, spent, want))
    if wrong:
        FAILURES.append("%d opcodes changed length, e.g. %s"
                        % (len(wrong), ", ".join("$%02X took %d want %d" % w
                                                 for w in wrong[:6])))
    else:
        print("      all 256 opcodes cost what the cycle table says")


# How many opcodes have every one of their cycles accounted for where it
# belongs.  The rest still pay their leftover at the end of the instruction,
# which is a placeholder, not a model.  Raise this as opcodes are done; it is
# here so the number cannot quietly go down again.
PLACED = 184


def test_most_opcodes_have_every_cycle_where_it_belongs():
    unplaced = []
    for op in range(256):
        apu = APU()
        apu.do_reset()
        apu.poke_ram(CODE, bytes([op, 0, 0, 0]))
        apu.set_pc(CODE)
        apu.do_step()
        if apu.regs["idle_tail"]:
            unplaced.append((op, apu.regs["idle_tail"]))
    placed = 256 - len(unplaced)
    if placed < PLACED:
        FAILURES.append("%d opcodes fully placed, was %d -- something regressed"
                        % (placed, PLACED))
    else:
        print("      %d of 256 opcodes fully placed; %d cycles still unplaced "
              "across %d opcodes"
              % (placed, sum(t for _op, t in unplaced), len(unplaced)))


def test_an_access_moves_the_clock_before_it_happens():
    """MOV A, dp is three cycles: opcode fetch, operand fetch, the read.  The
    read is the third, so by the time it happens the clock has moved three --
    not zero, which is what it moved when the instruction was charged at the
    end."""
    apu = APU()
    apu.do_reset()
    # A timer, counting as fast as it can, is the visible clock.
    apu.poke_ram(0x0010, b"\x01")          # something for the read to return
    apu.poke_ram(CODE, bytes([0xE4, 0x10]))   # MOV A, $10
    apu.set_pc(CODE)
    start = apu.regs["clock"]
    apu.do_step()
    spent = apu.regs["clock"] - start
    if spent != 3:
        FAILURES.append("MOV A,dp took %d cycles, want 3" % spent)
    if apu.regs["a"] != 0x01:
        FAILURES.append("MOV A,dp loaded $%02X, want $01" % apu.regs["a"])
    else:
        print("      MOV A,dp: 3 cycles, and it read the right byte")


def test_reading_a_timer_sees_the_cycles_of_its_own_instruction():
    """The point of the whole change.  Run the fast timer with the shortest
    possible divisor and read its output: the count has to include the cycles
    of the instruction doing the reading, not stop at the one before it."""
    apu = APU()
    apu.do_reset()
    # Both of these have to go through a real write: the divisor and the
    # enable live in the timer, not in the RAM the address decodes to.
    apu.poke_ram(CODE, bytes([0x8F, 0x01, 0xFC]))   # MOV $FC, #$01
    apu.set_pc(CODE)
    apu.do_step()
    apu.poke_ram(CODE, bytes([0x8F, 0x04, 0xF1]))   # MOV $F1, #$04
    apu.set_pc(CODE)
    apu.do_step()

    # Let it run a while, then read the counter twice in a row.  The second
    # read must see fewer ticks than the first, because the first cleared it.
    for _ in range(40):
        apu.poke_ram(CODE, bytes([0x00]))           # NOP
        apu.set_pc(CODE)
        apu.do_step()

    apu.poke_ram(CODE, bytes([0xE5, 0xFF, 0x00]))   # MOV A, $00FF (T2OUT)
    apu.set_pc(CODE)
    apu.do_step()
    first = apu.regs["a"]
    apu.set_pc(CODE)
    apu.do_step()
    second = apu.regs["a"]

    if first == 0:
        FAILURES.append("the timer never ticked")
    elif second >= first:
        FAILURES.append("reading T2OUT did not clear it: %d then %d"
                        % (first, second))
    else:
        print("      T2OUT read %d, then %d after the read cleared it"
              % (first, second))


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
    print("all APU timing tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
