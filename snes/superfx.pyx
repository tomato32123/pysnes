# cython: language_level=3
# cython: boundscheck=False, wraparound=False, cdivision=True
"""The SuperFX: a drawing processor on the cartridge.

The SA-1 is a second copy of the console's own CPU.  This is not: it is a
different processor with its own instruction set, built to rasterise polygons
into a bitmap the PPU can then show as ordinary tiles.  Star Fox hands it a
scene and waits, spinning on bit 5 of $3030 until the chip says it is done.

Three parts, and they are separable.

The *mapper* is the smallest: the console sees ROM and RAM through the
cartridge, and the sixteen registers plus the instruction cache at
$3000-$32FF.  While the chip is running it takes the ROM and RAM for itself,
and the console reading ROM gets a fixed vector table instead -- which is how
a game keeps its interrupt handlers reachable while the chip owns the bus.

The *processor* is sixteen 16-bit registers where r15 is the program counter,
so a write to r15 is a jump and any instruction can make one.  There are only
about eighty opcodes, but three prefix instructions -- ALT1, ALT2, ALT3 --
change what the next one means, and two more, FROM and TO, change which
register it reads and writes.  That is where the count of five hundred comes
from, and why the prefix state has to be cleared after almost every
instruction rather than at the end of a group.

The *plot unit* is the point of the whole chip: PLOT takes a colour and a
coordinate and writes it into a cache of eight pixels, which is flushed into
the character format the PPU wants -- a bitplane at a time, read-modify-write,
because eight pixels of one row are spread across two bytes per plane.

The instruction semantics, the plot unit's addressing and the cache's rules
are transcribed from bsnes's GSU.  The sequencing here is written against it.
"""
from libc.stdint cimport uint8_t, uint16_t, uint32_t, int8_t, int16_t, int32_t, int64_t
from libc.string cimport memset

from snes.board cimport Board, PK_DEVICE
from snes.cart cimport Cart


# SFR bits.
DEF SFR_Z    = 0x0002
DEF SFR_CY   = 0x0004
DEF SFR_S    = 0x0008
DEF SFR_OV   = 0x0010
DEF SFR_G    = 0x0020
DEF SFR_R    = 0x0040
DEF SFR_ALT1 = 0x0100
DEF SFR_ALT2 = 0x0200
DEF SFR_IL   = 0x0400
DEF SFR_IH   = 0x0800
DEF SFR_B    = 0x1000
DEF SFR_IRQ  = 0x8000

# The console reads this instead of ROM while the chip has it.  It is the
# reset and interrupt vector table, so a game's handlers stay reachable.
cdef uint8_t CPU_VECTOR[16]
CPU_VECTOR[:] = [0x00, 0x01, 0x00, 0x01, 0x04, 0x01, 0x00, 0x01,
                 0x00, 0x01, 0x08, 0x01, 0x00, 0x01, 0x0C, 0x01]


