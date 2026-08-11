# cython: language_level=3
# cython: boundscheck=False, wraparound=False, cdivision=True
"""The SA-1: a second 65816, on the cartridge, running at three times the speed.

The console's CPU is a 65816 at 3.58 MHz.  The SA-1 is the same processor at
10.74 MHz with its own 2 KB of fast RAM, and the cartridge decides which of
the two sees what.  Both address the same ROM through a bank switcher, both
address the same battery RAM through a window each, and they talk through a
pair of message registers and an interrupt each way.

Nothing here is a coprocessor in the sense of an accelerator with a command
set.  It is a whole second computer sharing a bus, so most of this file is
about who can see what, and only the last part -- multiply, divide, a
bit-stream reader and a DMA unit -- is hardware the S-CPU does not have.

The two are kept in step by catching up: whenever the console touches
anything the SA-1 can also see, the SA-1 is first run forward to that moment.
That is what makes a message written by one visible to the other in order.
"""
from libc.stdint cimport (uint8_t, uint16_t, uint32_t, uint64_t,
                          int16_t, int32_t, int64_t)
from libc.string cimport memset

from snes.board cimport Board, PK_DEVICE
from snes.cart cimport Cart
from snes.cpu cimport CPU
from snes.space cimport AddressSpace

# The SA-1 runs at three times the console's fastest rate: the S-CPU's
# quickest access is six master cycles and the SA-1's is two.
DEF SA1_CYCLE = 2

# The counters run on the console's timebase: a scanline is 1364 master
# cycles and a frame 262 of them.
DEF LINE_CYCLES = 1364
DEF LINES_PER_FRAME = 262


cdef class SA1Space(AddressSpace):
    """What the SA-1 processor can address.

    Its low 2 KB is the internal RAM rather than the console's WRAM, it has
    no PPU and no APU, and its ROM comes through the same bank switcher the
    console's does.
    """

    def __cinit__(self, SA1 chip):
        self.chip = chip
        self.master_clock = 0
        self.target = 0
        self.nmi_pending = 0
        self.irq_pending = 0

    cdef uint8_t read8(self, uint32_t addr) noexcept:
        return self.chip._read_common(addr, 1, 0)

    cdef void write8(self, uint32_t addr, uint8_t value) noexcept:
        self.chip._write_common(addr, value, 1)

    cdef uint8_t read8_fast(self, uint32_t addr) noexcept:
        return self.chip._read_common(addr, 1, 0)

    cdef void tick(self, int cycles) noexcept:
        self.master_clock += cycles

    cdef uint32_t speed(self, uint32_t addr) noexcept:
        # ROM and BW-RAM cost the SA-1 an extra clock when the console wants
        # them in the same cycle.  That arbitration is not modelled: it would
        # need both processors on one scheduler rather than one catching up
        # to the other.
        return SA1_CYCLE


