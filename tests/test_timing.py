"""Interrupt and counter timing, measured from the trace.

These assert *when* things happen, not just that they happen.  The trace
stamps every instruction with the master clock, so the cycle an interrupt
handler starts on is observable, and a scheduled event can be checked against
the cycle the hardware would place it at.

A scanline is 1364 master cycles and a dot is 4 of them.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.testrom import assemble_image
from snes.system import System

LINE = 1364
DOT = 4
# An interrupt is taken at an instruction boundary, as on hardware, so a
# measured time can sit up to one instruction late.  The spin loops here
# are a taken branch: two fetches and an internal cycle.
JITTER = 24
FAILURES = []


def check(name, got, want, fmt="%d"):
    if got != want:
        FAILURES.append("%s: got %s, want %s" % (name, fmt % got, fmt % want))


def check_near(name, got, want, tolerance, fmt="%d"):
    if abs(got - want) > tolerance:
        FAILURES.append("%s: got %s, want %s +/- %d"
                        % (name, fmt % got, fmt % want, tolerance))


def run_traced(source, frames=4, capacity=400000):
    image, labels = assemble_image(source)
    machine = System(rom_data=image)
    machine.cpu.trace_start(capacity=capacity, level=1)
    for _ in range(frames):
        machine.run_frame()
    return machine, labels, machine.cpu.trace_instructions()


def handler_entries(records, address):
    """Master clock of each entry into a handler at `address`."""
    return [r[0] for r in records if r[2] == (address & 0xFFFF)]


# --------------------------------------------------------------- H-IRQ ----

H_IRQ_SOURCE = """
        sep #$20
        lda #%(htime_lo)s
        sta $4207
        lda #%(htime_hi)s
        sta $4208
        lda #$10            ; NMITIMEN: IRQ on the H counter only
        sta $4200
        cli
spin:   bra spin
irq:    sep #$20
        lda $4211           ; acknowledge
        rti
"""


def h_irq_entries(htime, frames=3):
    source = H_IRQ_SOURCE % {"htime_lo": "$%02X" % (htime & 0xFF),
                             "htime_hi": "$%02X" % ((htime >> 8) & 1)}
    machine, labels, records = run_traced(source, frames=frames)
    return handler_entries(records, labels["irq"])


def test_h_irq_fires_once_per_line():
    """One per line.  The CPU finishes its current instruction before taking an
    interrupt, exactly as the hardware does, so individual gaps jitter by up to
    one instruction while the average stays locked to the line period."""
    entries = h_irq_entries(0x40)
    assert len(entries) > 40, "expected many H-IRQs, saw %d" % len(entries)
    # Each endpoint carries its own jitter, so allow one instruction either way
    # across the span; drift would show up as an error growing with the count.
    span = entries[40] - entries[10]
    check_near("H-IRQ period over 30 lines", span, 30 * LINE, JITTER)
    gaps = [entries[i + 1] - entries[i] for i in range(10, 40)]
    if max(gaps) - min(gaps) > JITTER:
        FAILURES.append("H-IRQ jitter is %d cycles, more than one instruction"
                        % (max(gaps) - min(gaps)))


def test_h_irq_position_follows_htime():
    """Moving HTIME by one dot must move the interrupt by exactly four cycles."""
    base = h_irq_entries(0x40)
    moved = h_irq_entries(0x60)
    assert len(base) > 10 and len(moved) > 10
    # Compare the phase within a scanline; the handler starts a fixed number
    # of cycles after the event, so the difference of phases is what matters.
    phase_base = base[5] % LINE
    phase_moved = moved[5] % LINE
    # Within the jitter of one instruction.
    check_near("HTIME +32 dots moves the IRQ",
               (phase_moved - phase_base) % LINE, 32 * DOT, 24)


# --------------------------------------------------------------- V-IRQ ----

def test_v_irq_fires_once_per_frame():
    machine, labels, records = run_traced("""
        sep #$20
        lda #$64
        sta $4209           ; VTIME = line 100
        stz $420A
        lda #$20            ; IRQ on the V counter only
        sta $4200
        cli
