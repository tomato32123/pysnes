import os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.romarg import from_argv
from snes.cart import Cart, mirror

ROM = from_argv()
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

def test_dq6():
    c = Cart(ROM)
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
    test_mirroring()
    test_dq6()
    print("all cart tests passed")