cdef class SA1(Board):

    def __cinit__(self, Cart cart):
        self.name = u"SA-1"
        self.space = SA1Space(self)
        self.cpu = CPU(self.space)
        self.bwram = cart.sram
        self.bwram_mask = cart.sram_mask
        self.reset_board()

    cdef void reset_board(self) noexcept:
        cdef int i
        memset(self.iram, 0, 0x800)
        for i in range(4):
            self.mmc[i] = 0
        # The SA-1 comes up held in reset and stays there until the console
        # clears bit 5 of $2200, which every game's boot code does early.
        self.ccnt = 0x20
        self.scnt = 0
        self.sie = 0
        self.sic = 0
        self.cie = 0
        self.cic = 0
        self.crv = 0
        self.cnv = 0
        self.civ = 0
        self.snv = 0
        self.siv = 0
        self.sa1_irq = 0
        self.sa1_nmi = 0
        self.scpu_irq = 0
        self.dma_irq_scpu = 0
        self.dma_irq_sa1 = 0
        self.timer_irq = 0
        self.stopped = 1
        self.bmaps = 0
        self.bmap = 0
        self.sbwe = 0
        self.cbwe = 0
        self.siwp = 0
        self.ciwp = 0
        self.math_ctl = 0
        self.math_a = 0
        self.math_b = 0
        self.math_result = 0
        self.math_overflow = 0
        self.vbd = 0
        self.vda = 0
        self.vbit = 0
        self.tmc = 0
        self.timer_h = 0
        self.timer_v = 0
        self.timer_base = 0
        self.timer_seen = 0
        self.dcnt = 0
        self.cdma = 0
        self.dsa = 0
        self.dda = 0
        self.dtc = 0
        self.cc_line = 0
        self.n_cc1 = 0
        self.n_cc2 = 0
        self.n_dma = 0
        self.n_math = 0
        self.n_varlen = 0
        self.n_timer_irq = 0
        for i in range(16):
            self.brf[i] = 0

    # =====================================================================
    # what the console sees
    # =====================================================================

    cdef int classify(self, uint32_t bank, uint32_t addr, uint32_t *base) noexcept:
        """Every page is a device page.

        Even plain ROM, because the bank switcher can be rewritten at any
        moment and a page table cannot follow that without being rebuilt on
        every write to $2220.  It also means every console access is a place
        to catch the SA-1 up, which is what keeps the two in order.
        """
        base[0] = 0
        return PK_DEVICE

    cdef uint8_t read(self, uint32_t addr, uint8_t data) noexcept:
        self.run_until(self.clock)
        return self._read_common(addr, 0, data)

    cdef void write(self, uint32_t addr, uint8_t value) noexcept:
        self.run_until(self.clock)
        self._write_common(addr, value, 0)

    # =====================================================================
    # the shared map
    # =====================================================================

    cdef uint32_t _rom_offset(self, uint32_t bank, uint32_t addr) noexcept:
        """Where in the ROM a bank and address land.

        The ROM is divided into four 1 MB slots.  $2220-$2223 say which
        megabyte each slot shows: with bit 7 clear a slot shows its own
        number, and with it set the low three bits choose instead.  Banks
        $00-$3F and $80-$BF see a slot 32 KB at a time through $8000-$FFFF;
        banks $C0-$FF see one whole 64 KB at a time.
        """
        cdef uint32_t slot, mb, linear

        if bank >= 0xC0:
            slot = (bank - 0xC0) >> 4
            mb = (self.mmc[slot] & 7) if (self.mmc[slot] & 0x80) else slot
            linear = (mb << 20) | ((bank & 0x0F) << 16) | addr
        else:
            # $00-$1F is slot C, $20-$3F slot D, $80-$9F slot E, $A0-$BF F.
            slot = ((bank >> 5) & 1) | ((bank >> 6) & 2)
            mb = (self.mmc[slot] & 7) if (self.mmc[slot] & 0x80) else slot
            linear = (mb << 20) | ((bank & 0x1F) << 15) | (addr & 0x7FFF)
        return self.cart.rom_offset(linear)

    cdef uint32_t _bwram_window(self, int from_sa1, uint32_t addr) noexcept:
        """$6000-$7FFF is an 8 KB window into the battery RAM.

        Each processor has its own block register, so the two can look at
        different parts of it at once.
        """
        cdef uint32_t block = (self.bmap if from_sa1 else self.bmaps) & 0x1F
        return ((block << 13) | (addr & 0x1FFF)) & self.bwram_mask

    cdef uint8_t _read_common(self, uint32_t addr, int from_sa1, uint8_t data) noexcept:
        cdef uint32_t bank = (addr >> 16) & 0xFF
        cdef uint32_t off = addr & 0xFFFF

        if bank < 0x40 or (0x80 <= bank < 0xC0):
            if 0x2200 <= off <= 0x23FF:
                return self._read_reg(off, from_sa1, data)
            if off < 0x0800:
                # The console has its own WRAM down here; the SA-1 has I-RAM.
                if from_sa1:
                    return self.iram[off]
                return data
            if 0x3000 <= off < 0x3800:
                return self.iram[off & 0x7FF]
            if 0x6000 <= off < 0x8000:
                if self.bwram_mask == 0:
                    return data
                if not from_sa1 and (self.dcnt & 0xB0) == 0xA0:
                    return self._cc1_read(self._bwram_window(0, off))
                return self.bwram[self._bwram_window(from_sa1, off)]
            if off >= 0x8000:
                # Neither processor necessarily reads its vectors out of the
                # cartridge.  The SA-1 always takes its own, from $2205 and
                # $2207, because the ROM's vectors belong to the console's
                # handlers and mean nothing to it.  The console takes the
                # SA-1's, from $220C and $220E, when the SA-1 asks it to --
                # that is how the SA-1 hands work back, by pointing the
                # console's interrupt somewhere of its choosing.
                if (bank & 0x7F) == 0:
                    if from_sa1:
                        if 0xFFEA <= off <= 0xFFEB:
                            return <uint8_t>(self.cnv >> ((off & 1) * 8))
                        if 0xFFEE <= off <= 0xFFEF:
                            return <uint8_t>(self.civ >> ((off & 1) * 8))
                    else:
                        if (self.scnt & 0x10) and 0xFFEA <= off <= 0xFFEB:
                            return <uint8_t>(self.snv >> ((off & 1) * 8))
                        if (self.scnt & 0x20) and 0xFFEE <= off <= 0xFFEF:
                            return <uint8_t>(self.siv >> ((off & 1) * 8))
                return self.cart.rom[self._rom_offset(bank, off)]
            return data

        if 0x40 <= bank < 0x50:                      # battery RAM, laid flat
            if self.bwram_mask == 0:
                return data
            if not from_sa1 and (self.dcnt & 0xB0) == 0xA0:
                return self._cc1_read((((bank & 0x0F) << 16) | off) & self.bwram_mask)
            return self.bwram[(((bank & 0x0F) << 16) | off) & self.bwram_mask]

        if bank >= 0xC0:
            return self.cart.rom[self._rom_offset(bank, off)]
        return data

    cdef void _write_common(self, uint32_t addr, uint8_t value, int from_sa1) noexcept:
        cdef uint32_t bank = (addr >> 16) & 0xFF
        cdef uint32_t off = addr & 0xFFFF

        if bank < 0x40 or (0x80 <= bank < 0xC0):
            if 0x2200 <= off <= 0x23FF:
                self._write_reg(off, value, from_sa1)
                return
            if off < 0x0800:
                if from_sa1:
                    self.iram[off] = value
                return
            if 0x3000 <= off < 0x3800:
                self.iram[off & 0x7FF] = value
                return
            if 0x6000 <= off < 0x8000:
                if self.bwram_mask:
                    self.bwram[self._bwram_window(from_sa1, off)] = value
                return
            return                                   # ROM swallows writes

        if 0x40 <= bank < 0x50:
            if self.bwram_mask:
                self.bwram[(((bank & 0x0F) << 16) | off) & self.bwram_mask] = value

    # =====================================================================
    # registers
    # =====================================================================

    cdef uint8_t _read_reg(self, uint32_t a, int from_sa1, uint8_t data) noexcept:
        cdef uint8_t v

        if a == 0x2300:                              # SFR, read by the S-CPU
            v = self.scnt & 0x0F
            v |= (self.scnt & 0x30)                  # which vectors the SA-1 supplies
            if self.scpu_irq:
                v |= 0x80
            if self.dma_irq_scpu:
                v |= 0x20
            return v

        if a == 0x2301:                              # CFR, read by the SA-1
            v = self.ccnt & 0x0F
            if self.sa1_irq:
                v |= 0x80
            if self.timer_irq:
                v |= 0x40
            if self.dma_irq_sa1:
                v |= 0x20
            if self.sa1_nmi:
                v |= 0x10
            return v

        if a == 0x2302:
            return <uint8_t>(self._hcount() & 0xFF)
        if a == 0x2303:
            return <uint8_t>((self._hcount() >> 8) & 0x07)
        if a == 0x2304:
            return <uint8_t>(self._vcount() & 0xFF)
        if a == 0x2305:
            return <uint8_t>((self._vcount() >> 8) & 0x01)

        if 0x2306 <= a <= 0x230A:                    # arithmetic result
            return <uint8_t>((self.math_result >> ((a - 0x2306) * 8)) & 0xFF)
        if a == 0x230B:
            return 0x80 if self.math_overflow else 0x00

        if a == 0x230C:                              # variable-length data
            return <uint8_t>(self._read_varlen() & 0xFF)
        if a == 0x230D:
            v = <uint8_t>(self._read_varlen() >> 8)
            if self.vbd & 0x80:                      # auto-advance on the high byte
                self._advance_varlen()
            return v

        if a == 0x230E:
            return 0x01                              # SA-1 revision

        if 0x2240 <= a <= 0x224F:
            return self.brf[a & 0x0F]

        return data

    cdef void _write_reg(self, uint32_t a, uint8_t value, int from_sa1) noexcept:
        if a == 0x2200:                              # CCNT: the console drives the SA-1
            self.ccnt = value
            if value & 0x80:
                self.sa1_irq = 1
            if value & 0x10:
                self.sa1_nmi = 1
            if value & 0x20:
                self.stopped = 1
            elif self.stopped:
                # Coming out of reset: start at the vector the console left
                # in $2203, not at the cartridge's own reset vector.
                self.stopped = 0
                self.cpu.reset()
                self.cpu.pc = self.crv
                self.cpu.pb = 0
            if value & 0x40:
                self.stopped = 1                     # wait
            self._refresh_interrupts()
            return

        if a == 0x2201:
            self.sie = value
            self._refresh_interrupts()
            return
        if a == 0x2202:                              # SIC: the console clears its flags
            if value & 0x80:
                self.scpu_irq = 0
            if value & 0x20:
                self.dma_irq_scpu = 0
            self._refresh_interrupts()
            return

        if a == 0x2203:
            self.crv = (self.crv & 0xFF00) | value
            return
        if a == 0x2204:
            self.crv = (self.crv & 0x00FF) | (<uint16_t>value << 8)
            return
        if a == 0x2205:
            self.cnv = (self.cnv & 0xFF00) | value
            return
        if a == 0x2206:
            self.cnv = (self.cnv & 0x00FF) | (<uint16_t>value << 8)
            return
        if a == 0x2207:
            self.civ = (self.civ & 0xFF00) | value
            return
        if a == 0x2208:
            self.civ = (self.civ & 0x00FF) | (<uint16_t>value << 8)
            return

        if a == 0x2209:                              # SCNT: the SA-1 drives the console
            self.scnt = value
            if value & 0x80:
                self.scpu_irq = 1
            self._refresh_interrupts()
            return
        if a == 0x220A:
            self.cie = value
            self._refresh_interrupts()
            return
        if a == 0x220B:                              # CIC: the SA-1 clears its flags
            if value & 0x80:
                self.sa1_irq = 0
            if value & 0x40:
                self.timer_irq = 0
            if value & 0x20:
                self.dma_irq_sa1 = 0
            if value & 0x10:
                self.sa1_nmi = 0
            self._refresh_interrupts()
            return

        if a == 0x220C:
            self.snv = (self.snv & 0xFF00) | value
            return
        if a == 0x220D:
            self.snv = (self.snv & 0x00FF) | (<uint16_t>value << 8)
            return
        if a == 0x220E:
            self.siv = (self.siv & 0xFF00) | value
            return
        if a == 0x220F:
            self.siv = (self.siv & 0x00FF) | (<uint16_t>value << 8)
            return

        if a == 0x2210:
            self.tmc = value
            return
        if a == 0x2211:                              # CTR: restart the timers
            self.timer_base = self.space.master_clock
            self.timer_seen = self.timer_base
            return
        if a == 0x2212:
            self.timer_h = (self.timer_h & 0xFF00) | value
            return
        if a == 0x2213:
            self.timer_h = (self.timer_h & 0x00FF) | (<uint16_t>value << 8)
            return
        if a == 0x2214:
            self.timer_v = (self.timer_v & 0xFF00) | value
            return
        if a == 0x2215:
            self.timer_v = (self.timer_v & 0x00FF) | (<uint16_t>value << 8)
            return

        if 0x2220 <= a <= 0x2223:
            self.mmc[a - 0x2220] = value
            return

        if a == 0x2224:
            self.bmaps = value
            return
        if a == 0x2225:
            self.bmap = value
            return
        if a == 0x2226:
            self.sbwe = value
            return
        if a == 0x2227:
            self.cbwe = value
            return
        if a == 0x2228:
            return                                   # BWPA: write protect area
        if a == 0x2229:
            self.siwp = value
            return
        if a == 0x222A:
            self.ciwp = value
            return

        if a == 0x2230:
            self.dcnt = value
            return
        if a == 0x2231:
            self.cdma = value
            if value & 0x80:                         # conversion finished
                self.cc_line = 0
            return
        if a == 0x2232:
            self.dsa = (self.dsa & 0xFFFF00) | value
            return
        if a == 0x2233:
            self.dsa = (self.dsa & 0xFF00FF) | (<uint32_t>value << 8)
            return
        if a == 0x2234:
            self.dsa = (self.dsa & 0x00FFFF) | (<uint32_t>value << 16)
            return
        if a == 0x2235:
            self.dda = (self.dda & 0xFFFF00) | value
            return
        if a == 0x2236:
            self.dda = (self.dda & 0xFF00FF) | (<uint32_t>value << 8)
            # I-RAM is 2 KB, so two address bytes are the whole of it and the
            # transfer starts here.  A BW-RAM destination waits for the third.
            if (self.dcnt & 0x08) == 0:
                self._run_dma()
            return
        if a == 0x2237:
            self.dda = (self.dda & 0x00FFFF) | (<uint32_t>value << 16)
            if self.dcnt & 0x08:
                self._run_dma()
            return
        if a == 0x2238:
            self.dtc = (self.dtc & 0xFF00) | value
            return
        if a == 0x2239:
            self.dtc = (self.dtc & 0x00FF) | (<uint16_t>value << 8)
            return

        if 0x2240 <= a <= 0x224F:
            self.brf[a & 0x0F] = value
            # Half the buffer at a time: filling either half converts it.
            if (a == 0x2247 or a == 0x224F) and (self.dcnt & 0xB0) == 0xB0:
                self._convert_buffer()
            return

        if a == 0x2250:
            self.math_ctl = value
            if value & 0x02:                         # clearing the accumulator
                self.math_result = 0
                self.math_overflow = 0
            return
        if a == 0x2251:
            self.math_a = (self.math_a & 0xFF00) | value
            return
        if a == 0x2252:
            self.math_a = (self.math_a & 0x00FF) | (<uint16_t>value << 8)
            return
        if a == 0x2253:
            self.math_b = (self.math_b & 0xFF00) | value
            return
        if a == 0x2254:
            self.math_b = (self.math_b & 0x00FF) | (<uint16_t>value << 8)
            self._start_math()
            return

        if a == 0x2258:
            self.vbd = value
            self._advance_varlen()
            return
        if a == 0x2259:
            self.vda = (self.vda & 0xFFFF00) | value
            return
        if a == 0x225A:
            self.vda = (self.vda & 0xFF00FF) | (<uint32_t>value << 8)
            return
        if a == 0x225B:
            self.vda = (self.vda & 0x00FFFF) | (<uint32_t>value << 16)
            self.vbit = 0
            return

    # =====================================================================
    # timers
    # =====================================================================
    #
    # The SA-1 keeps its own H and V counters on the same timebase as the
    # console's, restarted by a write to $2211.  A game reads them to find
    # out where the beam is without going through the console, and can ask
    # for an interrupt when they reach a chosen point.
    #
    # $2210 bit 7 picks between that and a linear timer, which is the same
    # pair of counters read as one number and compared against the same two
    # registers joined together.

    cdef int _hcount(self) noexcept:
        return <int>((self.space.master_clock - self.timer_base) % LINE_CYCLES)

    cdef int _vcount(self) noexcept:
        return <int>(((self.space.master_clock - self.timer_base) // LINE_CYCLES)
                     % LINES_PER_FRAME)

    cdef void _check_timer(self) noexcept:
        """Raise the timer interrupt if the compare point has just gone past.

        The check runs at each catch-up rather than each cycle, so it looks
        at the whole interval since the last one and asks whether the target
        fell inside it.
        """
        cdef int64_t now = self.space.master_clock
        cdef int64_t period, target, first, span
        cdef int64_t start = self.timer_seen

        if (self.tmc & 0x03) == 0 or now <= start:
            self.timer_seen = now
            return

        if self.tmc & 0x80:                          # H/V timer
            if self.tmc & 0x02:                      # both counters compare
                period = <int64_t>LINE_CYCLES * LINES_PER_FRAME
                target = (<int64_t>self.timer_v * LINE_CYCLES) + self.timer_h
            else:                                    # H only, once a line
                period = LINE_CYCLES
                target = self.timer_h
        else:                                        # linear timer
            period = (<int64_t>self.timer_v << 16) | self.timer_h
            if period <= 0:
                self.timer_seen = now
                return
            target = period - 1

        span = start - self.timer_base
        first = ((span // period) * period) + target + self.timer_base
        if first < start:
            first += period
        if first < now:
            self.timer_irq = 1
            self._refresh_interrupts()
        self.timer_seen = now

    cdef void _refresh_interrupts(self) noexcept:
        """Work out what each processor should be seeing on its IRQ line."""
        cdef int to_sa1 = 0
        if self.sa1_irq and (self.cie & 0x80):
            to_sa1 = 1
        if self.timer_irq and (self.cie & 0x40):
            to_sa1 = 1
        if self.dma_irq_sa1 and (self.cie & 0x20):
            to_sa1 = 1
        self.space.irq_pending = to_sa1
        self.space.nmi_pending = 1 if (self.sa1_nmi and (self.cie & 0x10)) else 0

        self.irq_line = 0
        if self.scpu_irq and (self.sie & 0x80):
            self.irq_line = 1
        if self.dma_irq_scpu and (self.sie & 0x20):
            self.irq_line = 1

    # =====================================================================
    # arithmetic
    # =====================================================================

    cdef void _start_math(self) noexcept:
        """Multiply, divide, or multiply and accumulate.

        The result register is 40 bits, which only the accumulating mode
        needs; a plain multiply fills the low 32 and a divide puts the
        quotient in the low 16 and the remainder above it.
        """
        self.n_math += 1
        cdef int32_t a = <int32_t><int16_t>self.math_a
        cdef int32_t b
        cdef int32_t quotient, remainder
        cdef int64_t product

        if (self.math_ctl & 1) == 0:                 # multiply
            b = <int32_t><int16_t>self.math_b
            product = <int64_t>a * b
            if self.math_ctl & 2:                    # ... and accumulate
                self.math_result += product
                if self.math_result & ~<int64_t>0xFFFFFFFFFF:
                    self.math_overflow = 1
                self.math_result &= <int64_t>0xFFFFFFFFFF
            else:
                self.math_result = <int64_t>(<uint32_t>product)
        else:                                        # divide
            b = <int32_t>self.math_b                 # the divisor is unsigned
            if b == 0:
                quotient = 0
                remainder = a
            else:
                quotient = a // b
                remainder = a - quotient * b
                if remainder < 0:                    # the hardware floors
                    quotient -= 1
                    remainder += b
            self.math_result = (<int64_t>(<uint16_t>quotient)
                                | (<int64_t>(<uint16_t>remainder) << 16))
        self.math_a = 0
        self.math_b = 0

    # =====================================================================
    # variable-length bit stream
    # =====================================================================
    #
    # A reader that pulls an arbitrary number of bits at a time out of ROM,
    # for the packed tables these games keep their maps and scripts in.  The
    # address is a byte address and the bit position runs on past it, so a
    # field can straddle as many bytes as it likes.

    cdef uint16_t _read_varlen(self) noexcept:
        cdef uint32_t addr = self.vda + (<uint32_t>self.vbit >> 3)
        cdef uint32_t word = 0
        cdef int shift = self.vbit & 7
        word = self._read_common(addr, 1, 0)
        word |= <uint32_t>self._read_common(addr + 1, 1, 0) << 8
        word |= <uint32_t>self._read_common(addr + 2, 1, 0) << 16
        return <uint16_t>((word >> shift) & 0xFFFF)

    cdef void _advance_varlen(self) noexcept:
        self.n_varlen += 1
        cdef int count = self.vbd & 0x0F
        if count == 0:
            count = 16
        self.vbit += count
        self.vda += <uint32_t>(self.vbit >> 3)
        self.vbit &= 7

    # =====================================================================
    # DMA
    # =====================================================================

    cdef void _run_dma(self) noexcept:
        """The plain transfer: bytes from ROM, BW-RAM or I-RAM to one of the
        latter two.  Character conversion is a different unit entirely."""
        cdef uint32_t src = self.dsa
        cdef uint32_t dst = self.dda
        cdef int n = self.dtc
        cdef int i

        if (self.dcnt & 0x80) == 0:
            return
        if self.dcnt & 0x20:                         # character conversion
            return
        self.n_dma += 1
        for i in range(n):
            self._write_common(dst + i, self._read_common(src + i, 1, 0), 1)
        self.dma_irq_scpu = 1
        self.dma_irq_sa1 = 1
        self._refresh_interrupts()

    # -------------------------------------------- character conversion ---
    #
    # A SNES character is planar: eight bytes carrying bit 0 of each row,
    # interleaved with eight carrying bit 1, and so on.  That is a miserable
    # format to draw into, so these games keep a plain linear bitmap --
    # consecutive bits per pixel, left to right -- and have the SA-1
    # transpose it on the way past.
    #
    # $2231 says how: the low two bits give the depth (0 is eight bits per
    # pixel, 1 is four, 2 is two) and the next three the width of the virtual
    # bitmap in characters, 1 to 32.
    #
    # There are two ways to drive it.  Type 1 converts as the console reads:
    # the console runs an ordinary DMA out of BW-RAM towards VRAM and each
    # read comes back transposed.  Type 2 is the SA-1 handing the bytes over
    # eight at a time through $2240-$224F.

    cdef int _cc_bpp(self) noexcept:
        return 2 << (2 - (self.cdma & 3))

    cdef void _convert_row(self, uint32_t bwaddr, uint32_t dst, int y) noexcept:
        """Transpose one eight-pixel row of the bitmap into I-RAM."""
        cdef int bpp = self._cc_bpp()
        cdef uint64_t data = 0
        cdef uint8_t out[8]
        cdef int byte, x, index

        for byte in range(bpp):
            data |= (<uint64_t>self.bwram[(bwaddr + byte) & self.bwram_mask]) << (byte * 8)
        for byte in range(8):
            out[byte] = 0
        for x in range(8):
            for byte in range(bpp):
                out[byte] |= <uint8_t>((data & 1) << (7 - x))
                data >>= 1
        for byte in range(bpp):
            # Planes go in pairs: 0 and 1 fill the first sixteen bytes of the
            # character, 2 and 3 the next sixteen.
            index = y * 2 + (byte & 1) + (byte >> 1) * 16
            self.iram[(dst + index) & 0x7FF] = out[byte]

    cdef uint8_t _cc1_read(self, uint32_t offset) noexcept:
        """A console read of BW-RAM while type 1 conversion is running.

        Crossing into a new character converts that whole character into
        I-RAM first; the read itself then comes out of I-RAM.
        """
        cdef int depth = self.cdma & 3
        cdef int width = (self.cdma >> 2) & 7
        cdef int bpp = self._cc_bpp()
        cdef uint32_t charmask = (<uint32_t>1 << (6 - depth)) - 1
        cdef uint32_t bpl = (<uint32_t>8 << width) >> depth
        cdef uint32_t base = self.dsa & self.bwram_mask
        cdef uint32_t tile, ty, tx, bwaddr
        cdef int y

        self.n_cc1 += 1
        if (offset & charmask) == 0:
            tile = ((offset - base) & self.bwram_mask) >> (6 - depth)
            ty = tile >> width
            tx = tile & ((<uint32_t>1 << width) - 1)
            bwaddr = base + ty * bpl * 8 + tx * <uint32_t>bpp
            for y in range(8):
                self._convert_row(bwaddr, self.dda, y)
                bwaddr += bpl
        return self.iram[(self.dda + (offset & charmask)) & 0x7FF]

    cdef void _convert_buffer(self) noexcept:
        """Type 2: the eight bytes just written to $2240-$224F are one row of
        eight pixels each, and become one row of a character."""
        cdef int bpp = self._cc_bpp()
        cdef uint32_t addr = self.dda & 0x7FF
        cdef int half = (self.cc_line & 1) << 3
        cdef int byte, bit
        cdef uint8_t out

        if bpp == 2:
            addr &= <uint32_t>0x7F0
        elif bpp == 4:
            addr &= <uint32_t>0x7E0
        else:
            addr &= <uint32_t>0x7C0
        addr += <uint32_t>((self.cc_line & 6) << 1)
        self.n_cc2 += 1

        for byte in range(bpp):
            out = 0
            for bit in range(8):
                out |= <uint8_t>(((self.brf[half + bit] >> byte) & 1) << (7 - bit))
            self.iram[(addr + <uint32_t>((byte & 6) << 3)
                       + <uint32_t>(byte & 1)) & 0x7FF] = out
        self.cc_line = (self.cc_line + 1) & 7

    # =====================================================================
    # running
    # =====================================================================

    cdef void run_until(self, int64_t master_clock) noexcept:
        """Let the SA-1 catch up with the console."""
        cdef int64_t limit = master_clock
        if self.stopped:
            self.space.master_clock = limit
            return
        if self.space.master_clock > limit:
            return
        while self.space.master_clock < limit:
            self.cpu.step()
            if self.stopped:
                self.space.master_clock = limit
                self._check_timer()
                return
        self._check_timer()

    def describe(self):
        return self.name

    def status(self):
        """What the chip is doing, for the debugger and the test tools."""
        return {
            "stopped": self.stopped,
            "pc": (self.cpu.pb << 16) | self.cpu.pc,
            "clock": self.space.master_clock,
            "ccnt": self.ccnt, "scnt": self.scnt,
            "sie": self.sie, "cie": self.cie,
            "crv": self.crv, "cnv": self.cnv, "civ": self.civ,
            "snv": self.snv, "siv": self.siv,
            "mmc": [self.mmc[i] for i in range(4)],
            "bmaps": self.bmaps, "bmap": self.bmap,
            "sa1_irq": self.sa1_irq, "sa1_nmi": self.sa1_nmi,
            "scpu_irq": self.scpu_irq,
            "timer": {"tmc": self.tmc, "h": self.timer_h,
                      "v": self.timer_v, "irq": self.timer_irq,
                      "hcount": self._hcount(), "vcount": self._vcount()},
            "counts": {"cc1": self.n_cc1, "cc2": self.n_cc2,
                       "dma": self.n_dma, "math": self.n_math,
                       "varlen": self.n_varlen},
            "dma": {"dcnt": self.dcnt, "cdma": self.cdma,
                    "src": self.dsa, "dst": self.dda, "count": self.dtc},
        }


from snes.board import register
register("SA-1", SA1)
