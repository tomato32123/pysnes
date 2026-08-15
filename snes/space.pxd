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
    # Bus cycles during which an interrupt may not be latched.  The 65816
    # decides whether to take one a cycle before an instruction ends, and a
    # DMA finishing inside that window hides the decision until the
    # instruction after next -- which is what Sour's dma_irq_test measures.
    cdef public int irq_lock
    # When the line last went up, and when the cycle now running began.  The
    # processor has to have seen the line before its instruction's last cycle
    # started; one that rises inside that cycle waits for the instruction
    # after.  Neither question can be answered at an instruction boundary,
    # which is the only place a trace can look.
    cdef public int64_t irq_rose_at
    cdef public int64_t nmi_rose_at
    cdef public int64_t cycle_start

    cdef uint8_t read8(self, uint32_t addr) noexcept
    cdef void write8(self, uint32_t addr, uint8_t value) noexcept
    cdef uint8_t read8_fast(self, uint32_t addr) noexcept
    cdef void tick(self, int cycles) noexcept
    cdef uint32_t speed(self, uint32_t addr) noexcept
