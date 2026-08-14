# cython: language_level=3
# cython: boundscheck=False, wraparound=False, cdivision=True
"""The SPC7110: four unrelated devices sharing one package and one register file.

A cartridge with this chip on it carries two ROMs, and the distinction runs
through everything else.  The *program* ROM is ordinary: the console fetches
its code from it and the chip is not involved.  The *data* ROM the console
cannot address at all -- it is behind the chip, it is much larger than the
address space has room for, and every byte of it arrives through one of the
chip's ports.  Momotarou Dentetsu Happy is 3 MB: 1 MB of program, 2 MB of
data.

The four devices, in the order the registers run:

  $4800-$480c  the decompression unit.  Graphics are stored packed; a write
               to $4806 starts a transfer and the unpacked bytes come out of
               $4800, one tile at a time.
  $4810-$481a  the data port: a cursor into the data ROM with a stride and an
               adjustment, so a game can walk a table without doing the
               arithmetic itself.
  $4820-$482f  a 16x16 multiplier and a 32/16 divider, signed or unsigned.
  $4830-$4834  the memory control unit: which megabyte of the data ROM each
               quarter of the address space shows, and whether the save RAM
               answers at all.

Only the first is hard.  The compression is a binary arithmetic coder with a
context model over the pixels already decoded, a move-to-front colour list,
and a 53-state probability ladder.  As with the S-DD1, none of that is
guessable and the table below is hardware design data: it is transcribed from
the public implementation by neviksti and talarubi rather than reasoned out
here.  The code around it is written here; the numbers are theirs.

There is also an RTC on some SPC7110 cartridges, at $4840-$4842, and which
cartridges those are is written into the header: Tengai Makyou Zero carries
chipset $F9 and has one, Momotarou Dentetsu Happy carries $F5 and does not.
It is an Epson part with sixteen four-bit registers holding the digits of the
time, reached through a little state machine -- a command saying whether this
exchange reads or writes, then a register number, then the nibbles, which
step on by themselves.  The register layout and that protocol are as ares
implements them.

The time it reports is this machine's, taken when the console asks.  A clock
that a game reads to decide what day it is has nothing to gain from being
emulated slowly.
"""
from cpython.bytes cimport PyBytes_FromStringAndSize
from libc.time cimport time, time_t, localtime, mktime, tm
from libc.stdint cimport (uint8_t, uint16_t, uint32_t, uint64_t,
                          int16_t, int32_t, int64_t)
from libc.string cimport memset, memcpy

from snes.board cimport Board, PK_OPENBUS, PK_DEVICE

# Master clocks in a second, which is what turns the console's clock into
# the wall clock the chip keeps.
cdef int64_t MASTER_HZ = 21477272


cdef int64_t days_from_civil(int y, int m, int d) noexcept:
    """A day number for a date, so two dates can be subtracted.

    Counting midnights by dividing a timestamp by 86400 counts them in UTC,
    which is not where the cartridge's midnight is; and counting them by day
    of the year goes wrong across a new year.  This is the usual civil-date
    algorithm, exact in both places.
    """
    cdef int64_t era, yoe, doy, doe
    if m <= 2:
        y -= 1
    era = (y if y >= 0 else y - 399) / 400
    yoe = y - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) / 5 + d - 1
    doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468


cdef int64_t local_day(int64_t seconds) noexcept:
    """Which day, in this machine's own reckoning, a timestamp falls on."""
    cdef time_t when = <time_t>seconds
    cdef tm *t = localtime(&when)
    if t is NULL:
        return 0
    return days_from_civil(t.tm_year + 1900, t.tm_mon + 1, t.tm_mday)
from snes.cart cimport Cart, _mirror


# The probability ladder.  Each state gives the probability of the more
# probable symbol, and where to go next when the more or the less probable
# symbol comes up.  The five runs are five ladders of different steepness;
# a context climbs within one of them.
cdef uint8_t EVO_PROB[53]
cdef uint8_t EVO_NEXT[53][2]
EVO_PROB[:] = [
    0x5a, 0x25, 0x11, 0x08, 0x03, 0x01,
    0x5a, 0x3f, 0x2c, 0x20, 0x17, 0x11, 0x0c, 0x09, 0x07, 0x05, 0x04, 0x03,
    0x02,
    0x5a, 0x48, 0x3a, 0x2e, 0x26, 0x1f, 0x19, 0x15, 0x11, 0x0e, 0x0b, 0x09,
    0x08, 0x07, 0x05, 0x04, 0x04, 0x03, 0x02, 0x02,
    0x58, 0x4d, 0x43, 0x3b, 0x34, 0x2e, 0x29, 0x25,
    0x56, 0x4f, 0x47, 0x41, 0x3c, 0x37,
]
_NEXT = [
    (1, 1), (2, 6), (3, 8), (4, 10), (5, 12), (5, 15),
    (7, 7), (8, 19), (9, 21), (10, 22), (11, 23), (12, 25), (13, 26),
    (14, 28), (15, 29), (16, 31), (17, 32), (18, 34), (5, 35),
    (20, 20), (21, 39), (22, 40), (23, 42), (24, 44), (25, 45), (26, 46),
    (27, 25), (28, 26), (29, 26), (30, 27), (31, 28), (32, 29), (33, 30),
    (34, 31), (35, 33), (36, 33), (37, 34), (38, 35), (5, 36),
    (40, 39), (41, 47), (42, 48), (43, 49), (44, 50), (45, 51), (46, 44),
    (24, 45),
    (48, 47), (49, 47), (50, 48), (51, 49), (52, 50), (43, 51),
]
for _i, (_mps, _lps) in enumerate(_NEXT):
    EVO_NEXT[_i][0] = _mps
    EVO_NEXT[_i][1] = _lps

DEF MPS = 0
DEF LPS = 1
DEF PROB_HALF = 0x55
DEF PROB_MAX = 0xFF


cdef uint64_t _deinterleave(uint64_t data, int bits) noexcept:
    """Inverse Morton transform: unpack big-endian packed pixels.

    The odd bits come back in the lower half and the even bits in the upper
    half, which is how a decoded run of pixels becomes two bitplanes."""
    data = data & ((<uint64_t>1 << bits) - 1)
    data = <uint64_t>0x5555555555555555 & ((data << bits) | (data >> 1))
    data = <uint64_t>0x3333333333333333 & (data | (data >> 1))
    data = <uint64_t>0x0f0f0f0f0f0f0f0f & (data | (data >> 2))
    data = <uint64_t>0x00ff00ff00ff00ff & (data | (data >> 4))
    data = <uint64_t>0x0000ffff0000ffff & (data | (data >> 8))
    return data | (data >> 16)


