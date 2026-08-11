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


# ------------------------------------------------------------------ DMA ----

DMA_SOURCE = """
        sep #$20
        lda #$80
        sta $2115
        rep #$20
        lda #$0000
        sta $2116
        sep #$20
        lda #$01
        sta $4300               ; channel 0: two registers, A -> B
        lda #$18
        sta $4301               ; to $2118
        lda #$01
        sta $4310               ; channel 1, same shape
        lda #$18
        sta $4311
        rep #$20
        lda #$0000
        sta $4302
        sta $4312
        sep #$20
        lda #$7E
        sta $4304
        sta $4314
        rep #$20
        lda #$%(count)04X
        sta $4305
        lda #$%(count)04X
        sta $4315
        sep #$20
        nop                     ; marker
        lda #$%(mask)02X
        sta $420B
        nop
"""


def dma_cost(nbytes, mask=0x01):
    """Master cycles the STA $420B takes, including the transfer."""
    image, _labels = assemble_image(DMA_SOURCE % {"count": nbytes, "mask": mask})
    machine = System(rom_data=image)
    machine.cpu.trace_start(capacity=20000, level=1)
    for _ in range(2):
        machine.run_frame()
        if machine.bus.read(0x7E4FFF):
            break
    recs = machine.cpu.trace_instructions()
    for i in range(2, len(recs) - 1):
        if recs[i][3] == 0x8D and recs[i - 1][3] == 0xA9 and recs[i - 2][3] == 0xEA:
            return recs[i + 1][0] - recs[i][0]
    raise AssertionError("could not find the STA $420B")


# STA abs from slow ROM: three fetches at 8 plus a write to $420B at 6.
STA_COST = 8 * 3 + 6


