"""65816 regression tests, run as real 65816 programs.

Each case is assembled into a bootable image, executed by the emulator, and
checked against values the program itself computed.  That keeps the tests
honest: they exercise the same fetch, decode and bus path a game would.

Timing cases assert master-clock deltas.  Every bus access to slow ROM costs
8 master cycles and every internal cycle costs 6, so an instruction the
datasheet calls "2 cycles" -- one opcode fetch plus one internal cycle -- must
take 14 here.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.testrom import run, assemble_image
from snes.system import System

FAILURES = []


def check(name, got, want, fmt="$%02X"):
    ok = got == want
    if not ok:
        FAILURES.append("%s: got %s, want %s" % (name, fmt % got, fmt % want))
    return ok


# ---------------------------------------------------------------- flags ----

def test_adc_flags_8bit():
    r = run("""
        sep #$20
        clc
        lda #$50
        adc #$50            ; 80 + 80 -> $A0, overflow, negative
        sta result+0
        php
        pla
        sta result+1

        clc
        lda #$FF
        adc #$01            ; wraps to 0, carry set, zero set
        sta result+2
        php
        pla
        sta result+3

        sec
        lda #$7F
        adc #$00            ; 127 + carry -> $80, overflow
        sta result+4
        php
        pla
        sta result+5
    """)
    assert r.finished
    check("ADC $50+$50 result", r[0], 0xA0)
    check("ADC $50+$50 flags", r[1] & 0xC3, 0xC0)          # N and V, no Z or C
    check("ADC $FF+$01 result", r[2], 0x00)
    check("ADC $FF+$01 flags", r[3] & 0xC3, 0x03)          # Z and C
    check("ADC $7F+carry result", r[4], 0x80)
    check("ADC $7F+carry flags", r[5] & 0xC3, 0xC0)        # N and V


def test_sbc_and_cmp():
    r = run("""
        sep #$20
        sec
        lda #$50
        sbc #$B0            ; 80 - 176 -> $A0, borrow, overflow
        sta result+0
        php
        pla
        sta result+1

        sec
        lda #$40
        cmp #$40            ; equal: Z and C set, A unchanged
        sta result+2
        php
        pla
        sta result+3

        lda #$10
        cmp #$20            ; less: no carry, negative
        php
        pla
        sta result+4
    """)
    assert r.finished
    check("SBC result", r[0], 0xA0)
    check("SBC flags", r[1] & 0xC3, 0xC0)                  # N, V, borrow -> C clear
    check("CMP leaves A", r[2], 0x40)
    check("CMP equal flags", r[3] & 0x83, 0x03)            # Z and C
    check("CMP less flags", r[4] & 0x83, 0x80)             # N only


def test_decimal_mode():
    r = run("""
        sep #$20
        sed
        clc
        lda #$09
        adc #$01            ; BCD 09 + 01 = 10
        sta result+0
        clc
        lda #$99
        adc #$01            ; BCD 99 + 01 = 00 with carry
        sta result+1
        php
        pla
        sta result+2
        sec
        lda #$10
        sbc #$01            ; BCD 10 - 01 = 09
        sta result+3
        cld
    """)
    assert r.finished
    check("decimal ADC 09+01", r[0], 0x10)
    check("decimal ADC 99+01", r[1], 0x00)
    check("decimal carry out", r[2] & 0x01, 0x01)
    check("decimal SBC 10-01", r[3], 0x09)


def test_16bit_arithmetic():
    r = run("""
        rep #$20
        clc
        lda #$7FFF
        adc #$0001          ; overflow into the sign bit
        sta result+0
        php
        sep #$20
        pla                 ; A is 8-bit here so this matches the 1-byte PHP
        sta result+2
        rep #$20
        clc
        lda #$FFFF
        adc #$0001          ; wraps, carry out
        sta result+3
        php
        sep #$20
        pla
        sta result+5
    """)
    assert r.finished
    check("16-bit ADC result", r.word(0), 0x8000, "$%04X")
    check("16-bit ADC flags", r[2] & 0xC3, 0xC0)
    check("16-bit ADC wrap", r.word(3), 0x0000, "$%04X")
    check("16-bit carry out", r[5] & 0x03, 0x03)


# ------------------------------------------------------- addressing modes ----

def test_addressing_modes():
    r = run("""
        rep #$30
        lda #$0200
        tcd                 ; direct page at $0200
        sep #$30

        lda #$AA
        sta $10             ; -> $0210
        lda #$BB
        ldx #$05
        sta $10,x           ; -> $0215

        rep #$20
        lda #$0210
        sta $30             ; pointer at $0230 -> $0210
        sep #$20

        lda ($30)           ; (dp) reads $0210
        sta result+0
        ldy #$05
        lda ($30),y         ; (dp),Y reads $0215
        sta result+1

        rep #$20
        lda #$0210
        sta $40
        sep #$20
        lda #$00
        sta $42             ; long pointer bank 0
        lda [$40]
        sta result+2
        ldy #$05
        lda [$40],y
        sta result+3

        lda $000210         ; absolute long
        sta result+4
        ldx #$0005
        lda $000210,x
        sta result+5
    """)
    assert r.finished
    check("(dp)", r[0], 0xAA)
    check("(dp),Y", r[1], 0xBB)
    check("[dp]", r[2], 0xAA)
    check("[dp],Y", r[3], 0xBB)
    check("long", r[4], 0xAA)
    check("long,X", r[5], 0xBB)


def test_stack_relative():
    r = run("""
        rep #$30
        lda #$1234
        pha                 ; on the stack at S+1, S+2
        lda #$0000
        lda $01,s           ; stack relative read
        sta result+0
        pla
        sep #$20
    """)
    assert r.finished
    check("sr,S read", r.word(0), 0x1234, "$%04X")


def test_read_modify_write():
    r = run("""
        sep #$20
        lda #$81
        sta $0300
        asl $0300           ; $81 -> $02 with carry
        lda $0300
        sta result+0
        php
        pla
        sta result+1

        lda #$01
        sta $0301
        dec $0301           ; -> 0, zero flag
        lda $0301
        sta result+2

        lda #$0F
        sta $0302
        lda #$F0
        tsb $0302           ; set bits: $FF, Z from A AND memory
        php
        pla
        sta result+4        ; capture before LDA overwrites N and Z
        lda $0302
        sta result+3

        lda #$0F
        trb $0302           ; clear bits -> $F0
        lda $0302
        sta result+5
    """)
    assert r.finished
    check("ASL memory", r[0], 0x02)
    check("ASL carry out", r[1] & 0x01, 0x01)
    check("DEC to zero", r[2], 0x00)
    check("TSB sets bits", r[3], 0xFF)
    check("TSB zero flag", r[4] & 0x02, 0x02)             # $F0 AND $0F == 0
    check("TRB clears bits", r[5], 0xF0)


def test_block_move():
    r = run("""
        rep #$30
        lda #$1111
        sta $0400
        lda #$2222
        sta $0402
        lda #$0003          ; move 4 bytes
        ldx #$0400
        ldy #$0500
        mvn $00,$00
        sep #$20
        lda $0500
        sta result+0
        lda $0503
        sta result+1
        ; MVN leaves the data bank as the destination bank
        phb
        pla
        sta result+2
    """)
    assert r.finished
    check("MVN first byte", r[0], 0x11)
    check("MVN last byte", r[1], 0x22)
    check("MVN sets DB", r[2], 0x00)


def test_emulation_mode_stack_wraps():
    """In emulation mode the stack lives in page 1 and wraps inside it."""
    r = run("""
        sec
        xce                 ; back to emulation mode
        lda #$00
        tax
        txs                 ; S = $0100
        lda #$AA
        pha                 ; writes $0100, S wraps to $01FF
        tsx
        stx $00
        clc
        xce                 ; native again so the harness can finish
        sep #$20
        lda $00
        sta result+0
        lda $000100
        sta result+1
    """)
    assert r.finished
    check("S wrapped inside page 1", r[0], 0xFF)
    check("pushed byte landed at $0100", r[1], 0xAA)


def test_interrupt_and_rti():
    r = run("""
        sep #$20
        lda #$00
        sta result+0
        cop #$12            ; vectors to the harness's irq label
        lda #$77
        sta result+1
        bra done
