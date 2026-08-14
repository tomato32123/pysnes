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
from libc.stdint cimport uint8_t, uint16_t, uint32_t, int64_t
from libc.math cimport sin, cos, sqrt, atan2, M_PI
from libc.string cimport memset

from snes.board cimport Board, PK_OPENBUS, PK_ROM, PK_SRAM, PK_DEVICE
from snes.cart cimport Cart, MAP_LOROM
from snes.necdsp cimport NECDSP

import os

# Where a firmware dump is looked for, and what it is called.  The names
# are the ones higan and ares use: a program ROM of 24-bit words and a data
# ROM of 16-bit ones, per chip.
FIRMWARE_DIRS = [
    os.environ.get("PYSNES_FIRMWARE", ""),
    "/home/moto/Projects/rom/firmware",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                 "firmware"),
]

# Which part each chip is, as (program words, data words, RAM words).  The
# DSP-n are a uPD77C25; the ST01x a uPD96050, which is the same with more
# of everything.
PARTS = {
    "dsp1": (2048, 1024, 256), "dsp1b": (2048, 1024, 256),
    "dsp2": (2048, 1024, 256), "dsp3": (2048, 1024, 256),
    "dsp4": (2048, 1024, 256),
    "st010": (16384, 2048, 2048), "st011": (16384, 2048, 2048),
}


def find_firmware(names):
    """The first (program, data) pair present for any of these chips."""
    for name in names:
        for directory in FIRMWARE_DIRS:
            if not directory:
                continue
            prg = os.path.join(directory, name + ".program.rom")
            dat = os.path.join(directory, name + ".data.rom")
            if os.path.exists(prg) and os.path.exists(dat):
                return name, prg, dat
    return None, None, None


# Bit 7 of the status register: the console spins on this before every
# transfer.  Nothing here takes any time, so it is always set.
cdef uint8_t SR_READY = 0x80


# How many bytes each command takes and gives back.  The chip answers a
# fixed shape per command -- so much written, so much read -- and getting
# that shape right is what keeps a game in step even before the arithmetic
# behind any of it is written.  The counts are from the dispatch table
# Snes9x's DSP-1 emulation uses, which is the published account of what
# these commands look like from the console's side.  Several numbers are
# aliases of one command, which is why the table is listed out in full.
cdef int CMD_PARAMS[256]
cdef int CMD_RESULTS[256]


cdef void _fill_commands() noexcept:
    cdef int i
    for i in range(256):
        CMD_PARAMS[i] = -1
        CMD_RESULTS[i] = 0


def _describe():
    """(command, name, parameters, results) for everything known."""
    return [(c, n, CMD_PARAMS[c], CMD_RESULTS[c])
            for c, n in sorted(_COMMANDS.items())]