cdef uint64_t _move_to_front(uint64_t lst, uint32_t nibble) noexcept:
    """Pull `nibble` out of the sixteen-entry list and put it at the front.

    The colour list is most-recently-used ordered, so a pixel is coded as its
    position in that list rather than as its colour.  Runs of the same few
    colours -- which is most of a tile -- then code as small numbers."""
    cdef int n
    cdef uint64_t mask = ~(<uint64_t>15)
    for n in range(0, 64, 4):
        if ((lst >> n) & 15) == nibble:
            return (lst & mask) + ((lst << 4) & ~mask) + nibble
        mask <<= 4
    return lst


cdef class SPC7110(Board):

    def __cinit__(self, Cart cart):
        self.name = u"SPC7110"
        self.rom = cart.rom
        # Which of these cartridges has a clock is in the header: Tengai
        # Makyou Zero says $F9 and has one, Momotarou Dentetsu Happy says
        # $F5 and does not.
        self.has_rtc = 1 if (cart.coprocessor & 0x0F) == 0x09 else 0
        if self.has_rtc:
            self.name = u"SPC7110 + RTC"
        # The program ROM is the first megabyte of the image and the data ROM
        # is everything after it.  That split is the cartridge's wiring and
        # the image records nothing about it, so it is an assumption -- one
        # that holds for Momotarou Dentetsu Happy, whose own check program
        # runs out of the first megabyte and passes.  $4834 bit 2 asks for a
        # 2 MB program ROM instead; no cartridge here sets it, and a board
        # that did would need this split to come from somewhere better than a
        # constant.
        self.prom_size = 0x100000 if cart.rom_size > 0x100000 else cart.rom_size
        self.drom_base = self.prom_size
        self.drom_size = cart.rom_size - self.prom_size
        self.reset_board()

    cdef void reset_board(self) noexcept:
        cdef int i
        self.rtc_state = 0
        self.rtc_reading = 0
        self.rtc_index = 0
        self.rtc_reads = 0
        self.rtc_touches = 0
        self.rtc_dirty = 0
        self.rtc_trace_len = 0
        self.rtc_last_clock = 0
        self.rtc_seconds = <int64_t>time(NULL)
        for i in range(16):
            self.rtc[i] = 0
        self.rtc_powerup_weekday()
        self.r4801 = 0
        self.r4802 = 0
        self.r4803 = 0
        self.r4804 = 0
        self.r4805 = 0
        self.r4806 = 0
        self.r4807 = 0
        self.r4809 = 0
        self.r480a = 0
        self.r480b = 0
        self.r480c = 0
        self.dcu_mode = 0
        self.dcu_address = 0
        self.dcu_offset = 0
        memset(self.dcu_tile, 0, sizeof(self.dcu_tile))

        self.r4810 = 0
        self.r4811 = 0
        self.r4812 = 0
        self.r4813 = 0
        self.r4814 = 0
        self.r4815 = 0
        self.r4816 = 0
        self.r4817 = 0
        self.r4818 = 0
        self.r481a = 0

        self.r4820 = 0
        self.r4821 = 0
        self.r4822 = 0
        self.r4823 = 0
        self.r4824 = 0
        self.r4825 = 0
        self.r4826 = 0
        self.r4827 = 0
        self.r4828 = 0
        self.r4829 = 0
        self.r482a = 0
        self.r482b = 0
        self.r482c = 0
        self.r482d = 0
        self.r482e = 0
        self.r482f = 0

        # The three data-ROM windows come up showing megabytes 0, 1 and 2, so
        # a game that never writes them still reads straight through.
        self.r4830 = 0
        self.r4831 = 0
        self.r4832 = 1
        self.r4833 = 2
        self.r4834 = 0

        self.bpp = 1
        self.offset = 0
        self.bits = 8
        self.range_ = 0
        self.input_ = 0
        self.output = 0
        self.pixels = 0
        self.colormap = 0
        self.result = 0
        memset(self.ctx_prediction, 0, sizeof(self.ctx_prediction))
        memset(self.ctx_swap, 0, sizeof(self.ctx_swap))

    # =====================================================================
    # the map
    # =====================================================================

    cdef int classify(self, uint32_t bank, uint32_t addr, uint32_t *base) noexcept:
        """Almost everything is asked per access.

        The three window registers can be rewritten at any moment and a page
        table cannot follow that, so the ROM goes through `read` rather than
        being resolved once.  $50 and $58 are two whole banks that are really
        one register each: a DMA reading a run of addresses out of $50 gets a
        run of decompressed bytes.
        """
        base[0] = 0
        if bank == 0x50 or bank == 0x58:
            return PK_DEVICE
        if (bank & 0x7F) < 0x40:
            if 0x6000 <= addr < 0x8000:
                return PK_DEVICE                 # save RAM, if $4830 allows
            if addr >= 0x8000:
                return PK_DEVICE                 # program ROM through the MCU
            return PK_OPENBUS
        if bank >= 0xC0:
            return PK_DEVICE
        return PK_OPENBUS

    cdef uint8_t datarom_read(self, uint32_t addr) noexcept:
        """A byte of the data ROM.

        $4834's low two bits say how much of it the cartridge has, and the
        chip folds the address into that before it reaches the ROM -- so a
        game reading past the end reads its own data again rather than
        whatever the next chip select would have answered."""
        cdef uint32_t size = <uint32_t>1 << (self.r4834 & 3)
        cdef uint32_t mask = 0x100000 * size - 1
        cdef uint32_t off = addr & mask
        if (self.r4834 & 3) != 3 and (addr & 0x400000):
            return 0x00
        if self.drom_size == 0:
            return 0x00
        return self.rom[self.drom_base + _mirror(off, self.drom_size)]

    cdef uint8_t mcurom_read(self, uint32_t addr, uint8_t data) noexcept:
        """The console's view of ROM, as four megabyte-wide quarters.

        The first quarter is the program ROM.  The other three are windows
        into the data ROM, and $4831-$4833 say which megabyte each shows --
        which is how 3 MB of data reaches a console with room for one."""
        if addr < 0x100000:
            if self.prom_size:
                return self.rom[_mirror(addr & 0x0FFFFF, self.prom_size)]
            return self.datarom_read((addr & 0x0FFFFF)
                                     | (0x100000 * (self.r4830 & 7)))
        if addr < 0x200000:
            if self.r4834 & 4:                   # a 2 MB program ROM
                return self.rom[_mirror(addr, self.prom_size)]
            return self.datarom_read((addr & 0x0FFFFF)
                                     | (0x100000 * (self.r4831 & 7)))
        if addr < 0x300000:
            return self.datarom_read((addr & 0x0FFFFF)
                                     | (0x100000 * (self.r4832 & 7)))
        if addr < 0x400000:
            return self.datarom_read((addr & 0x0FFFFF)
                                     | (0x100000 * (self.r4833 & 7)))
        return data

    cdef uint8_t read(self, uint32_t addr, uint8_t data) noexcept:
        cdef uint32_t bank = (addr >> 16) & 0xFF
        cdef uint32_t off = addr & 0xFFFF
        cdef Cart c = self.cart

        # Two banks that are one register each, so a DMA can stream from them.
        if bank == 0x50:
            return self.read_reg(0x4800, data)
        if bank == 0x58:
            return self.read_reg(0x4808, data)

        if (bank & 0x7F) < 0x40:
            if 0x4800 <= off <= 0x483F:
                return self.read_reg(off, data)
            if self.has_rtc and 0x4840 <= off <= 0x4842:
                return self.rtc_read(off, data)
            if 0x6000 <= off < 0x8000:
                if not (self.r4830 & 0x80) or c.sram_size == 0:
                    return 0x00
                return c.sram[(((bank & 0x3F) << 13) | (off - 0x6000))
                              & c.sram_mask]
            if off >= 0x8000:
                return self.mcurom_read(((bank & 0x3F) << 16) | off, data)
            return data

        if bank >= 0xC0:
            return self.mcurom_read(((bank & 0x3F) << 16) | off, data)
        return data

    cdef uint8_t peek(self, uint32_t addr, uint8_t data) noexcept:
        """Memory only.  Reading $4800 decodes another tile and reading $4810
        moves the data cursor, so the debugger must not touch either."""
        cdef uint32_t bank = (addr >> 16) & 0xFF
        cdef uint32_t off = addr & 0xFFFF
        cdef Cart c = self.cart
        if (bank & 0x7F) < 0x40:
            if 0x6000 <= off < 0x8000:
                if not (self.r4830 & 0x80) or c.sram_size == 0:
                    return 0x00
                return c.sram[(((bank & 0x3F) << 13) | (off - 0x6000))
                              & c.sram_mask]
            if off >= 0x8000:
                return self.mcurom_read(((bank & 0x3F) << 16) | off, data)
            return data
        if bank >= 0xC0:
            return self.mcurom_read(((bank & 0x3F) << 16) | off, data)
        return data

    cdef void write(self, uint32_t addr, uint8_t value) noexcept:
        cdef uint32_t bank = (addr >> 16) & 0xFF
        cdef uint32_t off = addr & 0xFFFF
        cdef Cart c = self.cart

        if bank == 0x50:
            self.write_reg(0x4800, value)
            return
        if bank == 0x58:
            self.write_reg(0x4808, value)
            return

        if (bank & 0x7F) < 0x40:
            if 0x4800 <= off <= 0x483F:
                self.write_reg(off, value)
                return
            if self.has_rtc and 0x4840 <= off <= 0x4842:
                self.rtc_write(off, value)
                return
            if 0x6000 <= off < 0x8000:
                if (self.r4830 & 0x80) and c.sram_size:
                    c.sram[(((bank & 0x3F) << 13) | (off - 0x6000))
                           & c.sram_mask] = value
                return

    # =====================================================================
    # the registers
    # =====================================================================

    cdef uint8_t read_reg(self, uint32_t off, uint8_t data) noexcept:
        cdef uint16_t counter
        cdef uint8_t v
        off = 0x4800 | (off & 0x3F)

        if off == 0x4800:
            # The counter runs down as the transfer is read out, so a game can
            # arm a DMA of the right length and watch it finish.
            counter = <uint16_t>(self.r4809 | (<uint16_t>self.r480a << 8))
            counter -= 1
            self.r4809 = <uint8_t>counter
            self.r480a = <uint8_t>(counter >> 8)
            return self.dcu_read()
        if off == 0x4801:
            return self.r4801
        if off == 0x4802:
            return self.r4802
        if off == 0x4803:
            return self.r4803
        if off == 0x4804:
            return self.r4804
        if off == 0x4805:
            return self.r4805
        if off == 0x4806:
            return self.r4806
        if off == 0x4807:
            return self.r4807
        if off == 0x4808:
            return 0x00
        if off == 0x4809:
            return self.r4809
        if off == 0x480A:
            return self.r480a
        if off == 0x480B:
            return self.r480b
        if off == 0x480C:
            return self.r480c

        if off == 0x4810:
            v = self.r4810
            self.data_port_increment_4810()
            return v
        if off == 0x4811:
            return self.r4811
        if off == 0x4812:
            return self.r4812
        if off == 0x4813:
            return self.r4813
        if off == 0x4814:
            return self.r4814
        if off == 0x4815:
            return self.r4815
        if off == 0x4816:
            return self.r4816
        if off == 0x4817:
            return self.r4817
        if off == 0x4818:
            return self.r4818
        if off == 0x481A:
            self.data_port_increment_481a()
            return 0x00

        if off == 0x4820:
            return self.r4820
        if off == 0x4821:
            return self.r4821
        if off == 0x4822:
            return self.r4822
        if off == 0x4823:
            return self.r4823
        if off == 0x4824:
            return self.r4824
        if off == 0x4825:
            return self.r4825
        if off == 0x4826:
            return self.r4826
        if off == 0x4827:
            return self.r4827
        if off == 0x4828:
            return self.r4828
        if off == 0x4829:
            return self.r4829
        if off == 0x482A:
            return self.r482a
        if off == 0x482B:
            return self.r482b
        if off == 0x482C:
            return self.r482c
        if off == 0x482D:
            return self.r482d
        if off == 0x482E:
            return self.r482e
        if off == 0x482F:
            return self.r482f

        if off == 0x4830:
            return self.r4830
        if off == 0x4831:
            return self.r4831
        if off == 0x4832:
            return self.r4832
        if off == 0x4833:
            return self.r4833
        if off == 0x4834:
            return self.r4834
        return data

    cdef void write_reg(self, uint32_t off, uint8_t value) noexcept:
        off = 0x4800 | (off & 0x3F)

        if off == 0x4801:
            self.r4801 = value
        elif off == 0x4802:
            self.r4802 = value
        elif off == 0x4803:
            self.r4803 = value
        elif off == 0x4804:
            self.r4804 = value
            self.dcu_load_address()
        elif off == 0x4805:
            self.r4805 = value
        elif off == 0x4806:
            # Writing the high half of the length is what starts a transfer.
            self.r4806 = value
            self.r480c &= 0x7F
            self.dcu_begin_transfer()
        elif off == 0x4807:
            self.r4807 = value
        elif off == 0x4809:
            self.r4809 = value
        elif off == 0x480A:
            self.r480a = value
        elif off == 0x480B:
            self.r480b = value & 0x03

        elif off == 0x4811:
            self.r4811 = value
        elif off == 0x4812:
            self.r4812 = value
        elif off == 0x4813:
            self.r4813 = value
            self.data_port_read()
        elif off == 0x4814:
            self.r4814 = value
            self.data_port_increment_4814()
        elif off == 0x4815:
            self.r4815 = value
            if self.r4818 & 2:
                self.data_port_read()
            self.data_port_increment_4815()
        elif off == 0x4816:
            self.r4816 = value
        elif off == 0x4817:
            self.r4817 = value
        elif off == 0x4818:
            self.r4818 = value & 0x7F
            self.data_port_read()

        elif off == 0x4820:
            self.r4820 = value
        elif off == 0x4821:
            self.r4821 = value
        elif off == 0x4822:
            self.r4822 = value
        elif off == 0x4823:
            self.r4823 = value
        elif off == 0x4824:
            self.r4824 = value
        elif off == 0x4825:
            # The high half of the multiplier starts the multiply, as the
            # high half of the divisor starts the divide.
            self.r4825 = value
            self.r482f |= 0x81
            self.alu_multiply()
        elif off == 0x4826:
            self.r4826 = value
        elif off == 0x4827:
            self.r4827 = value
            self.r482f |= 0x80
            self.alu_divide()
        elif off == 0x482E:
            self.r482e = value & 0x01

        elif off == 0x4830:
            self.r4830 = value & 0x87
        elif off == 0x4831:
            self.r4831 = value & 0x07
        elif off == 0x4832:
            self.r4832 = value & 0x07
        elif off == 0x4833:
            self.r4833 = value & 0x07
        elif off == 0x4834:
            self.r4834 = value & 0x07

    # =====================================================================
    # the decompression unit
    # =====================================================================

    cdef void dcu_load_address(self) noexcept:
        """$4801-$4803 point at a directory in the data ROM and $4804 indexes
        it.  Each four-byte entry is a mode and a 24-bit address, so a game
        asks for "picture 37" rather than knowing where it lives."""
        cdef uint32_t table = (self.r4801 | (<uint32_t>self.r4802 << 8)
                               | (<uint32_t>self.r4803 << 16))
        cdef uint32_t address = table + (<uint32_t>self.r4804 << 2)
        self.dcu_mode = self.datarom_read(address + 0)
        self.dcu_address = (<uint32_t>self.datarom_read(address + 1) << 16)
        self.dcu_address |= (<uint32_t>self.datarom_read(address + 2) << 8)
        self.dcu_address |= self.datarom_read(address + 3)

    cdef void dcu_begin_transfer(self) noexcept:
        """Start decoding.  $480b bit 1 asks to skip a number of tiles first,
        which is how a game reads the middle of a picture without unpacking
        what comes before it -- except that it does unpack it, and throws it
        away, because the coder has no other way to get there."""
        cdef uint32_t seek
        if self.dcu_mode == 3:
            return                               # not a mode the chip has
        self.dec_initialize(self.dcu_mode, self.dcu_address)
        self.dec_decode()
        seek = (self.r4805 | (<uint32_t>self.r4806 << 8)) if (self.r480b & 2) else 0
        while seek:
            self.dec_decode()
            seek -= 1
        self.r480c |= 0x80
        self.dcu_offset = 0

    cdef uint8_t dcu_read(self) noexcept:
        """Hand back the next byte of the tile, decoding another one when the
        last is exhausted.  The chip emits whole 8x8 tiles in the PPU's own
        bitplane order, so the DMA that reads this can go straight to VRAM."""
        cdef int row
        cdef uint32_t seek
        cdef uint8_t data
        if (self.r480c & 0x80) == 0:
            return 0x00

        if self.dcu_offset == 0:
            for row in range(8):
                if self.bpp == 1:
                    self.dcu_tile[row] = <uint8_t>self.result
                elif self.bpp == 2:
                    self.dcu_tile[row * 2 + 0] = <uint8_t>self.result
                    self.dcu_tile[row * 2 + 1] = <uint8_t>(self.result >> 8)
                elif self.bpp == 4:
                    self.dcu_tile[row * 2 + 0] = <uint8_t>self.result
                    self.dcu_tile[row * 2 + 1] = <uint8_t>(self.result >> 8)
                    self.dcu_tile[row * 2 + 16] = <uint8_t>(self.result >> 16)
                    self.dcu_tile[row * 2 + 17] = <uint8_t>(self.result >> 24)
                # $480b bit 0 turns $4807 into a row stride, for reading a
                # picture out in a different order than it was packed.
                seek = self.r4807 if (self.r480b & 1) else 1
                while seek:
                    self.dec_decode()
                    seek -= 1

        data = self.dcu_tile[self.dcu_offset]
        self.dcu_offset += 1
        self.dcu_offset &= <uint32_t>(8 * self.bpp - 1)
        return data

    # =====================================================================
    # the data port
    # =====================================================================

    cdef uint32_t data_offset(self) noexcept:
        return (self.r4811 | (<uint32_t>self.r4812 << 8)
                | (<uint32_t>self.r4813 << 16))

    cdef uint32_t data_adjust(self) noexcept:
        return self.r4814 | (<uint32_t>self.r4815 << 8)

    cdef uint32_t data_stride(self) noexcept:
        return self.r4816 | (<uint32_t>self.r4817 << 8)

    cdef void set_data_offset(self, uint32_t addr) noexcept:
        self.r4811 = <uint8_t>addr
        self.r4812 = <uint8_t>(addr >> 8)
        self.r4813 = <uint8_t>(addr >> 16)

    cdef void set_data_adjust(self, uint32_t addr) noexcept:
        self.r4814 = <uint8_t>addr
        self.r4815 = <uint8_t>(addr >> 8)

    cdef void data_port_read(self) noexcept:
        cdef uint32_t offset = self.data_offset()
        cdef uint32_t adjust = self.data_adjust() if (self.r4818 & 2) else 0
        if self.r4818 & 8:
            adjust = <uint32_t><int32_t><int16_t>adjust
        self.r4810 = self.datarom_read(offset + adjust)

    cdef void data_port_increment_4810(self) noexcept:
        cdef uint32_t offset = self.data_offset()
        cdef uint32_t stride = self.data_stride() if (self.r4818 & 1) else 1
        cdef uint32_t adjust = self.data_adjust()
        if self.r4818 & 4:
            stride = <uint32_t><int32_t><int16_t>stride
        if self.r4818 & 8:
            adjust = <uint32_t><int32_t><int16_t>adjust
        if (self.r4818 & 16) == 0:
            self.set_data_offset(offset + stride)
        else:
            self.set_data_adjust(adjust + stride)
        self.data_port_read()

    cdef void data_port_increment_4814(self) noexcept:
        cdef uint32_t offset, adjust
        if (self.r4818 >> 5) != 1:
            return
        offset = self.data_offset()
        adjust = self.data_adjust()
        if self.r4818 & 8:
            adjust = <uint32_t><int32_t><int16_t>adjust
        self.set_data_offset(offset + adjust)
        self.data_port_read()

    cdef void data_port_increment_4815(self) noexcept:
        cdef uint32_t offset, adjust
        if (self.r4818 >> 5) != 2:
            return
        offset = self.data_offset()
        adjust = self.data_adjust()
        if self.r4818 & 8:
            adjust = <uint32_t><int32_t><int16_t>adjust
        self.set_data_offset(offset + adjust)
        self.data_port_read()

    cdef void data_port_increment_481a(self) noexcept:
        cdef uint32_t offset, adjust
        if (self.r4818 >> 5) != 3:
            return
        offset = self.data_offset()
        adjust = self.data_adjust()
        if self.r4818 & 8:
            adjust = <uint32_t><int32_t><int16_t>adjust
        self.set_data_offset(offset + adjust)
        self.data_port_read()

    # =====================================================================
    # the arithmetic unit
    # =====================================================================

    cdef void alu_multiply(self) noexcept:
        cdef int32_t sresult
        cdef uint32_t uresult
        if self.r482e & 1:
            sresult = (<int32_t><int16_t>(self.r4824 | (<uint16_t>self.r4825 << 8))
                       * <int32_t><int16_t>(self.r4820 | (<uint16_t>self.r4821 << 8)))
            uresult = <uint32_t>sresult
        else:
            uresult = (<uint32_t>(self.r4824 | (<uint16_t>self.r4825 << 8))
                       * <uint32_t>(self.r4820 | (<uint16_t>self.r4821 << 8)))
        self.r4828 = <uint8_t>uresult
        self.r4829 = <uint8_t>(uresult >> 8)
        self.r482a = <uint8_t>(uresult >> 16)
        self.r482b = <uint8_t>(uresult >> 24)
        self.r482f &= 0x7F

    cdef void alu_divide(self) noexcept:
        cdef int32_t sdividend, squotient
        cdef int16_t sdivisor, sremainder
        cdef uint32_t udividend, uquotient
        cdef uint16_t udivisor, uremainder
        if self.r482e & 1:
            sdividend = <int32_t>(self.r4820 | (<uint32_t>self.r4821 << 8)
                                  | (<uint32_t>self.r4822 << 16)
                                  | (<uint32_t>self.r4823 << 24))
            sdivisor = <int16_t>(self.r4826 | (<uint16_t>self.r4827 << 8))
            if sdivisor:
                squotient = sdividend // sdivisor
                sremainder = <int16_t>(sdividend % sdivisor)
            else:
                # Dividing by zero is not defined by anything; the chip leaves
                # the dividend in the remainder and zeroes the quotient.
                squotient = 0
                sremainder = <int16_t>sdividend
            self.r4828 = <uint8_t>squotient
            self.r4829 = <uint8_t>(squotient >> 8)
            self.r482a = <uint8_t>(squotient >> 16)
            self.r482b = <uint8_t>(<uint32_t>squotient >> 24)
            self.r482c = <uint8_t>sremainder
            self.r482d = <uint8_t>(<uint16_t>sremainder >> 8)
        else:
            udividend = (self.r4820 | (<uint32_t>self.r4821 << 8)
                         | (<uint32_t>self.r4822 << 16)
                         | (<uint32_t>self.r4823 << 24))
            udivisor = <uint16_t>(self.r4826 | (<uint16_t>self.r4827 << 8))
            if udivisor:
                uquotient = udividend // udivisor
                uremainder = <uint16_t>(udividend % udivisor)
            else:
                uquotient = 0
                uremainder = <uint16_t>udividend
            self.r4828 = <uint8_t>uquotient
            self.r4829 = <uint8_t>(uquotient >> 8)
            self.r482a = <uint8_t>(uquotient >> 16)
            self.r482b = <uint8_t>(uquotient >> 24)
            self.r482c = <uint8_t>uremainder
            self.r482d = <uint8_t>(uremainder >> 8)
        self.r482f &= 0x7F

    # =====================================================================
    # the decompressor
    # =====================================================================

    cdef uint8_t dec_read(self) noexcept:
        cdef uint8_t v = self.datarom_read(self.offset)
        self.offset += 1
        return v

    cdef void dec_initialize(self, int mode, uint32_t origin) noexcept:
        memset(self.ctx_prediction, 0, sizeof(self.ctx_prediction))
        memset(self.ctx_swap, 0, sizeof(self.ctx_swap))
        self.bpp = 1 << mode
        self.offset = origin
        self.bits = 8
        self.range_ = PROB_MAX + 1
        self.input_ = self.dec_read()
        self.input_ = <uint16_t>((self.input_ << 8) | self.dec_read())
        self.output = 0
        self.pixels = 0
        # The colour list starts in order, so the first pixel of a picture
        # codes as itself.
        self.colormap = <uint64_t>0xfedcba9876543210

    cdef void dec_decode(self) noexcept:
        """Decode one row of eight pixels.

        Every bit is a binary decision taken against a probability that
        depends on where the bit sits in the tile and on how the three
        neighbouring pixels compare -- which is the whole of the compression:
        a pixel that matches its neighbours costs almost nothing to say."""
        cdef int pixel, plane, set_, prediction, symbol, index
        cdef uint32_t pa, pb, pc, match, diff, bit, history
        cdef uint64_t map_
        cdef uint8_t probability, lps_offset, swap

        for pixel in range(8):
            map_ = self.colormap
            diff = 0

            if self.bpp > 1:
                # The pixel to the left, above, and above-left.
                if self.bpp == 2:
                    pa = <uint32_t>(self.pixels >> 2) & 3
                    pb = <uint32_t>(self.pixels >> 14) & 3
                    pc = <uint32_t>(self.pixels >> 16) & 3
                else:
                    pa = <uint32_t>(self.pixels >> 0) & 15
                    pb = <uint32_t>(self.pixels >> 28) & 15
                    pc = <uint32_t>(self.pixels >> 32) & 15

                if pa != pb or pb != pc:
                    match = pa ^ pb ^ pc
                    diff = 4                     # no match: all three differ
                    if (match ^ pc) == 0:
                        diff = 3                 # a == b, c differs
                    if (match ^ pb) == 0:
                        diff = 2                 # c == a, b differs
                    if (match ^ pa) == 0:
                        diff = 1                 # b == c, a differs

                self.colormap = _move_to_front(self.colormap, pa)

                map_ = _move_to_front(map_, pc)
                map_ = _move_to_front(map_, pb)
                map_ = _move_to_front(map_, pa)

            for plane in range(self.bpp):
                bit = (<uint32_t>1 << plane) if self.bpp > 1 \
                    else (<uint32_t>1 << (pixel & 3))
                history = (bit - 1) & self.output
                set_ = 0

                if self.bpp == 1:
                    set_ = 1 if pixel >= 4 else 0
                if self.bpp == 2:
                    set_ = diff
                if plane >= 2 and history <= 1:
                    set_ = diff

                index = <int>(bit + history - 1)
                prediction = self.ctx_prediction[set_][index]
                swap = self.ctx_swap[set_][index]
                probability = EVO_PROB[prediction]
                # Deliberately eight bits wide: the chip's comparison is on
                # the top byte only, and the truncation is part of the coder.
                lps_offset = <uint8_t>(self.range_ - probability)
                symbol = 1 if self.input_ >= (<uint16_t>lps_offset << 8) else 0

                self.output = <uint8_t>((self.output << 1) | (symbol ^ swap))

                if symbol == MPS:                # [0 ... range-p]
                    self.range_ = lps_offset
                else:                            # [range-p+1 ... range]
                    self.range_ -= lps_offset
                    self.input_ = <uint16_t>(self.input_
                                             - (<uint16_t>lps_offset << 8))

                while self.range_ <= PROB_MAX / 2:
                    # Renormalising is also when the model moves: a context
                    # only climbs the ladder on a decision that narrowed the
                    # range enough to need it.
                    self.ctx_prediction[set_][index] = EVO_NEXT[prediction][symbol]
                    self.range_ = <uint16_t>(self.range_ << 1)
                    self.input_ = <uint16_t>(self.input_ << 1)
                    self.bits -= 1
                    if self.bits == 0:
                        self.bits = 8
                        self.input_ = <uint16_t>(self.input_ + self.dec_read())

                if symbol == LPS and probability > PROB_HALF:
                    self.ctx_swap[set_][index] = swap ^ 1

            index = <int>(self.output & ((1 << self.bpp) - 1))
            if self.bpp == 1:
                index ^= <int>((self.pixels >> 15) & 1)

            self.pixels = (self.pixels << self.bpp) | ((map_ >> (4 * index)) & 15)

        if self.bpp == 1:
            self.result = <uint32_t>self.pixels
        elif self.bpp == 2:
            self.result = <uint32_t>_deinterleave(self.pixels, 16)
        else:
            self.result = <uint32_t>_deinterleave(_deinterleave(self.pixels, 32), 32)

    # -- save state (generated by tools/gen_state.py; do not edit) --------

    def state_ints(self):
        cdef int i, j
        v = [self.prom_size, self.drom_base, self.drom_size, self.r4801, self.r4802, self.r4803, self.r4804, self.r4805, self.r4806, self.r4807, self.r4809, self.r480a, self.r480b, self.r480c, self.dcu_mode, self.dcu_address, self.dcu_offset, self.r4810, self.r4811, self.r4812, self.r4813, self.r4814, self.r4815, self.r4816, self.r4817, self.r4818, self.r481a, self.r4820, self.r4821, self.r4822, self.r4823, self.r4824, self.r4825, self.r4826, self.r4827, self.r4828, self.r4829, self.r482a, self.r482b, self.r482c, self.r482d, self.r482e, self.r482f, self.r4830, self.r4831, self.r4832, self.r4833, self.r4834, self.bpp, self.offset, self.bits, self.range_, self.input_, self.output, self.pixels, self.colormap, self.result, self.rtc_state, self.rtc_reading, self.rtc_index, self.rtc_reads, self.rtc_touches, self.rtc_seconds, self.rtc_last_clock, self.rtc_dirty]
        for i in range(32):
            v.append(self.dcu_tile[i])
        for i in range(16):
            v.append(self.rtc[i])
        for i in range(5):
            for j in range(15):
                v.append(self.ctx_prediction[i][j])
        for i in range(5):
            for j in range(15):
                v.append(self.ctx_swap[i][j])
        return v

    def load_ints(self, v):
        cdef int i, j, k = 65
        self.prom_size = v[0]
        self.drom_base = v[1]
        self.drom_size = v[2]
        self.r4801 = v[3]
        self.r4802 = v[4]
        self.r4803 = v[5]
        self.r4804 = v[6]
        self.r4805 = v[7]
        self.r4806 = v[8]
        self.r4807 = v[9]
        self.r4809 = v[10]
        self.r480a = v[11]
        self.r480b = v[12]
        self.r480c = v[13]
        self.dcu_mode = v[14]
        self.dcu_address = v[15]
        self.dcu_offset = v[16]
        self.r4810 = v[17]
        self.r4811 = v[18]
        self.r4812 = v[19]
        self.r4813 = v[20]
        self.r4814 = v[21]
        self.r4815 = v[22]
        self.r4816 = v[23]
        self.r4817 = v[24]
        self.r4818 = v[25]
        self.r481a = v[26]
        self.r4820 = v[27]
        self.r4821 = v[28]
        self.r4822 = v[29]
        self.r4823 = v[30]
        self.r4824 = v[31]
        self.r4825 = v[32]
        self.r4826 = v[33]
        self.r4827 = v[34]
        self.r4828 = v[35]
        self.r4829 = v[36]
        self.r482a = v[37]
        self.r482b = v[38]
        self.r482c = v[39]
        self.r482d = v[40]
        self.r482e = v[41]
        self.r482f = v[42]
        self.r4830 = v[43]
        self.r4831 = v[44]
        self.r4832 = v[45]
        self.r4833 = v[46]
        self.r4834 = v[47]
        self.bpp = v[48]
        self.offset = v[49]
        self.bits = v[50]
        self.range_ = v[51]
        self.input_ = v[52]
        self.output = v[53]
        self.pixels = v[54]
        self.colormap = v[55]
        self.result = v[56]
        self.rtc_state = v[57]
        self.rtc_reading = v[58]
        self.rtc_index = v[59]
        self.rtc_reads = v[60]
        self.rtc_touches = v[61]
        self.rtc_seconds = v[62]
        self.rtc_last_clock = v[63]
        self.rtc_dirty = v[64]
        for i in range(32):
            self.dcu_tile[i] = v[k + i]
        k += 32
        for i in range(16):
            self.rtc[i] = v[k + i]
        k += 16
        for i in range(5):
            for j in range(15):
                self.ctx_prediction[i][j] = v[k + i * 15 + j]
        k += 75
        for i in range(5):
            for j in range(15):
                self.ctx_swap[i][j] = v[k + i * 15 + j]
        k += 75

    def state_blobs(self):
        return []

    def load_blobs(self, blobs):
        pass

    # -- end generated save state ------------------------------------------


    # -- introspection ------------------------------------------------------

    def registers(self):
        return dict(
            prom=self.prom_size, drom=self.drom_size,
            dcu=dict(mode=self.dcu_mode, address=self.dcu_address,
                     ready=bool(self.r480c & 0x80), offset=self.dcu_offset,
                     bpp=self.bpp, r480b=self.r480b, r4807=self.r4807),
            data=dict(offset=self.data_offset(), adjust=self.data_adjust(),
                      stride=self.data_stride(), mode=self.r4818,
                      value=self.r4810),
            alu=dict(mode=self.r482e, status=self.r482f,
                     result=(self.r4828 | (self.r4829 << 8)
                             | (self.r482a << 16) | (self.r482b << 24)),
                     remainder=self.r482c | (self.r482d << 8)),
            mcu=dict(ram=bool(self.r4830 & 0x80),
                     banks=[self.r4831, self.r4832, self.r4833],
                     size=self.r4834),
        )

    def decompress(self, mode, address, tiles=1):
        """Unpack `tiles` tiles starting at `address`, for tests.

        The register path is how a game does it; this is the same work with
        the plumbing taken off, so a test can compare bytes without driving a
        65816 program to ask for them."""
        cdef int i
        out = bytearray()
        self.dec_initialize(mode, address)
        for i in range(tiles * 8):
            self.dec_decode()
            if self.bpp == 1:
                out.append(self.result & 0xFF)
            elif self.bpp == 2:
                out.append(self.result & 0xFF)
                out.append((self.result >> 8) & 0xFF)
            else:
                out.append(self.result & 0xFF)
                out.append((self.result >> 8) & 0xFF)
                out.append((self.result >> 16) & 0xFF)
                out.append((self.result >> 24) & 0xFF)
        return bytes(out)


    # =====================================================================
    # the clock
    # =====================================================================

    cdef void rtc_powerup_weekday(self) noexcept:
        """A cartridge coming up for the first time has to start somewhere,
        and this machine's weekday is a better guess than zero."""
        cdef time_t now = <time_t>self.rtc_seconds
        cdef tm *t = localtime(&now)
        if t is not NULL:
            self.rtc[12] = <uint8_t>t.tm_wday

    cdef void rtc_advance(self) noexcept:
        """Move the clock on by however long the console has been running.

        The chip keeps its own time.  It is set to this machine's when the
        cartridge is powered on, and after that it runs -- so a game that
        writes a time and reads it back gets what it wrote, which is what
        the cartridge's own check program looks for.  Register 15 bit 1
        stops it and register 13 bit 0 holds it.
        """
        cdef int64_t elapsed
        cdef int64_t was
        cdef int64_t days
        if self.rtc_last_clock == 0:
            self.rtc_last_clock = self.clock
            return
        elapsed = self.clock - self.rtc_last_clock
        if elapsed < MASTER_HZ:
            return
        self.rtc_last_clock += (elapsed / MASTER_HZ) * MASTER_HZ
        if (self.rtc[15] & 2) or (self.rtc[13] & 1):
            return
        was = local_day(self.rtc_seconds)
        self.rtc_seconds += elapsed / MASTER_HZ
        # The weekday is not worked out from the date -- the chip does not
        # know what day of the week a date is, and the cartridge's own check
        # program proves it: it writes 31 December '99 with weekday 6 and
        # expects 6 back, where the calendar says Thursday.  It is a counter
        # the game sets, and all the chip does is carry it at midnight.
        days = local_day(self.rtc_seconds) - was
        if days > 0:
            self.rtc[12] = <uint8_t>((self.rtc[12] + days) % 7)

    cdef void rtc_from_digits(self) noexcept:
        """Take the time back out of the registers, after a game wrote them."""
        cdef tm t
        cdef int hour = (self.rtc[5] & 3) * 10 + self.rtc[4]
        cdef time_t made
        if not (self.rtc[15] & 4):
            # Twelve-hour form: register 5 bit 2 says which half of the day.
            hour = hour % 12
            if self.rtc[5] & 4:
                hour += 12
        t.tm_sec = (self.rtc[1] & 7) * 10 + self.rtc[0]
        t.tm_min = (self.rtc[3] & 7) * 10 + self.rtc[2]
        t.tm_hour = hour
        t.tm_mday = (self.rtc[7] & 3) * 10 + self.rtc[6]
        t.tm_mon = ((self.rtc[9] & 1) * 10 + self.rtc[8]) - 1
        # Two digits of year, which the chip is all that holds; the century
        # is the one the machine is in.
        t.tm_year = (self.rtc[11] * 10 + self.rtc[10]) + 100
        t.tm_isdst = -1
        made = mktime(&t)
        if made != <time_t>-1:
            self.rtc_seconds = made
        self.rtc_dirty = 0

    cdef void rtc_sync(self) noexcept:
        """Fill the registers from the time the chip is holding.

        The registers hold decimal digits a nibble at a time, so each field
        is split into its tens and units.
        """
        cdef time_t now
        cdef tm *t
        if self.rtc_dirty:
            self.rtc_from_digits()
        now = <time_t>self.rtc_seconds
        t = localtime(&now)
        cdef int hour
        cdef int pm = 0
        if t is NULL:
            return
        hour = t.tm_hour
        # Register 15 bit 2 chooses the 24-hour clock; without it the hours
        # run 1 to 12 and register 5 bit 2 says which half of the day.
        if not (self.rtc[15] & 4):
            pm = 1 if hour >= 12 else 0
            hour = hour % 12
            if hour == 0:
                hour = 12
        self.rtc[0] = t.tm_sec % 10
        self.rtc[1] = (self.rtc[1] & 8) | (t.tm_sec / 10)
        self.rtc[2] = t.tm_min % 10
        self.rtc[3] = (self.rtc[3] & 8) | (t.tm_min / 10)
        self.rtc[4] = hour % 10
        self.rtc[5] = (self.rtc[5] & 8) | (hour / 10) | (4 if pm else 0)
        self.rtc[6] = t.tm_mday % 10
        self.rtc[7] = (self.rtc[7] & 0x0C) | (t.tm_mday / 10)
        self.rtc[8] = (t.tm_mon + 1) % 10
        self.rtc[9] = (self.rtc[9] & 0x0A) | ((t.tm_mon + 1) / 10)
        self.rtc[10] = (t.tm_year + 1900) % 10
        self.rtc[11] = ((t.tm_year + 1900) / 10) % 10

    cdef uint8_t rtc_read(self, uint32_t off, uint8_t data) noexcept:
        cdef uint8_t value
        cdef uint8_t answer
        self.rtc_touches += 1
        self.rtc_advance()
        if off == 0x4842:
            # Bit 7 says a transfer may happen.  Nothing here takes time.
            return 0x80
        if off == 0x4841:
            answer = 0
            if self.rtc_state == 4:
                answer = self.rtc[self.rtc_index & 15] & 15
                self.rtc_index = (self.rtc_index + 1) & 15
                self.rtc_reads += 1
            if self.rtc_trace_len < 512:
                self.rtc_trace[0][self.rtc_trace_len] = 0x41
                self.rtc_trace[1][self.rtc_trace_len] = 0
                self.rtc_trace[2][self.rtc_trace_len] = answer
                self.rtc_trace_len += 1
            return answer
        return data

    cdef void rtc_write(self, uint32_t off, uint8_t value) noexcept:
        self.rtc_touches += 1
        self.rtc_advance()
        if self.rtc_trace_len < 512:
            self.rtc_trace[0][self.rtc_trace_len] = off & 0xFF
            self.rtc_trace[1][self.rtc_trace_len] = 1
            self.rtc_trace[2][self.rtc_trace_len] = value
            self.rtc_trace_len += 1
        if off == 0x4840:
            # The chip select: raising it starts an exchange, dropping it
            # ends whatever was in progress.
            if value & 1:
                self.rtc_state = 1
            else:
                self.rtc_state = 0
                # The digits a game just wrote are the time from now on.
                if self.rtc_dirty:
                    self.rtc_from_digits()
            return
        if off != 0x4841:
            return
        if self.rtc_state == 1:
            # $03 begins a write, $0C a read; anything else is not a command.
            if value == 0x03:
                self.rtc_reading = 0
                self.rtc_state = 2
            elif value == 0x0C:
                self.rtc_reading = 1
                self.rtc_state = 2
                self.rtc_sync()
            return
        if self.rtc_state == 2:
            self.rtc_index = value & 15
            self.rtc_state = 4 if self.rtc_reading else 3
            return
        if self.rtc_state == 3:
            self.rtc[self.rtc_index & 15] = value & 15
            if (self.rtc_index & 15) < 13:
                self.rtc_dirty = 1       # a digit changed: this is the time now
            self.rtc_index = (self.rtc_index + 1) & 15

    def rtc_drive(self, uint32_t off, value=None):
        """Read or write one of the clock's three addresses.

        The same entry points the console reaches through the bus, called
        directly so a test can run the protocol against a real cartridge --
        the only one that has this part does not read its clock in the
        first minute after boot, and waiting for it is not a test.
        """
        if value is None:
            return self.rtc_read(off, 0)
        self.rtc_write(off, value)
        return None

    @property
    def rtc_registers(self):
        return [self.rtc[i] for i in range(16)]

    @property
    def rtc_read_count(self):
        return self.rtc_reads

    @property
    def rtc_touch_count(self):
        return self.rtc_touches

    @property
    def rtc_exchanges(self):
        """[(address, is_write, value)] for what the game asked of it."""
        return [(self.rtc_trace[0][i], self.rtc_trace[1][i], self.rtc_trace[2][i])
                for i in range(self.rtc_trace_len)]


def tables():
    """The transcribed ladder, so a test can look for a typo in it."""
    return [(EVO_PROB[i], EVO_NEXT[i][0], EVO_NEXT[i][1]) for i in range(53)]



from snes.board import register
register("SPC7110", SPC7110)
