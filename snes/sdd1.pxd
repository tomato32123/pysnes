# cython: language_level=3
from libc.stdint cimport uint8_t, uint16_t, uint32_t

from snes.board cimport Board


cdef class SDD1(Board):
    # -- memory mapper -----------------------------------------------------
    cdef uint8_t mmc[4]              # $4804-$4807, one per 1 MB slot of $C0-$FF

    # -- decompression arming ----------------------------------------------
    cdef uint8_t dma_enable          # $4800: channels the chip may take over
    cdef uint8_t dma_arm             # $4801: channels whose next DMA is packed

    # -- the decompressor ---------------------------------------------------
    cdef uint8_t out[0x10000]        # a whole transfer's worth of output
    cdef uint32_t out_len
    cdef uint32_t out_pos
    cdef int active                  # a claimed transfer is in progress

    cdef uint32_t in_addr            # bus address of the next packed byte
    cdef uint16_t in_stream
    cdef int valid_bits
    cdef uint8_t bit_ctr[8]          # one Golomb decoder per code size
    cdef uint8_t context_state[32]
    cdef uint8_t context_mps[32]
    cdef uint16_t prev_bits[8]       # per bitplane, the bits already decoded
    cdef int bitplane_type
    cdef int high_context_bits
    cdef int low_context_bits

    cdef uint8_t _next_packed(self) noexcept
    cdef uint8_t _codeword(self, int bits) noexcept
    cdef int _golomb_bit(self, int code_size) noexcept
    cdef int _prob_bit(self, int context) noexcept
    cdef int _bit(self, int plane) noexcept
    cdef void _decompress(self, uint32_t addr, uint32_t count) noexcept

    # -- what the cartridge has actually been seen to do --------------------
    # The registers are documented, but which of the two masks arms a
    # transfer, and whether the arming survives it, is the sort of thing a
    # game settles faster than a document.  These count it.
    cdef uint32_t dma_seen           # transfers the chip was told about
    cdef uint32_t dma_armed_seen     # of those, ones with a matching arm bit
    cdef uint8_t last_channel
    cdef uint8_t last_enable
    cdef uint8_t last_arm
    cdef uint32_t last_addr
    cdef uint32_t last_count

    cdef uint32_t rom_offset(self, uint32_t bank, uint32_t addr) noexcept
