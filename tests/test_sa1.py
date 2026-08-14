"""The SA-1's memory protection, from the console's side of it.

An SA-1 cartridge has two memories the console can reach -- 2 KB of fast
internal RAM at $3000 and the battery RAM at $6000 and $40:0000 -- and both
are protected by registers that start closed.  A cartridge that has not
asked for permission cannot write either, which is the part that was
missing: writes went through unconditionally, so a protection test found
nothing to protect and every value it read back was wrong.

These run 65816 programs on a cartridge whose header says SA-1, the same
way a game gets there.  The SA-1 processor itself stays in reset -- the
console holds it there at power-up -- so what is under test is only the
memory guard, which is the part games and this console share.

absindx's SA1RamProtectionTest checks all of this and 200 things besides,
against a photograph of the author's own Super Famicom.  It is the better
test and it is not in this repository; these are here so the same defects
cannot come back on a machine that has no cartridges at all.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.testrom import run

SA1 = 0x35                           # the header byte for an SA-1 board
SRAM_128K = 0x07                     # 1024 << 7
FAILURES = []


def check(name, got, want):
    if got != want:
        FAILURES.append("%s: got %s, wanted %s" % (name, got, want))


def sa1(source):
    return run(source, chipset=SA1, sram=SRAM_128K, max_frames=30)


def test_iram_is_shut_until_the_cartridge_opens_it():
    """$2229 starts at zero, and zero means the console may not write."""
    r = sa1("""
        lda #$AA
        sta $3000
        lda $3000
        sta result+0            ; still nothing, because nothing was allowed

        lda #$FF
        sta $2229               ; every block open
        lda #$AA
        sta $3000
        lda $3000
        sta result+1
    """)
    check("blocked write", r[0], 0x00)
    check("permitted write", r[1], 0xAA)


def test_each_bit_of_2229_covers_256_bytes():
    """Eight bits over 2 KB, so bit 0 is $3000-$30FF and bit 1 the next."""
    r = sa1("""
        lda #$01
        sta $2229               ; the first block only
        lda #$11
        sta $3000
        lda #$22
        sta $3100
        lda $3000
        sta result+0
        lda $3100
        sta result+1
    """)
    check("open block", r[0], 0x11)
    check("shut block", r[1], 0x00)


def test_the_console_cannot_open_the_sa1s_own_protection():
    """$222A belongs to the SA-1.  A write from this side does nothing.

    Without this the console could unprotect I-RAM against the SA-1's
    wishes, which would make the register pointless -- and the console's
    own $2229 would then be the only thing standing between the two.
    """
    r = sa1("""
        lda #$FF
        sta $222A               ; the SA-1's register, not ours
        lda #$AA
        sta $3000               ; ours is still shut
        lda $3000
        sta result+0
    """)
    check("write through the wrong register", r[0], 0x00)


def test_battery_ram_is_shut_until_2226_opens_it():
    """Battery RAM comes up filled rather than cleared, so a blocked write
    is shown by the memory keeping what was put there while it was open --
    reading a zero back would prove nothing."""
    r = sa1("""
        lda #$80
        sta $2226               ; write enable
        lda #$11
        sta $406000
        stz $2226               ; and shut again
        lda #$22
        sta $406000
        lda $406000
        sta result+0
    """)
    check("write after the memory was shut", r[0], 0x11)


def test_2228_says_how_much_of_the_battery_ram_is_protected():
    """256 bytes doubled once per step, from the front of the memory."""
    r = sa1("""
        lda #$80
        sta $2226
        lda #$11
        sta $400000
        sta $400100             ; both known, while everything is open

        stz $2226               ; shut, so the area applies
        stz $2228               ; $00: the first 256 bytes
        lda #$22
        sta $400000             ; inside the protected area
        sta $400100             ; just past it
        lda $400000
        sta result+0
        lda $400100
        sta result+1
    """)
    check("inside the protected area", r[0], 0x11)
    check("outside it", r[1], 0x22)


def main():
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
            except Exception as exc:                 # a crash is a failure
                FAILURES.append("%s raised %r" % (name, exc))
    for line in FAILURES:
        print("  " + line)
    if FAILURES:
        print("%d failed" % len(FAILURES))
        return 1
    print("sa1 protection ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
