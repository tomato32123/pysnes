# cython: language_level=3
# cython: boundscheck=False, wraparound=False, cdivision=True
"""The DSP-1, emulated by its effects rather than by its program.

The DSP-1 is an NEC uPD77C25 with a program mask-ROMed into the package.
That program is not on this machine, so there is no way to run it -- what
is written here instead answers the commands the console sends, computing
what each is documented to compute.  That is high-level emulation, and it
is a weaker thing than running the chip, in a way worth being plain about:

  * A command whose answer is not exactly the chip's answer will still
    look right.  The DSP-1 works in 16-bit fixed point with its own
    rounding, and matching a curve is not the same as matching a table.
  * A command nobody documented cannot be answered at all.
  * There is no oracle.  No test ROM here exercises the DSP-1, so the only
    evidence available is that a game which uses it draws what it should --
    which is how earlier emulators ran Super Mario Kart subtly wrong for
    years without anyone noticing.

So this file reports what it does not know rather than guessing quietly.
`unknown_count` and the command trace exist so that a game running on top
of it can be asked which commands it actually needs, and so that a command
that was never implemented shows up as a number rather than as a picture
that looks plausible.

The register pair and its addresses are from the SNESdev wiki's DSP-1
page: the data register at $30-$3F:8000-BFFF and the status register at
$30-$3F:C000-FFFF on a map-20 cartridge, at $00-$0F:6000 and $7000 on a
map-21 one, with bit 7 of the status register saying a transfer may
happen.
"""
from libc.stdint cimport uint8_t, uint16_t, uint32_t
from libc.string cimport memset

from snes.board cimport Board, PK_OPENBUS, PK_ROM, PK_SRAM, PK_DEVICE
from snes.cart cimport Cart, MAP_LOROM


# Bit 7 of the status register: the console spins on this before every
# transfer.  Nothing here takes any time, so it is always set.
cdef uint8_t SR_READY = 0x80


cdef class DSP1(Board):

    def __cinit__(self, Cart cart):
        self.name = u"DSP-1 (HLE)"
        self.hirom = 0 if cart.map_mode == MAP_LOROM else 1
        self.reset_board()

    cdef void reset_board(self) noexcept:
        self.sr = SR_READY
        self.command = 0
        self.have_command = 0
        self.param_len = 0
        self.param_want = -1
        self.result_len = 0
        self.result_pos = 0
        self.trace_len = 0
        self.unknown_count = 0

    # =====================================================================
    # the map
    # =====================================================================

    cdef int classify(self, uint32_t bank, uint32_t addr, uint32_t *base) noexcept:
        cdef Cart c = self.cart
        cdef uint32_t linear
        base[0] = 0

        if self.hirom:
            # Map 21: the chip sits in the same $6000-$7FFF window every
            # HiROM cartridge leaves free.
            if (bank & 0x7F) < 0x10 and 0x6000 <= addr < 0x8000:
                return PK_DEVICE
            if c.sram_size and 0x20 <= (bank & 0x7F) <= 0x3F and 0x6000 <= addr < 0x8000:
                base[0] = (((bank & 0x1F) << 13) | (addr & 0x1FFF)) & c.sram_mask
                return PK_SRAM
            if (bank & 0x7F) >= 0x40 or addr >= 0x8000:
                linear = ((bank & 0x3F) << 16) | addr
                base[0] = c.rom_offset(linear)
                return PK_ROM
            return PK_OPENBUS

        # Map 20: banks $30-$3F carry the chip where ROM would be.
        if 0x30 <= (bank & 0x7F) <= 0x3F and addr >= 0x8000:
            return PK_DEVICE
        if c.sram_size and 0x70 <= (bank & 0x7F) <= 0x7D and addr < 0x8000:
            base[0] = (((bank & 0x0F) << 15) | addr) & c.sram_mask
            return PK_SRAM
        if addr >= 0x8000:
            linear = ((bank & 0x7F) << 15) | (addr & 0x7FFF)
            base[0] = c.rom_offset(linear)
            return PK_ROM
        return PK_OPENBUS

    cdef int _is_status(self, uint32_t addr) noexcept:
        """Which of the two registers an address lands on."""
        if self.hirom:
            return 1 if (addr & 0x1000) else 0
        return 1 if (addr & 0x4000) else 0

    # =====================================================================
    # the register pair
    # =====================================================================

    cdef uint8_t read(self, uint32_t addr, uint8_t data) noexcept:
        if self._is_status(addr):
            return self.sr
        self._note(1, 0)
        if self.result_pos < self.result_len:
            data = self.result[self.result_pos]
            self.result_pos += 1
            return data
        # Reading past the answer gives back the last byte of it, which is
        # what a console that has lost count would see.
        return self.result[self.result_len - 1] if self.result_len else 0

    cdef uint8_t peek(self, uint32_t addr, uint8_t data) noexcept:
        # A register read is the thing the console asked for; describing
        # memory must not consume it.
        return data

    cdef void write(self, uint32_t addr, uint8_t value) noexcept:
        if self._is_status(addr):
            return
        self._note(0, value)
        if not self.have_command:
            self.command = value
            self.have_command = 1
            self.param_len = 0
            self.result_len = 0
            self.result_pos = 0
            self._dispatch()
            return
        if self.param_len < 32:
            self.params[self.param_len] = value
            self.param_len += 1
        self._dispatch()

    cdef void _note(self, uint8_t kind, uint8_t value) noexcept:
        if self.trace_len < 16384:
            self.trace_kind[self.trace_len] = kind
            self.trace_value[self.trace_len] = value
            self.trace_len += 1

    cdef void _dispatch(self) noexcept:
        """Answer the command once its parameters have all arrived.

        Nothing is implemented yet: every command is counted as unknown and
        the exchange ends, so a game runs on and the trace says what it
        wanted.  Commands are added here one at a time, each against its
        published description.
        """
        self.unknown_count += 1
        self.have_command = 0

    # =====================================================================
    # what the cartridge asked for
    # =====================================================================

    @property
    def trace(self):
        """[(kind, value)] for every access, kind 0 write and 1 read."""
        return [(self.trace_kind[i], self.trace_value[i])
                for i in range(self.trace_len)]

    @property
    def unimplemented(self):
        return self.unknown_count

    def state_ints(self):
        return [self.sr, self.command, self.have_command, self.param_len,
                self.param_want, self.result_len, self.result_pos]

    def load_ints(self, v):
        (self.sr, self.command, self.have_command, self.param_len,
         self.param_want, self.result_len, self.result_pos) = v

    def state_blobs(self):
        return dict(
            params=bytes(bytearray([self.params[i] for i in range(32)])),
            result=bytes(bytearray([self.result[i] for i in range(32)])),
        )

    def load_blobs(self, d):
        cdef int i
        for i in range(32):
            self.params[i] = d["params"][i]
            self.result[i] = d["result"][i]


from snes.board import register
register("DSP", DSP1)
