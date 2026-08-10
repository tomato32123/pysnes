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
    """INIDISP brightness n scales a channel by n/15: level 0 is black."""
    source = (SETUP % {"c0": "$%04X" % BLUE, "c1": "$%04X" % RED}) + """
        lda #$01
        sta $212C
        lda #$07
        sta $2100               ; brightness 7 of 15
spin:   bra spin
"""
    machine = run(source, max_frames=4).machine
    want = expand((31 * 7 + 7) // 15)
    check("brightness 7 of 15 on red", pixel(machine, 0, 0)[0], want, "%d")


def test_brightness_zero_is_black():
    source = (SETUP % {"c0": "$%04X" % BLUE, "c1": "$%04X" % RED}) + """
        lda #$01
        sta $212C
        lda #$00
        sta $2100               ; brightness 0, screen not forced blank
spin:   bra spin
"""
    machine = run(source, max_frames=4).machine
    check("brightness 0 on the tile", pixel(machine, 0, 0), (0, 0, 0))
    check("brightness 0 on the backdrop", pixel(machine, 128, 100), (0, 0, 0))


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


def test_register_write_takes_effect_mid_scanline():
    """The point of drawing by dot: a write part-way along a line must change
    only the pixels to its right.

    An IRQ is armed for one dot of one line and its handler blanks the screen;
    the NMI handler puts the brightness back during V-blank so the split
    repeats every frame.  Row 99 is the one being scanned out during line 100,
    so that is the row that ends up half drawn.
    """
    source = (SETUP % {"c0": "$%04X" % BLUE, "c1": "$%04X" % RED}) + """
        stz $212C               ; backdrop only, so every pixel is CGRAM 0
        lda #$0F
        sta $2100

        lda #$64
        sta $4209               ; VTIME = line 100
        stz $420A
        lda #$96
        sta $4207               ; HTIME = dot 150
        stz $4208
        lda #$B0                ; NMI on, IRQ on H and V together
        sta $4200
        cli
spin:   bra spin
irq:    sep #$20
        lda #$00
        sta $2100               ; blank from this dot rightwards
        lda $4211
        rti
nmi:    sep #$20
        lda #$0F
        sta $2100               ; restore during V-blank, ready for the next frame
        lda $4210
        rti
"""
    machine = run(source, max_frames=6).machine
    blue = (0, 0, expand(31))
    black = (0, 0, 0)
    check("row above the split is whole", pixel(machine, 200, 50), blue)
    check("left of the write on the split row", pixel(machine, 40, 99), blue)
    check("right of the write on the split row", pixel(machine, 220, 99), black)
    check("row below the split is blank", pixel(machine, 128, 150), black)


def test_mid_scanline_split_lands_near_the_requested_dot():
    """Scan the split row for the transition and check it is where HTIME put it."""
    source = (SETUP % {"c0": "$%04X" % BLUE, "c1": "$%04X" % RED}) + """
        stz $212C
        lda #$0F
        sta $2100
        lda #$64
        sta $4209
        stz $420A
        lda #$96
        sta $4207               ; HTIME = dot 150 -> screen column 128
        stz $4208
        lda #$B0
        sta $4200
        cli
spin:   bra spin
irq:    sep #$20
        lda #$00
        sta $2100
        lda $4211
        rti
nmi:    sep #$20
        lda #$0F
        sta $2100
        lda $4210
        rti
"""
    machine = run(source, max_frames=6).machine
    edge = None
    for x in range(W):
        if pixel(machine, x, 99) == (0, 0, 0):
            edge = x
            break
    if edge is None:
        FAILURES.append("the split row never goes dark")
        return
    # Output starts at dot 22, so HTIME 150 is column 128.  The interrupt is
    # taken at an instruction boundary and the handler takes a few more, so the
    # edge sits a little to the right of that.
    if not 128 <= edge <= 128 + 40:
        FAILURES.append("split at column %d, expected between 128 and 168" % edge)
    else:
        print("      split column: %d (HTIME 150 -> column 128)" % edge)


# --------------------------------------------------- offset-per-tile ----

OPT_SETUP = """
        sep #$20
        lda #$8F
        sta $2100

        ; palette 0 = blue backdrop, 1 = red
        stz $2121
        lda #$00
        sta $2122
        lda #$7C
        sta $2122
        lda #$1F
        sta $2122
        lda #$00
        sta $2122

        lda #$80
        sta $2115

        ; tile 1 at word $0010: solid colour 1
        rep #$20
        lda #$0010
        sta $2116
        ldx #$0008
optlo:  lda #$00FF
        sta $2118
        dex
        bne optlo
        ldx #$0008
opthi:  lda #$0000
        sta $2118
        dex
        bne opthi

        ; BG1 tilemap at word $0400: the first two tiles are solid, the rest
        ; empty, so shifting a column has something visible to reveal
        lda #$0400
        sta $2116
        lda #$0001
        sta $2118
        lda #$0001
        sta $2118
        ldx #$001E
map1:   lda #$0000
        sta $2118
        dex
        bne map1

        ; BG3 tilemap at word $0800 holds the per-column offsets.
        ; Entry for screen column 1 sits at BG3 tile column 0.
        lda #$0800
        sta $2116
        lda #%(entry)s
        sta $2118
        sep #$20

        lda #$04
        sta $2107               ; BG1 map base $0400
        lda #$08
        sta $2109               ; BG3 map base $0800
        stz $210B               ; BG1 characters at $0000
        stz $210C               ; BG3 characters at $0000
        lda #$02
        sta $2105               ; mode 2: BG3 is the offset source
        lda #$01
        sta $212C               ; BG1 on the main screen
        lda #$0F
        sta $2100
spin:   bra spin
"""


def test_offset_per_tile_shifts_one_column():
    """Mode 2: a BG3 entry with bit 13 set moves that column of BG1.

    Only the first two tiles of the BG1 row are solid.  Column 1 normally
    shows the second of them; an offset of 16 makes it sample two tiles
    further along, which is empty, so the column turns into backdrop while
    column 0 -- which has no entry -- stays solid.
    """
    plain = run(OPT_SETUP % {"entry": "$0000"}, max_frames=4).machine
    shifted = run(OPT_SETUP % {"entry": "$2010"}, max_frames=4).machine

    red = (expand(31), 0, 0)
    blue = (0, 0, expand(31))
    check("column 0 has no entry and stays solid", pixel(shifted, 4, 0), red)
    check("column 1 is solid without an offset", pixel(plain, 12, 0), red)
    check("column 1 moves to empty tilemap with one", pixel(shifted, 12, 0), blue)


def test_offset_per_tile_ignores_the_other_layer_bit():
    """An entry marked for BG2 only must leave BG1 alone."""
    bg2_only = run(OPT_SETUP % {"entry": "$4020"}, max_frames=4).machine
    plain = run(OPT_SETUP % {"entry": "$0000"}, max_frames=4).machine
    for x in (4, 12, 20):
        check("BG2-only entry leaves BG1 at x=%d" % x,
              pixel(bg2_only, x, 0), pixel(plain, x, 0))


# -------------------------------------------------- access windows ----

ACCESS_SOURCE = """
        sep #$20
        lda #$8F
        sta $2100               ; forced blank: everything is reachable

        lda #$80
        sta $2115               ; VMAIN: step 1, increment on the high byte
        rep #$20
        lda #$0100
        sta $2116
        lda #$1234
        sta $2118               ; seed word $0100 while blanked
        lda #$0102
        sta $2116
        lda #$1234
        sta $2118               ; and word $0102
        sep #$20

        lda #$0F
        sta $2100               ; screen on

        lda #$64
        sta $4209               ; VTIME = line 100, well inside the display
        stz $420A
        lda #$96
        sta $4207
        stz $4208
        lda #$B0                ; NMI on, IRQ on H and V
        sta $4200
        cli
spin:   bra spin

irq:    rep #$20
        lda #$0100
        sta $2116
        lda #$BEEF
        sta $2118               ; mid-display: the hardware drops this
        sep #$20
        lda $4211
        rti

nmi:    rep #$20
        lda #$0102
        sta $2116
        lda #$ABCD
        sta $2118               ; V-blank: this one must land
        ; read both words back
        lda #$0100
        sta $2116
        sep #$20
        lda $2139
        sta $7E4100
        lda $213A
        sta $7E4101
        rep #$20
        lda #$0102
        sta $2116
        sep #$20
        lda $2139
        sta $7E4102
        lda $213A
        sta $7E4103
        lda $4210
        rti
"""


def test_vram_writes_are_dropped_during_display():
    machine = run(ACCESS_SOURCE, max_frames=6).machine
    blocked = machine.bus.read(0x7E4100) | (machine.bus.read(0x7E4101) << 8)
    allowed = machine.bus.read(0x7E4102) | (machine.bus.read(0x7E4103) << 8)
    check("VRAM write during display was dropped", blocked, 0x1234, "$%04X")
    check("VRAM write during V-blank landed", allowed, 0xABCD, "$%04X")


def test_vram_writes_work_under_forced_blank():
    """The restriction must not touch the case every game relies on at boot."""
    machine = run("""
        sep #$20
        lda #$8F
        sta $2100
        lda #$80
        sta $2115
        rep #$20
        lda #$0200
        sta $2116
        lda #$5A5A
        sta $2118
        lda #$0200
        sta $2116
        sep #$20
        lda $2139
        sta $7E4100
        lda $213A
        sta $7E4101
""", max_frames=4)
    got = machine.machine.bus.read(0x7E4100) | (machine.machine.bus.read(0x7E4101) << 8)
    check("forced-blank VRAM write", got, 0x5A5A, "$%04X")


def test_cgram_writes_are_dropped_mid_line():
    """CGRAM is reachable in a line's margins but not while pixels are output."""
    machine = run("""
        sep #$20
        lda #$8F
        sta $2100
        stz $2121
        lda #$00
        sta $2122
        lda #$7C
        sta $2122               ; entry 0 = blue, set while blanked
        stz $212C
        lda #$0F
        sta $2100
        lda #$64
        sta $4209
        stz $420A
        lda #$96
        sta $4207               ; dot 150, inside the visible part of the line
        stz $4208
        lda #$30
        sta $4200
        cli
spin:   bra spin
irq:    sep #$20
        stz $2121
        lda #$1F
        sta $2122
        lda #$00
        sta $2122               ; try to make the backdrop red mid-line
        lda $4211
        rti
""", max_frames=6).machine
    # The backdrop must still be blue: the write never reached CGRAM.
    check("CGRAM held its value through the line", pixel(machine, 200, 150),
          (0, 0, expand(31)))


# --------------------------------------------------------------- HDMA ----

HDMA_SOURCE = """
        sep #$20
        lda #$8F
        sta $2100
        stz $2121
        lda #$1F
        sta $2122
        lda #$00
        sta $2122               ; backdrop red, so brightness is easy to read
        stz $212C

        ; build the HDMA table in WRAM at $7E5000
%(table)s

        lda #$00
        sta $4300               ; one register per line, A -> B
        lda #$00
        sta $4301               ; target $2100, INIDISP
        rep #$20
        lda #$5000
        sta $4302
        sep #$20
        lda #$7E
        sta $4304               ; table at $7E5000
        lda #$0F
        sta $2100               ; screen on before HDMA starts driving it
        lda #$01
        sta $420C               ; enable HDMA channel 0
spin:   bra spin
"""


def build_table(values):
    """Assembly that writes a byte sequence to $7E5000."""
    out = []
    for i, v in enumerate(values):
        out.append("        lda #$%02X" % v)
        out.append("        sta $7E%04X" % (0x5000 + i))
    return chr(10).join(out)


def brightness_of_row(machine, y):
    """Recover the brightness level from a red backdrop row."""
    r = pixel(machine, 128, y)[0]
    for level in range(16):
        if expand((31 * level + 7) // 15) == r:
            return level
    return -1


def test_hdma_repeat_mode_writes_a_value_per_line():
    """Bit 7 of the count means "send on each of these lines"."""
    table = build_table([0x84, 0x0F, 0x00, 0x0F, 0x00, 0x00])
    machine = run(HDMA_SOURCE % {"table": table}, max_frames=6).machine
    levels = [brightness_of_row(machine, y) for y in range(6)]
    # Four lines get their own value, then the table terminates and the last
    # written value sticks.
    if levels[0] == levels[1]:
        FAILURES.append("repeat mode wrote the same value to consecutive rows: %s"
                        % levels[:6])
    else:
        print("      repeat-mode brightness by row: %s" % levels[:6])


def test_hdma_non_repeat_holds_a_value():
    """Without bit 7 the value is written once and held for the whole run."""
    table = build_table([0x04, 0x00, 0x04, 0x0F, 0x00])
    machine = run(HDMA_SOURCE % {"table": table}, max_frames=6).machine
    levels = [brightness_of_row(machine, y) for y in range(10)]
    first = levels[1]
    if any(l != first for l in levels[1:4]):
        FAILURES.append("non-repeat mode did not hold its value: %s" % levels[:10])
    else:
        print("      non-repeat brightness by row: %s" % levels[:10])


def test_hdma_terminates_on_a_zero_count():
    """A zero count ends the channel; the register keeps its last value."""
    table = build_table([0x82, 0x00, 0x00, 0x00])
    machine = run(HDMA_SOURCE % {"table": table}, max_frames=6).machine
    later = brightness_of_row(machine, 120)
    check("value held after the table ended", later, 0, "%d")


def test_hdma_enabled_mid_frame_waits_for_the_next_frame():
    """The init pass happens once per frame; enabling later does nothing until
    the next one."""
    machine = run("""
        sep #$20
        lda #$8F
        sta $2100
        stz $2121
        lda #$1F
        sta $2122
        lda #$00
        sta $2122
        stz $212C
        lda #$0F
        sta $2100
        ; set the channel up but only enable it from inside the display
        lda #$00
        sta $4300
        lda #$00
        sta $4301
        rep #$20
        lda #$5000
        sta $4302
        sep #$20
        lda #$7E
        sta $4304
        lda #$82
        sta $7E5000
        lda #$00
        sta $7E5001
        lda #$00
        sta $7E5002
        lda #$00
        sta $7E5003

        lda #$64
        sta $4209
        stz $420A
        lda #$20                ; V-only IRQ on line 100
        sta $4200
        cli
spin:   bra spin
irq:    sep #$20
        lda #$01
        sta $420C               ; enable HDMA part-way down the first frame
        lda $4211
        rti
""", max_frames=1).machine
    # Only the first frame is examined.  The init pass that arms a channel runs
    # at the top of a frame, so nothing can transfer until the next one; rows
    # below line 100 must still be at full brightness.
    check("mid-frame enable does not start the channel",
          brightness_of_row(machine, 150), 15, "%d")


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
