# cython: language_level=3
"""S-CPU bus: address decoding, MMIO, DMA/HDMA, timing and interrupts.

Every S-CPU memory access funnels through here, so this is also where the
master clock advances and where scanline events (VBlank, IRQ, HDMA, auto
joypad read) are raised.
"""

from libc.string cimport memset, memcpy
from cpython.bytes cimport PyBytes_FromStringAndSize
from libc.stdint cimport uint8_t, uint16_t, uint32_t, int32_t, int64_t

from snes.board cimport Board
from snes.board import make_board
from snes.cart cimport Cart
from snes.ppu cimport PPU
from snes.apu cimport APU


cdef enum:
    # The automatic controller read starts just after V-blank begins and
    # holds $4212 bit 0 for this many master cycles -- about three lines.
    JOYPAD_READ_CYCLES = 4224
    CYCLES_PER_LINE = 1364
    HDMA_DOT = 278              # HDMA transfers late in the line, not at its end
    APU_SYNC_CYCLES = 1364      # catch the APU up at least once per line
    # Once a scanline the CPU is halted while DRAM is refreshed.  It is not
    # optional and not skippable, so it shortens every line's usable time.
    REFRESH_CYCLE = 538
    REFRESH_COST = 40
    # Scanline 240 of a non-interlaced odd NTSC field is one dot short, and
    # scanline 311 of an interlaced odd PAL field one dot long.
    SHORT_LINE = 1360
    LONG_LINE = 1368
    LINES_NTSC = 262
    LINES_PAL = 312

# Master clock in each region; the APU keeps its own crystal either way.
DEF MASTER_HZ_NTSC = 21477272
DEF MASTER_HZ_PAL = 21281370


# Bytes written per transfer unit, and the B-bus offset pattern, for each of
# the eight DMA transfer modes.
cdef int DMA_LEN[8]
cdef int DMA_OFF[8][4]
DMA_LEN[:] = [1, 2, 2, 4, 4, 4, 2, 4]
DMA_OFF[0][:] = [0, 0, 0, 0]
DMA_OFF[1][:] = [0, 1, 0, 1]
DMA_OFF[2][:] = [0, 0, 0, 0]
DMA_OFF[3][:] = [0, 0, 1, 1]
DMA_OFF[4][:] = [0, 1, 2, 3]
DMA_OFF[5][:] = [0, 1, 0, 1]
DMA_OFF[6][:] = [0, 0, 0, 0]
DMA_OFF[7][:] = [0, 0, 1, 1]


cdef enum:
    EV_LINE = 0
    EV_HDMA = 1
    EV_IRQ = 2
    EV_JOYPAD = 3
    EV_APU = 4
    EV_REFRESH = 5
    EV_COUNT = 6


DEF NEVER = 0x7FFFFFFFFFFFFFFF