irq:    sep #$20
        lda #$55
        sta result+0
        rti
done:
    """)
    assert r.finished
    check("COP ran the handler", r[0], 0x55)
    check("RTI resumed after COP", r[1], 0x77)


# ------------------------------------------------------------- timing ------

def measure(source, count):
    """Master-clock deltas for the first `count` instructions after the marker."""
    image, _labels = assemble_image("""
        sep #$30
        nop                 ; marker: the NOP before the sequence under test
""" + source)
    machine = System(rom_data=image)
    machine.cpu.trace_start(capacity=400, level=1)
    for _ in range(3):
        machine.run_frame()
        if machine.bus.read(0x7E4FFF):
            break
    recs = machine.cpu.trace_instructions()
    # find the marker NOP that follows a SEP
    start = None
    for i in range(1, len(recs)):
        if recs[i][3] == 0xEA and recs[i - 1][3] == 0xE2:
            start = i
            break
    assert start is not None, "marker not found"
    clocks = [recs[i][0] for i in range(start, start + count + 2)]
    return [clocks[i + 1] - clocks[i] for i in range(count + 1)]


def test_instruction_timing():
    # Slow ROM: 8 master cycles per bus access, 6 per internal cycle.
    deltas = measure("""
        nop                 ; 2 cycles: fetch + io          = 8 + 6  = 14
        lda #$12            ; 2 cycles: two fetches         = 16
        lda $10             ; 3 cycles: 2 fetches + 1 read  = 24
        lda $1234           ; 4 cycles: 3 fetches + 1 read  = 32
        nop
    """, 5)
    # deltas[0] is the marker NOP itself.
    check("NOP", deltas[1], 14, "%d")
    check("LDA #imm (8-bit)", deltas[2], 16, "%d")
    check("LDA dp", deltas[3], 24, "%d")
    check("LDA abs", deltas[4], 32, "%d")


def test_direct_page_penalty():
    """A non-zero low byte of D costs one extra internal cycle."""
    fast = measure("""
        lda $10
        nop
    """, 2)
    image, _ = assemble_image("""
        rep #$30
        lda #$0201          ; D low byte non-zero
        tcd
        sep #$30
        nop
        lda $10
        nop
    """)
    machine = System(rom_data=image)
    machine.cpu.trace_start(capacity=400, level=1)
    for _ in range(3):
        machine.run_frame()
        if machine.bus.read(0x7E4FFF):
            break
    recs = machine.cpu.trace_instructions()
    start = next(i for i in range(1, len(recs))
                 if recs[i][3] == 0xEA and recs[i - 1][3] == 0xE2)
    slow_delta = recs[start + 2][0] - recs[start + 1][0]
    check("LDA dp with DL=0", fast[1], 24, "%d")
    check("LDA dp with DL!=0", slow_delta, 30, "%d")       # one extra io cycle


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in tests:
        before = len(FAILURES)
        try:
            fn()
        except Exception as exc:
            FAILURES.append("%s raised %s: %s" % (fn.__name__, type(exc).__name__, exc))
        status = "ok" if len(FAILURES) == before else "FAIL"
        print("  %-34s %s" % (fn.__name__, status))
    print()
    if FAILURES:
        print("%d failure(s):" % len(FAILURES))
        for f in FAILURES:
            print("  " + f)
        return 1
    print("all CPU tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
