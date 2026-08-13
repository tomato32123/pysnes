# cython: language_level=3
"""Cartridge: ROM image loading, internal-header detection and address mapping."""

import os
from libc.stdint cimport uint8_t, uint32_t


# Field offsets inside the 64-byte internal header block.  header_offset points
# at the block base, i.e. the $FFB0 equivalent for the detected map mode.
cdef enum:
    H_TITLE      = 0x10   # 21 bytes
    H_MAPMODE    = 0x25
    H_ROMTYPE    = 0x26
    H_ROMSIZE    = 0x27
    H_RAMSIZE    = 0x28
    H_COUNTRY    = 0x29
    H_CKSUM_COMP = 0x2C   # 2 bytes
    H_CKSUM      = 0x2E   # 2 bytes
    H_VEC_NATIVE = 0x30   # $FFE0..$FFEF
    H_VEC_EMU    = 0x40   # $FFF0..$FFFF


cdef uint32_t _mirror(uint32_t addr, uint32_t size) noexcept nogil:
    """Fold `addr` into a ROM of `size` bytes, mirroring non-power-of-two tails
    the way real cartridge address decoding does."""
    cdef uint32_t base = 0
    cdef uint32_t mask = 1 << 23
    if size == 0:
        return 0
    while addr >= size:
        while not (addr & mask):
            mask >>= 1
        addr -= mask
        if size > mask:
            size -= mask
            base += mask
        mask >>= 1
    return base + addr


def mirror(addr, size):
    """Python-visible wrapper around the mirroring rule (used by tests)."""
    return _mirror(addr, size)


# Opcodes a reset handler plausibly starts with: SEI/CLC/SEC/STZ/JMP/JML/JSR/
# JSL/LDX#/LDA#/SEP/REP.
_BOOT_OPCODES = frozenset((0x78, 0x18, 0x38, 0x9C, 0x4C, 0x5C, 0x20, 0x22,
                           0xA2, 0xA9, 0xE2, 0xC2, 0x6C))


def score_header(bytes rom, uint32_t off, int is_hi, int is_ex):
    """Heuristic plausibility score for an internal header candidate at `off`."""
    cdef uint32_t size = len(rom)
    cdef int score = 0
    cdef int mapmode, romsize_k, i, c, opcode
    cdef uint32_t reset, cksum, comp, reset_file

    if off + 0x50 > size:
        return -1000

    mapmode = rom[off + H_MAPMODE]
    cksum = rom[off + H_CKSUM] | (rom[off + H_CKSUM + 1] << 8)
    comp = rom[off + H_CKSUM_COMP] | (rom[off + H_CKSUM_COMP + 1] << 8)
    reset = rom[off + H_VEC_EMU + 0x0C] | (rom[off + H_VEC_EMU + 0x0D] << 8)

    # The emulation-mode reset vector must point into the ROM half of a bank.
    if reset < 0x8000:
        return -1000

    # Follow the reset vector back to a file offset and sanity-check the opcode.
    if is_hi:
        reset_file = _mirror((off - (off & 0xFFFF)) + reset, size)
    else:
        reset_file = _mirror((off & ~0x7FFF) + (reset & 0x7FFF), size)
    opcode = rom[reset_file]
    if opcode in _BOOT_OPCODES:
        score += 8

    if (cksum ^ comp) == 0xFFFF and cksum != 0:
        score += 24

    # Map-mode nibble agreement.
    if is_ex:
        score += 16 if (mapmode & 0x0F) == 0x05 else -12
    elif is_hi:
        score += 16 if (mapmode & 0x0F) in (0x01, 0x0A) else -12
    else:
        score += 16 if (mapmode & 0x0F) in (0x00, 0x02, 0x03) else -12

    # Declared ROM size should be in the right ballpark.
    romsize_k = rom[off + H_ROMSIZE]
    if 0x08 <= romsize_k <= 0x0D and (<uint32_t>1024 << romsize_k) >= size // 2:
        score += 6

    # A sane title is mostly printable ASCII (or Shift-JIS high bytes).  A
    # zero is not evidence either way: a homebrew image often leaves the whole
    # header blank, and blargg's SPC tests do, so counting zeros against a
    # candidate rejects ROMs that run perfectly well on hardware.  Any other
    # control byte still counts against, which is what the check is for.
    for i in range(21):
        c = rom[off + H_TITLE + i]
        if 0x20 <= c < 0x7F:
            score += 1
        elif 0 < c < 0x20:
            score -= 3
    return score


