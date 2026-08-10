# cython: language_level=3
"""S-CPU bus: address decoding, MMIO, DMA/HDMA, timing and interrupts.

Every S-CPU memory access funnels through here, so this is also where the
master clock advances and where scanline events (VBlank, IRQ, HDMA, auto
joypad read) are raised.
"""

from libc.string cimport memset, memcpy
from cpython.bytes cimport PyBytes_FromStringAndSize
from libc.stdint cimport uint8_t, uint16_t, uint32_t, int32_t, int64_t

from snes.cart cimport Cart, MAP_LOROM, MAP_HIROM, MAP_EXHIROM
from snes.ppu cimport PPU
from snes.apu cimport APU


cdef enum:
    CYCLES_PER_LINE = 1364
    LINES_NTSC = 262
    LINES_PAL = 312


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


cdef class Bus:

    def __init__(self, Cart cart, PPU ppu, APU apu):
        self.cart = cart
        self.ppu = ppu
        self.apu = apu
        self.build_map()
        self.reset()

    # =====================================================================
    # address map
    # =====================================================================

    def build_map(self):
        """Fill the 8 KB page table for the cartridge's map mode."""
        cdef uint32_t page, bank, addr
        cdef Cart c = self.cart

        for page in range(2048):
            bank = page >> 3
            addr = (page & 7) << 13
            self.page_kind[page] = PK_OPENBUS
            self.page_base[page] = 0

            if bank == 0x7E or bank == 0x7F:
                self.page_kind[page] = PK_WRAM
                self.page_base[page] = ((bank - 0x7E) << 16) | addr
                continue

            if (bank & 0x7F) < 0x40:                    # $00-$3F / $80-$BF
                if addr < 0x2000:
                    self.page_kind[page] = PK_WRAM
                    self.page_base[page] = 0
                    continue
                if addr < 0x4000:
                    self.page_kind[page] = PK_MMIO_LO
                    continue
                if addr < 0x6000:
                    self.page_kind[page] = PK_MMIO_HI
                    continue
                if addr < 0x8000:
                    self._map_low_sram(page, bank)
                    continue

            self._map_rom(page, bank, addr)

    cdef void _map_low_sram(self, uint32_t page, uint32_t bank) noexcept:
        """$6000-$7FFF: HiROM puts battery SRAM here."""
        cdef Cart c = self.cart
        cdef uint32_t slot
        if c.sram_size == 0:
            return
        if c.map_mode == MAP_HIROM or c.map_mode == MAP_EXHIROM:
            if 0x20 <= (bank & 0x7F) <= 0x3F:
                slot = (bank & 0x1F) * 0x2000
                self.page_kind[page] = PK_SRAM
                self.page_base[page] = slot & c.sram_mask

    cdef void _map_rom(self, uint32_t page, uint32_t bank, uint32_t addr) noexcept:
        cdef Cart c = self.cart
        cdef uint32_t linear

        if c.map_mode == MAP_LOROM:
            # LoROM: $70-$7D and $F0-$FF low halves hold SRAM.
            if c.sram_size and 0x70 <= (bank & 0x7F) <= 0x7D and addr < 0x8000:
                self.page_kind[page] = PK_SRAM
                self.page_base[page] = (((bank & 0x0F) << 15) | addr) & c.sram_mask
                return
            linear = ((bank & 0x7F) << 15) | (addr & 0x7FFF)
        elif c.map_mode == MAP_EXHIROM:
            # The second 4 MB half lives in banks $00-$3F / $40-$7D.
            linear = ((bank & 0x3F) << 16) | addr
            if (bank & 0x80) == 0:
                linear += 0x400000
        else:                                            # HiROM
            linear = ((bank & 0x3F) << 16) | addr

        self.page_kind[page] = PK_ROM
        self.page_base[page] = c.rom_offset(linear)

    # =====================================================================
    # reset
    # =====================================================================

    def reset(self):
        cdef int i
        memset(self.wram, 0x55, sizeof(self.wram))
        self.mdr = 0
        self.master_clock = 0
        self.hcount = 0
        self.vcount = 0
        self.field = 0
        self.frame = 0
        self.frame_ready = 0
        self.ticking = 0
        self.lines_per_frame = LINES_NTSC
        self.vblank_start = 225

        self.nmi_enabled = 0
        self.nmi_flag = 0
        self.nmi_pending = 0
        self.irq_mode = 0
        self.irq_flag = 0
        self.irq_pending = 0
        self.irq_line_done = 0
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
            self.irq_pending = 0
            return v
        if a == 0x4212:                                   # HVBJOY
            v = self.mdr & 0x3E
            if self.in_vblank:
                v |= 0x80
            if self.in_hblank:
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

        return self.mdr

    cdef void write_mmio(self, uint32_t addr, uint8_t value) noexcept:
        cdef uint32_t a = addr & 0xFFFF
        cdef int ch, reg
        cdef uint32_t quotient, remainder

        if 0x2100 <= a <= 0x213F:
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
                self.irq_pending = 0
            # Enabling NMI while the flag is already set fires immediately.
            if (value & 0x80) and not self.nmi_enabled and self.nmi_flag:
                self.nmi_pending = 1
            self.nmi_enabled = (value >> 7) & 1
            return
        if a == 0x4201:
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
            return
        if a == 0x4208:
            self.htime = (self.htime & 0x0FF) | ((<uint16_t>value & 1) << 8)
            return
        if a == 0x4209:
            self.vtime = (self.vtime & 0x100) | value
            return
        if a == 0x420A:
            self.vtime = (self.vtime & 0x0FF) | ((<uint16_t>value & 1) << 8)
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

            self.dma_abus[ch] = a_addr
            self.dma_size[ch] = 0
        self.dma_enabled = 0

    # =====================================================================
    # HDMA
    # =====================================================================

    cdef void hdma_init(self) noexcept:
        cdef int ch
        for ch in range(8):
            self.hdma_active[ch] = 0
            self.hdma_do_transfer[ch] = 0
            if not (self.hdma_enabled & (1 << ch)):
                continue
            self.hdma_table[ch] = <uint16_t>(self.dma_abus[ch] & 0xFFFF)
            self.hdma_line[ch] = self.read8((self.dma_abus[ch] & 0xFF0000)
                                            | self.hdma_table[ch])
            self.hdma_table[ch] += 1
            if self.hdma_line[ch] == 0:
                continue
            self.hdma_active[ch] = 1
            self.hdma_do_transfer[ch] = 1
            if self.dma_param[ch] & 0x40:                # indirect
                self.dma_size[ch] = self._hdma_fetch16(ch)
        if self.hdma_enabled:
            self.tick(18)

    cdef inline uint16_t _hdma_fetch16(self, int ch) noexcept:
        cdef uint32_t bank = self.dma_abus[ch] & 0xFF0000
        cdef uint16_t lo = self.read8(bank | self.hdma_table[ch])
        self.hdma_table[ch] += 1
        cdef uint16_t hi = self.read8(bank | self.hdma_table[ch])
        self.hdma_table[ch] += 1
        return lo | (hi << 8)

    cdef void hdma_run(self) noexcept:
        cdef int ch, i, mode, unit
        cdef uint32_t src
        cdef uint8_t bbus, param, line

        if not self.hdma_enabled:
            return
        self.tick(18)
        for ch in range(8):
            if not self.hdma_active[ch] or not (self.hdma_enabled & (1 << ch)):
                continue
            param = self.dma_param[ch]
            mode = param & 7
            unit = DMA_LEN[mode]
            bbus = self.dma_bbus[ch]

            if self.hdma_do_transfer[ch]:
                self.tick(8)
                for i in range(unit):
                    if param & 0x40:                     # indirect
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

            self.hdma_line[ch] -= 1
            self.hdma_do_transfer[ch] = 1 if (self.hdma_line[ch] & 0x80) else 0

            if (self.hdma_line[ch] & 0x7F) == 0:
                line = self.read8((self.dma_abus[ch] & 0xFF0000) | self.hdma_table[ch])
                self.hdma_table[ch] += 1
                self.hdma_line[ch] = line
                if param & 0x40:
                    self.dma_size[ch] = self._hdma_fetch16(ch)
                self.hdma_do_transfer[ch] = 1
                if line == 0:
                    self.hdma_active[ch] = 0

    # =====================================================================
    # timing
    # =====================================================================

    cdef void tick(self, int cycles) noexcept:
        self.master_clock += cycles
        self.hcount += cycles
        if self.ticking:
            return
        self.ticking = 1

        # H-blank starts around dot 274 (cycle 1096).
        self.in_hblank = 1 if self.hcount >= 1096 else 0

        if self.irq_mode and not self.irq_line_done:
            self._check_irq()

        while self.hcount >= CYCLES_PER_LINE:
            self.hcount -= CYCLES_PER_LINE
            self._next_line()
        self.ticking = 0

    cdef void _check_irq(self) noexcept:
        cdef int trigger = 0
        cdef int dot = self.hcount >> 2
        if self.irq_mode == 1:                            # H only
            trigger = 1 if dot >= self.htime else 0
        elif self.irq_mode == 2:                          # V only
            trigger = 1 if (self.vcount == self.vtime and self.hcount >= 0) else 0
        elif self.irq_mode == 3:                          # H and V
            trigger = 1 if (self.vcount == self.vtime and dot >= self.htime) else 0
        if trigger:
            self.irq_flag = 1
            self.irq_pending = 1
            self.irq_line_done = 1

    cdef void _next_line(self) noexcept:
        self.vcount += 1
        self.irq_line_done = 0
        self.in_hblank = 0

        # The APU must be driven from the timeline, not only when the S-CPU
        # touches $2140-$2143: once a game has handed the sound driver its
        # commands it may never poll the ports again.
        self.apu.run_until(self.master_clock)

        if self.vcount >= self.lines_per_frame:
            self.vcount = 0
            self.field ^= 1
            self.frame += 1
            self.in_vblank = 0
            self.ppu.field = self.field
            self.hdma_init()

        self.ppu.vcounter = self.vcount

        if self.vcount == self.vblank_start:
            self.in_vblank = 1
            self.nmi_flag = 1
            if self.nmi_enabled:
                self.nmi_pending = 1
            if self.auto_joypad:
                self.poll_joypads()
            self.frame_ready = 1
        elif self.vcount == 0:
            self.in_vblank = 0

        if 1 <= self.vcount <= self.vblank_start:
            self.ppu.render_scanline(self.vcount - 1)
        if self.vcount < self.vblank_start:
            self.hdma_run()

    cdef void poll_joypads(self) noexcept:
        cdef int i
        for i in range(4):
            self.joy[i] = self.pad_state[i]


    # -- save state (generated by tools/gen_state.py; do not edit) --------

    def state_ints(self):
        cdef int i, j
        v = [self.mdr, self.master_clock, self.hcount, self.vcount, self.field, self.frame, self.frame_ready, self.ticking, self.lines_per_frame, self.vblank_start, self.nmi_enabled, self.nmi_flag, self.nmi_pending, self.irq_mode, self.irq_flag, self.irq_pending, self.irq_line_done, self.in_vblank, self.in_hblank, self.htime, self.vtime, self.fast_rom, self.wrio, self.mul_a, self.mul_b, self.div_a, self.div_b, self.rd_div, self.rd_mpy, self.wram_addr, self.auto_joypad, self.auto_joypad_busy, self.pad_latched, self.hdma_enabled, self.dma_enabled]
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
        cdef int i, j, k = 35
        self.mdr = v[0]
        self.master_clock = v[1]
        self.hcount = v[2]
        self.vcount = v[3]
        self.field = v[4]
        self.frame = v[5]
        self.frame_ready = v[6]
        self.ticking = v[7]
        self.lines_per_frame = v[8]
        self.vblank_start = v[9]
        self.nmi_enabled = v[10]
        self.nmi_flag = v[11]
        self.nmi_pending = v[12]
        self.irq_mode = v[13]
        self.irq_flag = v[14]
        self.irq_pending = v[15]
        self.irq_line_done = v[16]
        self.in_vblank = v[17]
        self.in_hblank = v[18]
        self.htime = v[19]
        self.vtime = v[20]
        self.fast_rom = v[21]
        self.wrio = v[22]
        self.mul_a = v[23]
        self.mul_b = v[24]
        self.div_a = v[25]
        self.div_b = v[26]
        self.rd_div = v[27]
        self.rd_mpy = v[28]
        self.wram_addr = v[29]
        self.auto_joypad = v[30]
        self.auto_joypad_busy = v[31]
        self.pad_latched = v[32]
        self.hdma_enabled = v[33]
        self.dma_enabled = v[34]
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

    def dma_state(self):
        return dict(hdma_enabled=self.hdma_enabled,
                    hdma_active=[self.hdma_active[i] for i in range(8)],
                    param=[self.dma_param[i] for i in range(8)],
                    bbus=[hex(self.dma_bbus[i]) for i in range(8)],
                    abus=[hex(self.dma_abus[i]) for i in range(8)],
                    line=[self.hdma_line[i] for i in range(8)])

    def set_pad(self, int index, int value):
        self.pad_state[index & 3] = <uint16_t>value

    @property
    def vcounter(self):
        return self.vcount

    @property
    def hcounter(self):
        return self.hcount

    def take_frame_ready(self):
        r = self.frame_ready
        self.frame_ready = 0
        return bool(r)

    def read(self, addr):
        return self.read8_fast(addr)

    def peek_range(self, addr, n):
        return bytes(bytearray([self.read8_fast((addr + i) & 0xFFFFFF) for i in range(n)]))
