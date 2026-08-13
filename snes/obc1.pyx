# cython: language_level=3
# cython: boundscheck=False, wraparound=False, cdivision=True
"""The OBC1: a sprite table builder, and the simplest chip on any cartridge.

Only one game has it -- Metal Combat: Falcon's Revenge -- and all it does
is make writing an object table cheaper.  The console cannot address OAM
directly while the screen is drawing, so a game builds the table in RAM
and sends it over by DMA.  The awkward part is that OAM is two tables:
four bytes a sprite for position and tile, and a separate area holding two
bits a sprite for the size and the ninth bit of X.  Writing the second
means a read, a mask, a shift and a write for every sprite.

The OBC1 does that arithmetic.  A game writes a sprite index to one
register and then writes the four bytes and the two bits to fixed
addresses; the chip works out where in its 8 KB of RAM each belongs.  What
comes out is an object table ready to be sent to OAM, and the console
never did the bit twiddling.

Everything below is the same behaviour ares implements: eight registers at
the top of the RAM, a base that is one of two places, an index, and the
two-bit field selected by the index's low bits.  It is glue logic with no
program of its own, so there is nothing here that a firmware dump would
tell us differently.
"""
from libc.stdint cimport uint8_t, uint32_t

from snes.board cimport Board, PK_OPENBUS, PK_ROM, PK_DEVICE
from snes.cart cimport Cart


cdef class OBC1(Board):

    def __cinit__(self, Cart cart):
        self.name = u"OBC1"
        self.reset_board()

    cdef void reset_board(self) noexcept:
        self._reload()

    cdef void _reload(self) noexcept:
        """Take the base, index and shift from the registers in RAM.

        They live in the RAM rather than in the chip, so they survive a
        reset with the save data and have to be read back out of it.
        """
        self.base = 0x1C00 if (self._ram_read(0x1FF5) & 1) else 0x1800
        self.index = self._ram_read(0x1FF6) & 0x7F
        self.shift = (self._ram_read(0x1FF6) & 3) << 1

    # =====================================================================
    # the map
    # =====================================================================

    cdef int classify(self, uint32_t bank, uint32_t addr, uint32_t *base) noexcept:
        cdef Cart c = self.cart
        cdef uint32_t linear
        base[0] = 0
        # The chip's RAM sits in the window every LoROM cartridge leaves
        # free, and it is the save RAM as well -- there is no other.
        if (bank & 0x7F) < 0x40 and 0x6000 <= addr < 0x8000:
            return PK_DEVICE
        if addr >= 0x8000:
            linear = ((bank & 0x7F) << 15) | (addr & 0x7FFF)
            base[0] = c.rom_offset(linear)
            return PK_ROM
        return PK_OPENBUS

    # =====================================================================
    # its RAM
    # =====================================================================

    cdef uint8_t _ram_read(self, uint32_t addr) noexcept:
        cdef Cart c = self.cart
        if not c.sram_size:
            return 0
        return c.sram[addr & c.sram_mask]

    cdef void _ram_write(self, uint32_t addr, uint8_t value) noexcept:
        cdef Cart c = self.cart
        if not c.sram_size:
            return
        c.sram[addr & c.sram_mask] = value

    cdef uint8_t read(self, uint32_t addr, uint8_t data) noexcept:
        cdef uint32_t off = addr & 0x1FFF
        if off == 0x1FF0 or off == 0x1FF1 or off == 0x1FF2 or off == 0x1FF3:
            # The four bytes of one sprite: position, tile and attributes.
            return self._ram_read(self.base + (self.index << 2) + (off & 3))
        if off == 0x1FF4:
            # The two bits that go with it, one pair of four in a byte.
            return (self._ram_read(self.base + (self.index >> 2) + 0x200)
                    >> self.shift) & 3
        return self._ram_read(off)

    cdef uint8_t peek(self, uint32_t addr, uint8_t data) noexcept:
        # Nothing here changes when it is read, so describing memory is
        # free -- unlike the coprocessors that answer with a register.
        return self.read(addr, data)

    cdef void write(self, uint32_t addr, uint8_t value) noexcept:
        cdef uint32_t off = addr & 0x1FFF
        cdef uint32_t where
        cdef uint8_t packed
        if off == 0x1FF0 or off == 0x1FF1 or off == 0x1FF2 or off == 0x1FF3:
            self._ram_write(self.base + (self.index << 2) + (off & 3), value)
            return
        if off == 0x1FF4:
            where = self.base + (self.index >> 2) + 0x200
            packed = self._ram_read(where)
            packed &= ~(<uint8_t>(3 << self.shift))
            packed |= (value & 3) << self.shift
            self._ram_write(where, packed)
            return
        self._ram_write(off, value)
        if off == 0x1FF5:
            self.base = 0x1C00 if (value & 1) else 0x1800
        elif off == 0x1FF6:
            self.index = value & 0x7F
            self.shift = (value & 3) << 1

    def describe(self):
        return u"OBC1, base $%04X, sprite %d" % (self.base, self.index)

    def state_ints(self):
        return [self.base, self.index, self.shift]

    def load_ints(self, v):
        self.base, self.index, self.shift = v

    def state_blobs(self):
        return {}

    def load_blobs(self, d):
        pass


from snes.board import register
register("OBC1", OBC1)