# command: (name, parameter bytes, result bytes)
_COMMANDS = {
    0x00: ("multiply", 4, 2),          0x20: ("multiply", 4, 2),
    0x10: ("inverse", 4, 4),           0x30: ("inverse", 4, 4),
    0x04: ("sin/cos", 4, 4),           0x24: ("sin/cos", 4, 4),
    0x08: ("radius", 6, 4),
    0x18: ("range", 8, 2),             0x38: ("range", 8, 2),
    0x28: ("distance", 6, 2),
    0x0C: ("rotate", 6, 4),            0x2C: ("rotate", 6, 4),
    0x1C: ("polar rotate", 12, 6),     0x3C: ("polar rotate", 12, 6),
    0x02: ("projection", 14, 8),       0x12: ("projection", 14, 8),
    0x22: ("projection", 14, 8),       0x32: ("projection", 14, 8),
    0x0A: ("raster", 2, 8),            0x1A: ("raster", 2, 8),
    0x2A: ("raster", 2, 8),            0x3A: ("raster", 2, 8),
    0x06: ("project object", 6, 6),    0x16: ("project object", 6, 6),
    0x26: ("project object", 6, 6),    0x36: ("project object", 6, 6),
    0x0E: ("target", 4, 4),            0x1E: ("target", 4, 4),
    0x2E: ("target", 4, 4),            0x3E: ("target", 4, 4),
    0x01: ("attitude a", 8, 0),        0x05: ("attitude a", 8, 0),
    0x31: ("attitude a", 8, 0),        0x35: ("attitude a", 8, 0),
    0x11: ("attitude b", 8, 0),        0x15: ("attitude b", 8, 0),
    0x21: ("attitude c", 8, 0),        0x25: ("attitude c", 8, 0),
    0x0D: ("objective a", 6, 6),       0x09: ("objective a", 6, 6),
    0x39: ("objective a", 6, 6),       0x3D: ("objective a", 6, 6),
    0x1D: ("objective b", 6, 6),       0x19: ("objective b", 6, 6),
    0x2D: ("objective c", 6, 6),       0x29: ("objective c", 6, 6),
    0x03: ("subjective a", 6, 6),      0x33: ("subjective a", 6, 6),
    0x13: ("subjective b", 6, 6),
    0x23: ("subjective c", 6, 6),
    0x0B: ("dot product a", 6, 2),     0x3B: ("dot product a", 6, 2),
    0x1B: ("dot product b", 6, 2),
    0x2B: ("dot product c", 6, 2),
    0x14: ("angle transform", 12, 6),  0x34: ("angle transform", 12, 6),
    0x0F: ("ram test", 2, 2),          0x07: ("ram test", 2, 2),
    0x2F: ("rom test", 2, 2),          0x27: ("rom test", 2, 2),
    0x1F: ("rom dump", 2, 2048),
    0x80: ("idle", 0, 0),
}

_fill_commands()
for _c, (_n, _p, _r) in _COMMANDS.items():
    CMD_PARAMS[_c] = _p
    CMD_RESULTS[_c] = _r



