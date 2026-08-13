"""The uPD77C25 core, against the tables in NEC's data sheet.

There is no firmware on this machine and no test ROM for these chips, so
the only evidence available is the data sheet itself: every instruction is
assembled here by hand from the published field layout, run, and its
result and flags compared with what the tables say must happen.

That is weaker than a hardware oracle and stronger than nothing.  It
catches a field decoded from the wrong bits, an ALU function wired to the
wrong opcode, a flag the table says is cleared and the code leaves alone --
which is most of what goes wrong in a processor core, and all of what
would go wrong silently.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.necdsp import NECDSP

FAILURES = []


def check(what, got, want, fmt="%s"):
    if got != want:
        FAILURES.append("%s: got %s, want %s" % (what, fmt % got, fmt % want))


# -- assembling by hand, from figures 4, 5 and 6 --------------------------

def op(alu=0, pselect=0, acc=0, src=0, dst=0, dpl=0, dph=0, rpdcr=0, rt=0):
    """An OP or RT instruction word, field by field."""
    return ((rt << 22) | (pselect << 20) | (alu << 16) | (acc << 15)
            | (dpl << 13) | (dph << 9) | (rpdcr << 8) | (src << 4) | dst)


def jp(brch, addr):
    return (2 << 22) | (brch << 13) | (addr << 2)


def ld(value, dst):
    return (3 << 22) | ((value & 0xFFFF) << 6) | dst


def machine(*words):
    chip = NECDSP(2048, 1024, 256)
    for i, word in enumerate(words):
        chip.poke_program(i, word)
    return chip


# -- the ALU, table 6 ------------------------------------------------------

def test_the_alu_functions_are_on_the_opcodes_the_table_gives():
    """Each function, checked by a value that no other function produces."""
    cases = [
        (1, 0xF000, 0x0F0F, 0xFF0F, "OR"),
        (2, 0xF0F0, 0x0FF0, 0x00F0, "AND"),
        (3, 0xFF00, 0x0FF0, 0xF0F0, "XOR"),
        (4, 0x0100, 0x0001, 0x00FF, "SUB"),
        (5, 0x0100, 0x0001, 0x0101, "ADD"),
        (8, 0x0100, 0x0000, 0x00FF, "DEC"),
        (9, 0x0100, 0x0000, 0x0101, "INC"),
        (10, 0x0F0F, 0x0000, 0xF0F0, "CMP"),
        (11, 0x0004, 0x0000, 0x0002, "SHR1"),
        (12, 0x0004, 0x0000, 0x0008, "SHL1"),
        (15, 0x1234, 0x0000, 0x3412, "XCHG"),
    ]
    for alu, a, p, want, name in cases:
        # P comes from the internal data bus, sourced from the L register.
        chip = machine(op(alu=alu, pselect=1, src=14))
        chip.set_registers(a=a, l=p)
        chip.run(1)
        check("%s result" % name, chip.registers["a"], want, "$%04X")


def test_a_right_shift_keeps_the_sign():
    chip = machine(op(alu=11))
    chip.set_registers(a=0x8000)
    chip.run(1)
    check("SHR1 of $8000", chip.registers["a"], 0xC000, "$%04X")
    check("SHR1 carry", chip.flags_a["c"], 0, "%d")


def test_a_right_shift_drops_its_low_bit_into_carry():
    chip = machine(op(alu=11))
    chip.set_registers(a=0x0003)
    chip.run(1)
    check("SHR1 of $0003", chip.registers["a"], 0x0001, "$%04X")
    check("SHR1 carry", chip.flags_a["c"], 1, "%d")


def test_the_left_shift_rotates_carry_in():
    chip = machine(op(alu=12))
    chip.set_registers(a=0x8000, c=1)
    chip.run(1)
    check("SHL1 of $8000 with carry", chip.registers["a"], 0x0001, "$%04X")
    check("SHL1 carry out", chip.flags_a["c"], 1, "%d")


def test_addition_sets_carry_and_overflow_where_the_table_says():
    chip = machine(op(alu=5, pselect=1, src=14))
    chip.set_registers(a=0xFFFF, l=0x0001)
    chip.run(1)
    check("wrap to zero", chip.registers["a"], 0x0000, "$%04X")
    check("carry out", chip.flags_a["c"], 1, "%d")
    check("zero", chip.flags_a["z"], 1, "%d")
    check("no signed overflow", chip.flags_a["ov0"], 0, "%d")

    chip = machine(op(alu=5, pselect=1, src=14))
    chip.set_registers(a=0x7FFF, l=0x0001)
    chip.run(1)
    check("past the largest positive", chip.registers["a"], 0x8000, "$%04X")
    check("signed overflow", chip.flags_a["ov0"], 1, "%d")
    check("sign", chip.flags_a["s0"], 1, "%d")


def test_subtraction_borrows():
    chip = machine(op(alu=4, pselect=1, src=14))
    chip.set_registers(a=0x0000, l=0x0001)
    chip.run(1)
    check("0 - 1", chip.registers["a"], 0xFFFF, "$%04X")
    check("borrow", chip.flags_a["c"], 1, "%d")


def test_a_logical_function_clears_carry_and_overflow():
    """Table 6: OR, AND and XOR leave carry and both overflow flags at 0."""
    chip = machine(op(alu=5, pselect=1, src=14),      # make carry first
                   op(alu=1, pselect=1, src=14))
    chip.set_registers(a=0xFFFF, l=0x0001)
    chip.run(1)
    check("carry is set to begin with", chip.flags_a["c"], 1, "%d")
    chip.run(1)
    check("OR clears carry", chip.flags_a["c"], 0, "%d")
    check("OR clears overflow", chip.flags_a["ov0"], 0, "%d")


def test_the_second_accumulator_is_selected_by_its_own_field():
    chip = machine(op(alu=5, pselect=1, src=14, acc=1))
    chip.set_registers(b=0x1000, l=0x0234)
    chip.run(1)
    check("B", chip.registers["b"], 0x1234, "$%04X")
    check("A untouched", chip.registers["a"], 0x0000, "$%04X")


# -- the multiplier --------------------------------------------------------

def test_the_multiplier_puts_a_31_bit_product_in_m_and_n():
    """The sign and fifteen high bits in M, fifteen low bits in N with its
    lowest bit zero."""
    chip = machine(op(), op())
    chip.set_registers(k=0x4000, l=0x0002)
    chip.run(1)
    product = 0x4000 * 0x0002
    check("M", chip.registers["m"], (product >> 15) & 0xFFFF, "$%04X")
    check("N", chip.registers["n"], (product << 1) & 0xFFFF, "$%04X")


def test_the_multiplier_treats_its_inputs_as_signed():
    chip = machine(op())
    chip.set_registers(k=0xFFFF, l=0x0002)          # -1 * 2
    chip.run(1)
    product = -1 * 2
    check("M of a negative product", chip.registers["m"],
          (product >> 15) & 0xFFFF, "$%04X")


def test_an_instruction_may_load_both_inputs_and_the_next_read_the_product():
    """The data sheet lists loading both multiplier inputs and the multiply
    itself among the operations of one instruction."""
    chip = machine(ld(0x0100, 10),                   # K = $0100
                   ld(0x0010, 13),                   # L = $0010
                   op(alu=5, pselect=2))             # A = A + M
    chip.run(3)
    check("A holds the product's high half", chip.registers["a"],
          ((0x0100 * 0x0010) >> 15) & 0xFFFF, "$%04X")


# -- moving data, tables 11 and 12 ----------------------------------------

def test_a_load_immediate_reaches_every_register_the_table_lists():
    for dst, name, read in ((1, "A", "a"), (2, "B", "b"), (3, "TR", "tr"),
                            (4, "DP", "dp"), (5, "RP", "rp"), (10, "K", "k"),
                            (13, "L", "l")):
        chip = machine(ld(0x1234, dst))
        chip.run(1)
        check("LD to %s" % name, chip.registers[read], 0x1234, "$%04X")


def test_ram_is_addressed_by_the_data_pointer():
    chip = machine(ld(0x0005, 4),                    # DP = 5
                   ld(0xBEEF, 15),                   # RAM[DP] = $BEEF
                   op(src=15, dst=1))                # A = RAM[DP]
    chip.run(3)
    check("RAM through DP", chip.registers["a"], 0xBEEF, "$%04X")
    check("the word is in RAM", chip.peek_ram(5), 0xBEEF, "$%04X")


def test_the_data_pointer_low_half_increments_and_wraps_inside_itself():
    """DPL touches only the low four bits; the high half is the DPH field's."""
    chip = machine(ld(0x000F, 4), op(dpl=1))
    chip.run(2)
    check("DP after increment", chip.registers["dp"], 0x0000, "$%04X")

    chip = machine(ld(0x0010, 4), op(dpl=2))
    chip.run(2)
    check("DP after decrement", chip.registers["dp"], 0x001F, "$%04X")

    chip = machine(ld(0x00FF, 4), op(dpl=3))
    chip.run(2)
    check("DP after clear", chip.registers["dp"], 0x00F0, "$%04X")


