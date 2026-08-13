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

W, H = 512, 478
NL = chr(10)
FAILURES = []


def check(name, got, want, fmt="%s"):
    if got != want:
        FAILURES.append("%s: got %s, want %s" % (name, fmt % (got,), fmt % (want,)))


def hipixel(machine, hx, y):
    """(r, g, b) at a raw buffer column, of which there are 512."""
    fb = machine.framebuffer
    i = (y * W + hx) * 4
    return (fb[i + 2], fb[i + 1], fb[i + 0])


def pixel(machine, x, y):
    """(r, g, b) for a dot.  Every dot is two buffer columns; this is the
    right-hand one, which is the main screen in every mode."""
    return hipixel(machine, x * 2 + 1, y)


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

        ; Scroll up one line.  Scanline 0 is never displayed, so the first row
        ; on screen is scanline 1 and a layer with no scroll shows its *second*
        ; line there.  Real games write $FFFF here for exactly this reason, and
        ; the tests below want the top-left tile at the top left of the screen.
        lda #$FF
        sta $210E
        sta $210E               ; BG1VOFS = -1
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


def test_overscan_draws_fifteen_more_rows_and_moves_vblank():
    """$2133 bit 2 makes the display 239 lines instead of 224, which pushes
    V-blank -- and the NMI with it -- fifteen lines down the frame."""
    blue = (0, 0, expand(31))
    plain = scene()
    check("row 230 without overscan", pixel(plain, 0, 230), (0, 0, 0))
    check("visible height without overscan", plain.visible_height, 224)

    wide = scene("""
        lda #$04
        sta $2133               ; overscan
""")
    check("row 230 with overscan", pixel(wide, 0, 230), blue)
    check("row 238 with overscan", pixel(wide, 0, 238), blue)
    check("visible height with overscan", wide.visible_height, 239)


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


def test_a_layer_with_no_scroll_starts_one_line_down():
    """The first row on screen is scanline 1, not scanline 0.

    So a background scrolled to zero shows its *second* line at the top of the
    screen, and its first line is never displayed at all.  Games write $FFFF to
    BGnVOFS when they want the top of the map at the top of the screen, which
    is why an emulator can have this wrong for a long time and have every game
    still look almost right -- one line, at the very top.

    Here the tilemap's first row is one tile, all colour 1, over a backdrop of
    colour 0.  With no scroll the tile covers rows 0 to 6 of the screen and row
    7 is already past it; with the -1 scroll the rest of this file uses, it
    covers rows 0 to 7.
    """
    machine = scene("""
        stz $210E
        stz $210E               ; BG1VOFS = 0, undoing the setup's -1
""")
    red = (expand(31), 0, 0)
    blue = (0, 0, expand(31))
    check("top of the tile is on screen row 0", pixel(machine, 0, 0), red)
    check("tile's last visible row is 6", pixel(machine, 0, 6), red)
    check("row 7 is past the tile", pixel(machine, 0, 7), blue)


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



# ------------------------------------------------------- direct colour ----
#
# An 8bpp tile whose every pixel is $BA, in mode 3, with $2130 bit 0 set.
# Two tilemap entries side by side carry palettes 0 and 7, which change the
# low bit of each channel and so give two different shades of the same pixel.