cdef class DSP1(Board):

    def __cinit__(self, Cart cart):
        self.hirom = 0 if cart.map_mode == MAP_LOROM else 1
        self.core = None
        self.last_clock = 0
        self.owed = 0
        # A DSP-1 cartridge may carry a DSP-1 or the later DSP-1B; nothing
        # in the header says which, so whichever dump is present is used.
        name, prg, dat = find_firmware(["dsp1b", "dsp1"])
        if name:
            words, drom, ram = PARTS[name]
            core = NECDSP(words, drom, ram)
            with open(prg, "rb") as fh:
                core.load_program(fh.read())
            with open(dat, "rb") as fh:
                core.load_data(fh.read())
            self.core = core
            self.name = u"DSP-1 (%s)" % name
        else:
            self.name = u"DSP-1 (HLE, no firmware)"
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

    cdef void run_until(self, int64_t master_clock) noexcept:
        """Let the chip catch up.  It runs at 8.192 MHz against the
        console's 21.477, and an instruction takes one of its cycles."""
        cdef int64_t elapsed
        if self.core is None:
            return
        elapsed = master_clock - self.last_clock
        if elapsed <= 0:
            return
        self.last_clock = master_clock
        self.owed += elapsed * 8192
        if self.owed > 21477272 * 100:       # a long jump: do not spin
            self.owed = 21477272 * 100
        while self.owed >= 21477272:
            self.owed -= 21477272
            self.core.step()

    cdef uint8_t read(self, uint32_t addr, uint8_t data) noexcept:
        if self.core is not None:
            self.run_until(self.clock)
            if self._is_status(addr):
                return self.core.host_status()
            return self.core.host_read()
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
        if self.core is not None:
            self.run_until(self.clock)
            if not self._is_status(addr):
                self.core.host_write(value)
            return
        if self._is_status(addr):
            return
        self._note(0, value)
        if not self.have_command:
            self.command = value
            self.param_want = CMD_PARAMS[value]
            self.param_len = 0
            self.result_len = 0
            self.result_pos = 0
            if self.param_want <= 0:
                # An unknown command has no shape to follow, so the
                # exchange ends there and it is counted.  Guessing a length
                # would put the console out of step with the chip, which is
                # worse than answering nothing.
                if self.param_want < 0:
                    self.unknown_count += 1
                else:
                    self._dispatch()
                return
            self.have_command = 1
            return
        if self.param_len < 32:
            self.params[self.param_len] = value
        self.param_len += 1
        if self.param_len >= self.param_want:
            self.have_command = 0
            self._dispatch()

    cdef void _note(self, uint8_t kind, uint8_t value) noexcept:
        if self.trace_len < 16384:
            self.trace_kind[self.trace_len] = kind
            self.trace_value[self.trace_len] = value
            self.trace_len += 1

    cdef int _p16(self, int i) noexcept:
        """Parameter word i.  The console writes each word low byte first."""
        cdef int v = self.params[i * 2] | (<int>self.params[i * 2 + 1] << 8)
        return v - 0x10000 if v & 0x8000 else v

    cdef void _r16(self, int i, int value) noexcept:
        self.result[i * 2] = <uint8_t>(value & 0xFF)
        self.result[i * 2 + 1] = <uint8_t>((value >> 8) & 0xFF)

    cdef void _dispatch(self) noexcept:
        """Answer a command whose parameters have all arrived.

        The shape is right -- the console writes what the command takes and
        reads back what it gives -- so a game stays in step with the chip
        even where the arithmetic behind a command is not written.  What it
        reads is zero, which is wrong, and the count says how often.  A
        wrong answer that keeps the protocol is a better place to build
        from than a right-looking one that loses it.
        """
        cdef int i
        cdef int cmd = self.command & 0x3F
        cdef double angle, radius, x, y, z, length
        cdef int want = CMD_RESULTS[self.command]
        self.result_len = want if want <= 32 else 32
        self.result_pos = 0
        for i in range(self.result_len):
            self.result[i] = 0

        if cmd == 0x00 or cmd == 0x20:
            # Two signed words multiplied, the product taken from the top:
            # this is fixed point with fifteen bits after the point, which
            # is the form everything else on this chip works in.
            self._r16(0, (self._p16(0) * self._p16(1)) >> 15)
        elif cmd == 0x0F or cmd == 0x07:
            self._r16(0, 0)                  # the RAM is well: it always is
        elif cmd == 0x27 or cmd == 0x2F:
            self._r16(0, 0x0100)             # what the ROM check answers
        elif cmd == 0x04 or cmd == 0x24:
            # An angle and a radius in, the two components out.  A whole
            # turn is 65536, and everything is fifteen bits after the point.
            angle = self._p16(0) * 2.0 * M_PI / 65536.0
            radius = self._p16(1)
            self._r16(0, <int>(radius * sin(angle)))
            self._r16(1, <int>(radius * cos(angle)))
        elif cmd == 0x0C or cmd == 0x2C:
            # Turn a point about the origin.
            angle = self._p16(0) * 2.0 * M_PI / 65536.0
            x = self._p16(1)
            y = self._p16(2)
            self._r16(0, <int>(x * cos(angle) - y * sin(angle)))
            self._r16(1, <int>(x * sin(angle) + y * cos(angle)))
        elif cmd == 0x08 or cmd == 0x28:
            # The length of a three-dimensional vector.  Radius answers in
            # two words and distance in one, but the sum is the same.
            x = self._p16(0)
            y = self._p16(1)
            z = self._p16(2)
            length = sqrt(x * x + y * y + z * z)
            self._r16(0, <int>length)
        elif cmd == 0x80:
            pass                             # idle
        else:
            # The shape is right and the answer is not.  Counted, so that
            # "it draws something" is never mistaken for "it is emulated".
            self.uncomputed[self.command] += 1
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

    @property
    def commands_used(self):
        """{command byte: how often it was asked for and not computed}."""
        return {c: self.uncomputed[c] for c in range(256) if self.uncomputed[c]}

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