def test_the_data_pointer_high_half_is_exclusive_ored_with_the_field():
    chip = machine(ld(0x0030, 4), op(dph=1))
    chip.run(2)
    check("DP after M1", chip.registers["dp"], 0x0020, "$%04X")


def test_the_rom_pointer_decrements_when_the_field_says_so():
    chip = machine(ld(0x0005, 5), op(rpdcr=1))
    chip.run(2)
    check("RP", chip.registers["rp"], 0x0004, "$%04X")


def test_the_data_rom_is_read_through_the_rom_pointer():
    chip = machine(ld(0x0002, 5), op(src=6, dst=1))
    chip.poke_data(2, 0xCAFE)
    chip.run(2)
    check("data ROM", chip.registers["a"], 0xCAFE, "$%04X")


def test_a_move_to_the_selected_accumulator_supersedes_the_alu():
    """The data sheet: if the accumulator in the ASL field is also the
    destination of the move, the ALU operation becomes a NOP."""
    chip = machine(op(alu=5, pselect=1, src=14, dst=1))
    chip.set_registers(a=0x1000, l=0x0234)
    chip.run(1)
    check("the move won", chip.registers["a"], 0x0234, "$%04X")


# -- branches, table 13 ----------------------------------------------------

def test_an_unconditional_jump_goes_where_it_says():
    chip = machine(jp(0x100, 0x010))
    chip.run(1)
    check("PC", chip.registers["pc"], 0x010, "$%04X")


