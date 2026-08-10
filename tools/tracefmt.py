"""Canonical text form for CPU traces, so they can be diffed against another
emulator's log or against a previous run of this one.

One line per instruction:

    00008F2A 00:8034 A9 LDA #$12          A:0000 X:0000 Y:0000 S:01FF D:0000 DB:00 P:34 E:1

The leading field is the master clock at the start of the instruction, which is
what makes two traces comparable cycle by cycle.  `bus_lines` renders the
individual accesses when the trace was taken at level 2.
"""

from tools import disasm

FLAG_LETTERS = "czidxmvn"


def flags_text(p, e):
    out = []
    for i in range(8):
        letter = FLAG_LETTERS[i]
        out.append(letter.upper() if (p >> i) & 1 else letter)
    return "".join(reversed(out))


def instruction_lines(records, read=None):
    """`read(addr)` should be side-effect free; without it operands are omitted."""
    out = []
    for clock, pb, pc, op, a, x, y, s, d, db, p, e in records:
        if read is not None:
            m16 = not e and not (p & 0x20)
            x16 = not e and not (p & 0x10)
            text, _ = disasm.disassemble(read, pb, pc, m16, x16)
            text = text[12:].strip()          # drop the raw bytes column
        else:
            name, _mode = disasm.OPCODES.get(op, ("???", disasm.IMP))
            text = name
        out.append("%08X %02X:%04X %02X %-18s A:%04X X:%04X Y:%04X S:%04X D:%04X DB:%02X P:%02X E:%d"
                   % (clock, pb, pc, op, text, a, x, y, s, d, db, p, e))
    return out


def bus_lines(records):
    return ["%08X %s %06X %02X" % (clock, "w" if write else "r", addr, value)
            for clock, addr, value, write in records]


def first_difference(a, b):
    """Index of the first differing line, or None.  Traces are compared by
    position; a length mismatch counts as a difference at the shorter end."""
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i
    if len(a) != len(b):
        return min(len(a), len(b))
    return None


def report_difference(a, b, context=6, label_a="a", label_b="b"):
    i = first_difference(a, b)
    if i is None:
        return "traces are identical (%d lines)" % len(a)
    lo = max(0, i - context)
    out = ["first difference at line %d" % i, ""]
    for j in range(lo, i):
        out.append("   %s" % a[j])
    out.append("  --- %s" % label_a)
    out.append("  %s" % (a[i] if i < len(a) else "<end of trace>"))
    out.append("  --- %s" % label_b)
    out.append("  %s" % (b[i] if i < len(b) else "<end of trace>"))
    return "\n".join(out)
