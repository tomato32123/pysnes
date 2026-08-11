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
from libc.stdint cimport (uint8_t, uint16_t, uint32_t, int16_t,
                          int32_t, int64_t)
from libc.string cimport memset

from snes.board cimport Board, PK_DEVICE
from snes.cart cimport Cart
from snes.cpu cimport CPU
from snes.space cimport AddressSpace

# The SA-1 runs at three times the console's fastest rate: the S-CPU's
# quickest access is six master cycles and the SA-1's is two.
DEF SA1_CYCLE = 2


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
        self.hcount = 0
        self.vcount = 0
        self.dcnt = 0
        self.cdma = 0
        self.dsa = 0
        self.dda = 0
        self.dtc = 0
        self.cc_line = 0
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
                return self.bwram[self._bwram_window(from_sa1, off)]
            if off >= 0x8000:
                # The SA-1 can lend the console its own NMI and IRQ vectors,
                # which is how it hands work back: the console's handler ends
                # up somewhere the SA-1 chose rather than where the cartridge
                # header points.
                if not from_sa1 and (bank & 0x7F) == 0:
                    if (self.scnt & 0x10) and 0xFFEA <= off <= 0xFFEB:
                        return <uint8_t>(self.snv >> ((off & 1) * 8))
                    if (self.scnt & 0x20) and 0xFFEE <= off <= 0xFFEF:
                        return <uint8_t>(self.siv >> ((off & 1) * 8))
                return self.cart.rom[self._rom_offset(bank, off)]
            return data

        if 0x40 <= bank < 0x50:                      # battery RAM, laid flat
            if self.bwram_mask == 0:
                return data
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
            return <uint8_t>(self.hcount & 0xFF)
        if a == 0x2303:
            return <uint8_t>(self.hcount >> 8)
        if a == 0x2304:
            return <uint8_t>(self.vcount & 0xFF)
        if a == 0x2305:
            return <uint8_t>(self.vcount >> 8)

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
            self.hcount = 0
            self.vcount = 0
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
            if value & 0x80:                         # character conversion off
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
            # A destination in I-RAM starts the transfer here; one in BW-RAM
            # waits for the high byte.
            if (self.dcnt & 0x04) == 0:
                self._run_dma()
            return
        if a == 0x2237:
            self.dda = (self.dda & 0x00FFFF) | (<uint32_t>value << 16)
            if self.dcnt & 0x04:
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
        latter two.  Character conversion is a different unit and is not
        modelled; games that need it get their tiles unconverted."""
        cdef uint32_t src = self.dsa
        cdef uint32_t dst = self.dda
        cdef int n = self.dtc
        cdef int i

        if self.dcnt & 0x20:                         # character conversion
            return
        for i in range(n):
            self._write_common(dst + i, self._read_common(src + i, 1, 0), 1)
        self.dma_irq_scpu = 1
        self.dma_irq_sa1 = 1
        self._refresh_interrupts()

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
                return

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
            "dma": {"dcnt": self.dcnt, "cdma": self.cdma,
                    "src": self.dsa, "dst": self.dda, "count": self.dtc},
        }


from snes.board import register
register("SA-1", SA1)