DIRECT_SETUP = """
        sep #$20
        lda #$8F
        sta $2100
        lda #$80
        sta $2115               ; step 1, increment on the high byte

        rep #$20
        lda #$0000
        sta $2116               ; tile 0 of an 8bpp character at word $0000
        ldx #$0008
dp01:   lda #$FF00              ; the low byte is plane 0, so bits 1-0 = %%10
        sta $2118
        dex
        bne dp01
        ldx #$0008
dp23:   lda #$FF00              ; bits 3-2 = %%10
        sta $2118
        dex
        bne dp23
        ldx #$0008
dp45:   lda #$FFFF              ; bits 5-4 = %%11
        sta $2118
        dex
        bne dp45
        ldx #$0008
dp67:   lda #$FF00              ; bits 7-6 = %%10, so the pixel is $BA
        sta $2118
        dex
        bne dp67

        lda #$0400
        sta $2116
        lda #$0000
        sta $2118               ; column 0: tile 0, palette 0
        lda #$1C00
        sta $2118               ; column 1: tile 0, palette 7
        sep #$20

        lda #$04
        sta $2107               ; BG1 map base $0400
        stz $210B               ; BG1 character base $0000
        lda #$03
        sta $2105               ; mode 3: BG1 is 8 bits deep
        lda #$01
        sta $2130               ; CGWSEL: direct colour
"""

# The tile's pixel value, read back out of the planes written above.
DIRECT_PIXEL = 0xBA


def direct_colour(pixel_value, palette):
    r = ((pixel_value & 0x07) << 2) | ((palette & 1) << 1)
    g = ((pixel_value & 0x38) >> 1) | (palette & 2)
    b = ((pixel_value & 0xC0) >> 3) | ((palette & 4) << 1)
    return expand(r), expand(g), expand(b)


def test_direct_colour_turns_the_pixel_into_a_colour():
    """CGRAM is untouched, so anything but black proves the index was not
    looked up."""
    machine = run(DIRECT_SETUP + SHOW, max_frames=4).machine
    check("palette 0", pixel(machine, 0, 0), direct_colour(DIRECT_PIXEL, 0))
    check("palette 7", pixel(machine, 8, 0), direct_colour(DIRECT_PIXEL, 7))


def test_direct_colour_is_ignored_when_the_bit_is_clear():
    """Same scene without $2130 bit 0: now it is an index into CGRAM, which
    is still all zero, so the pixel is black."""
    plain = DIRECT_SETUP.replace("lda #$01" + NL + "        sta $2130",
                                 "stz $2130")
    machine = run(plain + SHOW, max_frames=4).machine
    check("no direct colour", pixel(machine, 0, 0), (0, 0, 0))


def test_direct_colour_does_not_reach_a_four_bit_layer():
    """Mode 1 has no 8bpp layer, so the bit must do nothing there."""
    machine = scene("""
        lda #$01
        sta $2130
""")
    check("mode 1 with the direct bit", pixel(machine, 0, 0), (expand(31), 0, 0))



# --------------------------------------------------------------- EXTBG ----
#
# Mode 7 draws one layer, but $2133 bit 6 splits it in two: BG1 keeps all
# eight bits of each pixel, while BG2 reads bit 7 as a priority and the low
# seven as its own palette index.  BG2's high half sits in front of BG1 and
# its low half behind, so the same pixel can be either.

MODE7_SETUP = """
        sep #$20
        lda #$8F
        sta $2100

        lda #$01
        sta $2121               ; CGRAM 1 = red: BG2's colour, and BG1's when
        lda #$1F                ; the pixel has no bit 7
        sta $2122
        lda #$00
        sta $2122
        lda #$81
        sta $2121               ; CGRAM $81 = blue: BG1's colour when it has
        lda #$00                ; the whole eight bits
        sta $2122
        lda #$7C
        sta $2122

        lda #$80
        sta $2115
        rep #$20
        lda #$0000
        sta $2116
        ldx #$0040
m7fill: lda #$%(pixel)02X00      ; low byte: tilemap entry 0; high byte: the pixel
        sta $2118
        dex
        bne m7fill
        sep #$20

        stz $211B
        lda #$01
        sta $211B               ; M7A = $0100
        stz $211C
        stz $211C
        stz $211D
        stz $211D
        stz $211E
        lda #$01
        sta $211E               ; M7D = $0100, so the matrix is the identity
        stz $211F
        stz $211F
        stz $2120
        stz $2120
        stz $210D
        stz $210D
        stz $210E
        stz $210E
        stz $211A
        lda #$07
        sta $2105               ; mode 7
"""

