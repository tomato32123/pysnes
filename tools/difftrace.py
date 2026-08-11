"""Compare a trace against a reference, and report the first divergence.

Two uses.

The one this was built for: run a test ROM here and in bsnes or ares, dump
both traces, and diff them.  The first line that differs is a cycle number and
an instruction, which turns "the picture looks wrong" into a place to look.
That needs a reference emulator to hand, and one is not required to be.

The one available without a reference: record a trace once, commit it, and
compare against it afterwards.  That does not say the emulator is right --
only the reference can say that -- but it does say that nothing changed
without someone meaning it, which is most of what a regression net is for.

    python tools/difftrace.py record <name>          # write a golden trace
    python tools/difftrace.py check [<name> ...]     # compare against them
    python tools/difftrace.py diff <a> <b>           # any two trace files

The trace format is tools/tracefmt's, one instruction per line, stamped with
the master clock.  A reference emulator's log has to be brought into that
shape first; `--fields` selects which columns take part in the comparison, so
a log that does not carry, say, the direct page register can still be used
for everything else.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools import tracefmt
from tools.testrom import assemble_image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GOLDEN = os.path.join(ROOT, "tests", "golden")

# Short programs that between them touch the parts of the core whose behaviour
# a change is most likely to disturb.  Kept small on purpose: a golden trace is
# only useful if a human can read the diff.
PROGRAMS = {
    "arithmetic": """
        sep #$30
        lda #$7F
        clc
        adc #$01                ; overflow into the sign
        sta $7E4000
        sed
        lda #$19
        clc
        adc #$01                ; decimal carry
        sta $7E4001
        cld
        rep #$30
        lda #$1234
        ldx #$00FF
        clc
        adc #$EDCB              ; sixteen-bit carry out
        sta $7E4002
        sep #$30
        lda #$FF
        sta $7E4FFF
__end:  bra __end
""",
    "addressing": """
        rep #$30
        lda #$1000
        tcd                     ; direct page away from zero
        ldx #$0004
        lda #$ABCD
        sta $1010
        lda $1010
        sta $7E4000
        lda $1010,x
        sta $7E4002
        sep #$30
        lda #$FF
        sta $7E4FFF
__end:  bra __end
""",
    "stack_and_flow": """
        sep #$30
        lda #$42
        pha
        lda #$00
        pla                     ; back off the stack
        sta $7E4000
        rep #$30
        pea $1234
        pla
        sta $7E4002
        jsr __sub
        sep #$30
        lda #$FF
        sta $7E4FFF
__end:  bra __end
__sub:  nop
        rts
""",
    "interrupts": """
        sep #$20
        lda #$40
        sta $4207               ; HTIME, so the IRQ comes within one line
        stz $4208
        lda #$10
        sta $4200               ; IRQ on the H counter only
        cli
        rep #$30
__spin: lda $7E4000             ; wait for the handler to say it ran
        beq __spin
        sep #$20
        lda #$00
        sta $4200               ; and stop it firing again
        lda #$FF
        sta $7E4FFF
__end:  bra __end

irq:    sep #$20
        lda $4211               ; acknowledge
        lda #$01
        sta $7E4000
        rti
