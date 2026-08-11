# cython: language_level=3
from libc.stdint cimport uint8_t, uint16_t, uint32_t, int32_t, int64_t

from snes.board cimport (Board, PageKind, PK_OPENBUS, PK_ROM, PK_WRAM,
                         PK_SRAM, PK_MMIO_LO, PK_MMIO_HI, PK_DEVICE)
from snes.cart cimport Cart
from snes.space cimport AddressSpace
from snes.ppu cimport PPU
from snes.apu cimport APU


cdef class Bus(AddressSpace):
    cdef readonly Cart cart
    cdef readonly Board board
    cdef readonly PPU ppu
    cdef readonly APU apu

    cdef uint8_t wram[0x20000]

    # 8 KB page table over the whole 24-bit address space.
    cdef uint8_t page_kind[2048]
    cdef uint32_t page_base[2048]

    cdef uint8_t mdr                 # open-bus latch

    # -- timing ------------------------------------------------------------
    cdef int hcount                  # unused; the H counter is derived now
    cdef int64_t line_start          # master clock at the start of this line
    cdef int64_t ev_time[6]          # absolute deadline per event kind
    cdef int64_t next_event          # cached earliest deadline
    cdef int vcount                  # current scanline
    cdef int field
    cdef readonly int64_t frame
    cdef int frame_ready
    cdef int ticking          # guards tick() against re-entry from HDMA/DMA
    cdef readonly int lines_per_frame
    cdef readonly int pal
    cdef readonly int vblank_start   # 225, or 240 with overscan

    # -- interrupts --------------------------------------------------------
    cdef int nmi_enabled
    cdef int nmi_flag                # $4210 bit 7
    cdef int irq_mode                # bits 4-5 of $4200
    cdef int irq_flag
    cdef int timer_irq               # the console's own H/V IRQ, before
                                     # the cartridge is taken into account
    cdef int irq_line_done
    cdef readonly int64_t nmi_count, irq_count
    cdef int in_vblank
    cdef int in_hblank
    cdef uint16_t htime, vtime

    # -- CPU-side registers ------------------------------------------------
    cdef int fast_rom                # $420D bit 0
    cdef uint8_t wrio
    cdef uint8_t mul_a, mul_b
    cdef uint16_t div_a
    cdef uint8_t div_b
    cdef uint16_t rd_div, rd_mpy
    cdef uint32_t wram_addr          # $2181-$2183 port

    # -- joypads -----------------------------------------------------------
    cdef int auto_joypad
    cdef int auto_joypad_busy
    cdef int64_t joypad_busy_until   # master clock at which $4212 bit 0 clears
    cdef uint16_t pad_state[4]       # live button state, set by the frontend
    cdef uint16_t joy[4]             # latched $4218-$421F
    cdef uint16_t pad_shift[4]
    cdef int pad_latched

    # -- DMA / HDMA --------------------------------------------------------
    cdef uint8_t dma_param[8]
    cdef uint8_t dma_bbus[8]
    cdef uint32_t dma_abus[8]        # 24-bit A-bus address
    cdef uint16_t dma_size[8]        # also HDMA indirect address
    cdef uint8_t dma_indirect_bank[8]
    cdef uint16_t hdma_table[8]      # A2An
    cdef uint8_t hdma_line[8]        # NTRLn
    cdef uint8_t dma_unused[8]
    cdef int hdma_active[8]
    cdef int hdma_do_transfer[8]
    cdef uint8_t hdma_enabled
    cdef uint8_t dma_enabled

    # -- interface ---------------------------------------------------------
    cdef uint8_t read8(self, uint32_t addr) noexcept
    cdef void write8(self, uint32_t addr, uint8_t value) noexcept
    cdef uint8_t read8_fast(self, uint32_t addr) noexcept   # no MDR/side effects
    cdef uint32_t speed(self, uint32_t addr) noexcept
    cdef void tick(self, int cycles) noexcept
    cdef uint8_t read_mmio(self, uint32_t addr) noexcept
    cdef void write_mmio(self, uint32_t addr, uint8_t value) noexcept
    cdef void run_dma(self, uint8_t channels) noexcept
    cdef void hdma_init(self) noexcept
    cdef void hdma_run(self) noexcept
    cdef void poll_joypads(self) noexcept

    # -- internals ---------------------------------------------------------
    cdef uint8_t _dma_read_a(self, uint32_t addr) noexcept
    cdef void _dma_write_b(self, uint8_t bbus, uint8_t value) noexcept
    cdef uint8_t _dma_read_b(self, uint8_t bbus) noexcept
    cdef uint16_t _hdma_fetch16(self, int ch) noexcept
    cdef void _hdma_reload(self, int ch) noexcept
    cdef void _hdma_transfer(self, int ch) noexcept
    cdef void _hdma_advance(self, int ch) noexcept
    cdef void _schedule(self, int kind, int64_t when) noexcept
    cdef void _cancel(self, int kind) noexcept
    cdef void _rescan(self) noexcept
    cdef void _run_events(self) noexcept
    cdef void _event_line(self, int64_t when) noexcept
    cdef void _arm_irq(self, int64_t line_start) noexcept
    cdef int _hcount(self) noexcept
    cdef int _screen_x(self) noexcept
    cdef void _update_irq(self) noexcept
    cdef int _line_length(self) noexcept
