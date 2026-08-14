# cython: language_level=3
from libc.stdint cimport (uint8_t, uint16_t, uint32_t, uint64_t,
                          int32_t, int64_t)

from snes.board cimport Board
from snes.cart cimport Cart
from snes.cpu cimport CPU
from snes.space cimport AddressSpace


cdef class SA1Space(AddressSpace):
    cdef SA1 chip
    cdef int64_t target              # master clock to run up to
    # What the SA-1's own bus last carried.  An address it does not decode
    # reads this back, the same way the console's does on its side.
    cdef uint8_t mdr

    cdef uint8_t read8(self, uint32_t addr) noexcept
    cdef void write8(self, uint32_t addr, uint8_t value) noexcept
    cdef uint8_t read8_fast(self, uint32_t addr) noexcept
    cdef void tick(self, int cycles) noexcept
    cdef uint32_t speed(self, uint32_t addr) noexcept


cdef class SA1(Board):
    cdef readonly SA1Space space
    cdef readonly CPU cpu

    cdef uint8_t iram[0x800]         # 2 KB, shared with the S-CPU
    cdef uint8_t *bwram              # battery RAM, the cartridge's SRAM
    cdef uint32_t bwram_mask

    # -- Super MMC ---------------------------------------------------------
    cdef uint8_t mmc[4]              # $2220-$2223, one per 1 MB ROM slot

    # -- control and messages ----------------------------------------------
    cdef uint8_t ccnt                # $2200, S-CPU -> SA-1
    cdef uint8_t scnt                # $2209, SA-1 -> S-CPU
    cdef uint8_t sie, sic, cie, cic
    cdef uint16_t crv, cnv, civ      # SA-1 reset / NMI / IRQ vectors
    cdef uint16_t snv, siv           # S-CPU NMI / IRQ vectors, SA-1 supplied
    cdef int sa1_irq, sa1_nmi        # pending from the S-CPU
    cdef int scpu_irq                # pending from the SA-1
    cdef int dma_irq_scpu, dma_irq_sa1
    cdef int timer_irq
    cdef int stopped                 # SA-1 held in reset or waiting

    # -- BW-RAM windows ----------------------------------------------------
    cdef uint8_t bmaps               # $2224, the S-CPU's $6000 window
    cdef uint8_t bmap                # $2225, the SA-1's
    cdef uint8_t sbwe, cbwe          # write protection
    cdef uint8_t bwpa                # $2228, how much of it is protected
    cdef uint8_t siwp, ciwp          # I-RAM write protection

    # -- arithmetic --------------------------------------------------------
    cdef uint8_t math_ctl            # $2250
    cdef uint16_t math_a, math_b
    cdef int64_t math_result
    cdef int math_overflow

    # -- variable-length bit reader ----------------------------------------
    cdef uint8_t vbd                 # $2258
    cdef uint32_t vda                # $2259-$225B
    cdef int vbit                    # bit position inside the stream

    # -- timers ------------------------------------------------------------
    cdef uint8_t tmc                 # $2210
    cdef uint16_t timer_h, timer_v   # $2212-$2215 compare values
    cdef int64_t timer_base          # master clock the counters started from
    cdef int64_t timer_seen          # how far the compare has been checked

    # -- DMA ---------------------------------------------------------------
    cdef uint8_t dcnt, cdma          # $2230, $2231
    cdef uint32_t dsa, dda           # source, destination
    cdef uint16_t dtc                # transfer count
    cdef uint8_t brf[16]             # $2240-$224F character conversion buffer
    cdef int cc_line

    # -- counters, so a defect can be traced to a path ----------------
    cdef int64_t n_cc1, n_cc2, n_dma, n_math, n_varlen, n_timer_irq

    cdef uint32_t _rom_offset(self, uint32_t bank, uint32_t addr) noexcept
    cdef uint8_t _read_common(self, uint32_t addr, int from_sa1, uint8_t data) noexcept
    cdef void _write_common(self, uint32_t addr, uint8_t value, int from_sa1) noexcept
    cdef uint8_t _read_reg(self, uint32_t a, int from_sa1, uint8_t data) noexcept
    cdef int _owns_reg(self, uint32_t a, int from_sa1) noexcept
    cdef void _write_reg(self, uint32_t a, uint8_t value, int from_sa1) noexcept
    cdef void _refresh_interrupts(self) noexcept
    cdef void _start_math(self) noexcept
    cdef uint16_t _read_varlen(self) noexcept
    cdef void _advance_varlen(self) noexcept
    cdef void _run_dma(self) noexcept
    cdef uint32_t _bwram_window(self, int from_sa1, uint32_t addr) noexcept
    cdef int _bwram_writable(self, uint32_t raw) noexcept
    cdef int _hcount(self) noexcept
    cdef int _vcount(self) noexcept
    cdef void _check_timer(self) noexcept
    cdef int _cc_bpp(self) noexcept
    cdef void _convert_row(self, uint32_t bwaddr, uint32_t dst, int y) noexcept
    cdef uint8_t _cc1_read(self, uint32_t offset) noexcept
    cdef void _convert_buffer(self) noexcept
    cdef int classify(self, uint32_t bank, uint32_t addr, uint32_t *base) noexcept
    cdef uint8_t read(self, uint32_t addr, uint8_t data) noexcept
    cdef void write(self, uint32_t addr, uint8_t value) noexcept
    cdef void reset_board(self) noexcept
    cdef void run_until(self, int64_t master_clock) noexcept