MODE7_SHOW = """
        lda #$%(layers)02X
        sta $212C
        lda #$%(extbg)02X
        sta $2133
        lda #$5F
        sta $2132               ; fixed colour: green at full
        lda #$%(math)02X
        sta $2131               ; which layers add it
        lda #$0F
        sta $2100
spin:   bra spin
"""


def mode7(pixel, layers, extbg, math=0x00):
    source = (MODE7_SETUP % {"pixel": pixel}
              + MODE7_SHOW % {"layers": layers, "extbg": 0x40 if extbg else 0,
                              "math": math})
    return run(source, max_frames=4).machine


RED_RGB = (expand(31), 0, 0)
BLUE_RGB = (0, 0, expand(31))
RED_PLUS_GREEN = (expand(31), expand(31), 0)
MATH_ON_BG2 = 0x02


def test_mode7_without_extbg_is_one_layer():
    check("BG1 alone", pixel(mode7(0x81, 0x01, False), 0, 0), BLUE_RGB)
    check("BG2 is not there", pixel(mode7(0x81, 0x02, False), 0, 0), (0, 0, 0))


def test_extbg_gives_mode7_a_second_layer():
    """BG2 shows palette entry 1, which is bit 7 stripped off pixel $81."""
    check("BG2 with EXTBG", pixel(mode7(0x81, 0x02, True), 0, 0), RED_RGB)


def test_extbg_bit_seven_puts_bg2_in_front_of_bg1():
    check("pixel $81, both layers", pixel(mode7(0x81, 0x03, True), 0, 0), RED_RGB)


def test_extbg_without_bit_seven_puts_bg2_behind_bg1():
    """A pixel under $80 gives both layers the same palette index, so which
    one won is only visible through colour math: it is switched on for BG2 and
    off for BG1, and the pixel comes out unmodified."""
    check("BG2 alone, with math",
          pixel(mode7(0x01, 0x02, True, MATH_ON_BG2), 0, 0), RED_PLUS_GREEN)
    check("both layers, math on BG2 only",
          pixel(mode7(0x01, 0x03, True, MATH_ON_BG2), 0, 0), RED_RGB)



# ---------------------------------------------------- hires and interlace ----
#
# The PPU emits two pixels for every dot.  Normally they are the same, so a
# 512-wide buffer holds a 256-wide picture.  $2133 bit 3 makes the left one
# come from the sub screen instead, and modes 5 and 6 go further and give the
# layers themselves a value per half-dot.

BACKDROP = (0, 0, expand(31))       # CGRAM 0, the SETUP scene's blue
TILE = (expand(31), 0, 0)           # CGRAM 1, its red


def test_a_dot_is_two_identical_pixels_by_default():
    machine = scene()
    check("left of dot 0", hipixel(machine, 0, 0), TILE)
    check("right of dot 0", hipixel(machine, 1, 0), TILE)


def test_pseudo_hires_shows_the_sub_screen_between_the_main_pixels():
    """Nothing is on the sub screen, so its half of every dot is the
    backdrop and the picture comes out striped."""
    machine = scene("""
        lda #$08
        sta $2133
""")
    check("left of dot 0 is the sub screen", hipixel(machine, 0, 0), BACKDROP)
    check("right of dot 0 is the main screen", hipixel(machine, 1, 0), TILE)
    check("left of dot 3", hipixel(machine, 6, 0), BACKDROP)
    check("right of dot 3", hipixel(machine, 7, 0), TILE)