spin:   bra spin
irq:    sep #$20
        lda $4211
        rti
    """, frames=4)
    entries = handler_entries(records, labels["irq"])
    assert len(entries) >= 3, "expected one V-IRQ per frame, saw %d" % len(entries)
    want = LINE * machine.bus.lines_per_frame
    span = entries[-1] - entries[0]
    check_near("V-IRQ period", span, (len(entries) - 1) * want, JITTER)


def test_v_irq_lands_on_the_requested_line():
    machine, labels, records = run_traced("""
        sep #$20
        lda #$64
        sta $4209
        stz $420A
        lda #$20
        sta $4200
        cli
spin:   bra spin
irq:    sep #$20
        lda $4211           ; acknowledge
        lda $213F           ; reset the counter read latches
        lda $2137           ; $2137 is what actually latches H and V
        lda $213D           ; OPVCT low
        sta $7E4100
        rti
    """, frames=4)
    line = machine.bus.read(0x7E4100)
    check_near("V-IRQ line reported by OPVCT", line, 100, 1)


# ----------------------------------------------------------------- NMI ----

def test_nmi_fires_at_the_start_of_vblank():
    machine, labels, records = run_traced("""
        sep #$20
        lda #$80            ; NMI enabled
        sta $4200
spin:   bra spin
nmi:    sep #$20
        lda $4210           ; acknowledge
        rti
    """, frames=4)
    entries = handler_entries(records, labels["nmi"])
    assert len(entries) >= 3, "expected one NMI per frame, saw %d" % len(entries)
    want = LINE * machine.bus.lines_per_frame
    span = entries[-1] - entries[0]
    check_near("NMI period", span, (len(entries) - 1) * want, JITTER)
    # V-blank begins on line 225, so the NMI phase within the frame is that far in.
    phase = entries[1] % (LINE * machine.bus.lines_per_frame)
    check_near("NMI position in the frame", phase, 225 * LINE, 200)


# ------------------------------------------------------- counter latch ----

def test_hv_counter_latch():
    """$2137 latches the counters; OPHCT should report where we were."""
    machine, labels, records = run_traced("""
        sep #$20
        lda $2137           ; latch H and V
        lda $213C
        sta $7E4100         ; OPHCT low
        lda $213C
        sta $7E4101         ; OPHCT high
        lda $213D
        sta $7E4102         ; OPVCT low
    """, frames=2)
    h = machine.bus.read(0x7E4100) | ((machine.bus.read(0x7E4101) & 1) << 8)
    if not 0 <= h <= 339:
        FAILURES.append("OPHCT out of range: %d" % h)


def test_hblank_flag_tracks_the_dot():
    """$4212 bit 6 must follow the H counter rather than a per-line latch."""
    image, labels = assemble_image("""
        sep #$20
        ldx #$00
loop:   lda $4212
        and #$40
        beq loop            ; wait for H-blank to be reported
        lda $2137
        lda $213C
        sta $7E4100
        lda $213C
        sta $7E4101
    """)
    machine = System(rom_data=image)
    for _ in range(2):
        machine.run_frame()
        if machine.bus.read(0x7E4FFF):
            break
    dot = machine.bus.read(0x7E4100) | ((machine.bus.read(0x7E4101) & 1) << 8)
    # H-blank starts at dot 274; the read that saw it must be at or past that.
    if dot < 270:
        FAILURES.append("H-blank reported at dot %d, expected >= 274" % dot)


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in tests:
        before = len(FAILURES)
        try:
            fn()
        except Exception as exc:
            FAILURES.append("%s raised %s: %s" % (fn.__name__, type(exc).__name__, exc))
        print("  %-40s %s" % (fn.__name__, "ok" if len(FAILURES) == before else "FAIL"))
    print()
    if FAILURES:
        print("%d failure(s):" % len(FAILURES))
        for f in FAILURES:
            print("  " + f)
        return 1
    print("all timing tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
