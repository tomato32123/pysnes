"""Which board a cartridge is, as opposed to which one its header claims.

The header carries a map-mode byte and a chipset byte, and between them they
name the board correctly most of the time.  Most is not all: the bytes are
set by whoever built the ROM, several boards share a value, and a few titles
simply have them wrong.  So the chipset byte is the first guess and the
override table below is the last word, keyed on the CRC-32 of the ROM after
any copier header has been stripped.

Keeping this beside the boards rather than inside a tool means the emulator,
the batch tester and anything else all decide the same way.
"""
import zlib

# The chipset byte at $FFD6.  The low nibble says what else is on the board
# besides ROM and RAM; the high nibble which chip that is.
CHIPSET = {
    0x03: "DSP", 0x04: "DSP", 0x05: "DSP",
    0x13: "SuperFX", 0x14: "SuperFX", 0x15: "SuperFX", 0x1A: "SuperFX",
    0x25: "OBC1",
    0x32: "SA-1", 0x33: "SA-1", 0x34: "SA-1", 0x35: "SA-1",
    0x43: "S-DD1", 0x45: "S-DD1",
    0x55: "S-RTC",
    0xE3: "Super Game Boy",
    0xF3: "CX4",
    0xF5: "SPC7110", 0xF6: "SPC7110", 0xF9: "SPC7110",
}

# CRC-32 of the stripped ROM -> the chip that is really on the board.  Use
# None to say "no coprocessor, whatever the header says".
OVERRIDES = {
}


def crc32(rom_data):
    return zlib.crc32(bytes(rom_data)) & 0xFFFFFFFF


def coprocessor(cart):
    """The chip on this cartridge, or None for plain ROM and RAM."""
    key = crc32(cart.rom_data)
    if key in OVERRIDES:
        return OVERRIDES[key]
    return CHIPSET.get(cart.coprocessor)
