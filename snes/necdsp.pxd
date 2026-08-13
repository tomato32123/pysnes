# cython: language_level=3
from libc.stdint cimport uint8_t, uint16_t, uint32_t, int64_t


cdef class NECDSP:
    # -- what the part is --------------------------------------------------
    cdef uint32_t prg_mask           # 2047 on a 77C25, 16383 on a 96050
    cdef uint32_t drom_mask
    cdef uint32_t ram_mask

    # -- memory ------------------------------------------------------------
    cdef uint32_t prg[16384]         # 24-bit instruction words
    cdef uint16_t drom[2048]
    cdef uint16_t ram[2048]

    # -- registers ---------------------------------------------------------
    cdef uint16_t pc
    cdef uint16_t rp                 # data ROM pointer
    cdef uint16_t dp                 # data RAM pointer
    cdef uint16_t k, l               # multiplier inputs
    cdef uint16_t m, n               # multiplier outputs
    cdef uint16_t a, b               # accumulators
    cdef uint16_t tr, trb            # temporary registers
    cdef uint16_t dr                 # the host's data register
    cdef uint16_t sr                 # status
    cdef uint16_t si, so             # serial, which nothing on a cartridge uses

    # Flags per accumulator: sign, sign auxiliary, carry, zero, overflow and
    # overflow auxiliary.  The auxiliary pair is what lets three additions in
    # a row still know the true sign.
    cdef int s0a, s1a, ca, za, ov0a, ov1a
    cdef int s0b, s1b, cb, zb, ov0b, ov1b

    cdef uint16_t stack[8]
    cdef int sp

    cdef int64_t clock               # master clocks consumed
    cdef int loaded                  # a program is present

    cdef uint16_t _src(self, int which) noexcept
    cdef void _dst(self, int which, uint16_t value) noexcept
    cdef void _alu(self, int op, uint16_t p, int use_b) noexcept
    cdef int _cond(self, int brch) noexcept
    cdef void step(self) noexcept
    cdef void run_cycles(self, int cycles) noexcept