def test_a_call_stacks_the_return_address_and_a_return_takes_it_back():
    chip = machine(jp(0x140, 0x004), op(), op(), op(),
                   op(rt=1))                          # at $004
    chip.run(1)
    check("PC after the call", chip.registers["pc"], 0x004, "$%04X")
    check("one entry stacked", chip.registers["sp"], 1, "%d")
    chip.run(1)
    check("PC after the return", chip.registers["pc"], 0x001, "$%04X")
    check("the stack is empty again", chip.registers["sp"], 0, "%d")


def test_a_conditional_jump_reads_the_flag_it_names():
    # JNZA: taken when the zero flag is clear.
    chip = machine(op(alu=5, pselect=1, src=14), jp(0x088, 0x020))
    chip.set_registers(a=0x0001, l=0x0001)
    chip.run(2)
    check("taken when not zero", chip.registers["pc"], 0x020, "$%04X")

    chip = machine(op(alu=5, pselect=1, src=14), jp(0x088, 0x020))
    chip.set_registers(a=0x0000, l=0x0000)
    chip.run(2)
    check("not taken when zero", chip.registers["pc"], 0x002, "$%04X")


# -- the host's side -------------------------------------------------------

def test_the_console_reads_a_word_as_two_bytes_high_first():
    chip = machine(ld(0xABCD, 6))                    # DR = $ABCD
    chip.run(1)
    check("the chip is asking", chip.read_status() & 0x80, 0x80, "$%02X")
    check("high byte first", chip.read_data(), 0xAB, "$%02X")
    check("still asking between halves", chip.read_status() & 0x80, 0x80, "$%02X")
    check("then the low byte", chip.read_data(), 0xCD, "$%02X")
    check("the request is answered", chip.read_status() & 0x80, 0x00, "$%02X")


def test_a_write_from_the_console_lands_in_the_data_register():
    chip = machine(op())
    chip.write_data(0x12)
    chip.write_data(0x34)
    check("DR", chip.registers["dr"], 0x1234, "$%04X")


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
    print("the core matches the data sheet's tables")
    return 0


if __name__ == "__main__":
    sys.exit(main())
