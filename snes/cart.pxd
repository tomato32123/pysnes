# cython: language_level=3
from libc.stdint cimport uint8_t, uint32_t

cdef enum MapMode:
    MAP_LOROM = 0
    MAP_HIROM = 1
    MAP_EXHIROM = 2

cdef class Cart:
    cdef readonly bytes rom_data
    cdef readonly bytearray sram_data
    cdef const uint8_t *rom
    cdef uint8_t *sram

    cdef readonly object path
    cdef readonly unicode title
    cdef readonly uint32_t rom_size
    cdef readonly uint32_t sram_size
    cdef readonly uint32_t sram_mask
    cdef readonly int map_mode              # MapMode
    cdef readonly int fast_rom
    cdef readonly int has_battery
    cdef readonly int coprocessor           # chipset byte at $FFD6
    cdef readonly int had_copier_header
    cdef readonly int was_interleaved
    cdef readonly uint32_t header_offset
    cdef readonly uint32_t checksum
    cdef readonly uint32_t checksum_complement
    cdef readonly uint32_t computed_checksum
    cdef readonly int checksum_ok

    cdef uint32_t rom_offset(self, uint32_t linear) noexcept nogil
