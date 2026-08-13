# cython: language_level=3
# cython: boundscheck=False, wraparound=False, cdivision=True
"""The S-DD1: a decompressor on the cartridge, and the mapper it sits behind.

Two separate things share the same chip and the same eight registers, and
they are worth keeping apart in one's head.

The first is a memory mapper.  A 32 Mbit S-DD1 cartridge does not fit any
standard map, so banks $C0-$FF are a 4 MB window made of four 1 MB slots, and
$4804-$4807 say which megabyte of ROM each slot shows.  Street Fighter Zero 2
jumps to $C0:0000 as the third instruction after reset, so nothing at all
happens without this part.

The second is the decompressor proper: graphics are stored packed and are
unpacked on the way through DMA rather than by the CPU.  A channel armed
through $4800 and $4801 reads from the chip instead of from the ROM, and the
address it thinks it is reading from is only the place the packed data
starts.

The compression is Ricoh's ABS: adaptive binary arithmetic-free coding, run
lengths through Golomb codes with a probability state per context.  Nothing
about it is guessable, and the two sets of constants below -- the 33-state
probability evolution table and the run-length table -- are hardware design
data rather than anything derivable, so they are transcribed from the public
description of the algorithm reverse-engineered by Andreas Naive, with The
Dumper's hardware data and John Weidman's and Brad Jorsch's work on top of
it.  The code around them is written here; the numbers are theirs.
"""
from cpython.bytes cimport PyBytes_FromStringAndSize
from libc.stdint cimport uint8_t, uint16_t, uint32_t
from libc.string cimport memset, memcpy

from snes.board cimport Board, PK_OPENBUS, PK_ROM, PK_SRAM, PK_DEVICE
from snes.cart cimport Cart


# Probability states.  Each says which Golomb code size to read a run with,
# and which state to move to when the more or the less probable symbol comes
# up.  States 25 upwards are the fast path taken on a fresh context.
cdef uint8_t EVO_SIZE[33]
cdef uint8_t EVO_MPS[33]
cdef uint8_t EVO_LPS[33]
EVO_SIZE[:] = [0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 5,
               5, 6, 6, 7, 7, 0, 1, 2, 3, 4, 5, 6, 7]
EVO_MPS[:] = [25, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17,
              18, 19, 20, 21, 22, 23, 24, 24, 26, 27, 28, 29, 30, 31, 32, 24]
EVO_LPS[:] = [25, 1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
              16, 17, 18, 19, 20, 21, 22, 23, 1, 2, 4, 8, 12, 16, 18, 22]

# A codeword's remaining run length, indexed by the bits that followed it.
cdef uint8_t RUN_TABLE[128]
RUN_TABLE[:] = [
    128,  64,  96,  32, 112,  48,  80,  16, 120,  56,  88,  24, 104,  40,  72,
      8, 124,  60,  92,  28, 108,  44,  76,  12, 116,  52,  84,  20, 100,  36,
     68,   4, 126,  62,  94,  30, 110,  46,  78,  14, 118,  54,  86,  22, 102,
     38,  70,   6, 122,  58,  90,  26, 106,  42,  74,  10, 114,  50,  82,  18,
     98,  34,  66,   2, 127,  63,  95,  31, 111,  47,  79,  15, 119,  55,  87,
     23, 103,  39,  71,   7, 123,  59,  91,  27, 107,  43,  75,  11, 115,  51,
     83,  19,  99,  35,  67,   3, 125,  61,  93,  29, 109,  45,  77,  13, 117,
     53,  85,  21, 101,  37,  69,   5, 121,  57,  89,  25, 105,  41,  73,   9,
    113,  49,  81,  17,  97,  33,  65,   1]