def test_the_hires_left_half_dot_is_a_dot_behind():
    """The sub half-dot goes through colour math against the dot to its *left*.

    The output stage builds the left half of a dot before it has looked at
    that dot's main screen, so the operand and the switches it uses are the
    previous dot's.  Here BG1 covers dots 0 to 7 on both screens with colour
    math adding the sub screen, and dot 8 is past it:

      dot 8's right half   main screen is the backdrop, which has math off,
                           so it comes out plain blue
      dot 8's left  half   the sub screen is the backdrop too, but the switches
                           are dot 7's, where BG1 had math on -- so it is
                           blue plus dot 7's red

    An implementation that blends the two halves of the same dot gives plain
    blue here.  The whole of krom's hires references turn on this pixel.
    """
    machine = scene("""
        lda #$01
        sta $212D               ; BG1 on the sub screen as well
        lda #$08
        sta $2133               ; pseudo-hires
        lda #$02
        sta $2130               ; CGWSEL: the sub screen is the operand
        lda #$01
        sta $2131               ; CGADSUB: add, no halve, BG1 only
""")
    magenta = (expand(31), 0, expand(31))
    check("left of dot 0 is the sub screen untouched", hipixel(machine, 0, 0), TILE)
    check("right of dot 8 is the backdrop", hipixel(machine, 17, 0), BACKDROP)
    check("left of dot 8 carries dot 7's red", hipixel(machine, 16, 0), magenta)


def test_pseudo_hires_with_the_layer_on_both_screens_looks_normal():
    machine = scene("""
        lda #$01
        sta $212D               ; BG1 on the sub screen as well
        lda #$08
        sta $2133
""")
    check("left of dot 0", hipixel(machine, 0, 0), TILE)
    check("right of dot 0", hipixel(machine, 1, 0), TILE)


# Mode 5 draws BG1 across 512 half-dots, so the eight-pixel tile the SETUP
# scene puts at the origin covers eight of them -- four dots -- instead of
# eight dots.

MODE5 = """
        lda #$05
        sta $2105               ; mode 5
        lda #$01
        sta $212D               ; BG1 on the sub screen too, to see all 512
"""


def test_mode5_makes_a_tile_half_as_wide():
    machine = scene(MODE5)
    check("half-dot 0", hipixel(machine, 0, 0), TILE)
    check("half-dot 7", hipixel(machine, 7, 0), TILE)
    check("half-dot 8", hipixel(machine, 8, 0), BACKDROP)
    check("half-dot 9", hipixel(machine, 9, 0), BACKDROP)


def test_mode5_without_the_sub_screen_shows_only_the_odd_half_dots():
    """The main screen owns the right pixel of each dot, so a layer that is
    only on the main screen appears in half the columns."""
    machine = scene("""
        lda #$05
        sta $2105
""")
    check("half-dot 0 is the sub screen", hipixel(machine, 0, 0), BACKDROP)
    check("half-dot 1 is the main screen", hipixel(machine, 1, 0), TILE)
    check("half-dot 7", hipixel(machine, 7, 0), TILE)
    check("half-dot 8", hipixel(machine, 8, 0), BACKDROP)


def test_interlace_draws_alternating_rows_and_doubles_the_height():
    """Each field fills every other row of the buffer and leaves the other
    field's rows as they were, which is what a real display does."""
    machine = scene("""
        lda #$01
        sta $2133               ; interlace
""")
    check("visible height", machine.visible_height, 448)
    check("row 0", hipixel(machine, 0, 0), TILE)
    check("row 1", hipixel(machine, 0, 1), TILE)
    check("row 16 is past the tile", hipixel(machine, 0, 16), BACKDROP)


def test_without_interlace_the_height_is_not_doubled():
    check("visible height", scene().visible_height, 224)



# -------------------------------------------------------------- mosaic ----
#
# The SETUP scene puts one 8x8 tile at the origin.  With mosaic on, each
# block takes its colour from its top-left corner, so a block that starts
# inside the tile is filled with the tile's colour and one that starts
# outside is filled with the backdrop.

def mosaic_scene(size, layers="$01"):
    return scene("""
        lda #$%02X
        sta $2106               ; mosaic size %d, on BG1
""" % ((size - 1) << 4 | 0x01, size))


