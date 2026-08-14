"""Why is this cartridge not drawing anything?

A black screen says nothing about its cause.  Three times now the answer has
been different -- a chip register read as the wrong bit, an interrupt raised
that hardware would not raise, a processor executing its own title text --
and each time the first hour went on the same four questions.  This asks
them.

    python tools/whystuck.py <rom> [more roms...]

It reports, for each cartridge:

  * whether the processor is running or going round in a small circle
  * whether it is inside an interrupt handler it never leaves
  * where it left code that belongs to the program, if it did
  * what the screen is being told: force blank, brightness, which layers
  * how many interrupts the console raised, and how many were taken

None of that is a diagnosis.  It is the set of readings that has, so far,
always contained one -- and taking them by hand costs an hour each time.
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.system import System

SETTLE = 60                      # frames to let a program finish booting
SAMPLE = 400_000                 # instructions to record in the frame after


def mapped(pc):
    """Whether an address in bank $00 is somewhere a program would run.

    Rough on purpose: the point is to catch a processor that has left its
    own code entirely, not to model a board's decoding.
    """
    return pc >= 0x8000 or pc < 0x2000 or 0x3000 <= pc < 0x3800 \
        or 0x6000 <= pc < 0x8000


def look(path):
    name = os.path.basename(path)
    machine = System(path)
    for _ in range(SETTLE):
        machine.run_frame()

    irq_before = machine.bus.irq_count
    # Level 2 records every bus access as well.  It costs memory, but the
    # question a stalled program raises is always "waiting for what", and
    # that is answered by which register it keeps reading.
    machine.cpu.trace_start(capacity=SAMPLE, level=2)
    machine.run_frame()
    ins = machine.cpu.trace_instructions()
    reads = machine.cpu.trace_bus()
    machine.cpu.trace_stop()
    irq_raised = machine.bus.irq_count - irq_before

    fb = machine.framebuffer
    nonblack = sum(1 for i in range(0, len(fb), 4)
                   if fb[i] or fb[i + 1] or fb[i + 2])

    print("=" * 72)
    print(name)
    print("  picture      : %d non-black pixels" % nonblack)
    print("  " + machine.ppu.dump().splitlines()[0].strip())

    if not ins:
        print("  processor    : did not execute anything")
        return

    spots = collections.Counter((r[1], r[2]) for r in ins)
    print("  processor    : %d instructions over %d addresses"
          % (len(ins), len(spots)))
    if len(spots) <= 16:
        print("  going round in a circle:")
        for (pb, pc), n in spots.most_common(16):
            print("      %02X:%04X  x%d" % (pb, pc, n))

    # What a stalled program keeps reading is what it is waiting for, and a
    # register it reads thousands of times in a frame is not being used, it
    # is being watched.
    polled = collections.Counter()
    for _c, addr, _v, write in reads:
        off = addr & 0xFFFF
        if not write and 0x2100 <= off <= 0x437F:
            polled[off] += 1
    watched = [(n, off) for off, n in polled.items() if n > 200]
    if watched:
        watched.sort(reverse=True)
        print("  watching     : %s"
              % ", ".join("$%04X x%d" % (off, n) for n, off in watched[:5]))

    # An interrupt taken and never left shows as RTIs that never come.  The
    # count matters more than the addresses: a handler that returns leaves
    # one RTI per entry, and one that does not leaves none at all.
    rti = sum(1 for r in ins if r[3] == 0x40)
    masked = sum(1 for r in ins if r[10] & 0x04)
    print("  interrupts   : %d raised by the console, %d returned from, "
          "%d%% of instructions with them masked"
          % (irq_raised, rti, 100 * masked // len(ins)))
    if irq_raised > 4 and rti == 0 and masked == len(ins):
        print("      -> raised and never serviced: something was entered and "
              "not left")

    # Bank $00 below $8000 is registers and RAM; a program fetching code from
    # there has usually lost its way rather than chosen to.
    for i, r in enumerate(ins):
        if r[1] == 0 and not mapped(r[2]):
            print("  left its own code at instruction %d:" % i)
            for r2 in ins[max(0, i - 5):i + 2]:
                print("      %02X:%04X op=%02X A=%04X X=%04X S=%04X P=%02X"
                      % (r2[1], r2[2], r2[3], r2[4], r2[5], r2[7], r2[10]))
            break

    banks = collections.Counter(r[1] for r in ins)
    print("  banks        : %s"
          % ", ".join("$%02X x%d" % (b, n) for b, n in banks.most_common(4)))

    # A frame is 357,368 master cycles.  A processor that gets through only a
    # few hundred instructions in one is not running slowly -- it is stopped,
    # and the gaps say where the time went: WAI and STP halt it, DMA takes the
    # bus away from it, and a chip on the cartridge can hold it too.
    span = ins[-1][0] - ins[0][0]
    gaps = [(b[0] - a[0], a[1], a[2], a[3]) for a, b in zip(ins, ins[1:])]
    gaps.sort(reverse=True)
    idle = sum(g[0] for g in gaps if g[0] > 200)
    waits = sum(1 for r in ins if r[3] == 0xCB)
    stops = sum(1 for r in ins if r[3] == 0xDB)
    if waits or stops:
        print("  halts        : WAI x%d, STP x%d" % (waits, stops))
    if idle > span // 20:
        print("  standing still: %d%% of the frame, in %d stretches over 50 dots"
              % (100 * idle // max(1, span),
                 sum(1 for g in gaps if g[0] > 200)))
        for cost, pb, pc, op in gaps[:3]:
            print("      %5d master (%4d dots) after %02X:%04X op=%02X"
                  % (cost, cost // 4, pb, pc, op))


def main():
    roms = sys.argv[1:]
    if not roms:
        print(__doc__.strip().splitlines()[2])
        print("usage: python tools/whystuck.py <rom> [more roms...]")
        return 1
    for path in roms:
        try:
            look(path)
        except Exception as exc:
            print("=" * 72)
            print("%s\n  could not run: %s: %s"
                  % (os.path.basename(path), type(exc).__name__, exc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
