# cython: language_level=3
from libc.stdint cimport uint8_t, uint16_t, uint32_t, uint64_t, int32_t, int64_t

from snes.board cimport Board


cdef class SPC7110(Board):
    # -- the two ROMs the cartridge carries ---------------------------------
    cdef const uint8_t *rom
    cdef uint32_t prom_size          # the program ROM: what the console runs
    cdef uint32_t drom_base          # where the data ROM starts in the image
    cdef uint32_t drom_size

    # -- decompression unit -------------------------------------------------
    cdef uint8_t r4801, r4802, r4803, r4804, r4805, r4806, r4807
    cdef uint8_t r4809, r480a, r480b, r480c
    cdef uint8_t dcu_mode
    cdef uint32_t dcu_address
    cdef uint8_t dcu_tile[32]
    cdef uint32_t dcu_offset

    # -- data port unit -----------------------------------------------------
    cdef uint8_t r4810, r4811, r4812, r4813, r4814, r4815
    cdef uint8_t r4816, r4817, r4818, r481a

    # -- arithmetic unit ----------------------------------------------------
    cdef uint8_t r4820, r4821, r4822, r4823, r4824, r4825, r4826, r4827
    cdef uint8_t r4828, r4829, r482a, r482b, r482c, r482d, r482e, r482f

    # -- memory control unit ------------------------------------------------
    cdef uint8_t r4830, r4831, r4832, r4833, r4834

    # -- the decompressor's own state ---------------------------------------
    cdef uint8_t ctx_prediction[5][15]
    cdef uint8_t ctx_swap[5][15]
    cdef int bpp
    cdef uint32_t offset             # where in the data ROM the next byte is
    cdef int bits                    # bits left in `input`
    cdef uint16_t range_
    cdef uint16_t input_
    cdef uint8_t output
    cdef uint64_t pixels
    cdef uint64_t colormap
    cdef uint32_t result

    cdef uint8_t datarom_read(self, uint32_t addr) noexcept
    cdef uint8_t mcurom_read(self, uint32_t addr, uint8_t data) noexcept
    cdef uint8_t read_reg(self, uint32_t off, uint8_t data) noexcept
    cdef void write_reg(self, uint32_t off, uint8_t value) noexcept

    cdef void dcu_load_address(self) noexcept
    cdef void dcu_begin_transfer(self) noexcept
    cdef uint8_t dcu_read(self) noexcept

    cdef uint32_t data_offset(self) noexcept
    cdef uint32_t data_adjust(self) noexcept
    cdef uint32_t data_stride(self) noexcept
    cdef void set_data_offset(self, uint32_t addr) noexcept
    cdef void set_data_adjust(self, uint32_t addr) noexcept
    cdef void data_port_read(self) noexcept
    cdef void data_port_increment_4810(self) noexcept
    cdef void data_port_increment_4814(self) noexcept
    cdef void data_port_increment_4815(self) noexcept
    cdef void data_port_increment_481a(self) noexcept

    cdef void alu_multiply(self) noexcept
    cdef void alu_divide(self) noexcept

    cdef uint8_t dec_read(self) noexcept
    cdef void dec_initialize(self, int mode, uint32_t origin) noexcept
    cdef void dec_decode(self) noexcept

    # -- the real-time clock, on the cartridges that have one -------------
    cdef int has_rtc
    cdef uint8_t rtc[16]             # sixteen four-bit registers
    cdef int rtc_state               # 0 idle, 1 command, 2 index, 3 write, 4 read
    cdef int rtc_reading
    cdef int rtc_index
    cdef uint32_t rtc_reads          # how often the game has asked, for tooling
    cdef uint32_t rtc_touches        # any access at all to $4840-$4842
    cdef int64_t rtc_seconds         # the time the chip is holding
    cdef int64_t rtc_last_clock      # master clock when it last advanced
    cdef int rtc_dirty               # digits were written; take the time from them
    # What the game asked of the clock, so its own check program can be
    # read rather than guessed at: address, whether it was a write, value.
    cdef uint8_t rtc_trace[3][512]
    cdef int rtc_trace_len

    cdef void rtc_powerup_weekday(self) noexcept
    cdef void rtc_advance(self) noexcept
    cdef void rtc_from_digits(self) noexcept
    cdef void rtc_sync(self) noexcept
    cdef uint8_t rtc_read(self, uint32_t off, uint8_t data) noexcept
    cdef void rtc_write(self, uint32_t off, uint8_t value) noexcept