def test_mosaic_spreads_the_corner_of_each_block():
    """Size 4: the tile is eight wide, so blocks at 0 and 4 are inside it
    and the block at 8 is not."""
    machine = mosaic_scene(4)
    check("dot 3 takes dot 0", pixel(machine, 3, 0), TILE)
    check("dot 7 takes dot 4", pixel(machine, 7, 0), TILE)
    check("dot 8 is outside", pixel(machine, 8, 0), BACKDROP)
    check("row 3 takes row 0", pixel(machine, 0, 3), TILE)
    check("row 8 is outside", pixel(machine, 0, 8), BACKDROP)


def test_mosaic_of_one_changes_nothing():
    machine = mosaic_scene(1)
    check("dot 7", pixel(machine, 7, 0), TILE)
    check("dot 8", pixel(machine, 8, 0), BACKDROP)


def test_a_sixteen_line_block_reaches_past_the_tile():
    """Size 16 makes rows 0 to 15 all sample row 0, so the tile's colour
    runs eight rows further down than the tile does."""
    machine = mosaic_scene(16)
    check("row 15 still takes row 0", pixel(machine, 0, 15), TILE)
    check("row 16 starts a new block", pixel(machine, 0, 16), BACKDROP)


# -------------------------------------------------- H/V counter latch ----

LATCH_SOURCE = """
        sep #$30
        lda $213F               ; clear any stale latch flag
        lda #$80
        sta $4201               ; the latch line idle high
        lda #$00
        sta $4201               ; and taken low, which latches
        lda $213F
        sta $7E4000             ; bit 6 says the counters are latched
        lda $213C
        sta $7E4001             ; H, low byte
        lda $213D
        sta $7E4002             ; V, low byte
        lda $213F
        sta $7E4003             ; reading $213F cleared the flag
        lda #$FF
        sta $7E4FFF
__end:  bra __end
"""


def test_taking_the_wrio_latch_line_low_freezes_the_counters():
    from tools.testrom import run as run_rom
    r = run_rom(LATCH_SOURCE)
    if not r[0] & 0x40:
        FAILURES.append("STAT78 did not report a latch: got $%02X" % r[0])
    if r[3] & 0x40:
        FAILURES.append("the latch flag survived a read of $213F")
    # The program runs early in the frame, on a line the PPU is drawing.
    if not 0 <= r[1] <= 255:
        FAILURES.append("latched H out of range: %d" % r[1])


def test_the_latch_flag_stays_clear_without_a_falling_edge():
    from tools.testrom import run as run_rom
    low = "        lda #$00" + NL + "        sta $4201"
    high = "        lda #$80" + NL + "        sta $4201"
    source = LATCH_SOURCE.replace(low, high)
    r = run_rom(source)
    if r[0] & 0x40:
        FAILURES.append("STAT78 reported a latch with the line held high")



# --------------------------------------------------------- colour math ----
#
# $2130 bits 7-6 force the main screen to black over a region, and bits 5-4
# say where colour math applies.  The two are separate questions, and the
# second one still asks whether the layer that would have been showing has
# math switched on -- forcing black changes the colour, not who produced it.

CMATH = """
        lda #$5F
        sta $2132               ; fixed colour: green at full
        lda #$%(cgwsel)02X
        sta $2130
        lda #$%(cgadsub)02X
        sta $2131
"""

GREEN_RGB = (0, expand(31), 0)


def cmath(cgwsel, cgadsub):
    return scene(CMATH % {"cgwsel": cgwsel, "cgadsub": cgadsub})


def test_colour_math_adds_the_fixed_colour():
    """No window anywhere, math on BG1: red plus green."""
    check("BG1 plus fixed", pixel(cmath(0x00, 0x01), 0, 0),
          (expand(31), expand(31), 0))


def test_colour_math_respects_the_per_layer_switch():
    check("math enabled for BG2 only", pixel(cmath(0x00, 0x02), 0, 0), TILE)


