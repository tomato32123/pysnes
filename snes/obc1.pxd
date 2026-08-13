# cython: language_level=3
from libc.stdint cimport uint8_t, uint32_t

from snes.board cimport Board


cdef class OBC1(Board):
    cdef uint32_t base                # $1800 or $1C00, from $1FF5 bit 0
    cdef uint32_t index               # which sprite, from $1FF6
    cdef int shift                    # which 2-bit field, from $1FF6 bits 0-1

    cdef uint8_t _ram_read(self, uint32_t addr) noexcept
    cdef void _ram_write(self, uint32_t addr, uint8_t value) noexcept
    cdef void _reload(self) noexcept