cdef class SDD1(Board):

    def __cinit__(self, Cart cart):
        self.name = u"S-DD1"
        self.reset_board()

    cdef void reset_board(self) noexcept:
        cdef int i
        # The slots come up showing the four megabytes in order, so a
        # cartridge that never writes the registers still reads straight
        # through.  Every S-DD1 game does write them, early.
        for i in range(4):
            self.mmc[i] = <uint8_t>i
        self.dma_enable = 0
        self.dma_arm = 0
        self.dma_seen = 0
        self.dma_armed_seen = 0
        self.last_channel = 0xFF
        self.last_enable = 0
        self.last_arm = 0
        self.last_addr = 0
        self.last_count = 0
        self.active = 0
        self.out_len = 0
        self.out_pos = 0

    # =====================================================================
    # the map
    # =====================================================================

    cdef uint32_t rom_offset(self, uint32_t bank, uint32_t addr) noexcept:
        """Where in the ROM a bank and address land.

        Below $C0 the cartridge is an ordinary LoROM: the top half of each
        bank is the next 32 KB of ROM.  From $C0 up it is a window of four
        1 MB slots, a whole 64 KB bank at a time, with $4804-$4807 choosing
        the megabyte each slot shows.
        """
        cdef uint32_t slot, mb, linear
        if bank >= 0xC0:
            slot = (bank >> 4) & 3
            mb = self.mmc[slot] & 7
            linear = (mb << 20) | ((bank & 0x0F) << 16) | addr
        else:
            linear = ((bank & 0x3F) << 15) | (addr & 0x7FFF)
        return self.cart.rom_offset(linear)

    cdef int classify(self, uint32_t bank, uint32_t addr, uint32_t *base) noexcept:
        cdef Cart c = self.cart
        base[0] = 0

        # $4800-$4807.  The console does not decode up here, so the bus has
        # already handed the whole of $4400-$5FFF to the cartridge; claiming
        # the page is what makes it ask.
        if (bank & 0x7F) < 0x40 and 0x4000 <= addr < 0x6000:
            return PK_DEVICE

        # Star Ocean's battery RAM.  Street Fighter Zero 2 has none, and a
        # cartridge with no SRAM must not answer here at all.
        if c.sram_size and 0x70 <= bank <= 0x73 and addr < 0x8000:
            base[0] = (((bank & 3) << 15) | addr) & c.sram_mask
            return PK_SRAM

        if bank >= 0xC0:
            # A slot register can be rewritten at any moment, and a page
            # table cannot follow that without being rebuilt on every write.
            # So these are asked per access, like the SA-1's banks.
            return PK_DEVICE

        if (bank & 0x7F) < 0x40 and addr >= 0x8000:
            base[0] = self.rom_offset(bank, addr)
            return PK_ROM

        return PK_OPENBUS

    # =====================================================================
    # registers, and the banks that go through the mapper
    # =====================================================================

    cdef uint8_t read(self, uint32_t addr, uint8_t data) noexcept:
        cdef uint32_t bank = (addr >> 16) & 0xFF
        cdef uint32_t off = addr & 0xFFFF

        if bank >= 0xC0:
            if self.active:
                # A claimed transfer is running: the chip answers, and the
                # address the DMA thinks it is walking means nothing.
                if self.out_pos < self.out_len:
                    data = self.out[self.out_pos]
                    self.out_pos += 1
                    return data
                return 0
            return self.cart.rom[self.rom_offset(bank, off)]

        if 0x4800 <= off <= 0x4807:
            if off == 0x4800:
                return self.dma_enable
            if off == 0x4801:
                return self.dma_arm
            if off >= 0x4804:
                return self.mmc[off & 3]
            return data                      # $4802/$4803 read back open bus
        return data

    cdef uint8_t peek(self, uint32_t addr, uint8_t data) noexcept:
        """The mapped ROM, and never the decompressor: a debugger reading the
        window during a claimed transfer would consume the output."""
        cdef uint32_t bank = (addr >> 16) & 0xFF
        if bank >= 0xC0:
            return self.cart.rom[self.rom_offset(bank, addr & 0xFFFF)]
        return data

    cdef void write(self, uint32_t addr, uint8_t value) noexcept:
        cdef uint32_t bank = (addr >> 16) & 0xFF
        cdef uint32_t off = addr & 0xFFFF

        if bank >= 0xC0:
            return                           # ROM swallows writes

        if off == 0x4800:
            self.dma_enable = value
        elif off == 0x4801:
            self.dma_arm = value
        elif 0x4804 <= off <= 0x4807:
            self.mmc[off & 3] = value & 7

    # =====================================================================
    # the decompressor
    # =====================================================================
    #
    # Four things in a chain.  A bit reader pulls packed bytes out of the ROM.
    # A Golomb decoder turns a codeword into a run: "the next N symbols are
    # the probable one, and then one is not".  A probability state per context
    # says which code size to read that run with, and walks up or down as it
    # is proved right or wrong.  A context model picks which of the 32 states
    # to use from the bits already decoded in the same bitplane, which is what
    # makes it good at tiles: the bit above and the bit to the left of a pixel
    # predict it.  Output logic then reassembles the bitplanes into bytes the
    # way the tile format wants them.

    cdef uint8_t _next_packed(self) noexcept:
        """The next byte of packed data, followed through the mapper.

        The chip reads the ROM at the address the DMA was pointed at, so a
        block that runs off the end of a bank continues wherever that bank's
        successor is mapped -- which is not the same as the next ROM offset.
        """
        cdef uint8_t v = self.cart.rom[self.rom_offset((self.in_addr >> 16) & 0xFF,
                                                       self.in_addr & 0xFFFF)]
        self.in_addr = (self.in_addr + 1) & 0xFFFFFF
        return v

    cdef uint8_t _codeword(self, int bits) noexcept:
        """One Golomb codeword: either a full run of 2**bits, or a shorter one
        whose length the following `bits` bits give."""
        cdef uint8_t tmp
        if not self.valid_bits:
            self.in_stream |= self._next_packed()
            self.valid_bits = 8
        self.in_stream = <uint16_t>(self.in_stream << 1)
        self.valid_bits -= 1
        self.in_stream ^= 0x8000
        if self.in_stream & 0x8000:
            # A full run.  For seven bits this is 0x100, which truncates to
            # zero and counts down through the wrap -- 256 minus 128 is the
            # 128 symbols wanted, so the truncation is load-bearing.
            return <uint8_t>(0x80 + (1 << bits))
        tmp = <uint8_t>((self.in_stream >> 8) | (0x7F >> bits))
        self.in_stream = <uint16_t>(self.in_stream << bits)
        self.valid_bits -= bits
        if self.valid_bits < 0:
            self.in_stream |= <uint16_t>(self._next_packed() << (-self.valid_bits))
            self.valid_bits += 8
        return RUN_TABLE[tmp]

    cdef int _golomb_bit(self, int code_size) noexcept:
        """0 for another probable symbol, 1 for the improbable one, and 2 for
        the last probable one of a run -- which the state machine above needs
        to tell apart from the others."""
        if not self.bit_ctr[code_size]:
            self.bit_ctr[code_size] = self._codeword(code_size)
        self.bit_ctr[code_size] = <uint8_t>(self.bit_ctr[code_size] - 1)
        if self.bit_ctr[code_size] == 0x80:
            self.bit_ctr[code_size] = 0
            return 2
        return 1 if self.bit_ctr[code_size] == 0 else 0

    cdef int _prob_bit(self, int context) noexcept:
        cdef uint8_t state = self.context_state[context]
        cdef int bit = self._golomb_bit(EVO_SIZE[state])
        if bit & 1:
            self.context_state[context] = EVO_LPS[state]
            if state < 2:
                # Down at the bottom of the table the symbol that was the less
                # probable one becomes the more probable one.
                self.context_mps[context] ^= 1
                return self.context_mps[context]
            return self.context_mps[context] ^ 1
        elif bit:
            self.context_state[context] = EVO_MPS[state]
        return self.context_mps[context]

    cdef int _bit(self, int plane) noexcept:
        cdef int context = (((plane & 1) << 4)
                            | ((self.prev_bits[plane] & self.high_context_bits) >> 5)
                            | (self.prev_bits[plane] & self.low_context_bits))
        cdef int bit = self._prob_bit(context)
        self.prev_bits[plane] = <uint16_t>((self.prev_bits[plane] << 1) | bit)
        return bit

    cdef void _decompress(self, uint32_t addr, uint32_t count) noexcept:
        """Unpack `count` bytes of the block starting at bus address `addr`."""
        cdef uint8_t head0, head1, byte1, byte2, bit
        cdef uint32_t written = 0
        cdef int plane = 0
        cdef uint8_t i = 0

        if count == 0 or count > 0x10000:
            count = 0x10000

        self.in_addr = addr
        head0 = self._next_packed()
        head1 = self._next_packed()

        # The top two bits of the header say how the bitplanes are arranged,
        # and the next two which bits of the decoded history form a context.
        self.bitplane_type = head0 >> 6
        if (head0 & 0x30) == 0x00:
            self.high_context_bits = 0x01C0
            self.low_context_bits = 0x0001
        elif (head0 & 0x30) == 0x10:
            self.high_context_bits = 0x0180
            self.low_context_bits = 0x0001
        elif (head0 & 0x30) == 0x20:
            self.high_context_bits = 0x00C0
            self.low_context_bits = 0x0001
        else:
            self.high_context_bits = 0x0180
            self.low_context_bits = 0x0003

        # The bitstream starts part-way into the two header bytes.
        self.in_stream = <uint16_t>((head0 << 11) | (head1 << 3))
        self.valid_bits = 5
        memset(self.bit_ctr, 0, sizeof(self.bit_ctr))
        memset(self.context_state, 0, sizeof(self.context_state))
        memset(self.context_mps, 0, sizeof(self.context_mps))
        memset(self.prev_bits, 0, sizeof(self.prev_bits))

        if self.bitplane_type == 3:
            # Mode 7: one bitplane per bit position, eight at a time.
            while written < count:
                byte1 = 0
                plane = 0
                bit = 1
                while bit:
                    if self._bit(plane):
                        byte1 |= bit
                    bit = <uint8_t>(bit << 1)
                    plane += 1
                self.out[written] = byte1
                written += 1
        else:
            while written < count:
                byte1 = 0
                byte2 = 0
                bit = 0x80
                while bit:
                    if self._bit(plane):
                        byte1 |= bit
                    if self._bit(plane + 1):
                        byte2 |= bit
                    bit >>= 1
                self.out[written] = byte1
                written += 1
                if written >= count:
                    break
                self.out[written] = byte2
                written += 1
                # Type 0 is two bitplanes alternating and never moves on.  The
                # other two step every 8 rows, one through all eight planes and
                # one between the two pairs.
                i = <uint8_t>(i + 32)
                if i == 0:
                    if self.bitplane_type == 1:
                        plane = (plane + 2) & 7
                    elif self.bitplane_type == 2:
                        plane ^= 2
        self.out_len = written

    # =====================================================================
    # DMA
    # =====================================================================

    cdef void dma_begin(self, int channel, uint32_t addr, uint32_t count) noexcept:
        """Decide whether this transfer is the chip's, and if it is, unpack it.

        The chip streams a byte at a time as the DMA asks for them; unpacking
        the block up front produces the same bytes in the same order, and the
        console cannot tell the difference because it is halted throughout.
        """
        cdef uint32_t bank = (addr >> 16) & 0xFF
        self.dma_seen += 1
        # Arming alone cannot be the whole rule: Street Fighter Zero 2 leaves
        # the bit set and then does its sprite DMA out of WRAM on the same
        # channel.  The chip is on the cartridge and can only answer for
        # addresses it decodes, so the source has to be in its own window
        # too.  That is a fact about where the chip is, not a reading of the
        # register, which is why it is the part to lean on.
        if ((self.dma_enable & self.dma_arm) >> channel) & 1 and bank >= 0xC0:
            self.dma_armed_seen += 1
            self.last_channel = <uint8_t>channel
            self.last_enable = self.dma_enable
            self.last_arm = self.dma_arm
            self.last_addr = addr
            self.last_count = count
            self._decompress(addr, count)
            self.out_pos = 0
            self.active = 1

    cdef void dma_end(self, int channel) noexcept:
        self.active = 0

    # -- save state (generated by tools/gen_state.py; do not edit) --------

    def state_ints(self):
        cdef int i, j
        v = [self.dma_enable, self.dma_arm, self.out_len, self.out_pos, self.active, self.in_addr, self.in_stream, self.valid_bits, self.bitplane_type, self.high_context_bits, self.low_context_bits, self.dma_seen, self.dma_armed_seen, self.last_channel, self.last_enable, self.last_arm, self.last_addr, self.last_count]
        for i in range(4):
            v.append(self.mmc[i])
        for i in range(8):
            v.append(self.bit_ctr[i])
        for i in range(32):
            v.append(self.context_state[i])
        for i in range(32):
            v.append(self.context_mps[i])
        for i in range(8):
            v.append(self.prev_bits[i])
        return v

    def load_ints(self, v):
        cdef int i, j, k = 18
        self.dma_enable = v[0]
        self.dma_arm = v[1]
        self.out_len = v[2]
        self.out_pos = v[3]
        self.active = v[4]
        self.in_addr = v[5]
        self.in_stream = v[6]
        self.valid_bits = v[7]
        self.bitplane_type = v[8]
        self.high_context_bits = v[9]
        self.low_context_bits = v[10]
        self.dma_seen = v[11]
        self.dma_armed_seen = v[12]
        self.last_channel = v[13]
        self.last_enable = v[14]
        self.last_arm = v[15]
        self.last_addr = v[16]
        self.last_count = v[17]
        for i in range(4):
            self.mmc[i] = v[k + i]
        k += 4
        for i in range(8):
            self.bit_ctr[i] = v[k + i]
        k += 8
        for i in range(32):
            self.context_state[i] = v[k + i]
        k += 32
        for i in range(32):
            self.context_mps[i] = v[k + i]
        k += 32
        for i in range(8):
            self.prev_bits[i] = v[k + i]
        k += 8

    def state_blobs(self):
        return [PyBytes_FromStringAndSize(<char *>self.out, 65536)]

    def load_blobs(self, blobs):
        if len(blobs[0]) != 65536:
            raise ValueError('bad out blob')
        memcpy(<char *>self.out, <char *><bytes>blobs[0], 65536)

    # -- end generated save state ------------------------------------------


    # -- introspection ------------------------------------------------------

    def registers(self):
        return dict(mmc=[self.mmc[i] for i in range(4)],
                    dma_enable=self.dma_enable, dma_arm=self.dma_arm)

    def dma_stats(self):
        return dict(seen=self.dma_seen, armed=self.dma_armed_seen,
                    last_channel=self.last_channel,
                    last_enable=self.last_enable, last_arm=self.last_arm,
                    last_addr=self.last_addr, last_count=self.last_count)


def tables():
    """The transcribed constants, so a test can look for a typo in them.

    Two hundred-odd numbers copied by hand is the one part of this file that
    can be wrong without being wrong anywhere a human would look."""
    return dict(
        evolution=[(EVO_SIZE[i], EVO_MPS[i], EVO_LPS[i]) for i in range(33)],
        run=[RUN_TABLE[i] for i in range(128)],
    )


from snes.board import register
register("S-DD1", SDD1)
