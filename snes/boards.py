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


# A chipset byte of $Fx says only "something unusual", and four different
# chips share it.  The byte at $FFBF picks between them.  Values from ares's
# loader, and confirmed here against the cartridges themselves: Momotarou
# Dentetsu Happy ($F5) and Tengai Makyou Zero ($F9) both carry subtype $00,
# Rockman X 2 ($F3) carries $10, and Exhaust Heat II and Hayazashi Nidan
# Morita Shougi -- both $F6, which the chipset byte alone would call an
# SPC7110 -- carry $01.
SUBTYPE = {0x00: "SPC7110", 0x01: "ST01x", 0x02: "ST018", 0x10: "CX4"}


def subtype_byte(cart):
    """$FFBF, the byte that tells the $Fx chips apart.

    The header block starts at $FFB0, so this is 15 bytes in.  It is read
    whatever $FFDA says: the expanded header is supposed to be announced by
    a developer ID of $33, and the two ST01x cartridges here announce $29
    while still carrying a correct subtype.
    """
    at = cart.header_offset + 0x0F
    return cart.rom_data[at] if at < len(cart.rom_data) else -1


def coprocessor(cart):
    """The chip on this cartridge, or None for plain ROM and RAM."""
    key = crc32(cart.rom_data)
    if key in OVERRIDES:
        return OVERRIDES[key]
    if (cart.coprocessor & 0xF0) == 0xF0:
        found = SUBTYPE.get(subtype_byte(cart))
        if found:
            return found
    return CHIPSET.get(cart.coprocessor)
