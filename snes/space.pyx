# cython: language_level=3
# cython: boundscheck=False, wraparound=False, cdivision=True
"""The interface a 65816 needs from whatever it is plugged into.

Two processors in this machine are 65816s -- the one in the console and the
one on an SA-1 cartridge -- and they differ only in what they can address and
how long each access takes.  Keeping that behind one small class means the
core is written once.
"""
from libc.stdint cimport uint8_t, uint32_t


cdef class AddressSpace:

    cdef uint8_t read8(self, uint32_t addr) noexcept:
        return 0

    cdef void write8(self, uint32_t addr, uint8_t value) noexcept:
        pass

    cdef uint8_t read8_fast(self, uint32_t addr) noexcept:
        """Side-effect-free, for the debugger and the disassembler."""
        return 0

    cdef void tick(self, int cycles) noexcept:
        pass

    cdef uint32_t speed(self, uint32_t addr) noexcept:
        """Master cycles one access to this address costs."""
        return 6
