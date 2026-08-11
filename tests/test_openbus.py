"""Open bus: what a read returns when nothing drives the data lines.

The SNES has no pull-ups on the data bus, so a read from an address nothing
answers returns whatever was last on the lines.  There is more than one set
of lines.  The CPU's own bus holds the last byte the CPU moved, which for a
`lda abs` is the high byte of the operand it just fetched.  The two PPU
chips each latch their own last value, and a read of a write-only PPU
register returns that rather than the CPU's.

Programs do rely on this: the value is deterministic, so code that reads a
write-only register gets a predictable answer, and a few games depend on it.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.testrom import run

FAILURES = []


def check(name, got, want):
    if got != want:
        FAILURES.append("%s: got $%02X, want $%02X" % (name, got, want))


# ------------------------------------------------------------ CPU bus ----

CPU_MDR_SOURCE = """
        sep #$30
        lda #$5A
        sta $4200               ; NMITIMEN is write-only
        lda $4200               ; so this reads the bus, not the register
        sta $7E4000
        lda $2200               ; nothing is mapped here at all
        sta $7E4001
        lda #$FF
        sta $7E4FFF
__end:  bra __end
"""


def test_write_only_register_reads_the_last_operand_byte():
    """`lda $4200` fetches AD 00 42, so $42 is the last byte on the bus."""
    r = run(CPU_MDR_SOURCE)
    check("read of $4200", r[0], 0x42)


def test_unmapped_address_reads_the_last_operand_byte():
    r = run(CPU_MDR_SOURCE)
    check("read of $2200", r[1], 0x22)


WIDE_SOURCE = """
        sep #$30
        rep #$20
        lda $2200               ; two reads, both open bus
        sep #$20
        sta $7E4000
        xba
        sta $7E4001
        lda #$FF
        sta $7E4FFF
__end:  bra __end
"""


def test_a_sixteen_bit_open_bus_read_repeats_the_byte():
    """The low read leaves its own value on the bus, so the high read sees it."""
    r = run(WIDE_SOURCE)
    check("low byte", r[0], 0x22)
    check("high byte", r[1], 0x22)


# ------------------------------------------------------------ PPU bus ----

PPU_MDR_SOURCE = """
        sep #$30
        lda #$05
        sta $211B               ; M7A low
        lda #$00
        sta $211B               ; M7A high, so M7A = $0005
        lda #$07
        sta $211C               ; M7B = 7, and the product is $23
        lda $2134               ; MPYL, which latches PPU1's bus
        sta $7E4000
        lda $2100               ; INIDISP is write-only: PPU1 open bus
        sta $7E4001
        lda $2101               ; and again, from a different operand byte
        sta $7E4002
        lda #$FF
        sta $7E4FFF
__end:  bra __end
"""


def test_the_multiply_result_latches_the_ppu1_bus():
    r = run(PPU_MDR_SOURCE)
    check("MPYL", r[0], 0x23)


def test_write_only_ppu_registers_read_the_ppu1_bus():
    """Not the CPU's bus, which holds $21 from the operand fetch."""
    r = run(PPU_MDR_SOURCE)
    check("read of $2100", r[1], 0x23)
    check("read of $2101", r[2], 0x23)


PPU2_SOURCE = """
        sep #$30
        lda #$80
        sta $2100               ; forced blank, so CGRAM takes writes
        lda #$00
        sta $2121
        lda #$20
        sta $2122               ; colour 0 low byte = $20
        lda #$00
        sta $2122
        lda #$00
        sta $2121
        lda $213B               ; reading it latches PPU2's bus with $20
        sta $7E4000
        lda $213F               ; STAT78 fills bit 5 from that latch
        sta $7E4001

        lda #$00
        sta $2121
        lda #$00
        sta $2122               ; now colour 0 low byte = $00
        lda #$00
        sta $2122
        lda #$00
        sta $2121
        lda $213B
        sta $7E4002
        lda $213F
        sta $7E4003

        lda $2134               ; and PPU1's own latch, from an earlier test
        sta $7E4004
        lda $213E               ; STAT77 fills bit 4 from PPU1
        sta $7E4005
        lda #$FF
        sta $7E4FFF
__end:  bra __end
"""

# The field and counter-latch bits move on their own, so only the version and
# the open-bus bit are asserted.
STAT_MASK = 0x2F


def test_stat78_takes_its_spare_bit_from_the_ppu2_latch():
    r = run(PPU2_SOURCE)
    check("CGDATAREAD low", r[0], 0x20)
    check("STAT78 after a $20 latch", r[1] & STAT_MASK, 0x23)
    check("CGDATAREAD low again", r[2], 0x00)
    check("STAT78 after a $00 latch", r[3] & STAT_MASK, 0x03)


def test_stat77_takes_its_spare_bit_from_the_ppu1_latch():
    """The two chips report different versions, so this also shows they are
    not one latch: PPU1 is revision 1 and PPU2 revision 3."""
    r = run(PPU2_SOURCE)
    check("STAT77 version", r[5] & 0x0F, 0x01)
    check("STAT77 bit 4 from MPYL $%02X" % r[4], r[5] & 0x10, r[4] & 0x10)


# --------------------------------------------------------------- DMA ----

DMA_SOURCE = """
        sep #$30
        lda #$00
        sta $4300               ; A to B, one byte per write
        lda #$22                ; $2122 is CGDATA
        sta $4301
        lda #<__data
        sta $4302
        lda #>__data
        sta $4303
        lda #$80
        sta $4304
        rep #$20
        lda #$0004
        sta $4305
        sep #$20
        lda #$01
        sta $420B               ; the last byte transferred lands on the bus
        lda $4200               ; open bus, but now driven by the DMA
        sta $7E4000
        lda #$FF
        sta $7E4FFF
__end:  bra __end

__data: .byte $11, $22, $33, $9C
"""


def test_dma_leaves_its_last_byte_on_the_bus():
    """DMA drives the same lines the CPU does, so it moves the latch."""
    r = run(DMA_SOURCE)
    check("bus after DMA", r[0], 0x42)


def main():
    print("open bus")
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in tests:
        before = len(FAILURES)
        try:
            fn()
        except Exception as exc:
            FAILURES.append("%s raised %s: %s" % (fn.__name__, type(exc).__name__, exc))
        print("  %-56s %s" % (fn.__name__, "ok" if len(FAILURES) == before else "FAIL"))
    print()
    if FAILURES:
        print("%d failure(s):" % len(FAILURES))
        for f in FAILURES:
            print("  " + f)
        return 1
    print("all open bus tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
