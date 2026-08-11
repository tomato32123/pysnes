# cython: language_level=3
from libc.stdint cimport uint8_t, uint32_t, int64_t


cdef class AddressSpace:
    """What a 65816 can see.

    The S-CPU sees the console's bus; an SA-1 on the cartridge sees a
    different map of the same ROM plus its own RAM.  The core is the same
    processor either way, so it is written against this and not against one
    of them.
    """
    cdef readonly int64_t master_clock
    cdef public int nmi_pending      # edge latched for the CPU
    cdef public int irq_pending      # level held for the CPU

    cdef uint8_t read8(self, uint32_t addr) noexcept
    cdef void write8(self, uint32_t addr, uint8_t value) noexcept
    cdef uint8_t read8_fast(self, uint32_t addr) noexcept
    cdef void tick(self, int cycles) noexcept
    cdef uint32_t speed(self, uint32_t addr) noexcept
