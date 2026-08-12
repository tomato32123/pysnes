"""Every SPC700 opcode's bus cycles, in order.

The cycle *count* of each opcode was already pinned by its table.  This pins
the shape: which of an instruction's cycles read, which write, and which touch
nothing.  A program can see the difference -- that is what blargg's
`spc_mem_access_times` is measuring -- and so can any hardware being driven
through those addresses.

The expected sequences are the SPC700's documented cycle-by-cycle behaviour,
transcribed from bsnes's core, which writes each addressing mode as an
explicit run of reads, writes and idles.  Nothing here is derivable from the
cycle counts: that a store reads its destination first, that `MOV (X)+, A`
skips that read and idles instead, and that `INCW` writes the low byte back
before it reads the high one, are all facts about the chip.

Sequences stop at the first point an instruction can branch, so a conditional
is compared on its common prefix.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.apu import APU

FAILURES = []
CODE = 0x0200

# mode -> (opcodes, the cycles it spends, in order)
MODES = [
    ("no operation",              [0x00], "rr"),
    ("call table",                [0x01, 0x11, 0x21, 0x31, 0x41, 0x51, 0x61, 0x71,
                                   0x81, 0x91, 0xA1, 0xB1, 0xC1, 0xD1, 0xE1, 0xF1], "rriwwirr"),
    ("direct bit set",            [0x02, 0x12, 0x22, 0x32, 0x42, 0x52, 0x62, 0x72,
                                   0x82, 0x92, 0xA2, 0xB2, 0xC2, 0xD2, 0xE2, 0xF2], "rrrw"),
    ("branch on bit",             [0x03, 0x13, 0x23, 0x33, 0x43, 0x53, 0x63, 0x73,
                                   0x83, 0x93, 0xA3, 0xB3, 0xC3, 0xD3, 0xE3, 0xF3], "rrrir"),
    ("direct read",               [0x04, 0x24, 0x44, 0x64, 0x84, 0xA4, 0xE4,
                                   0x3E, 0x7E, 0xF8, 0xEB], "rrr"),
    ("absolute read",             [0x05, 0x25, 0x45, 0x65, 0x85, 0xA5, 0xE5,
                                   0x1E, 0x5E, 0xE9, 0xEC], "rrrr"),
    ("indirect X read",           [0x06, 0x26, 0x46, 0x66, 0x86, 0xA6, 0xE6], "rrr"),
    ("indexed indirect read",     [0x07, 0x27, 0x47, 0x67, 0x87, 0xA7, 0xE7], "rrirrr"),
    ("immediate read",            [0x08, 0x28, 0x48, 0x68, 0x88, 0xA8, 0xE8,
                                   0x8D, 0xAD, 0xCD, 0xC8], "rr"),
    ("direct to direct modify",   [0x09, 0x29, 0x49, 0x89, 0xA9], "rrrrrw"),
    ("carry bit combine",         [0x0A, 0x2A, 0x8A], "rrrri"),
    ("carry bit read",            [0x4A, 0x6A, 0xAA], "rrrr"),
    ("carry bit store",           [0xCA], "rrrriw"),
    ("carry bit invert",          [0xEA], "rrrrw"),
    ("direct modify",             [0x0B, 0x2B, 0x4B, 0x6B, 0x8B, 0xAB], "rrrw"),
    ("absolute modify",           [0x0C, 0x2C, 0x4C, 0x6C, 0x8C, 0xAC], "rrrrw"),
    ("push",                      [0x0D, 0x2D, 0x4D, 0x6D], "rrwi"),
    ("test and set bits",         [0x0E, 0x4E], "rrrrrw"),
    ("break",                     [0x0F], "rrwwwirr"),
    ("branch",                    [0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0, 0x2F], "rr"),
    ("direct indexed read",       [0x14, 0x34, 0x54, 0x74, 0x94, 0xB4, 0xF4, 0xF9, 0xFB], "rrir"),
    ("absolute indexed read",     [0x15, 0x16, 0x35, 0x36, 0x55, 0x56, 0x75, 0x76,
                                   0x95, 0x96, 0xB5, 0xB6, 0xF5, 0xF6], "rrrir"),
    ("indirect indexed read",     [0x17, 0x37, 0x57, 0x77, 0x97, 0xB7, 0xF7], "rrrrir"),
    ("direct immediate modify",   [0x18, 0x38, 0x58, 0x98, 0xB8], "rrrrw"),
    ("indirect X against Y",      [0x19, 0x39, 0x59, 0x99, 0xB9], "rrrrw"),
    ("word modify",               [0x1A, 0x3A], "rrrwrw"),
    ("direct indexed modify",     [0x1B, 0x3B, 0x5B, 0x7B, 0x9B, 0xBB], "rrirw"),
    ("implied modify",            [0x1C, 0x1D, 0x3C, 0x3D, 0x5C, 0x7C,
                                   0x9C, 0xBC, 0xDC, 0xFC], "rr"),
    ("indexed indirect jump",     [0x1F], "rrrirr"),
    ("flag set",                  [0x20, 0x40, 0x60, 0x80], "rr"),
    ("interrupt flag set",        [0xA0, 0xC0], "rri"),
    ("compare and branch",        [0x2E], "rrrir"),
    ("call absolute",             [0x3F], "rrriwwii"),
    ("call page",                 [0x4F], "rriwwi"),
    ("word compare",              [0x5A], "rrrr"),
    ("transfer",                  [0x5D, 0x7D, 0x9D, 0xBD, 0xDD, 0xFD], "rr"),
    ("jump absolute",             [0x5F], "rrr"),
    ("direct to direct compare",  [0x69], "rrrrri"),
    ("decrement and branch",      [0x6E], "rrrwr"),
    ("return",                    [0x6F], "rrirr"),
    ("direct immediate compare",  [0x78], "rrrri"),
    ("indirect X against Y cmp",  [0x79], "rrrri"),
    ("word read",                 [0x7A, 0x9A, 0xBA], "rrrir"),
    ("return from interrupt",     [0x7F], "rrirrr"),
    ("pull flags",                [0x8E], "rrir"),
    ("direct immediate write",    [0x8F], "rrrrw"),
    ("divide",                    [0x9E], "rr" + "i" * 10),
    ("exchange nibbles",          [0x9F], "rr" + "i" * 3),
    ("pull",                      [0xAE, 0xCE, 0xEE], "rrir"),
    ("indirect X increment write", [0xAF], "rriw"),
    ("decimal adjust",            [0xBE, 0xDF], "rri"),
    ("indirect X increment read", [0xBF], "rrri"),
    ("direct write",              [0xC4, 0xCB, 0xD8], "rrrw"),
    ("absolute write",            [0xC5, 0xC9, 0xCC], "rrrrw"),
    ("indirect X write",          [0xC6], "rrrw"),
    ("indexed indirect write",    [0xC7], "rrirrrw"),
    ("multiply",                  [0xCF], "rr" + "i" * 7),
    ("direct indexed write",      [0xD4, 0xD9, 0xDB], "rrirw"),
    ("absolute indexed write",    [0xD5, 0xD6], "rrrirw"),
    ("indirect indexed write",    [0xD7], "rrrrirw"),
    ("word write",                [0xDA], "rrrww"),
    ("compare indexed and branch", [0xDE], "rririr"),
    ("clear overflow",            [0xE0], "rr"),
    ("complement carry",          [0xED], "rri"),
    ("halt",                      [0xEF, 0xFF], "rri"),
    ("direct to direct write",    [0xFA], "rrrrw"),
    ("decrement Y and branch",    [0xFE], "rrir"),
]


def observed(op):
    apu = APU()
    apu.do_reset()
    apu.access_log(1)
    apu.poke_ram(CODE, bytes([op, 0x30, 0x40, 0x50]))
    apu.set_pc(CODE)
    apu.do_step()
    return "".join(kind for kind, _addr in apu.access_log())


def test_every_opcode_is_accounted_for():
    seen = set()
    for _name, ops, _want in MODES:
        for op in ops:
            if op in seen:
                FAILURES.append("$%02X listed twice" % op)
            seen.add(op)
    missing = sorted(set(range(256)) - seen)
    if missing:
        FAILURES.append("%d opcodes have no expected sequence: %s"
                        % (len(missing), " ".join("$%02X" % o for o in missing)))
    else:
        print("      all 256 opcodes have an expected sequence")


def test_the_bus_cycles_are_in_the_right_order():
    wrong = []
    for name, ops, want in MODES:
        for op in ops:
            got = observed(op)
            if not got.startswith(want):
                wrong.append((op, name, got, want))
    if wrong:
        FAILURES.append("%d opcodes access in the wrong order:\n    %s"
                        % (len(wrong), "\n    ".join(
                            "$%02X %-26s got %-14s want %s" % w for w in wrong)))
    else:
        print("      all 256 opcodes read, write and idle in the right order")


def main():
    for fn in (test_every_opcode_is_accounted_for,
               test_the_bus_cycles_are_in_the_right_order):
        before = len(FAILURES)
        try:
            fn()
        except Exception as exc:
            FAILURES.append("%s raised %s: %s" % (fn.__name__, type(exc).__name__, exc))
        print("  %-46s %s" % (fn.__name__, "ok" if len(FAILURES) == before else "FAIL"))
    print()
    if FAILURES:
        print("%d failure(s):" % len(FAILURES))
        for f in FAILURES:
            print("  " + f)
        return 1
    print("all APU cycle-order tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
