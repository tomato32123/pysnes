import os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.cart import Cart, mirror


def _synthetic_lorom(size, checksum_rule):
    """A minimal LoROM image of `size` bytes, with the header checksum filled
    in by `checksum_rule`.  Deliberately not a power of two, so the mirrored
    tail is counted twice by hardware and once by a naive sum."""
    rom = bytearray(size)
    for i in range(size):                       # something other than zeros,
        rom[i] = (i * 7 + (i >> 11)) & 0xFF     # so the tail actually matters
    rom[0x0000] = 0x78                          # SEI at the reset vector
    head = 0x7FC0
    rom[head:head + 21] = b"PYSNES CHECKSUM".ljust(21)
    rom[head + 0x15] = 0x20                     # LoROM, SlowROM
    rom[head + 0x16] = 0x00                     # ROM only
    rom[head + 0x17] = 0x0A
    rom[head + 0x18] = 0x00                     # no SRAM
    rom[head + 0x19] = 0x01                     # NTSC
    for off in range(0x7FE0, 0x8000, 2):
        rom[off], rom[off + 1] = 0xFF, 0xFF
    rom[0x7FFC], rom[0x7FFD] = 0x00, 0x80       # reset -> $8000
    rom[head + 0x1E] = rom[head + 0x1F] = 0     # zero the fields being summed
    rom[head + 0x1C] = rom[head + 0x1D] = 0
    # The checksum covers its own field.  Whatever value goes in, the four
    # bytes of the value and its complement always add $01FE, so the sum with
    # them zeroed plus $1FE is the fixed point -- no iteration needed.
    value = (checksum_rule(rom) + 0x1FE) & 0xFFFF
    rom[head + 0x1E], rom[head + 0x1F] = value & 0xFF, value >> 8
    comp = value ^ 0xFFFF
    rom[head + 0x1C], rom[head + 0x1D] = comp & 0xFF, comp >> 8
    return bytes(rom), value


def _mirrored_sum(rom):
    window = 1
    while window < len(rom):
        window <<= 1
    return sum(rom[mirror(i, len(rom))] for i in range(window))


def test_checksum_counts_the_mirrored_tail():
    # 96 KB: the top 32 KB is mirrored to fill a 128 KB window, so hardware
    # counts it twice.  Summing the file instead is wrong by that much.
    rom, expected = _synthetic_lorom(0x18000, _mirrored_sum)
    c = Cart(data=rom)
    assert c.rom_size == 0x18000
    assert c.computed_checksum == expected, \
        "expected $%04X, got $%04X" % (expected, c.computed_checksum)
    assert c.checksum_ok
    # And the naive sum really is a different number, so the test would have
    # failed against the old behaviour rather than passing by coincidence.
    assert (sum(rom) & 0xFFFF) != c.computed_checksum
    print("  non-power-of-two checksum OK")


def test_checksum_power_of_two_unchanged():
    rom, expected = _synthetic_lorom(0x20000, lambda r: sum(r))
    c = Cart(data=rom)
    assert c.computed_checksum == expected
    assert c.checksum_ok
    print("  power-of-two checksum OK")


def test_mirroring():
    # Power-of-two ROMs mirror by plain masking.
    assert mirror(0x000000, 0x400000) == 0x000000
    assert mirror(0x3FFFFF, 0x400000) == 0x3FFFFF
    assert mirror(0x400000, 0x400000) == 0x000000
    assert mirror(0x7FFFFF, 0x400000) == 0x3FFFFF
    # A 6 Mbit (0x0C0000) ROM: the 0x080000..0x0BFFFF chunk repeats.
    assert mirror(0x0C0000, 0x0C0000) == 0x080000
    assert mirror(0x0FFFFF, 0x0C0000) == 0x0BFFFF
    print("  mirroring OK")

def test_dq6(rom):
    c = Cart(rom)
    print(c.describe())
    assert c.had_copier_header
    assert c.rom_size == 0x400000
    assert c.title == "DRAGONQUEST6"
    assert c.map_mode_name == "HiROM"
    assert c.fast_rom == 1
    assert c.sram_size == 8192
    assert c.has_battery
    assert c.checksum_ok
    assert c.coprocessor == 0x02
    print("  DQ6 header OK")

if __name__ == "__main__":
    # The checksum and mirroring rules are testable without a cartridge, and
    # are the part CI can actually check, so they run first and unconditionally.
    test_mirroring()
    test_checksum_counts_the_mirrored_tail()
    test_checksum_power_of_two_unchanged()
    # The header test needs a real ROM.  Absent one, say so and still pass,
    # rather than throwing away the three tests that did run.
    from tools.romarg import from_argv, NO_ROM
    try:
        rom = from_argv(quiet=True)
    except SystemExit as exc:
        if exc.code != NO_ROM:
            raise
        print("  (no ROM: skipping the DQ6 header test)")
    else:
        test_dq6(rom)
    print("all cart tests passed")