cdef class Bus:

    def __init__(self, Cart cart, PPU ppu, APU apu, Board board=None):
        self.cart = cart
        self.board = board if board is not None else make_board(cart)
        self.ppu = ppu
        self.apu = apu
        self.build_map()
        self.reset()

    # =====================================================================
    # address map
    # =====================================================================

    def build_map(self):
        """Fill the 8 KB page table.

        The parts the console itself decodes -- WRAM, the two register
        blocks -- are fixed and answered here.  Everything else is the
        cartridge's business, so the board is asked what is at each page.
        """
        cdef uint32_t page, bank, addr, base
        cdef int kind

        for page in range(2048):
            bank = page >> 3
            addr = (page & 7) << 13
            self.page_kind[page] = PK_OPENBUS
            self.page_base[page] = 0

            if bank == 0x7E or bank == 0x7F:
                self.page_kind[page] = PK_WRAM
                self.page_base[page] = ((bank - 0x7E) << 16) | addr
                continue

            if (bank & 0x7F) < 0x40 and addr < 0x6000:  # $00-$3F / $80-$BF
                if addr < 0x2000:
                    self.page_kind[page] = PK_WRAM
                    self.page_base[page] = 0
                elif addr < 0x4000:
                    self.page_kind[page] = PK_MMIO_LO
                else:
                    self.page_kind[page] = PK_MMIO_HI
                continue

            base = 0
            kind = self.board.classify(bank, addr, &base)
            self.page_kind[page] = <uint8_t>kind
            self.page_base[page] = base

    # =====================================================================
    # reset
    # =====================================================================

    def reset(self):
        cdef int i
        memset(self.wram, 0x55, sizeof(self.wram))
        self.mdr = 0
        self.master_clock = 0
        self.line_start = 0
        self.hcount = 0
        self.vcount = 0
        self.field = 0
        self.frame = 0
        self.frame_ready = 0
        self.ticking = 0
        for i in range(EV_COUNT):
            self.ev_time[i] = NEVER
        self.next_event = NEVER
        self.pal = self.cart.is_pal
        self.lines_per_frame = LINES_PAL if self.pal else LINES_NTSC
        self.vblank_start = 225
        self.ppu.pal = self.pal
        self.ppu.vdisp = self.vblank_start
        self.apu.master_hz = MASTER_HZ_PAL if self.pal else MASTER_HZ_NTSC

        self.nmi_enabled = 0
        self.nmi_flag = 0
        self.nmi_pending = 0
        self.irq_mode = 0
        self.irq_flag = 0
        self.timer_irq = 0
        self.irq_pending = 0
        self.irq_line_done = 0
        self.nmi_count = 0
        self.irq_count = 0
        self.in_vblank = 0
        self.in_hblank = 0
        self.htime = 0x1FF
        self.vtime = 0x1FF

        self.fast_rom = 0
        self.wrio = 0xFF
        self.mul_a = 0xFF
        self.mul_b = 0xFF
        self.div_a = 0xFFFF
        self.div_b = 0xFF
        self.rd_div = 0
        self.rd_mpy = 0
        self.wram_addr = 0

        self.auto_joypad = 0
        self.auto_joypad_busy = 0
        self.joypad_busy_until = 0
        self.pad_latched = 0
        for i in range(4):
            self.pad_state[i] = 0
            self.joy[i] = 0
            self.pad_shift[i] = 0

        for i in range(8):
            self.dma_param[i] = 0xFF
            self.dma_bbus[i] = 0xFF
            self.dma_abus[i] = 0xFFFFFF
            self.dma_size[i] = 0xFFFF
            self.dma_indirect_bank[i] = 0xFF
            self.hdma_table[i] = 0xFFFF
            self.hdma_line[i] = 0xFF
            self.dma_unused[i] = 0xFF
            self.hdma_active[i] = 0
            self.hdma_do_transfer[i] = 0
        self.hdma_enabled = 0
        self.dma_enabled = 0

        # Prime the timeline.
        self._schedule(EV_LINE, CYCLES_PER_LINE)
        self._schedule(EV_REFRESH, REFRESH_CYCLE)
        self._schedule(EV_APU, APU_SYNC_CYCLES)

    # =====================================================================
    # access speed
    # =====================================================================

    cdef uint32_t speed(self, uint32_t addr) noexcept:
        cdef uint32_t bank = (addr >> 16) & 0xFF
        cdef uint32_t a = addr & 0xFFFF
        if bank & 0x40:                                  # $40-$7F, $C0-$FF
            if bank >= 0xC0:
                return 6 if self.fast_rom else 8
            return 8
        if a < 0x2000:
            return 8
        if a < 0x4000:
            return 6
        if a < 0x4200:
            return 12
        if a < 0x6000:
            return 6
        if a < 0x8000:
            return 8
        if bank & 0x80:
            return 6 if self.fast_rom else 8
        return 8

    # =====================================================================
    # memory access
    # =====================================================================

    cdef uint8_t read8(self, uint32_t addr) noexcept:
        cdef uint32_t page = (addr >> 13) & 0x7FF
        cdef uint8_t kind = self.page_kind[page]
        cdef uint32_t off = addr & 0x1FFF

        if kind == PK_ROM:
            self.mdr = self.cart.rom[(self.page_base[page] + off) % self.cart.rom_size]
        elif kind == PK_WRAM:
            self.mdr = self.wram[(self.page_base[page] + off) & 0x1FFFF]
        elif kind == PK_MMIO_LO or kind == PK_MMIO_HI:
            self.mdr = self.read_mmio(addr)
        elif kind == PK_SRAM:
            self.mdr = self.cart.sram[(self.page_base[page] + off) & self.cart.sram_mask]
        elif kind == PK_DEVICE:
            self.board.clock = self.master_clock
            self.mdr = self.board.read(addr, self.mdr)
            self._update_irq()
        return self.mdr

    cdef void write8(self, uint32_t addr, uint8_t value) noexcept:
        cdef uint32_t page = (addr >> 13) & 0x7FF
        cdef uint8_t kind = self.page_kind[page]
        cdef uint32_t off = addr & 0x1FFF

        self.mdr = value
        if kind == PK_WRAM:
            self.wram[(self.page_base[page] + off) & 0x1FFFF] = value
        elif kind == PK_MMIO_LO or kind == PK_MMIO_HI:
            self.write_mmio(addr, value)
        elif kind == PK_SRAM:
            self.cart.sram[(self.page_base[page] + off) & self.cart.sram_mask] = value
        elif kind == PK_DEVICE:
            self.board.clock = self.master_clock
            self.board.write(addr, value)
            self._update_irq()
        # ROM and open bus swallow writes.

    cdef uint8_t read8_fast(self, uint32_t addr) noexcept:
        """Side-effect-free read, for the debugger and the disassembler."""
        cdef uint32_t page = (addr >> 13) & 0x7FF
        cdef uint8_t kind = self.page_kind[page]
        cdef uint32_t off = addr & 0x1FFF
        if kind == PK_ROM:
            return self.cart.rom[(self.page_base[page] + off) % self.cart.rom_size]
        if kind == PK_WRAM:
            return self.wram[(self.page_base[page] + off) & 0x1FFFF]
        if kind == PK_SRAM:
            return self.cart.sram[(self.page_base[page] + off) & self.cart.sram_mask]
        return self.mdr

    # =====================================================================
    # MMIO
    # =====================================================================

    cdef uint8_t read_mmio(self, uint32_t addr) noexcept:
        cdef uint32_t a = addr & 0xFFFF
        cdef int ch, reg
        cdef uint8_t v

        if 0x2100 <= a <= 0x213F:
            self.ppu.hcounter = self._hcount() >> 2
            self.ppu.vcounter = self.vcount
            return self.ppu.read_reg(a)

        if 0x2140 <= a <= 0x217F:
            self.apu.run_until(self.master_clock)
            return self.apu.cpu_read_port(a & 3)

        if a == 0x2180:
            v = self.wram[self.wram_addr & 0x1FFFF]
            self.wram_addr = (self.wram_addr + 1) & 0x1FFFF
            return v

        if a == 0x4016:
            v = self.mdr & 0xFC
            v |= <uint8_t>(self.pad_shift[0] >> 15)
            self.pad_shift[0] = (self.pad_shift[0] << 1) | 1
            return v
        if a == 0x4017:
            v = (self.mdr & 0xE0) | 0x1C
            v |= <uint8_t>(self.pad_shift[1] >> 15)
            self.pad_shift[1] = (self.pad_shift[1] << 1) | 1
            return v

        if a == 0x4210:                                   # RDNMI
            v = (self.mdr & 0x70) | 0x02
            if self.nmi_flag:
                v |= 0x80
            self.nmi_flag = 0
            return v
        if a == 0x4211:                                   # TIMEUP
            v = self.mdr & 0x7F
            if self.irq_flag:
                v |= 0x80
            self.irq_flag = 0
            self.timer_irq = 0
            self._update_irq()
            return v
        if a == 0x4212:                                   # HVBJOY
            v = self.mdr & 0x3E
            if self.in_vblank:
                v |= 0x80
            if self._hcount() >= 1096:                    # H-blank from dot 274
                v |= 0x40
            if self.auto_joypad_busy:
                v |= 0x01
            return v
        if a == 0x4213:
            return self.wrio
        if a == 0x4214:
            return <uint8_t>(self.rd_div & 0xFF)
        if a == 0x4215:
            return <uint8_t>(self.rd_div >> 8)
        if a == 0x4216:
            return <uint8_t>(self.rd_mpy & 0xFF)
        if a == 0x4217:
            return <uint8_t>(self.rd_mpy >> 8)
        if 0x4218 <= a <= 0x421F:
            ch = (a - 0x4218) >> 1
            if a & 1:
                return <uint8_t>(self.joy[ch] >> 8)
            return <uint8_t>(self.joy[ch] & 0xFF)

        if 0x4300 <= a <= 0x437F:
            ch = (a >> 4) & 7
            reg = a & 0x0F
            if reg == 0x0:
                return self.dma_param[ch]
            if reg == 0x1:
                return self.dma_bbus[ch]
            if reg == 0x2:
                return <uint8_t>(self.dma_abus[ch] & 0xFF)
            if reg == 0x3:
                return <uint8_t>((self.dma_abus[ch] >> 8) & 0xFF)
            if reg == 0x4:
                return <uint8_t>((self.dma_abus[ch] >> 16) & 0xFF)
            if reg == 0x5:
                return <uint8_t>(self.dma_size[ch] & 0xFF)
            if reg == 0x6:
                return <uint8_t>(self.dma_size[ch] >> 8)
            if reg == 0x7:
                return self.dma_indirect_bank[ch]
            if reg == 0x8:
                return <uint8_t>(self.hdma_table[ch] & 0xFF)
            if reg == 0x9:
                return <uint8_t>(self.hdma_table[ch] >> 8)
            if reg == 0xA:
                return self.hdma_line[ch]
            return self.dma_unused[ch]

        # The console decodes $2100-$21FF and $4000-$44FF.  Everything else in
        # here is brought out to the cartridge connector, which is where an
        # SA-1's registers and its internal RAM live.
        self.board.clock = self.master_clock
        return self.board.read(addr, self.mdr)

    cdef void write_mmio(self, uint32_t addr, uint8_t value) noexcept:
        cdef uint32_t a = addr & 0xFFFF
        cdef int ch, reg
        cdef uint32_t quotient, remainder

        if 0x2100 <= a <= 0x213F:
            # Draw everything to the left of this write with the old state, so
            # a mid-scanline change takes effect from here rather than from the
            # start of the line.
            self.ppu.hcounter = self._hcount() >> 2
            self.ppu.vcounter = self.vcount
            self.ppu.catch_up(self._screen_x())
            self.ppu.write_reg(a, value)
            return

        if 0x2140 <= a <= 0x217F:
            self.apu.run_until(self.master_clock)
            self.apu.cpu_write_port(a & 3, value)
            return

        if a == 0x2180:
            self.wram[self.wram_addr & 0x1FFFF] = value
            self.wram_addr = (self.wram_addr + 1) & 0x1FFFF
            return
        if a == 0x2181:
            self.wram_addr = (self.wram_addr & 0x1FF00) | value
            return
        if a == 0x2182:
            self.wram_addr = (self.wram_addr & 0x100FF) | (<uint32_t>value << 8)
            return
        if a == 0x2183:
            self.wram_addr = (self.wram_addr & 0x0FFFF) | ((<uint32_t>value & 1) << 16)
            return

        if a == 0x4016:                                   # JOYWR strobe
            if value & 1:
                self.pad_latched = 1
                self.pad_shift[0] = self.pad_state[0]
                self.pad_shift[1] = self.pad_state[1]
            else:
                self.pad_latched = 0
            return

        if a == 0x4200:                                   # NMITIMEN
            self.auto_joypad = value & 1
            self.irq_mode = (value >> 4) & 3
            if self.irq_mode == 0:
                self.irq_flag = 0
                self.timer_irq = 0
                self._update_irq()
                self._cancel(EV_IRQ)
            else:
                self._arm_irq(self.line_start)
            # Enabling NMI while the flag is already set fires immediately.
            if (value & 0x80) and not self.nmi_enabled and self.nmi_flag:
                self.nmi_pending = 1
            self.nmi_enabled = (value >> 7) & 1
            return
        if a == 0x4201:
            # Bit 7 drives pin 6 of controller port 2, which is also the PPU's
            # latch line.  Taking it low freezes the H and V counters, and
            # that is how a light gun reports where it was pointed.
            if (self.wrio & 0x80) and not (value & 0x80):
                self.ppu.hcounter = self._hcount() >> 2
                self.ppu.vcounter = self.vcount
                self.ppu.latch_counters()
            self.wrio = value
            return
        if a == 0x4202:
            self.mul_a = value
            return
        if a == 0x4203:
            self.mul_b = value
            self.rd_mpy = <uint16_t>(<uint32_t>self.mul_a * <uint32_t>value)
            return
        if a == 0x4204:
            self.div_a = (self.div_a & 0xFF00) | value
            return
        if a == 0x4205:
            self.div_a = (self.div_a & 0x00FF) | (<uint16_t>value << 8)
            return
        if a == 0x4206:
            self.div_b = value
            if value == 0:
                self.rd_div = 0xFFFF
                self.rd_mpy = self.div_a
            else:
                quotient = self.div_a // value
                remainder = self.div_a % value
                self.rd_div = <uint16_t>quotient
                self.rd_mpy = <uint16_t>remainder
            return
        if a == 0x4207:
            self.htime = (self.htime & 0x100) | value
            self._arm_irq(self.line_start)
            return
        if a == 0x4208:
            self.htime = (self.htime & 0x0FF) | ((<uint16_t>value & 1) << 8)
            self._arm_irq(self.line_start)
            return
        if a == 0x4209:
            self.vtime = (self.vtime & 0x100) | value
            self._arm_irq(self.line_start)
            return
        if a == 0x420A:
            self.vtime = (self.vtime & 0x0FF) | ((<uint16_t>value & 1) << 8)
            self._arm_irq(self.line_start)
            return
        if a == 0x420B:                                   # MDMAEN
            self.dma_enabled = value
            if value:
                self.run_dma(value)
            return
        if a == 0x420C:                                   # HDMAEN
            self.hdma_enabled = value
            return
        if a == 0x420D:                                   # MEMSEL
            self.fast_rom = value & 1
            return

        if 0x4300 <= a <= 0x437F:
            ch = (a >> 4) & 7
            reg = a & 0x0F
            if reg == 0x0:
                self.dma_param[ch] = value
            elif reg == 0x1:
                self.dma_bbus[ch] = value
            elif reg == 0x2:
                self.dma_abus[ch] = (self.dma_abus[ch] & 0xFFFF00) | value
            elif reg == 0x3:
                self.dma_abus[ch] = (self.dma_abus[ch] & 0xFF00FF) | (<uint32_t>value << 8)
            elif reg == 0x4:
                self.dma_abus[ch] = (self.dma_abus[ch] & 0x00FFFF) | (<uint32_t>value << 16)
            elif reg == 0x5:
                self.dma_size[ch] = (self.dma_size[ch] & 0xFF00) | value
            elif reg == 0x6:
                self.dma_size[ch] = (self.dma_size[ch] & 0x00FF) | (<uint16_t>value << 8)
            elif reg == 0x7:
                self.dma_indirect_bank[ch] = value
            elif reg == 0x8:
                self.hdma_table[ch] = (self.hdma_table[ch] & 0xFF00) | value
            elif reg == 0x9:
                self.hdma_table[ch] = (self.hdma_table[ch] & 0x00FF) | (<uint16_t>value << 8)
            elif reg == 0xA:
                self.hdma_line[ch] = value
            else:
                self.dma_unused[ch] = value
            return

        self.board.clock = self.master_clock
        self.board.write(addr, value)

    # =====================================================================
    # DMA
    # =====================================================================

    cdef inline uint8_t _dma_read_a(self, uint32_t addr) noexcept:
        # The A bus cannot see the B bus; $2100-$21FF reads back open bus.
        if (addr & 0xFF00) == 0x2100 and ((addr >> 16) & 0x40) == 0:
            return self.mdr
        return self.read8(addr)

    cdef inline void _dma_write_b(self, uint8_t bbus, uint8_t value) noexcept:
        self.write_mmio(0x2100 | bbus, value)

    cdef inline uint8_t _dma_read_b(self, uint8_t bbus) noexcept:
        return self.read_mmio(0x2100 | bbus)

    cdef void run_dma(self, uint8_t channels) noexcept:
        cdef int ch, i, mode, step, unit
        cdef uint32_t a_addr
        cdef uint8_t bbus, param
        cdef uint32_t count

        # DMA is clocked at one eighth of the master clock, so starting a
        # transfer first waits for that edge: one to eight cycles, never zero.
        self.tick(<int>(8 - (self.master_clock & 7)))
        self.tick(8)                                     # DMA startup overhead
        for ch in range(8):
            if not (channels & (1 << ch)):
                continue
            self.tick(8)                                 # per-channel overhead

            param = self.dma_param[ch]
            mode = param & 7
            unit = DMA_LEN[mode]
            bbus = self.dma_bbus[ch]
            a_addr = self.dma_abus[ch]
            if param & 0x08:                             # fixed A address
                step = 0
            elif param & 0x10:
                step = -1
            else:
                step = 1

            count = self.dma_size[ch]
            if count == 0:
                count = 0x10000
            # A chip on the cartridge may want to answer this channel's reads
            # itself.  It is told before the first one, because a decompressor
            # has to start from the address the channel was pointed at.
            self.board.clock = self.master_clock
            self.board.dma_begin(ch, a_addr, count)
            i = 0
            while count:
                self.tick(8)
                if param & 0x80:                         # B -> A
                    self.write8(a_addr, self._dma_read_b(bbus + DMA_OFF[mode][i]))
                else:                                    # A -> B
                    self._dma_write_b(bbus + DMA_OFF[mode][i],
                                      self._dma_read_a(a_addr))
                a_addr = (a_addr & 0xFF0000) | ((a_addr + step) & 0xFFFF)
                i = (i + 1) & 3
                if i >= unit:
                    i = 0
                count -= 1

            self.board.dma_end(ch)
            self.dma_abus[ch] = a_addr
            self.dma_size[ch] = 0
        self.dma_enabled = 0

    # =====================================================================
    # HDMA
    # =====================================================================
    #
    # A channel walks a table in the cartridge.  Each entry is a line count
    # followed, in direct mode, by the bytes to send.  Bit 7 of the count
    # selects repeat mode: send on every one of those lines rather than once
    # and hold.  A count of zero ends the channel for the frame.
    #
    # The per-line pass transfers for every channel first and only then
    # advances them, which is the order the hardware uses and which matters
    # because reloading reads more of the table.

    cdef void _hdma_reload(self, int ch) noexcept:
        """Read the next line count, and an indirect address if the channel
        uses one.  A zero count finishes the channel."""
        cdef uint32_t bank = self.dma_abus[ch] & 0xFF0000
        self.hdma_line[ch] = self.read8(bank | self.hdma_table[ch])
        self.hdma_table[ch] += 1
        if self.hdma_line[ch] == 0:
            self.hdma_active[ch] = 0
            self.hdma_do_transfer[ch] = 0
        else:
            self.hdma_active[ch] = 1
            self.hdma_do_transfer[ch] = 1
        # The indirect address is fetched even for a terminating entry: the
        # hardware has already started the read by the time it sees the zero.
        if self.dma_param[ch] & 0x40:
            self.dma_size[ch] = self._hdma_fetch16(ch)

    cdef void hdma_init(self) noexcept:
        """Start of frame: point every enabled channel at its table."""
        cdef int ch
        for ch in range(8):
            self.hdma_active[ch] = 0
            self.hdma_do_transfer[ch] = 0
        if not self.hdma_enabled:
            return
        self.tick(<int>(8 - (self.master_clock & 7)))
        self.tick(18)
        for ch in range(8):
            if not (self.hdma_enabled & (1 << ch)):
                continue
            self.tick(8)
            self.hdma_table[ch] = <uint16_t>(self.dma_abus[ch] & 0xFFFF)
            self._hdma_reload(ch)

    cdef inline uint16_t _hdma_fetch16(self, int ch) noexcept:
        cdef uint32_t bank = self.dma_abus[ch] & 0xFF0000
        cdef uint16_t lo = self.read8(bank | self.hdma_table[ch])
        self.hdma_table[ch] += 1
        cdef uint16_t hi = self.read8(bank | self.hdma_table[ch])
        self.hdma_table[ch] += 1
        return lo | (hi << 8)

    cdef void _hdma_transfer(self, int ch) noexcept:
        cdef uint8_t param = self.dma_param[ch]
        cdef int mode = param & 7
        cdef int unit = DMA_LEN[mode]
        cdef uint8_t bbus = self.dma_bbus[ch]
        cdef uint32_t src
        cdef int i

        self.tick(8)
        for i in range(unit):
            if param & 0x40:                             # indirect
                src = ((<uint32_t>self.dma_indirect_bank[ch] << 16)
                       | ((self.dma_size[ch] + i) & 0xFFFF))
            else:
                src = (self.dma_abus[ch] & 0xFF0000) | self.hdma_table[ch]
                self.hdma_table[ch] += 1
            self.tick(8)
            if param & 0x80:
                self.write8(src, self._dma_read_b(bbus + DMA_OFF[mode][i]))
            else:
                self._dma_write_b(bbus + DMA_OFF[mode][i], self.read8(src))
        if param & 0x40:
            self.dma_size[ch] = (self.dma_size[ch] + unit) & 0xFFFF

    cdef void _hdma_advance(self, int ch) noexcept:
        """Count this line off, and reload when the entry runs out."""
        self.hdma_line[ch] -= 1
        self.hdma_do_transfer[ch] = 1 if (self.hdma_line[ch] & 0x80) else 0
        if (self.hdma_line[ch] & 0x7F) == 0:
            self._hdma_reload(ch)

    cdef void hdma_run(self) noexcept:
        cdef int ch
        cdef int any = 0

        if not self.hdma_enabled:
            return
        for ch in range(8):
            if self.hdma_active[ch] and (self.hdma_enabled & (1 << ch)):
                any = 1
                break
        if not any:
            return

        self.tick(<int>(8 - (self.master_clock & 7)))
        self.tick(18)
        for ch in range(8):
            if (self.hdma_active[ch] and (self.hdma_enabled & (1 << ch))
                    and self.hdma_do_transfer[ch]):
                self._hdma_transfer(ch)
        for ch in range(8):
            if self.hdma_active[ch] and (self.hdma_enabled & (1 << ch)):
                self._hdma_advance(ch)

    # =====================================================================
    # timing
    # =====================================================================
    #
    # Time has one owner.  Each thing that must happen at a particular master
    # cycle is registered as an event with an absolute deadline, and tick()
    # advances the clock and fires whatever has come due, earliest first.
    #
    # The previous arrangement checked every condition on every bus access and
    # acted on line boundaries, which made an IRQ fire at the first access
    # after its dot rather than at the dot.  Deadlines put those events where
    # the hardware puts them.
    #
    # The hot path stays one comparison: the earliest deadline is cached, and
    # only recomputed when an event is scheduled or fires.

    cdef inline void _schedule(self, int kind, int64_t when) noexcept:
        self.ev_time[kind] = when
        if when < self.next_event:
            self.next_event = when

    cdef inline void _cancel(self, int kind) noexcept:
        self.ev_time[kind] = NEVER
        self._rescan()

    cdef void _rescan(self) noexcept:
        cdef int i
        cdef int64_t best = NEVER
        for i in range(EV_COUNT):
            if self.ev_time[i] < best:
                best = self.ev_time[i]
        self.next_event = best

    cdef void tick(self, int cycles) noexcept:
        self.master_clock += cycles
        if self.ticking:
            # DMA and HDMA charge their own cycles from inside an event; the
            # outer tick owns event processing.
            return
        if self.master_clock >= self.next_event:
            self.ticking = 1
            self._run_events()
            self.ticking = 0

    cdef void _run_events(self) noexcept:
        cdef int i, which
        cdef int64_t when
        while True:
            which = -1
            when = NEVER
            for i in range(EV_COUNT):
                if self.ev_time[i] < when:
                    when = self.ev_time[i]
                    which = i
            if which < 0 or when > self.master_clock:
                self.next_event = when
                return
            self.ev_time[which] = NEVER
            if which == EV_LINE:
                self._event_line(when)
            elif which == EV_HDMA:
                self.hdma_run()
            elif which == EV_IRQ:
                self.irq_flag = 1
                self.timer_irq = 1
                self._update_irq()
                self.irq_count += 1
            elif which == EV_JOYPAD:
                self.auto_joypad_busy = 0
            elif which == EV_REFRESH:
                self.tick(REFRESH_COST)
            else:
                self.apu.run_until(self.master_clock)
                self._schedule(EV_APU, self.master_clock + APU_SYNC_CYCLES)

    cdef void _event_line(self, int64_t when) noexcept:
        """Start of a scanline."""
        self.line_start = when
        self.vcount += 1
        self.in_hblank = 0

        if self.vcount >= self._frame_lines():
            self.vcount = 0
            self.field ^= 1
            self.frame += 1
            self.in_vblank = 0
            self.nmi_flag = 0
            self.ppu.field = self.field
            # $213E bits 6 and 7 report what happened during this frame.
            self.ppu.range_over = 0
            self.ppu.time_over = 0
            self.hdma_init()

        self.ppu.vcounter = self.vcount

        # $2133 bit 2 lengthens the display from 224 lines to 239, which moves
        # V-blank -- and so NMI -- fifteen lines later.  The bit is sampled per
        # line, so a game may turn overscan on part-way down the screen.
        self.vblank_start = 240 if self.ppu.overscan else 225
        self.ppu.vdisp = self.vblank_start

        if self.vcount == self.vblank_start:
            self.in_vblank = 1
            self.nmi_flag = 1
            if self.nmi_enabled:
                self.nmi_pending = 1
                self.nmi_count += 1
            if self.auto_joypad:
                # Games watch bit 0 of $4212 go high and then low again;
                # leaving it permanently low hangs them at boot.
                self.auto_joypad_busy = 1
                self.poll_joypads()
                self._schedule(EV_JOYPAD, when + JOYPAD_READ_CYCLES)
            self.frame_ready = 1
        elif self.vcount == 0:
            self.in_vblank = 0

        self.ppu.end_line()
        if 1 <= self.vcount < self.vblank_start:
            self.ppu.begin_line(self.vcount - 1)
        else:
            self.ppu.begin_line(-1)

        # HDMA runs late in the line, not at the boundary.
        if self.vcount < self.vblank_start and self.hdma_enabled:
            self._schedule(EV_HDMA, when + HDMA_DOT * 4)

        # A chip on the cartridge runs on its own and only meets the console
        # at an access, so it is also given the end of every line: without
        # that it would stall whenever the console left it alone.
        self.board.clock = when
        self.board.run_until(when)
        self._update_irq()

        self._arm_irq(when)
        self._schedule(EV_REFRESH, when + REFRESH_CYCLE)
        self._schedule(EV_LINE, when + self._line_length())

    cdef inline void _update_irq(self) noexcept:
        """The CPU sees one IRQ line.  The console's H/V timer drives it, and
        so can a chip on the cartridge, so the flag is the OR of the two."""
        self.irq_pending = 1 if (self.timer_irq or self.board.irq_line) else 0

    cdef inline int _line_length(self) noexcept:
        """Length of the line just started.

        Almost every line is 1364 master cycles.  Two are not, and each
        belongs to one region only: an NTSC machine drops a dot from scanline
        240 of a non-interlaced odd field, and a PAL machine adds one to
        scanline 311 of an interlaced odd field.  Both fall inside V-blank,
        so neither moves the picture; they exist to keep the line count in
        step with the colour subcarrier, which is why the two regions need
        opposite corrections.
        """
        if self.field:
            if (not self.pal) and (not self.ppu.screen_interlace) and self.vcount == 240:
                return SHORT_LINE
            if self.pal and self.ppu.screen_interlace and self.vcount == 311:
                return LONG_LINE
        return CYCLES_PER_LINE

    cdef inline int _frame_lines(self) noexcept:
        """How many scanlines this frame has.

        Interlace adds one to the field whose flag in $213F is clear, which is
        what makes the two fields differ by half a line and so comb together
        into one picture."""
        if self.ppu.screen_interlace and not self.field:
            return self.lines_per_frame + 1
        return self.lines_per_frame

    cdef void _arm_irq(self, int64_t line_start) noexcept:
        """Place this line's IRQ at the exact cycle its condition is met."""
        cdef int64_t at
        if self.irq_mode == 0:
            return
        if self.irq_mode == 2:                       # V match, at dot 0
            if self.vcount != self.vtime:
                return
            at = line_start
        elif self.irq_mode == 1:                     # H match, every line
            at = line_start + <int64_t>self.htime * 4
        else:                                        # H and V
            if self.vcount != self.vtime:
                return
            at = line_start + <int64_t>self.htime * 4
        if at <= self.master_clock:
            at = self.master_clock + 1
        self._schedule(EV_IRQ, at)

    cdef inline int _screen_x(self) noexcept:
        """Screen column the beam is at.  Output starts at dot 22."""
        cdef int x = (<int>(self.master_clock - self.line_start) >> 2) - 22
        if x < 0:
            return 0
        if x > 256:
            return 256
        return x

    cdef inline int _hcount(self) noexcept:
        return <int>(self.master_clock - self.line_start)

    cdef void poll_joypads(self) noexcept:
        cdef int i
        for i in range(4):
            self.joy[i] = self.pad_state[i]



    # -- save state (generated by tools/gen_state.py; do not edit) --------

    def state_ints(self):
        cdef int i, j
        v = [self.mdr, self.master_clock, self.hcount, self.line_start, self.next_event, self.vcount, self.field, self.frame, self.frame_ready, self.ticking, self.lines_per_frame, self.vblank_start, self.nmi_enabled, self.nmi_flag, self.nmi_pending, self.irq_mode, self.irq_flag, self.irq_pending, self.irq_line_done, self.in_vblank, self.in_hblank, self.htime, self.vtime, self.fast_rom, self.wrio, self.mul_a, self.mul_b, self.div_a, self.div_b, self.rd_div, self.rd_mpy, self.wram_addr, self.auto_joypad, self.auto_joypad_busy, self.joypad_busy_until, self.pad_latched, self.hdma_enabled, self.dma_enabled]
        for i in range(6):
            v.append(self.ev_time[i])
        for i in range(4):
            v.append(self.pad_state[i])
        for i in range(4):
            v.append(self.joy[i])
        for i in range(4):
            v.append(self.pad_shift[i])
        for i in range(8):
            v.append(self.dma_param[i])
        for i in range(8):
            v.append(self.dma_bbus[i])
        for i in range(8):
            v.append(self.dma_abus[i])
        for i in range(8):
            v.append(self.dma_size[i])
        for i in range(8):
            v.append(self.dma_indirect_bank[i])
        for i in range(8):
            v.append(self.hdma_table[i])
        for i in range(8):
            v.append(self.hdma_line[i])
        for i in range(8):
            v.append(self.dma_unused[i])
        for i in range(8):
            v.append(self.hdma_active[i])
        for i in range(8):
            v.append(self.hdma_do_transfer[i])
        return v

    def load_ints(self, v):
        cdef int i, j, k = 38
        self.mdr = v[0]
        self.master_clock = v[1]
        self.hcount = v[2]
        self.line_start = v[3]
        self.next_event = v[4]
        self.vcount = v[5]
        self.field = v[6]
        self.frame = v[7]
        self.frame_ready = v[8]
        self.ticking = v[9]
        self.lines_per_frame = v[10]
        self.vblank_start = v[11]
        self.nmi_enabled = v[12]
        self.nmi_flag = v[13]
        self.nmi_pending = v[14]
        self.irq_mode = v[15]
        self.irq_flag = v[16]
        self.irq_pending = v[17]
        self.irq_line_done = v[18]
        self.in_vblank = v[19]
        self.in_hblank = v[20]
        self.htime = v[21]
        self.vtime = v[22]
        self.fast_rom = v[23]
        self.wrio = v[24]
        self.mul_a = v[25]
        self.mul_b = v[26]
        self.div_a = v[27]
        self.div_b = v[28]
        self.rd_div = v[29]
        self.rd_mpy = v[30]
        self.wram_addr = v[31]
        self.auto_joypad = v[32]
        self.auto_joypad_busy = v[33]
        self.joypad_busy_until = v[34]
        self.pad_latched = v[35]
        self.hdma_enabled = v[36]
        self.dma_enabled = v[37]
        for i in range(6):
            self.ev_time[i] = v[k + i]
        k += 6
        for i in range(4):
            self.pad_state[i] = v[k + i]
        k += 4
        for i in range(4):
            self.joy[i] = v[k + i]
        k += 4
        for i in range(4):
            self.pad_shift[i] = v[k + i]
        k += 4
        for i in range(8):
            self.dma_param[i] = v[k + i]
        k += 8
        for i in range(8):
            self.dma_bbus[i] = v[k + i]
        k += 8
        for i in range(8):
            self.dma_abus[i] = v[k + i]
        k += 8
        for i in range(8):
            self.dma_size[i] = v[k + i]
        k += 8
        for i in range(8):
            self.dma_indirect_bank[i] = v[k + i]
        k += 8
        for i in range(8):
            self.hdma_table[i] = v[k + i]
        k += 8
        for i in range(8):
            self.hdma_line[i] = v[k + i]
        k += 8
        for i in range(8):
            self.dma_unused[i] = v[k + i]
        k += 8
        for i in range(8):
            self.hdma_active[i] = v[k + i]
        k += 8
        for i in range(8):
            self.hdma_do_transfer[i] = v[k + i]
        k += 8

    def state_blobs(self):
        return [PyBytes_FromStringAndSize(<char *>self.wram, 131072)]

    def load_blobs(self, blobs):
        if len(blobs[0]) != 131072:
            raise ValueError('bad wram blob')
        memcpy(<char *>self.wram, <char *><bytes>blobs[0], 131072)

    # -- end generated save state ------------------------------------------


    # =====================================================================
    # python interface
    # =====================================================================

    def irq_state(self):
        return dict(nmi_enabled=self.nmi_enabled, nmi_flag=self.nmi_flag,
                    nmi_pending=self.nmi_pending, nmi_count=self.nmi_count,
                    irq_mode=self.irq_mode, irq_flag=self.irq_flag,
                    irq_pending=self.irq_pending, irq_count=self.irq_count,
                    htime=self.htime, vtime=self.vtime,
                    auto_joypad=self.auto_joypad, fast_rom=self.fast_rom)

    def page_kind_at(self, addr):
        """Which kind of memory backs this address: for spotting execution
        that has run off into open bus."""
        names = ("openbus", "rom", "wram", "sram", "mmio_lo", "mmio_hi")
        return names[self.page_kind[(addr >> 13) & 0x7FF]]

    def dma_state(self):
        return dict(hdma_enabled=self.hdma_enabled,
                    hdma_active=[self.hdma_active[i] for i in range(8)],
                    param=[self.dma_param[i] for i in range(8)],
                    bbus=[hex(self.dma_bbus[i]) for i in range(8)],
                    abus=[hex(self.dma_abus[i]) for i in range(8)],
                    line=[self.hdma_line[i] for i in range(8)])

    def irq_state(self):
        """What $4200 has been told and what has fired since.

        A boot that has stopped moving has usually stopped waiting on one of
        these, so a diagnostic wants them together rather than one at a time."""
        return dict(nmi_enabled=bool(self.nmi_enabled), nmi_flag=bool(self.nmi_flag),
                    nmi_pending=bool(self.nmi_pending), nmi_count=self.nmi_count,
                    irq_mode=self.irq_mode, irq_flag=bool(self.irq_flag),
                    irq_pending=bool(self.irq_pending), irq_count=self.irq_count,
                    htime=self.htime, vtime=self.vtime,
                    auto_joypad=bool(self.auto_joypad))

    def set_pad(self, int index, int value):
        self.pad_state[index & 3] = <uint16_t>value

    @property
    def vcounter(self):
        return self.vcount

    @property
    def hcounter(self):
        return self._hcount()

    def take_frame_ready(self):
        r = self.frame_ready
        self.frame_ready = 0
        return bool(r)

    def read(self, addr):
        return self.read8_fast(addr)

    def peek_range(self, addr, n):
        return bytes(bytearray([self.read8_fast((addr + i) & 0xFFFFFF) for i in range(n)]))