def best_header_score(bytes rom):
    """Best plausibility score over the three internal-header positions."""
    return max(score_header(rom, 0x007FB0, 0, 0),
               score_header(rom, 0x00FFB0, 1, 0),
               score_header(rom, 0x40FFB0, 1, 1))


def deinterleave(bytes data):
    """Undo the block-interleaved dump format some copiers produced.

    The image holds the odd 32 KB blocks first and the even ones after, so
    file block i is real block 2i+1 and file block half+i is real block 2i.
    A HiROM image stored this way puts its header at $7FB0 -- the LoROM
    position -- which is what gives the format away."""
    cdef Py_ssize_t size = len(data)
    cdef Py_ssize_t blocks = size // 0x8000
    cdef Py_ssize_t half = blocks // 2
    cdef Py_ssize_t i
    out = bytearray(size)
    for i in range(half):
        out[(2 * i + 1) * 0x8000:(2 * i + 2) * 0x8000] = data[i * 0x8000:(i + 1) * 0x8000]
        out[(2 * i) * 0x8000:(2 * i + 1) * 0x8000] = data[(half + i) * 0x8000:(half + i + 1) * 0x8000]
    return bytes(out)


cdef class Cart:
    """The ROM image plus its battery-backed SRAM, and the detected map mode."""

    def __cinit__(self):
        self.rom = NULL
        self.sram = NULL

    def __init__(self, path=None, bytes data=None):
        cdef bytes raw
        if data is None:
            if path is None:
                raise ValueError("Cart needs either a path or raw data")
            with open(path, "rb") as fh:
                raw = fh.read()
        else:
            raw = data
        self.path = path

        # Strip the 512-byte copier ("SMC") header if present.
        if len(raw) % 1024 == 512:
            raw = raw[512:]
            self.had_copier_header = 1
        else:
            self.had_copier_header = 0

        if len(raw) < 0x10000:
            raise ValueError("ROM image too small: %d bytes" % len(raw))

        # Some dumps are block-interleaved.  Trust whichever arrangement makes
        # the internal header look more plausible.
        self.was_interleaved = 0
        if len(raw) % 0x10000 == 0 and (len(raw) // 0x8000) >= 2:
            swapped = deinterleave(raw)
            if best_header_score(swapped) > best_header_score(raw):
                raw = swapped
                self.was_interleaved = 1

        self.rom_data = raw
        self.rom_size = len(raw)
        self.rom = <const uint8_t *>self.rom_data

        self._detect_header()
        self._alloc_sram()

    def _detect_header(self):
        cdef bytes rom = self.rom_data
        cdef int mapmode_byte, ram_k
        cdef uint32_t total = 0
        cdef uint32_t i, window

        candidates = ((0x007FB0, <int>MAP_LOROM, 0, 0),
                      (0x00FFB0, <int>MAP_HIROM, 1, 0),
                      (0x40FFB0, <int>MAP_EXHIROM, 1, 1))
        best = None
        best_score = -10000
        for off, mode, is_hi, is_ex in candidates:
            s = score_header(rom, off, is_hi, is_ex)
            if s > best_score:
                best_score, best = s, (off, mode)
        if best is None or best_score < 0:
            raise ValueError("no usable SNES internal header found")

        self.header_offset = best[0]
        self.map_mode = best[1]

        mapmode_byte = rom[self.header_offset + H_MAPMODE]
        self.fast_rom = 1 if (mapmode_byte & 0x10) else 0
        self.coprocessor = rom[self.header_offset + H_ROMTYPE]
        self.has_battery = 1 if self.coprocessor in (0x02, 0x05, 0x06, 0x09, 0x0A) else 0

        raw_title = rom[self.header_offset + H_TITLE: self.header_offset + H_TITLE + 21]
        try:
            self.title = raw_title.decode("shift_jis").rstrip()
        except UnicodeDecodeError:
            self.title = raw_title.decode("latin-1").rstrip()

        self.checksum = (rom[self.header_offset + H_CKSUM]
                         | (rom[self.header_offset + H_CKSUM + 1] << 8))
        self.checksum_complement = (rom[self.header_offset + H_CKSUM_COMP]
                                    | (rom[self.header_offset + H_CKSUM_COMP + 1] << 8))

        # The checksum is over the ROM *as the console addresses it*, not over
        # the file.  A cartridge whose size is not a power of two mirrors its
        # tail to fill the window, so those bytes are counted more than once --
        # summing the file instead reports a mismatch for every 12, 20 or 40
        # Mbit game.  Folding each address through the same rule the bus uses
        # keeps the two definitions from drifting apart.
        window = 1
        while window < self.rom_size:
            window <<= 1
        for i in range(window):
            total += self.rom[_mirror(i, self.rom_size)]
        self.computed_checksum = total & 0xFFFF
        self.checksum_ok = 1 if self.computed_checksum == self.checksum else 0

        # Country byte: $02-$0C are the PAL territories, bar Korea ($0D).
        self.region = rom[self.header_offset + H_COUNTRY]
        self.is_pal = 1 if (0x02 <= self.region <= 0x0C or self.region in (0x10, 0x11)) else 0

        ram_k = rom[self.header_offset + H_RAMSIZE]
        self.sram_size = (<uint32_t>1024 << ram_k) if 0 < ram_k <= 0x09 else 0

    def _alloc_sram(self):
        # Always keep a real buffer so the bus never has to null-check.
        #
        # A save RAM that has never been written reads $FF, not $00: the cell
        # is undriven and the bus pulls up.  Momotarou Dentetsu Happy is where
        # this stops being a detail -- its cartridge carries a check program,
        # and that program's S-RAM BACKUP test reads the whole window and
        # expects $FF.  Filled with zeroes it reports NG, refuses to write the
        # "SPC7110 CHECK OK" signature the boot code looks for, and the game
        # never starts.
        self.sram_data = bytearray(b"\xFF" * (self.sram_size if self.sram_size else 1))
        self.sram = <uint8_t *>self.sram_data
        self.sram_mask = (self.sram_size - 1) if self.sram_size else 0

    cdef uint32_t rom_offset(self, uint32_t linear) noexcept nogil:
        return _mirror(linear, self.rom_size)

    # -- battery save -----------------------------------------------------

    def load_sram(self, path):
        if not self.sram_size or not os.path.exists(path):
            return False
        with open(path, "rb") as fh:
            blob = fh.read()
        n = min(len(blob), <int>self.sram_size)
        self.sram_data[:n] = blob[:n]
        return True

    def save_sram(self, path):
        if not self.sram_size:
            return False
        with open(path, "wb") as fh:
            fh.write(bytes(self.sram_data))
        return True

    @property
    def map_mode_name(self):
        return {MAP_LOROM: "LoROM", MAP_HIROM: "HiROM", MAP_EXHIROM: "ExHiROM"}[self.map_mode]

    def describe(self):
        return (
            "title      : %s\n"
            "map mode   : %s %s\n"
            "rom size   : %d bytes (%d Mbit)\n"
            "sram size  : %d bytes\n"
            "chipset    : $%02X%s\n"
            "region     : $%02X (%s)\n"
            "checksum   : $%04X (computed $%04X) %s\n"
            "copier hdr : %s   interleaved: %s"
            % (self.title,
               self.map_mode_name, "FastROM" if self.fast_rom else "SlowROM",
               self.rom_size, self.rom_size // 131072,
               self.sram_size,
               self.coprocessor, " battery" if self.has_battery else "",
               self.region, "PAL" if self.is_pal else "NTSC",
               self.checksum, self.computed_checksum,
               "OK" if self.checksum_ok else "MISMATCH",
               bool(self.had_copier_header), bool(self.was_interleaved))
        )