""",
}

# Which columns of a trace line take part in a comparison.  A reference log
# that is missing one of them can be compared on the rest.
ALL_FIELDS = ("clock", "pc", "op", "a", "x", "y", "s", "d", "db", "p", "e")


def capture(source, frames=4, capacity=200000):
    """Run a program and return the trace of its own instructions.

    A frame runs to its end whether the program has finished or not, so the
    raw trace is mostly the harness clearing memory beforehand and a branch
    to itself afterwards.  Neither says anything about the core, and both
    would bury a real difference, so the trace is cut down to the span
    between the program's first instruction and the loop it parks in.
    """
    from snes.system import System

    image, labels = assemble_image(source)
    machine = System(rom_data=image)
    machine.cpu.trace_start(capacity=capacity, level=1)
    for _ in range(frames):
        machine.run_frame()
        if machine.bus.read(0x7E4FFF):
            break
    records = machine.cpu.trace_instructions()

    start = labels["__main"] & 0xFFFF
    stop = labels["__end"] & 0xFFFF
    first = next((i for i, r in enumerate(records) if r[2] == start), 0)
    last = next((i for i, r in enumerate(records)
                 if i > first and r[2] == stop), len(records))
    return tracefmt.instruction_lines(records[first:last + 1], machine.bus.read)


def split_fields(line):
    """Pull a trace line apart into named columns.

    Anything that does not look like one of ours is returned whole under
    "raw", so `diff` still works on a foreign log even when `--fields` cannot.
    """
    parts = line.split()
    if len(parts) < 4 or ":" not in parts[1]:
        return {"raw": line}
    out = {"clock": parts[0], "pc": parts[1], "op": parts[2]}
    for token in parts:
        if ":" in token and len(token.split(":")) == 2:
            key, value = token.split(":")
            key = key.lower()
            if key in ALL_FIELDS:
                out[key] = value
    return out


def compare(got, want, fields, context=4):
    """First differing line, with the lines around it.  None if they match."""
    keys = [f for f in fields if f != "pc"] + ["pc"]
    for i in range(max(len(got), len(want))):
        if i >= len(got):
            return report(i, got, want, "the trace ends early", context)
        if i >= len(want):
            return report(i, got, want, "the trace runs on past the reference",
                          context)
        a = split_fields(got[i])
        b = split_fields(want[i])
        if "raw" in a or "raw" in b:
            if got[i] != want[i]:
                return report(i, got, want, "lines differ", context)
            continue
        for key in keys:
            if key in a and key in b and a[key] != b[key]:
                return report(i, got, want,
                              "%s: %s, reference says %s" % (key, a[key], b[key]),
                              context)
    return None


def report(index, got, want, why, context):
    lines = ["first divergence at instruction %d: %s" % (index, why), ""]
    lo = max(0, index - context)
    for i in range(lo, index):
        lines.append("   %s" % got[i])
    lines.append(" > %s" % (got[index] if index < len(got) else "(end of trace)"))
    lines.append(" ! %s" % (want[index] if index < len(want) else "(end of reference)"))
    for i in range(index + 1, min(index + 1 + context, len(got))):
        lines.append("   %s" % got[i])
    return "\n".join(lines)


def golden_path(name):
    return os.path.join(GOLDEN, name + ".trace")


def cmd_record(names):
    os.makedirs(GOLDEN, exist_ok=True)
    for name in names:
        lines = capture(PROGRAMS[name])
        with open(golden_path(name), "w", encoding="utf-8", newline="\n") as fh:
            fh.write("\n".join(lines) + "\n")
        print("%-16s %d instructions" % (name, len(lines)))
    return 0


def cmd_check(names, fields):
    failed = 0
    for name in names:
        path = golden_path(name)
        if not os.path.exists(path):
            print("%-16s NO GOLDEN TRACE (run `record` first)" % name)
            failed += 1
            continue
        want = open(path, encoding="utf-8").read().splitlines()
        got = capture(PROGRAMS[name])
        why = compare(got, want, fields)
        if why is None:
            print("%-16s ok (%d instructions)" % (name, len(got)))
        else:
            print("%-16s DIFFERS" % name)
            print("\n".join("    " + l for l in why.splitlines()))
            failed += 1
    return 1 if failed else 0


def cmd_diff(a, b, fields):
    got = open(a, encoding="utf-8").read().splitlines()
    want = open(b, encoding="utf-8").read().splitlines()
    why = compare(got, want, fields)
    if why is None:
        print("identical over %d instructions" % min(len(got), len(want)))
        return 0
    print(why)
    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("command", choices=["record", "check", "diff", "list"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--fields", default=",".join(ALL_FIELDS),
                    help="columns to compare, comma separated (default: all)")
    opts = ap.parse_args()
    fields = tuple(f.strip() for f in opts.fields.split(",") if f.strip())

    if opts.command == "list":
        for name in sorted(PROGRAMS):
            print(name)
        return 0
    if opts.command == "diff":
        if len(opts.args) != 2:
            ap.error("diff takes two trace files")
        return cmd_diff(opts.args[0], opts.args[1], fields)

    names = opts.args or sorted(PROGRAMS)
    for name in names:
        if name not in PROGRAMS:
            ap.error("no such program: %s (try `list`)" % name)
    if opts.command == "record":
        return cmd_record(names)
    return cmd_check(names, fields)


if __name__ == "__main__":
    sys.exit(main())