def test_forcing_the_main_screen_black_still_asks_about_the_layer():
    """The discriminating case.  Black is forced everywhere and math is
    allowed everywhere, but BG1 is not one of the layers math applies to, so
    the pixel has to stay black rather than let the fixed colour through."""
    check("forced black, no math on BG1", pixel(cmath(0xC0, 0x00), 0, 0),
          (0, 0, 0))


def test_forcing_black_with_math_on_shows_the_operand():
    """And with BG1 switched on, black plus green is green -- which is how a
    game shows the sub screen through a hole in the main one."""
    check("forced black, math on BG1", pixel(cmath(0xC0, 0x01), 0, 0), GREEN_RGB)


def test_half_applies_to_the_sum():
    check("halved", pixel(cmath(0x00, 0x41), 0, 0),
          (expand(15), expand(15), 0))


def test_subtract_takes_the_operand_away():
    """Red minus green is red: the green channel was already zero and the
    result clamps rather than wrapping."""
    check("subtracted", pixel(cmath(0x00, 0x81), 0, 0), TILE)


# Pinned so a change to the renderer shows up here and has to be judged
# rather than absorbed.  Override with PYSNES_PPU_HASH to re-baseline.
SCENE_HASH = "6a4600cba64293ced593c0f4a55d80b89b5bb035"


def test_scene_hash_is_stable():
    """A snapshot, so a change in rendering has to be looked at deliberately."""
    machine = scene()
    digest = hashlib.sha1(bytes(machine.framebuffer)).hexdigest()
    expected = os.environ.get("PYSNES_PPU_HASH", SCENE_HASH)
    print("      scene hash: %s" % digest)
    check("scene hash", digest, expected)


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


# ------------------------------------------------------------ sprites ----

OBJ_SETUP = """
        sep #$20
        lda #$8F
        sta $2100

        ; backdrop blue, sprite palette 0 colour 1 = green
        stz $2121
        lda #$00
        sta $2122
        lda #$7C
        sta $2122
        lda #$81
        sta $2121               ; CGRAM 129: sprite palette 0, colour 1
        lda #$E0
        sta $2122
        lda #$03
        sta $2122

        ; sprite tile 0 at VRAM word 0: bitplane 0 all ones
        lda #$80
        sta $2115
        rep #$20
        lda #$0000
        sta $2116
        ldx #$0008
objlo:  lda #$00FF
        sta $2118
        dex
        bne objlo
        ldx #$0008
objhi:  lda #$0000
        sta $2118
        dex
        bne objhi
        sep #$20

        stz $2101               ; OBJ characters at $0000, 8x8 / 16x16

        ; park all 128 sprites below the display first
        stz $2102
        stz $2103
        ldx #$00
park:   lda #$00
        sta $2104               ; X
        lda #$F0
        sta $2104               ; Y = 240, off the bottom
        lda #$00
        sta $2104
        lda #$00
        sta $2104
        inx
        cpx #$80
        bne park

        ; %(count)s sprites along one line, eight pixels apart
        stz $2102
        stz $2103
        lda #$00
        sta $00                 ; running X
        ldx #$00
oaml:   lda $00
        sta $2104               ; X
        lda #$10
        sta $2104               ; Y = 16
        lda #$00
        sta $2104               ; tile 0
        lda #%(attr)s
        sta $2104               ; attributes
        lda $00
        clc
        adc #$08
        sta $00
        inx
        cpx #%(count)s
        bne oaml

        lda #%(size)s
        sta $2101               ; OBSEL: sprite size selection
        lda #$10
        sta $212C               ; OBJ on the main screen
        lda #$0F
        sta $2100
spin:   bra spin
"""


def objects(count, attr="$20", size="$00"):
    return run(OBJ_SETUP % {"count": "$%02X" % count, "attr": attr, "size": size},
               max_frames=4).machine


