# cython: language_level=3
from libc.stdint cimport uint8_t, uint16_t, uint32_t, int32_t, int64_t

from snes.board cimport Board
from snes.cart cimport Cart


cdef class SuperFX(Board):
    # -- the processor -----------------------------------------------------
    cdef uint16_t r[16]              # general purpose; r15 is the program counter
    cdef int r14_modified
    cdef int r15_modified
    cdef uint16_t sfr                # status flags
    cdef uint8_t pbr                 # program bank
    cdef uint8_t rombr               # ROM bank for the buffered reader
    cdef int rambr                   # RAM bank, one bit
    cdef uint16_t cbr                # cache base
    cdef uint8_t scbr                # screen base
    cdef uint8_t colr                # the colour plot writes
    cdef int bramr
    cdef uint8_t vcr                 # version, read-only
    cdef int clsr                    # clock select: 21 MHz rather than 10.7
    cdef uint8_t pipeline            # the byte fetched ahead of the one running
    cdef uint16_t ramaddr

    # screen mode, unpacked
    cdef int scmr_ht, scmr_ron, scmr_ran, scmr_md
    # plot options, unpacked
    cdef int por_obj, por_freezehigh, por_highnibble, por_dither, por_transparent
    # config, unpacked
    cdef int cfgr_irq, cfgr_ms0

    cdef int sreg, dreg              # which register a source or result means

    # -- the buffered ROM and RAM readers ----------------------------------
    cdef int romcl
    cdef uint8_t romdr
    cdef int ramcl
    cdef uint16_t ramar
    cdef uint8_t ramdr

    # -- the instruction cache ---------------------------------------------
    cdef uint8_t cache_buffer[512]
    cdef int cache_valid[32]

    # -- the pixel cache: two rows of eight, one filling, one draining ------
    cdef uint32_t pc_offset[2]
    cdef uint8_t pc_bitpend[2]
    cdef uint8_t pc_data[2][8]

    # -- the cartridge -----------------------------------------------------
    cdef uint8_t *rom
    cdef uint32_t rom_mask
    cdef uint8_t *ram
    cdef uint32_t ram_mask
    cdef object ram_data

    cdef int64_t gsu_clock           # in master cycles, so the console can be met
    cdef int64_t target

    cdef void run_until(self, int64_t master_clock) noexcept
    cdef void step(self, int clocks) noexcept
    cdef void main(self) noexcept
    cdef uint8_t gsu_read(self, uint32_t addr) noexcept
    cdef void gsu_write(self, uint32_t addr, uint8_t value) noexcept
    cdef uint8_t read_opcode(self, uint16_t addr) noexcept
    cdef uint8_t peekpipe(self) noexcept
    cdef uint8_t pipe(self) noexcept
    cdef void flush_cache(self) noexcept
    cdef void sync_rom_buffer(self) noexcept
    cdef uint8_t read_rom_buffer(self) noexcept
    cdef void update_rom_buffer(self) noexcept
    cdef void sync_ram_buffer(self) noexcept
    cdef uint8_t read_ram_buffer(self, uint16_t addr) noexcept
    cdef void write_ram_buffer(self, uint16_t addr, uint8_t value) noexcept
    cdef uint8_t plot_colour(self, uint8_t source) noexcept
    cdef void plot(self, uint8_t x, uint8_t y) noexcept
    cdef uint8_t rpix(self, uint8_t x, uint8_t y) noexcept
    cdef void flush_pixel_cache(self, int which) noexcept
    cdef uint32_t char_address(self, uint8_t x, uint8_t y, int *bpp) noexcept
    cdef uint8_t read_reg(self, uint32_t off) noexcept
    cdef void write_reg(self, uint32_t off, uint8_t value) noexcept
    cdef uint16_t sr(self) noexcept
    cdef void set_dr(self, uint32_t value) noexcept
    cdef void set_r(self, int n, uint32_t value) noexcept
    cdef void setf(self, uint16_t mask, int on) noexcept
    cdef void nz(self, uint16_t v) noexcept
    cdef void reset_prefix(self) noexcept
    cdef void execute(self, uint8_t op) noexcept