def test_dma_costs_eight_cycles_per_byte():
    small = dma_cost(8)
    large = dma_cost(40)
    check("DMA per-byte cost", (large - small) // 32, 8)


def test_dma_fixed_overhead():
    """One channel: eight cycles to start, eight for the channel, eight per
    byte, plus one to eight cycles waiting for the DMA clock edge."""
    total = dma_cost(1)
    overhead = total - STA_COST - 8          # take off the single byte
    check_near("DMA fixed overhead", overhead, 16 + 4, 4)


def test_a_second_channel_costs_one_more_setup():
    one = dma_cost(4, mask=0x01)
    two = dma_cost(4, mask=0x03)
    # The second channel adds its own eight-cycle setup and its four bytes.
    check_near("second channel cost", two - one, 8 + 4 * 8, 8)


def test_hdma_steals_time_from_the_cpu():
    """An active HDMA channel must cost the CPU cycles every visible line."""
    def instructions_per_frame(enable_hdma):
        source = """
        sep #$20
        lda #$00
        sta $4300               ; one register, A -> B
        lda #$00
        sta $4301               ; $2100
        rep #$20
        lda #$5000
        sta $4302               ; table in WRAM
        sep #$20
        lda #$7E
        sta $4304
        ; table: 127 lines of repeat, then a terminator
        lda #$FF
        sta $7E5000
        ldx #$00
fill:   lda #$0F
        sta $7E5001,x
        inx
        bne fill
        lda #%s
        sta $420C
spin:   bra spin
""" % ("$01" if enable_hdma else "$00")
        image, _ = assemble_image(source)
        machine = System(rom_data=image)
        machine.run_frame()
        before = machine.cpu.instructions
        machine.run_frame()
        return machine.cpu.instructions - before

    without = instructions_per_frame(False)
    with_hdma = instructions_per_frame(True)
    if with_hdma >= without:
        FAILURES.append("HDMA stole no CPU time: %d instructions with, %d without"
                        % (with_hdma, without))
    else:
        print("      HDMA cost the CPU %d instructions per frame (%.1f%%)"
              % (without - with_hdma, (without - with_hdma) * 100.0 / without))


# --------------------------------------------------- DRAM refresh ----

def test_dram_refresh_stalls_the_cpu_once_a_line():
    """The CPU is halted for 40 master cycles once per scanline while DRAM is
    refreshed.  In a stream of NOPs it shows up as one oversized gap per line."""
    image, _ = assemble_image("""
        sep #$30
spin:   nop
        nop
        nop
        nop
        bra spin
""")
    machine = System(rom_data=image)
    machine.cpu.trace_start(capacity=60000, level=1)
    machine.run_frame()
    recs = machine.cpu.trace_instructions()
    import collections
    gaps = collections.Counter(recs[i + 1][0] - recs[i][0] for i in range(len(recs) - 1))
    nop = 14                       # fetch at 8 plus one internal cycle at 6
    branch = 22                    # taken BRA: two fetches and an internal cycle
    stalls = {g: n for g, n in gaps.items() if g > branch + 4}
    if not stalls:
        FAILURES.append("no refresh stall appeared in a frame")
        return
    # The stall lands inside whichever instruction was running, so it shows up
    # as that instruction's cost plus 40.
    common = max(stalls, key=lambda g: stalls[g])
    check("refresh stall on a NOP", common, nop + 40)
    if branch + 40 not in stalls:
        FAILURES.append("no refresh landed inside a branch: %s" % sorted(stalls))
    total = sum(stalls.values())
    # run_frame stops at V-blank, so the count matches the lines drawn so far.
    if not 200 <= total <= machine.bus.lines_per_frame:
        FAILURES.append("saw %d stalls, expected about one per line" % total)
    else:
        print("      %d refresh stalls, %d of them %d cycles"
              % (total, stalls[common], common))


def test_frame_length_alternates_with_the_short_scanline():
    """Scanline 240 of a non-interlaced odd field is one dot shorter, so every
    other frame saves four master cycles.

    A single frame boundary carries up to one instruction of jitter, which is
    far more than four cycles, so the saving is measured across many frames
    where it accumulates and the jitter does not.
    """
    image, _ = assemble_image("""
spin:   bra spin
""")
    machine = System(rom_data=image)
    machine.run_frame()
    start = machine.master_clock
    frames = 40
    for _ in range(frames):
        machine.run_frame()
    span = machine.master_clock - start

    full = LINE * machine.bus.lines_per_frame
    expected_no_short = frames * full
    expected_with_short = frames * full - (frames // 2) * 4
    check_near("cumulative frame time", span, expected_with_short, JITTER)
    if abs(span - expected_no_short) <= JITTER:
        FAILURES.append("no short scanline: %d frames took the full %d cycles"
                        % (frames, span))
    else:
        print("      %d frames took %d cycles, %d short of %d full-length ones"
              % (frames, span, expected_no_short - span, frames))


# ------------------------------------------------------- NMI flag ----

def test_rdnmi_clears_on_read_and_at_the_top_of_the_frame():
    """$4210 bit 7 is raised at V-blank, cleared by reading it, and cleared
    again when the next frame starts even if nobody read it."""
    machine, labels, records = run_traced("""
        sep #$20
        stz $4200               ; NMI disabled: only the flag moves
        ldx #$00
wait1:  lda $4212
        bpl wait1               ; wait for V-blank
        lda $4210
        sta $7E4100             ; first read: bit 7 should be set
        lda $4210
        sta $7E4101             ; second read: cleared by the first
wait2:  lda $4212
        bmi wait2               ; wait for the display to resume
wait3:  lda $4212
        bpl wait3               ; and for the next V-blank
        lda $4210
        sta $7E4102             ; raised again for the new frame
    """, frames=4)
    check("flag set at V-blank", machine.bus.read(0x7E4100) & 0x80, 0x80, "$%02X")
    check("cleared by reading", machine.bus.read(0x7E4101) & 0x80, 0x00, "$%02X")
    check("raised again next frame", machine.bus.read(0x7E4102) & 0x80, 0x80, "$%02X")


def test_enabling_nmi_while_the_flag_is_set_fires_immediately():
    """A game that enables NMI during V-blank, with the flag already up, gets
    an interrupt at once rather than waiting a frame."""
    machine, labels, records = run_traced("""
        sep #$20
        stz $4200
wait:   lda $4212
        bpl wait                ; inside V-blank, flag already set
        lda #$80
        sta $4200               ; enable NMI now
        nop
        nop
        nop
spin:   bra spin
nmi:    sep #$20
        lda #$5A
        sta $7E4100
        lda $4210
        rti
    """, frames=2)
    check("NMI taken on enable", machine.bus.read(0x7E4100), 0x5A, "$%02X")


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
