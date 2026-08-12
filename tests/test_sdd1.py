"""The S-DD1 cartridge: its memory mapper, driven from a real program.

The decompressor is not written yet.  What is here is the part without which
nothing else can be: a 32 Mbit S-DD1 cartridge fits no standard map, and
Street Fighter Zero 2 jumps into the mapped window three instructions after
reset, so the mapping is the whole difference between a black screen and a
running game.

These run a 65816 program on a cartridge whose header says S-DD1, so the
board is chosen the way a real one is and the reads go down the same path a
game's do, rather than the mapper being asked directly.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.testrom import assemble_image, WRAM_BASE, RESULT_ADDR, DONE_ADDR
from snes.system import System

SDD1_CHIPSET = 0x43
IMAGE = 0x200000                 # 2 MB, so the mapping has somewhere to point

# Marker bytes at three offsets that the mapper should tell apart: the same
# address in slot 0's first bank, in its second bank, and in another megabyte.
MARKS = {0x001234: 0xA1, 0x011234: 0xB2, 0x101234: 0xC3}


def build(source):
    image, labels = assemble_image(source, chipset=SDD1_CHIPSET)
    rom = bytearray(IMAGE)
    rom[0:len(image)] = image
    for off, value in MARKS.items():
        rom[off] = value
    return bytes(rom), labels


def run(source, max_frames=10):
    image, _ = build(source)
    machine = System(rom_data=image)
    assert machine.bus.board.name == "S-DD1", machine.bus.board.name
    for _ in range(max_frames):
        machine.run_frame()
        if machine.bus.read(WRAM_BASE + DONE_ADDR):
            break
    else:
        raise AssertionError("program never finished")
    return [machine.bus.read(WRAM_BASE + RESULT_ADDR + i) for i in range(8)], machine


def test_mapped_window():
    """$C0-$FF is four 1 MB slots, a whole bank at a time, and $4804-$4807
    choose which megabyte each slot shows."""
    r, machine = run("""
        sep #$20
        lda $c01234
        sta result+0
        lda $c11234                     ; bank field inside the slot
        sta result+1
        lda #$01
        sta $4804                       ; slot 0 now shows megabyte 1
        lda $c01234
        sta result+2
        lda $4804                       ; and the register reads back
        sta result+3
    """)
    assert r[0] == 0xA1, "$C0:1234 -> %02X" % r[0]
    assert r[1] == 0xB2, "$C1:1234 -> %02X" % r[1]
    assert r[2] == 0xC3, "$C0:1234 after $4804=1 -> %02X" % r[2]
    assert r[3] == 0x01
    print("  mapped window OK")


def test_lorom_half_is_still_lorom():
    """Below $C0 the board is an ordinary LoROM, which is how the reset
    vector and the boot code are reached at all."""
    r, machine = run("""
        sep #$20
        lda $808000                     ; = $00:8000, the first byte of code
        sta result+0
        lda $018000                     ; second 32 KB bank
        sta result+1
    """)
    image, _ = build("")
    assert r[0] == image[0x0000], "%02X vs %02X" % (r[0], image[0x0000])
    assert r[1] == image[0x8000], "%02X vs %02X" % (r[1], image[0x8000])
    print("  LoROM half OK")


def test_arming_registers_read_back():
    r, _ = run("""
        sep #$20
        lda #$81
        sta $4800
        lda #$01
        sta $4801
        lda $4800
        sta result+0
        lda $4801
        sta result+1
    """)
    assert r[0] == 0x81
    assert r[1] == 0x01
    print("  $4800/$4801 read back OK")


def test_tables_are_not_mistyped():
    """The decompressor's two constant tables are transcribed hardware design
    data, and a typo in them would show as slightly wrong graphics rather than
    as anything that looks like an error.  Both have enough structure to check.
    """
    from snes.sdd1 import tables
    t = tables()

    # The run-length table is a permutation of 1..128: every length appears
    # exactly once, so a transposed or dropped digit cannot survive.
    assert sorted(t["run"]) == list(range(1, 129))

    evo = t["evolution"]
    assert len(evo) == 33
    # States 1..24 are a ladder: right takes you one rung up, wrong one down,
    # and the ends stay put.
    for i in range(1, 25):
        size, mps, lps = evo[i]
        assert mps == (i + 1 if i < 24 else 24), "state %d MPS -> %d" % (i, mps)
        assert lps == (i - 1 if i > 1 else 1), "state %d LPS -> %d" % (i, lps)
    # 25 upwards is the run a fresh context takes, one code size per step.
    for i in range(25, 33):
        size, mps, lps = evo[i]
        assert size == i - 25, "state %d size %d" % (i, size)
        assert mps == (i + 1 if i < 32 else 24)
    # Code sizes never exceed the eight Golomb decoders there are.
    for size, mps, lps in evo:
        assert 0 <= size <= 7
        assert mps < 33 and lps < 33
    print("  decompressor tables OK")


if __name__ == "__main__":
    test_mapped_window()
    test_lorom_half_is_still_lorom()
    test_arming_registers_read_back()
    test_tables_are_not_mistyped()
    print("all S-DD1 tests passed")