def test_sprite_is_drawn_where_oam_puts_it():
    machine = objects(1)
    green = (0, expand(31), 0)
    blue = (0, 0, expand(31))
    check("sprite pixel", pixel(machine, 0, 16), green)
    check("sprite pixel at its far corner", pixel(machine, 7, 23), green)
    check("just right of the sprite", pixel(machine, 8, 16), blue)
    check("just below the sprite", pixel(machine, 0, 24), blue)


def test_thirty_three_sprites_raise_range_over():
    """Only 32 sprites per line survive evaluation; a 33rd sets the flag and
    is not drawn."""
    machine = objects(33)
    check("range over set", machine.ppu.range_over, 1, "%d")
    check("time over not set", machine.ppu.time_over, 0, "%d")
    green = (0, expand(31), 0)
    blue = (0, 0, expand(31))
    # Sprites sit at X = 8n, so 0..31 cover the whole line and the 33rd, at
    # X = 256, is off screen -- but it still consumed a slot, and the slot it
    # was refused is what the flag reports.
    check("the 32nd sprite is drawn", pixel(machine, 248, 16), green)


def test_thirty_two_large_sprites_raise_time_over():
    """32 sprites is within the range limit, but 16x16 sprites need two tiles
    each and only 34 tiles fit on a line."""
    # OBSEL size selection 3 is 16x16 / 32x32, so the small size -- which is
    # what the OAM high table selects here -- is already two tiles wide.
    machine = objects(32, size="$60")
    check("range over not set", machine.ppu.range_over, 0, "%d")
    check("time over set", machine.ppu.time_over, 1, "%d")


def test_a_single_sprite_raises_neither_flag():
    machine = objects(4)
    check("range over clear", machine.ppu.range_over, 0, "%d")
    check("time over clear", machine.ppu.time_over, 0, "%d")


def test_lower_index_sprites_are_in_front():
    """Two overlapping sprites with the same priority: the lower OAM index wins."""
    machine = run("""
        sep #$20
        lda #$8F
        sta $2100
        stz $2121
        lda #$00
        sta $2122
        lda #$7C
        sta $2122
        lda #$81
        sta $2121
        lda #$E0
        sta $2122
        lda #$03
        sta $2122               ; palette 0 colour 1 = green
        lda #$91
        sta $2121
        lda #$1F
        sta $2122
        lda #$00
        sta $2122               ; palette 1 colour 1 = red

        lda #$80
        sta $2115
        rep #$20
        lda #$0000
        sta $2116
        ldx #$0008
p1:     lda #$00FF
        sta $2118
        dex
        bne p1
        ldx #$0008
p2:     lda #$0000
        sta $2118
        dex
        bne p2
        sep #$20
        stz $2101

        stz $2102
        stz $2103
        lda #$20
        sta $2104               ; sprite 0 at X = 32
        lda #$10
        sta $2104
        lda #$00
        sta $2104
        lda #$20
        sta $2104               ; palette 0, priority 2
        lda #$20
        sta $2104               ; sprite 1 at the same place
        lda #$10
        sta $2104
        lda #$00
        sta $2104
        lda #$22
        sta $2104               ; palette 1, same priority

        lda #$10
        sta $212C
        lda #$0F
        sta $2100
spin:   bra spin
""", max_frames=4).machine
    check("sprite 0 covers sprite 1", pixel(machine, 32, 16), (0, expand(31), 0))


def test_overflow_flags_clear_each_frame():
    """$213E bits 6 and 7 describe one frame, so they must not accumulate."""
    machine = objects(33)
    check("range over after a busy frame", machine.ppu.range_over, 1, "%d")
    machine.ppu.range_over = 1
    machine.ppu.time_over = 1
    # Reaching the next frame clears them before evaluation refills them.
    machine.run_frame()
    machine.run_frame()
    check("still set by the same busy line", machine.ppu.range_over, 1, "%d")
    check("time over stayed clear", machine.ppu.time_over, 0, "%d")


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