cdef class SuperFX(Board):

    def __cinit__(self, Cart cart):
        self.name = u"SuperFX"
        self.rom = cart.rom
        self.rom_mask = _mask_for(cart.rom_size)
        # SuperFX cartridges carry their work RAM in the expansion-size byte
        # rather than the ordinary one, and it is not battery backed.
        self.ram_data = bytearray(_superfx_ram_size(cart))
        self.ram = <uint8_t *>self.ram_data
        self.ram_mask = len(self.ram_data) - 1
        self.reset_board()

    cdef void reset_board(self) noexcept:
        cdef int i, j
        for i in range(16):
            self.r[i] = 0
        self.r14_modified = 0
        self.r15_modified = 0
        self.sfr = 0
        self.pbr = 0
        self.rombr = 0
        self.rambr = 0
        self.cbr = 0
        self.scbr = 0
        self.colr = 0
        self.bramr = 0
        self.vcr = 0x04                  # GSU-2; what Star Fox's successors ask for
        self.clsr = 0
        self.pipeline = 0x01             # nop
        self.ramaddr = 0
        self.scmr_ht = 0
        self.scmr_ron = 0
        self.scmr_ran = 0
        self.scmr_md = 0
        self.por_obj = 0
        self.por_freezehigh = 0
        self.por_highnibble = 0
        self.por_dither = 0
        self.por_transparent = 0
        self.cfgr_irq = 0
        self.cfgr_ms0 = 0
        self.sreg = 0
        self.dreg = 0
        self.romcl = 0
        self.romdr = 0
        self.ramcl = 0
        self.ramar = 0
        self.ramdr = 0
        memset(self.cache_buffer, 0, sizeof(self.cache_buffer))
        for i in range(32):
            self.cache_valid[i] = 0
        for i in range(2):
            self.pc_offset[i] = 0xFFFFFFFF
            self.pc_bitpend[i] = 0
            for j in range(8):
                self.pc_data[i][j] = 0
        self.gsu_clock = 0
        self.target = 0
        self.irq_line = 0

    # =====================================================================
    # what the console sees
    # =====================================================================

    cdef int classify(self, uint32_t bank, uint32_t addr, uint32_t *base) noexcept:
        """Every page is asked per access.

        The chip takes the ROM and the RAM away from the console while it is
        running, and gives them back when it stops, which a page table cannot
        follow.  It is also where the console's access catches the chip up.
        """
        base[0] = 0
        return PK_DEVICE

    cdef uint8_t read(self, uint32_t addr, uint8_t data) noexcept:
        cdef uint32_t bank = (addr >> 16) & 0xFF
        cdef uint32_t off = addr & 0xFFFF
        cdef uint32_t linear
        self.run_until(self.clock)

        if (bank & 0x7F) < 0x40:
            if 0x3000 <= off <= 0x32FF:
                return self.read_reg(off)
            if 0x6000 <= off < 0x8000:
                # The RAM window the console shares with the chip.
                if (self.sfr & SFR_G) and self.scmr_ran:
                    return data
                return self.ram[((bank & 0x3F) * 0x2000 + (off - 0x6000)) & self.ram_mask]
            if off >= 0x8000:
                if (self.sfr & SFR_G) and self.scmr_ron:
                    return CPU_VECTOR[addr & 15]
                linear = ((bank & 0x3F) << 15) | (off & 0x7FFF)
                return self.rom[linear & self.rom_mask]
            return data

        if 0x40 <= (bank & 0x7F) <= 0x5F:
            if (self.sfr & SFR_G) and self.scmr_ron:
                return CPU_VECTOR[addr & 15]
            return self.rom[(((bank & 0x7F) - 0x40) * 0x10000 + off) & self.rom_mask]

        if 0x60 <= (bank & 0x7F) <= 0x7D:
            if (self.sfr & SFR_G) and self.scmr_ran:
                return data
            return self.ram[(((bank & 0x7F) - 0x60) * 0x10000 + off) & self.ram_mask]

        return data

    cdef uint8_t peek(self, uint32_t addr, uint8_t data) noexcept:
        """Memory only, and without catching the chip up: the debugger asks
        what is at an address, which must not move the machine on."""
        cdef uint32_t bank = (addr >> 16) & 0xFF
        cdef uint32_t off = addr & 0xFFFF
        if (bank & 0x7F) < 0x40:
            if 0x6000 <= off < 0x8000:
                return self.ram[((bank & 0x3F) * 0x2000 + (off - 0x6000))
                                & self.ram_mask]
            if off >= 0x8000:
                return self.rom[(((bank & 0x3F) << 15) | (off & 0x7FFF))
                                & self.rom_mask]
            return data
        if 0x40 <= (bank & 0x7F) <= 0x5F:
            return self.rom[(((bank & 0x7F) - 0x40) * 0x10000 + off)
                            & self.rom_mask]
        if 0x60 <= (bank & 0x7F) <= 0x7D:
            return self.ram[(((bank & 0x7F) - 0x60) * 0x10000 + off)
                            & self.ram_mask]
        return data

    cdef void write(self, uint32_t addr, uint8_t value) noexcept:
        cdef uint32_t bank = (addr >> 16) & 0xFF
        cdef uint32_t off = addr & 0xFFFF
        self.run_until(self.clock)

        if (bank & 0x7F) < 0x40:
            if 0x3000 <= off <= 0x32FF:
                self.write_reg(off, value)
                return
            if 0x6000 <= off < 0x8000:
                if (self.sfr & SFR_G) and self.scmr_ran:
                    return
                self.ram[((bank & 0x3F) * 0x2000 + (off - 0x6000)) & self.ram_mask] = value
                return
            return

        if 0x60 <= (bank & 0x7F) <= 0x7D:
            if (self.sfr & SFR_G) and self.scmr_ran:
                return
            self.ram[(((bank & 0x7F) - 0x60) * 0x10000 + off) & self.ram_mask] = value

    # -- the registers at $3000-$32FF --------------------------------------

    cdef uint8_t read_reg(self, uint32_t off) noexcept:
        cdef uint8_t r
        cdef int n
        if 0x3100 <= off <= 0x32FF:
            return self.cache_buffer[(off - 0x3100 + self.cbr) & 511]
        if off <= 0x301F:
            n = (off >> 1) & 15
            return <uint8_t>(self.r[n] >> ((off & 1) << 3))
        if off == 0x3030:
            return <uint8_t>(self.sfr & 0xFF)
        if off == 0x3031:
            r = <uint8_t>(self.sfr >> 8)
            self.sfr &= ~SFR_IRQ
            self.irq_line = 0
            return r
        if off == 0x3034:
            return self.pbr
        if off == 0x3036:
            return self.rombr
        if off == 0x303B:
            return self.vcr
        if off == 0x303C:
            return <uint8_t>self.rambr
        if off == 0x303E:
            return <uint8_t>(self.cbr & 0xFF)
        if off == 0x303F:
            return <uint8_t>(self.cbr >> 8)
        return 0x00

    cdef void write_reg(self, uint32_t off, uint8_t value) noexcept:
        cdef int n, was_going
        cdef uint32_t a
        if 0x3100 <= off <= 0x32FF:
            a = (off - 0x3100 + self.cbr) & 511
            self.cache_buffer[a] = value
            if (a & 15) == 15:
                self.cache_valid[a >> 4] = 1
            return
        if off <= 0x301F:
            n = (off >> 1) & 15
            if (off & 1) == 0:
                self.r[n] = (self.r[n] & 0xFF00) | value
            else:
                self.r[n] = (<uint16_t>value << 8) | (self.r[n] & 0x00FF)
            if n == 14:
                self.update_rom_buffer()
            # Writing the high half of r15 is what starts the chip: the
            # console has just given it a program counter.
            if off == 0x301F:
                self.sfr |= SFR_G
            return
        if off == 0x3030:
            was_going = 1 if (self.sfr & SFR_G) else 0
            self.sfr = (self.sfr & 0xFF00) | value
            if was_going and not (self.sfr & SFR_G):
                self.cbr = 0
                self.flush_cache()
            return
        if off == 0x3031:
            self.sfr = (<uint16_t>value << 8) | (self.sfr & 0x00FF)
            return
        if off == 0x3033:
            self.bramr = value & 1
            return
        if off == 0x3034:
            self.pbr = value & 0x7F
            self.flush_cache()
            return
        if off == 0x3037:
            self.cfgr_irq = 1 if (value & 0x80) else 0
            self.cfgr_ms0 = 1 if (value & 0x20) else 0
            return
        if off == 0x3038:
            self.scbr = value
            return
        if off == 0x3039:
            self.clsr = value & 1
            return
        if off == 0x303A:
            self.scmr_ht = (((value >> 5) & 1) << 1) | ((value >> 2) & 1)
            self.scmr_ron = 1 if (value & 0x10) else 0
            self.scmr_ran = 1 if (value & 0x08) else 0
            self.scmr_md = value & 3
            return

    # =====================================================================
    # what the chip sees
    # =====================================================================

    cdef uint8_t gsu_read(self, uint32_t addr) noexcept:
        cdef uint32_t bank = (addr >> 16) & 0xFF
        if bank < 0x40:
            # The chip sees the LoROM halves folded into one run of bytes.
            return self.rom[((((addr & 0x3F0000) >> 1) | (addr & 0x7FFF))) & self.rom_mask]
        if bank < 0x60:
            return self.rom[addr & self.rom_mask]
        if bank < 0x80:
            return self.ram[addr & self.ram_mask]
        return 0

    cdef void gsu_write(self, uint32_t addr, uint8_t value) noexcept:
        if 0x60 <= ((addr >> 16) & 0xFF) < 0x80:
            self.ram[addr & self.ram_mask] = value

    # =====================================================================
    # clocking
    # =====================================================================

    cdef void run_until(self, int64_t master_clock) noexcept:
        """Catch the chip up with the console.

        The GSU runs at half the master clock, or all of it when $3039 asks
        for the faster part.  As with the SA-1, it catches up rather than the
        two sharing a scheduler, so a contended cycle is not modelled."""
        if master_clock <= self.target:
            return
        self.target = master_clock
        while self.gsu_clock < self.target:
            if not (self.sfr & SFR_G):
                # Idle: charge the time and stop, or the loop never ends.
                self.gsu_clock = self.target
                return
            self.main()

    cdef void step(self, int clocks) noexcept:
        cdef int master = clocks if self.clsr else clocks * 2
        if self.romcl:
            self.romcl -= clocks if clocks < self.romcl else self.romcl
            if self.romcl == 0:
                self.sfr &= ~SFR_R
                self.romdr = self.gsu_read((<uint32_t>self.rombr << 16) + self.r[14])
        if self.ramcl:
            self.ramcl -= clocks if clocks < self.ramcl else self.ramcl
            if self.ramcl == 0:
                self.gsu_write(0x700000 + (<uint32_t>self.rambr << 16) + self.ramar,
                               self.ramdr)
        self.gsu_clock += master

    cdef void main(self) noexcept:
        self.execute(self.peekpipe())
        if self.r14_modified:
            self.r14_modified = 0
            self.update_rom_buffer()
        if self.r15_modified:
            self.r15_modified = 0
        else:
            self.r[15] += 1

    # -- the buffered readers ----------------------------------------------

    cdef void sync_rom_buffer(self) noexcept:
        if self.romcl:
            self.step(self.romcl)

    cdef uint8_t read_rom_buffer(self) noexcept:
        self.sync_rom_buffer()
        return self.romdr

    cdef void update_rom_buffer(self) noexcept:
        self.sfr |= SFR_R
        self.romcl = 5 if self.clsr else 6

    cdef void sync_ram_buffer(self) noexcept:
        if self.ramcl:
            self.step(self.ramcl)

    cdef uint8_t read_ram_buffer(self, uint16_t addr) noexcept:
        self.sync_ram_buffer()
        return self.gsu_read(0x700000 + (<uint32_t>self.rambr << 16) + addr)

    cdef void write_ram_buffer(self, uint16_t addr, uint8_t value) noexcept:
        self.sync_ram_buffer()
        self.ramcl = 5 if self.clsr else 6
        self.ramar = addr
        self.ramdr = value

    # -- the instruction cache ---------------------------------------------

    cdef void flush_cache(self) noexcept:
        cdef int i
        for i in range(32):
            self.cache_valid[i] = 0

    cdef uint8_t read_opcode(self, uint16_t addr) noexcept:
        """Instructions come out of a 512-byte cache the chip fills a line of
        sixteen at a time.  A tight loop that fits in it runs without touching
        the cartridge at all, which is most of why the chip is worth having."""
        cdef uint16_t offset = <uint16_t>(addr - self.cbr)
        cdef uint32_t dp, sp
        cdef int n
        if offset < 512:
            if not self.cache_valid[offset >> 4]:
                dp = offset & 0xFFF0
                sp = (<uint32_t>self.pbr << 16) + ((self.cbr + dp) & 0xFFF0)
                for n in range(16):
                    self.step(5 if self.clsr else 6)
                    self.cache_buffer[dp] = self.gsu_read(sp)
                    dp += 1
                    sp += 1
                self.cache_valid[offset >> 4] = 1
            else:
                self.step(1 if self.clsr else 2)
            return self.cache_buffer[offset]

        if self.pbr <= 0x5F:
            self.sync_rom_buffer()
        else:
            self.sync_ram_buffer()
        self.step(5 if self.clsr else 6)
        return self.gsu_read((<uint32_t>self.pbr << 16) | addr)

    cdef uint8_t peekpipe(self) noexcept:
        cdef uint8_t result = self.pipeline
        self.pipeline = self.read_opcode(self.r[15])
        self.r15_modified = 0
        return result

    cdef uint8_t pipe(self) noexcept:
        cdef uint8_t result = self.pipeline
        self.r[15] += 1
        self.pipeline = self.read_opcode(self.r[15])
        self.r15_modified = 0
        return result

    # =====================================================================
    # the plot unit
    # =====================================================================

    cdef uint8_t plot_colour(self, uint8_t source) noexcept:
        if self.por_highnibble:
            return (self.colr & 0xF0) | (source >> 4)
        if self.por_freezehigh:
            return (self.colr & 0xF0) | (source & 0x0F)
        return source

    cdef uint32_t char_address(self, uint8_t x, uint8_t y, int *bpp) noexcept:
        """Where the eight-pixel row containing (x, y) lives in RAM.

        The bitmap is stored as PPU characters, so this is the tile number for
        the pixel, times the tile's size, plus the row within it."""
        cdef uint32_t cn
        cdef int mode = 3 if self.por_obj else self.scmr_ht
        if mode == 0:
            cn = ((x & 0xF8) << 1) + ((y & 0xF8) >> 3)
        elif mode == 1:
            cn = ((x & 0xF8) << 1) + ((x & 0xF8) >> 1) + ((y & 0xF8) >> 3)
        elif mode == 2:
            cn = ((x & 0xF8) << 1) + (x & 0xF8) + ((y & 0xF8) >> 3)
        else:
            cn = ((<uint32_t>(y & 0x80)) << 2) + ((<uint32_t>(x & 0x80)) << 1) \
                 + ((<uint32_t>(y & 0x78)) << 1) + ((x & 0x78) >> 3)
        bpp[0] = 2 << (self.scmr_md - (self.scmr_md >> 1))
        return (0x700000 + (cn * (<uint32_t>bpp[0] << 3))
                + (<uint32_t>self.scbr << 10) + ((y & 7) * 2))

    cdef void plot(self, uint8_t x, uint8_t y) noexcept:
        cdef uint8_t colour
        cdef uint32_t offset
        cdef int i

        if not self.por_transparent:
            if self.scmr_md == 3:
                if self.por_freezehigh:
                    if (self.colr & 0x0F) == 0:
                        return
                else:
                    if self.colr == 0:
                        return
            else:
                if (self.colr & 0x0F) == 0:
                    return

        colour = self.colr
        if self.por_dither and self.scmr_md != 3:
            if (x ^ y) & 1:
                colour >>= 4
            colour &= 0x0F

        offset = (<uint32_t>y << 5) + (x >> 3)
        if offset != self.pc_offset[0]:
            self.flush_pixel_cache(1)
            self.pc_offset[1] = self.pc_offset[0]
            self.pc_bitpend[1] = self.pc_bitpend[0]
            for i in range(8):
                self.pc_data[1][i] = self.pc_data[0][i]
            self.pc_bitpend[0] = 0
            self.pc_offset[0] = offset

        x = (x & 7) ^ 7
        self.pc_data[0][x] = colour
        self.pc_bitpend[0] |= <uint8_t>(1 << x)
        if self.pc_bitpend[0] == 0xFF:
            self.flush_pixel_cache(1)
            self.pc_offset[1] = self.pc_offset[0]
            self.pc_bitpend[1] = self.pc_bitpend[0]
            for i in range(8):
                self.pc_data[1][i] = self.pc_data[0][i]
            self.pc_bitpend[0] = 0

    cdef void flush_pixel_cache(self, int which) noexcept:
        cdef uint8_t x, y, data
        cdef uint32_t addr, byte
        cdef int bpp, n, i
        if self.pc_bitpend[which] == 0:
            return
        x = <uint8_t>(self.pc_offset[which] << 3)
        y = <uint8_t>(self.pc_offset[which] >> 5)
        addr = self.char_address(x, y, &bpp)
        for n in range(bpp):
            byte = ((<uint32_t>n >> 1) << 4) + (n & 1)
            data = 0
            for i in range(8):
                data |= <uint8_t>(((self.pc_data[which][i] >> n) & 1) << i)
            if self.pc_bitpend[which] != 0xFF:
                self.step(5 if self.clsr else 6)
                data &= self.pc_bitpend[which]
                data |= self.gsu_read(addr + byte) & ~self.pc_bitpend[which]
            self.step(5 if self.clsr else 6)
            self.gsu_write(addr + byte, data)
        self.pc_bitpend[which] = 0

    cdef uint8_t rpix(self, uint8_t x, uint8_t y) noexcept:
        cdef uint32_t addr, byte
        cdef int bpp, n
        cdef uint8_t data = 0
        self.flush_pixel_cache(1)
        self.flush_pixel_cache(0)
        addr = self.char_address(x, y, &bpp)
        x = (x & 7) ^ 7
        for n in range(bpp):
            byte = ((<uint32_t>n >> 1) << 4) + (n & 1)
            self.step(5 if self.clsr else 6)
            data |= <uint8_t>(((self.gsu_read(addr + byte) >> x) & 1) << n)
        return data

    # =====================================================================
    # instructions
    # =====================================================================

    cdef void reset_prefix(self) noexcept:
        """Almost every instruction ends by forgetting the prefixes.

        ALT1, ALT2, ALT3, FROM and TO change what the *next* instruction
        means and nothing after it, so the clearing belongs at the end of
        every instruction that is not itself a prefix."""
        self.sfr &= ~(SFR_B | SFR_ALT1 | SFR_ALT2)
        self.sreg = 0
        self.dreg = 0

    cdef inline uint16_t sr(self) noexcept:
        return self.r[self.sreg]

    cdef inline void set_dr(self, uint32_t value) noexcept:
        self.r[self.dreg] = <uint16_t>value
        if self.dreg == 14:
            self.r14_modified = 1
        elif self.dreg == 15:
            self.r15_modified = 1

    cdef inline void set_r(self, int n, uint32_t value) noexcept:
        self.r[n] = <uint16_t>value
        if n == 14:
            self.r14_modified = 1
        elif n == 15:
            self.r15_modified = 1

    cdef inline void setf(self, uint16_t mask, int on) noexcept:
        if on:
            self.sfr |= mask
        else:
            self.sfr &= ~mask

    cdef inline void nz(self, uint16_t v) noexcept:
        self.setf(SFR_S, v & 0x8000)
        self.setf(SFR_Z, v == 0)

    cdef void execute(self, uint8_t op) noexcept:
        cdef int n = op & 15
        cdef int alt1 = 1 if (self.sfr & SFR_ALT1) else 0
        cdef int alt2 = 1 if (self.sfr & SFR_ALT2) else 0
        cdef int32_t rr, m
        cdef uint32_t big
        cdef uint16_t v, lo
        cdef uint8_t b
        cdef int take, i

        # -- $00-$0f: control and the branches ------------------------------
        if op == 0x00:                                   # stop
            if not self.cfgr_irq:
                self.sfr |= SFR_IRQ
                self.irq_line = 1
            self.sfr &= ~SFR_G
            self.pipeline = 0x01
            self.reset_prefix()
        elif op == 0x01:                                 # nop
            self.reset_prefix()
        elif op == 0x02:                                 # cache
            if self.cbr != (self.r[15] & 0xFFF0):
                self.cbr = self.r[15] & 0xFFF0
                self.flush_cache()
            self.reset_prefix()
        elif op == 0x03:                                 # lsr
            self.setf(SFR_CY, self.sr() & 1)
            self.set_dr(self.sr() >> 1)
            self.nz(self.r[self.dreg])
            self.reset_prefix()
        elif op == 0x04:                                 # rol
            take = 1 if (self.sr() & 0x8000) else 0
            self.set_dr((self.sr() << 1) | (1 if (self.sfr & SFR_CY) else 0))
            self.setf(SFR_S, self.r[self.dreg] & 0x8000)
            self.setf(SFR_CY, take)
            self.setf(SFR_Z, self.r[self.dreg] == 0)
            self.reset_prefix()
        elif op <= 0x0F:                                 # bra and its conditions
            if op == 0x05:
                take = 1
            elif op == 0x06:
                take = 1 if ((1 if self.sfr & SFR_S else 0) ^ (1 if self.sfr & SFR_OV else 0)) == 0 else 0
            elif op == 0x07:
                take = 1 if ((1 if self.sfr & SFR_S else 0) ^ (1 if self.sfr & SFR_OV else 0)) == 1 else 0
            elif op == 0x08:
                take = 0 if (self.sfr & SFR_Z) else 1
            elif op == 0x09:
                take = 1 if (self.sfr & SFR_Z) else 0
            elif op == 0x0A:
                take = 0 if (self.sfr & SFR_S) else 1
            elif op == 0x0B:
                take = 1 if (self.sfr & SFR_S) else 0
            elif op == 0x0C:
                take = 0 if (self.sfr & SFR_CY) else 1
            elif op == 0x0D:
                take = 1 if (self.sfr & SFR_CY) else 0
            elif op == 0x0E:
                take = 0 if (self.sfr & SFR_OV) else 1
            else:
                take = 1 if (self.sfr & SFR_OV) else 0
            b = self.pipe()
            if take:
                self.set_r(15, self.r[15] + <int8_t>b)

        # -- $10-$2f: the register prefixes ---------------------------------
        elif op <= 0x1F:                                 # to rN / move rN
            if not (self.sfr & SFR_B):
                self.dreg = n
            else:
                self.set_r(n, self.sr())
                self.reset_prefix()
        elif op <= 0x2F:                                 # with rN
            self.sreg = n
            self.dreg = n
            self.sfr |= SFR_B

        # -- $30-$3f ---------------------------------------------------------
        elif op <= 0x3B:                                 # stw/stb (rN)
            self.ramaddr = self.r[n]
            self.write_ram_buffer(self.ramaddr, <uint8_t>self.sr())
            if not alt1:
                self.write_ram_buffer(self.ramaddr ^ 1, <uint8_t>(self.sr() >> 8))
            self.reset_prefix()
        elif op == 0x3C:                                 # loop
            self.set_r(12, self.r[12] - 1)
            self.setf(SFR_S, self.r[12] & 0x8000)
            self.setf(SFR_Z, self.r[12] == 0)
            if not (self.sfr & SFR_Z):
                self.set_r(15, self.r[13])
            self.reset_prefix()
        elif op == 0x3D:                                 # alt1
            self.sfr &= ~SFR_B
            self.sfr |= SFR_ALT1
        elif op == 0x3E:                                 # alt2
            self.sfr &= ~SFR_B
            self.sfr |= SFR_ALT2
        elif op == 0x3F:                                 # alt3
            self.sfr &= ~SFR_B
            self.sfr |= SFR_ALT1 | SFR_ALT2

        # -- $40-$4f ---------------------------------------------------------
        elif op <= 0x4B:                                 # ldw/ldb (rN)
            self.ramaddr = self.r[n]
            v = self.read_ram_buffer(self.ramaddr)
            if not alt1:
                v |= <uint16_t>self.read_ram_buffer(self.ramaddr ^ 1) << 8
            self.set_dr(v)
            self.reset_prefix()
        elif op == 0x4C:                                 # plot / rpix
            if not alt1:
                self.plot(<uint8_t>self.r[1], <uint8_t>self.r[2])
                self.set_r(1, self.r[1] + 1)
            else:
                self.set_dr(self.rpix(<uint8_t>self.r[1], <uint8_t>self.r[2]))
                self.nz(self.r[self.dreg])
            self.reset_prefix()
        elif op == 0x4D:                                 # swap
            self.set_dr((self.sr() >> 8) | (self.sr() << 8))
            self.nz(self.r[self.dreg])
            self.reset_prefix()
        elif op == 0x4E:                                 # color / cmode
            if not alt1:
                self.colr = self.plot_colour(<uint8_t>self.sr())
            else:
                v = self.sr()
                self.por_obj = 1 if (v & 0x10) else 0
                self.por_freezehigh = 1 if (v & 0x08) else 0
                self.por_highnibble = 1 if (v & 0x04) else 0
                self.por_dither = 1 if (v & 0x02) else 0
                self.por_transparent = 1 if (v & 0x01) else 0
            self.reset_prefix()
        elif op == 0x4F:                                 # not
            self.set_dr(~self.sr())
            self.nz(self.r[self.dreg])
            self.reset_prefix()

        # -- $50-$6f: the adders ---------------------------------------------
        elif op <= 0x5F:                                 # add / adc, register or immediate
            m = n if alt2 else <int32_t>self.r[n]
            rr = <int32_t>self.sr() + m + ((1 if (self.sfr & SFR_CY) else 0) if alt1 else 0)
            self.setf(SFR_OV, (~(<int32_t>self.sr() ^ m) & (m ^ rr)) & 0x8000)
            self.setf(SFR_S, rr & 0x8000)
            self.setf(SFR_CY, rr >= 0x10000)
            self.setf(SFR_Z, (<uint16_t>rr) == 0)
            self.set_dr(rr)
            self.reset_prefix()
        elif op <= 0x6F:                                 # sub / sbc / cmp
            m = <int32_t>self.r[n] if (not alt2 or alt1) else n
            rr = <int32_t>self.sr() - m - ((0 if (self.sfr & SFR_CY) else 1)
                                           if (not alt2 and alt1) else 0)
            self.setf(SFR_OV, ((<int32_t>self.sr() ^ m) & (<int32_t>self.sr() ^ rr)) & 0x8000)
            self.setf(SFR_S, rr & 0x8000)
            self.setf(SFR_CY, rr >= 0)
            self.setf(SFR_Z, (<uint16_t>rr) == 0)
            if not alt2 or not alt1:
                self.set_dr(rr)
            self.reset_prefix()

        # -- $70-$7f ---------------------------------------------------------
        elif op == 0x70:                                 # merge
            self.set_dr((self.r[7] & 0xFF00) | (self.r[8] >> 8))
            v = self.r[self.dreg]
            self.setf(SFR_OV, v & 0xC0C0)
            self.setf(SFR_S, v & 0x8080)
            self.setf(SFR_CY, v & 0xE0E0)
            self.setf(SFR_Z, v & 0xF0F0)
            self.reset_prefix()
        elif op <= 0x7F:                                 # and / bic
            m = n if alt2 else <int32_t>self.r[n]
            self.set_dr(self.sr() & (<uint16_t>(~m) if alt1 else <uint16_t>m))
            self.nz(self.r[self.dreg])
            self.reset_prefix()

        # -- $80-$8f ---------------------------------------------------------
        elif op <= 0x8F:                                 # mult / umult
            m = n if alt2 else <int32_t>self.r[n]
            if not alt1:
                self.set_dr(<uint16_t>(<int32_t><int8_t>self.sr() * <int32_t><int8_t>m))
            else:
                self.set_dr(<uint16_t>(<uint32_t>(self.sr() & 0xFF) * <uint32_t>(m & 0xFF)))
            self.nz(self.r[self.dreg])
            self.reset_prefix()
            if not self.cfgr_ms0:
                self.step(1 if self.clsr else 2)

        # -- $90-$9f ---------------------------------------------------------
        elif op == 0x90:                                 # sbk
            self.write_ram_buffer(self.ramaddr ^ 0, <uint8_t>self.sr())
            self.write_ram_buffer(self.ramaddr ^ 1, <uint8_t>(self.sr() >> 8))
            self.reset_prefix()
        elif op <= 0x94:                                 # link #N
            self.set_r(11, self.r[15] + (op & 15))
            self.reset_prefix()
        elif op == 0x95:                                 # sex
            self.set_dr(<uint16_t><int16_t><int8_t>self.sr())
            self.nz(self.r[self.dreg])
            self.reset_prefix()
        elif op == 0x96:                                 # asr / div2
            self.setf(SFR_CY, self.sr() & 1)
            rr = <int32_t><int16_t>self.sr() >> 1
            if alt1:
                rr += ((<int32_t>self.sr() + 1) >> 16)
            self.set_dr(rr)
            self.nz(self.r[self.dreg])
            self.reset_prefix()
        elif op == 0x97:                                 # ror
            take = self.sr() & 1
            self.set_dr(((1 if (self.sfr & SFR_CY) else 0) << 15) | (self.sr() >> 1))
            self.setf(SFR_S, self.r[self.dreg] & 0x8000)
            self.setf(SFR_CY, take)
            self.setf(SFR_Z, self.r[self.dreg] == 0)
            self.reset_prefix()
        elif op <= 0x9D:                                 # jmp / ljmp
            # $98-$9d name r8 through r13, not r0 through r5: the register is
            # the opcode's low nibble, as everywhere else.
            if not alt1:
                self.set_r(15, self.r[n])
            else:
                self.pbr = self.r[n] & 0x7F
                self.set_r(15, self.sr())
                self.cbr = self.r[15] & 0xFFF0
                self.flush_cache()
            self.reset_prefix()
        elif op == 0x9E:                                 # lob
            self.set_dr(self.sr() & 0xFF)
            self.setf(SFR_S, self.r[self.dreg] & 0x80)
            self.setf(SFR_Z, self.r[self.dreg] == 0)
            self.reset_prefix()
        elif op == 0x9F:                                 # fmult / lmult
            big = <uint32_t>(<int32_t><int16_t>self.sr() * <int32_t><int16_t>self.r[6])
            if alt1:
                self.set_r(4, big & 0xFFFF)
            self.set_dr(big >> 16)
            self.setf(SFR_S, self.r[self.dreg] & 0x8000)
            self.setf(SFR_CY, big & 0x8000)
            self.setf(SFR_Z, self.r[self.dreg] == 0)
            self.reset_prefix()
            self.step((3 if self.cfgr_ms0 else 7) * (1 if self.clsr else 2))

        # -- $a0-$af ---------------------------------------------------------
        elif op <= 0xAF:                                 # ibt / lms / sms
            if alt1:
                self.ramaddr = <uint16_t>(self.pipe() << 1)
                lo = self.read_ram_buffer(self.ramaddr ^ 0)
                self.set_r(n, (<uint16_t>self.read_ram_buffer(self.ramaddr ^ 1) << 8) | lo)
            elif alt2:
                self.ramaddr = <uint16_t>(self.pipe() << 1)
                self.write_ram_buffer(self.ramaddr ^ 0, <uint8_t>self.r[n])
                self.write_ram_buffer(self.ramaddr ^ 1, <uint8_t>(self.r[n] >> 8))
            else:
                self.set_r(n, <uint16_t><int16_t><int8_t>self.pipe())
            self.reset_prefix()

        # -- $b0-$bf ---------------------------------------------------------
        elif op <= 0xBF:                                 # from rN / moves rN
            if not (self.sfr & SFR_B):
                self.sreg = n
            else:
                self.set_dr(self.r[n])
                self.setf(SFR_OV, self.r[self.dreg] & 0x80)
                self.setf(SFR_S, self.r[self.dreg] & 0x8000)
                self.setf(SFR_Z, self.r[self.dreg] == 0)
                self.reset_prefix()

        # -- $c0-$cf ---------------------------------------------------------
        elif op == 0xC0:                                 # hib
            self.set_dr(self.sr() >> 8)
            self.setf(SFR_S, self.r[self.dreg] & 0x80)
            self.setf(SFR_Z, self.r[self.dreg] == 0)
            self.reset_prefix()
        elif op <= 0xCF:                                 # or / xor
            m = n if alt2 else <int32_t>self.r[n]
            if not alt1:
                self.set_dr(self.sr() | <uint16_t>m)
            else:
                self.set_dr(self.sr() ^ <uint16_t>m)
            self.nz(self.r[self.dreg])
            self.reset_prefix()

        # -- $d0-$df ---------------------------------------------------------
        elif op <= 0xDE:                                 # inc rN
            self.set_r(n, self.r[n] + 1)
            self.setf(SFR_S, self.r[n] & 0x8000)
            self.setf(SFR_Z, self.r[n] == 0)
            self.reset_prefix()
        elif op == 0xDF:                                 # getc / ramb / romb
            if not alt2:
                self.colr = self.plot_colour(self.read_rom_buffer())
            elif not alt1:
                self.sync_ram_buffer()
                self.rambr = self.sr() & 1
            else:
                self.sync_rom_buffer()
                self.rombr = self.sr() & 0x7F
            self.reset_prefix()

        # -- $e0-$ef ---------------------------------------------------------
        elif op <= 0xEE:                                 # dec rN
            self.set_r(n, self.r[n] - 1)
            self.setf(SFR_S, self.r[n] & 0x8000)
            self.setf(SFR_Z, self.r[n] == 0)
            self.reset_prefix()
        elif op == 0xEF:                                 # getb and its variants
            take = (alt2 << 1) | alt1
            if take == 0:
                self.set_dr(self.read_rom_buffer())
            elif take == 1:
                self.set_dr((<uint16_t>self.read_rom_buffer() << 8) | (self.sr() & 0xFF))
            elif take == 2:
                self.set_dr((self.sr() & 0xFF00) | self.read_rom_buffer())
            else:
                self.set_dr(<uint16_t><int16_t><int8_t>self.read_rom_buffer())
            self.reset_prefix()

        # -- $f0-$ff ---------------------------------------------------------
        else:                                            # iwt / lm / sm
            if alt1:
                self.ramaddr = self.pipe()
                self.ramaddr |= <uint16_t>self.pipe() << 8
                lo = self.read_ram_buffer(self.ramaddr ^ 0)
                self.set_r(n, (<uint16_t>self.read_ram_buffer(self.ramaddr ^ 1) << 8) | lo)
            elif alt2:
                self.ramaddr = self.pipe()
                self.ramaddr |= <uint16_t>self.pipe() << 8
                self.write_ram_buffer(self.ramaddr ^ 0, <uint8_t>self.r[n])
                self.write_ram_buffer(self.ramaddr ^ 1, <uint8_t>(self.r[n] >> 8))
            else:
                lo = self.pipe()
                self.set_r(n, (<uint16_t>self.pipe() << 8) | lo)
            self.reset_prefix()

    # -- introspection ------------------------------------------------------

    def registers(self):
        return dict(r=[self.r[i] for i in range(16)], sfr=self.sfr,
                    pbr=self.pbr, rombr=self.rombr, rambr=self.rambr,
                    cbr=self.cbr, scbr=self.scbr, colr=self.colr,
                    clsr=self.clsr, going=bool(self.sfr & SFR_G),
                    scmr=dict(ht=self.scmr_ht, ron=self.scmr_ron,
                              ran=self.scmr_ran, md=self.scmr_md),
                    ram=len(self.ram_data))


cdef uint32_t _mask_for(uint32_t size) noexcept:
    cdef uint32_t m = 1
    while m < size:
        m <<= 1
    return m - 1


def _superfx_ram_size(Cart cart):
    """How much work RAM the cartridge carries.

    SuperFX boards keep it in the byte before the ordinary RAM size, and a
    zero there means 32 KB rather than none -- Star Fox's header says nothing
    at all and the board has 32 KB on it."""
    cdef bytes rom = cart.rom_data
    cdef int off = cart.header_offset + 0x0D        # $FFBD, the expansion size
    cdef int k
    if 0 <= off < len(rom):
        k = rom[off]
        if 1 <= k <= 8:
            return 1024 << k
    return 32768


from snes.board import register
register("SuperFX", SuperFX)
