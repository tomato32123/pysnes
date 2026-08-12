# cython: language_level=3
from libc.stdint cimport uint8_t, uint32_t, int64_t

from snes.cart cimport Cart


cdef enum PageKind:
    PK_OPENBUS = 0
    PK_ROM     = 1
    PK_WRAM    = 2
    PK_SRAM    = 3
    PK_MMIO_LO = 4      # $2000-$3FFF
    PK_MMIO_HI = 5      # $4000-$5FFF
    PK_DEVICE  = 6      # something on the cartridge answers here


cdef class Board:
    cdef readonly Cart cart
    cdef readonly unicode name
    cdef public object unsupported   # chip name we have no board for, or None

    cdef public int64_t clock        # master clock, as of the last access
    cdef public int irq_line         # a chip on the board is asserting IRQ

    cdef int classify(self, uint32_t bank, uint32_t addr, uint32_t *base) noexcept
    cdef uint8_t read(self, uint32_t addr, uint8_t data) noexcept
    cdef void write(self, uint32_t addr, uint8_t value) noexcept
    cdef void reset_board(self) noexcept
    cdef void run_until(self, int64_t master_clock) noexcept
    cdef void dma_begin(self, int channel, uint32_t addr, uint32_t count) noexcept
    cdef void dma_end(self, int channel) noexcept


cdef class LoROM(Board):
    pass


cdef class HiROM(Board):
    cdef int extended            # ExHiROM: a second 4 MB half in $00-$3F
