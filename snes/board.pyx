# cython: language_level=3
# cython: boundscheck=False, wraparound=False, cdivision=True
"""What a cartridge is, as far as the bus is concerned.

A SNES cartridge is not a "map mode".  It is a board: some ROM, maybe some
RAM, address decoding built out of discrete logic, and sometimes a chip of
its own that answers to part of the bus.  The header's map-mode byte only
hints at the first two of those, which is why it cannot be the whole story.

Board turns that into one question the bus asks per 8 KB page -- what is at
this address -- plus two the bus asks per access, for the pages a board
claims for a chip of its own.  Adding a coprocessor then means writing a
Board rather than threading another special case through the bus.
"""
from libc.stdint cimport uint8_t, uint32_t, int64_t

from snes.cart cimport Cart, MAP_LOROM, MAP_HIROM, MAP_EXHIROM


cdef class Board:
    """Base board: no devices, everything open bus.

    `classify` answers for the start of an 8 KB page and writes the offset
    the page begins at into `base`.  It is called once when the machine is
    built, not per access, so it can be as slow as it likes.
    """

    def __cinit__(self, Cart cart):
        self.cart = cart
        self.name = u"none"
        self.unsupported = None
        self.clock = 0
        self.irq_line = 0

    cdef int classify(self, uint32_t bank, uint32_t addr, uint32_t *base) noexcept:
        base[0] = 0
        return PK_OPENBUS

    cdef uint8_t read(self, uint32_t addr, uint8_t data) noexcept:
        """Answer a read on a PK_DEVICE page.  `data` is the bus's open-bus
        value, which is what an unclaimed address inside the range returns."""
        return data

    cdef uint8_t peek(self, uint32_t addr, uint8_t data) noexcept:
        """Answer a read that must not change anything.

        The disassembler and the tracer read memory to describe it, and a
        board that claims its ROM pages -- which the coprocessor boards all
        do, because their maps move -- would otherwise show them open bus and
        every instruction as BRK.  Answering memory but not registers is the
        rule: a register read is often the thing the console asked for.
        """
        return data

    cdef void write(self, uint32_t addr, uint8_t value) noexcept:
        pass

    cdef void reset_board(self) noexcept:
        pass

    cdef void run_until(self, int64_t master_clock) noexcept:
        """Let whatever is on the board catch up with the console.

        Called once a scanline and before every access the board answers, so
        a chip that shares memory with the console is never behind when the
        console looks."""
        pass

    cdef void dma_begin(self, int channel, uint32_t addr, uint32_t count) noexcept:
        """A DMA channel is about to read `count` bytes starting at `addr`.

        A cartridge chip cannot see $420B, but it can see the reads that
        follow it, and the S-DD1 decides from the channel number whether the
        bytes it hands back are the ROM's or its decompressor's.  So the bus
        says which channel is running rather than the board having to guess
        from an address."""
        pass

    cdef void dma_end(self, int channel) noexcept:
        pass

    def describe(self):
        return self.name


cdef class LoROM(Board):
    """ROM in the top half of every bank, SRAM in $70-$7D.

    The 32 KB halves are laid end to end, so bank n holds linear offset
    n * $8000.  Some boards also mirror SRAM into $F0-$FF; that falls out of
    masking the bank to seven bits.
    """

    def __cinit__(self, Cart cart):
        self.name = u"LoROM"

    cdef int classify(self, uint32_t bank, uint32_t addr, uint32_t *base) noexcept:
        cdef Cart c = self.cart
        cdef uint32_t linear
        if c.sram_size and 0x70 <= (bank & 0x7F) <= 0x7D and addr < 0x8000:
            base[0] = (((bank & 0x0F) << 15) | addr) & c.sram_mask
            return PK_SRAM
        linear = ((bank & 0x7F) << 15) | (addr & 0x7FFF)
        base[0] = c.rom_offset(linear)
        return PK_ROM


cdef class HiROM(Board):
    """ROM addressed linearly across whole banks, SRAM at $20-$3F:$6000.

    ExHiROM is the same board with an extra 4 MB reached through banks
    $00-$3F, which is why it is a flag here rather than a class of its own.
    """

    def __cinit__(self, Cart cart):
        self.extended = 1 if cart.map_mode == MAP_EXHIROM else 0
        self.name = u"ExHiROM" if self.extended else u"HiROM"

    cdef int classify(self, uint32_t bank, uint32_t addr, uint32_t *base) noexcept:
        cdef Cart c = self.cart
        cdef uint32_t linear
        if (c.sram_size and 0x20 <= (bank & 0x7F) <= 0x3F
                and 0x6000 <= addr < 0x8000):
            base[0] = ((bank & 0x1F) * 0x2000) & c.sram_mask
            return PK_SRAM
        linear = ((bank & 0x3F) << 16) | addr
        if self.extended and (bank & 0x80) == 0:
            linear += 0x400000
        base[0] = c.rom_offset(linear)
        return PK_ROM


# Chip name -> the Board that emulates it.  A chip missing from here has no
# board yet; the plain mapping is closer than nothing, and `describe` says so
# rather than pretending the cartridge is ordinary.
_BOARDS = {}


def register(name, cls):
    """Boards live in their own modules and add themselves here."""
    _BOARDS[name] = cls


def _load_boards():
    """Import the modules that register boards.  Deferred so board.pyx does
    not have to know about every chip at compile time."""
    from snes import sa1                      # noqa: F401  (registers itself)
    from snes import sdd1                     # noqa: F401
    from snes import superfx                  # noqa: F401
    from snes import spc7110                  # noqa: F401
    from snes import dsp1                     # noqa: F401
    from snes import obc1                     # noqa: F401


def make_board(Cart cart):
    """Pick the board for a cartridge.

    snes.boards decides what chip is on it: the header's chipset byte, with a
    per-game override for the headers that lie.
    """
    from snes.boards import coprocessor
    cdef Board board
    if not _BOARDS:
        _load_boards()
    chip = coprocessor(cart)
    if chip is not None and chip in _BOARDS:
        return _BOARDS[chip](cart)
    board = LoROM(cart) if cart.map_mode == MAP_LOROM else HiROM(cart)
    if chip is not None:
        board.unsupported = chip
        board.name = u"%s (%s not emulated)" % (board.name, chip)
    return board
