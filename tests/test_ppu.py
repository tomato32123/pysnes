"""PPU rendering tests.

The programs here set the PPU up through its registers the way a game does --
forced blank, CGRAM, VRAM, a tilemap, then the screen on -- and the assertions
read individual pixels out of the framebuffer.  Colours are checked against
values worked out from the register writes, so these are correctness tests
rather than snapshots of whatever the renderer happened to produce.

A scene hash is also recorded.  That one *is* a snapshot: its job is to make a
rendering change announce itself rather than to say the output is right.
"""
import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.testrom import run

W, H = 256, 239
FAILURES = []


def check(name, got, want, fmt="%s"):
    if got != want:
        FAILURES.append("%s: got %s, want %s" % (name, fmt % (got,), fmt % (want,)))


def pixel(machine, x, y):
    """(r, g, b) at a screen position."""
    fb = machine.framebuffer
    i = (y * W + x) * 4
    return (fb[i + 2], fb[i + 1], fb[i + 0])


def expand(five):
    """5-bit channel to 8, the way the renderer does it."""
    return (five << 3) | (five >> 2)


# A colour word is 0BBBBBGGGGGRRRRR.
BLUE = 0x7C00           # B = 31
RED = 0x001F            # R = 31
GREEN = 0x03E0          # G = 31

SETUP = """
        sep #$20
        lda #$8F
        sta $2100               ; forced blank while we load memory

        ; palette entry 0 = %(c0)s, entry 1 = %(c1)s
        stz $2121
        lda #<%(c0)s
        sta $2122
        lda #>%(c0)s
        sta $2122
        lda #<%(c1)s
        sta $2122
        lda #>%(c1)s
        sta $2122

        lda #$80
        sta $2115               ; VMAIN: step 1, increment on the high byte

        ; tile 1 at word $0010: bitplane 0 all ones, so every pixel is colour 1
        rep #$20
        lda #$0010
        sta $2116
        ldx #$0008
tilelo: lda #$00FF
        sta $2118
        dex
        bne tilelo
        ldx #$0008
tilehi: lda #$0000
        sta $2118
        dex
        bne tilehi

        ; tilemap at word $0400, first entry selects tile 1
        lda #$0400
        sta $2116
        lda #$0001
        sta $2118
        sep #$20

        lda #$04
        sta $2107               ; BG1 map base $0400, 32x32
        stz $210B               ; BG1 character base $0000
        lda #$01
        sta $2105               ; mode 1, 8x8 tiles
"""

SHOW = """
        lda #$01
        sta $212C               ; BG1 on the main screen
        lda #$0F
        sta $2100               ; screen on, full brightness
spin:   bra spin
"""


def scene(setup_extra="", c0=BLUE, c1=RED, frames=4):
    source = (SETUP % {"c0": "$%04X" % c0, "c1": "$%04X" % c1}) + setup_extra + SHOW
    return run(source, max_frames=frames).machine


def test_backdrop_fills_the_screen():
    """With no layer enabled every pixel is CGRAM entry 0."""
    source = (SETUP % {"c0": "$%04X" % BLUE, "c1": "$%04X" % RED}) + """
        stz $212C               ; nothing on the main screen
        lda #$0F
        sta $2100
spin:   bra spin
"""
    machine = run(source, max_frames=4).machine
    want = (0, 0, expand(31))
    check("backdrop at (0,0)", pixel(machine, 0, 0), want)
    check("backdrop at (128,100)", pixel(machine, 128, 100), want)
    check("backdrop at (255,223)", pixel(machine, 255, 223), want)


def test_bg1_tile_is_drawn_where_the_tilemap_puts_it():
    machine = scene()
    red = (expand(31), 0, 0)
    blue = (0, 0, expand(31))
    check("tile pixel (0,0)", pixel(machine, 0, 0), red)
    check("tile pixel (7,7)", pixel(machine, 7, 7), red)
    check("outside the tile (8,0)", pixel(machine, 8, 0), blue)
    check("outside the tile (0,8)", pixel(machine, 0, 8), blue)


def test_forced_blank_is_black():
    source = (SETUP % {"c0": "$%04X" % BLUE, "c1": "$%04X" % RED}) + """
        lda #$01
        sta $212C
        lda #$8F
        sta $2100               ; leave forced blank on
spin:   bra spin
"""
    machine = run(source, max_frames=4).machine
    check("forced blank at (0,0)", pixel(machine, 0, 0), (0, 0, 0))
    check("forced blank at (100,100)", pixel(machine, 100, 100), (0, 0, 0))


def test_brightness_scales_the_output():
    """INIDISP brightness n scales a channel by (n+1)/16."""
    source = (SETUP % {"c0": "$%04X" % BLUE, "c1": "$%04X" % RED}) + """
        lda #$01
        sta $212C
        lda #$07
        sta $2100               ; brightness 7 of 15
spin:   bra spin
"""
    machine = run(source, max_frames=4).machine
    want = expand((31 * 8) >> 4)
    check("half-bright red", pixel(machine, 0, 0)[0], want, "%d")


def test_scroll_moves_the_layer():
    machine = scene("""
        lda #$04
        sta $210D               ; BG1 horizontal scroll low byte
        stz $210D               ; high byte
""")
    red = (expand(31), 0, 0)
    blue = (0, 0, expand(31))
    # Scrolling right by 4 moves the tile 4 pixels to the left.
    check("scrolled tile at (0,0)", pixel(machine, 0, 0), red)
    check("scrolled tile at (3,0)", pixel(machine, 3, 0), red)
    check("past the scrolled tile (4,0)", pixel(machine, 4, 0), blue)


def test_scene_hash_is_stable():
    """A snapshot, so a change in rendering has to be looked at deliberately."""
    machine = scene()
    digest = hashlib.sha1(bytes(machine.framebuffer)).hexdigest()
    expected = os.environ.get("PYSNES_PPU_HASH")
    if expected:
        check("scene hash", digest, expected)
    else:
        print("      scene hash: %s" % digest)


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in tests:
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
    print("all PPU tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
