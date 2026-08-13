# cython: language_level=3
# cython: boundscheck=False, wraparound=False, cdivision=True
"""The NEC uPD77C25, the processor inside the DSP-1 and its relatives.

Six of the cartridge chips this console ever saw are the same part with a
different program burned into it: the DSP-1, -2, -3 and -4 are a uPD77C25,
and the ST010 and ST011 are a uPD96050, which is the same architecture with
more memory.  So this is written once, sized at construction, and the chip
it becomes depends only on which program is loaded into it.

That is the reason to run the processor rather than answer its commands
from outside.  Emulating the effects means writing six chips from six
descriptions and hoping each description is complete; emulating the part
means writing one processor from its data sheet and letting the programs
be themselves.

Everything here is from NEC's uPD77C25/77P25 data sheet: the three
instruction formats and their fields, the sixteen ALU functions and which
flags each touches, the source and destination register tables, the branch
conditions, and the host interface with its data and status registers.

Two things the data sheet does not settle are taken from ares, and are
marked where they appear: the update rule for the auxiliary sign and
overflow flags -- the data sheet says what they are for and leaves the
rule to a manual not published with it -- and what the two- and four-bit
left shifts put into the bits they vacate.
"""
from libc.stdint cimport uint8_t, uint16_t, uint32_t, int32_t, int64_t
from libc.string cimport memset


# Status register bits.  The console only ever sees the top eight.
cdef uint16_t SR_RQM = 0x8000        # a transfer may happen
cdef uint16_t SR_USF1 = 0x4000
cdef uint16_t SR_USF0 = 0x2000
cdef uint16_t SR_DRS = 0x1000        # half of a 16-bit transfer has gone
cdef uint16_t SR_DMA = 0x0800
cdef uint16_t SR_DRC = 0x0400        # 1: the host moves a byte at a time
cdef uint16_t SR_SOC = 0x0200
cdef uint16_t SR_SIC = 0x0100
cdef uint16_t SR_EI = 0x0080


cdef class NECDSP:

    def __cinit__(self, int prg_words=2048, int drom_words=1024,
                  int ram_words=256):
        self.prg_mask = prg_words - 1
        self.drom_mask = drom_words - 1
        self.ram_mask = ram_words - 1
        self.loaded = 0
        memset(self.prg, 0, sizeof(self.prg))
        memset(self.drom, 0, sizeof(self.drom))
        self.reset()

    def reset(self):
        """Reset sets the program counter to zero; the rest is not specified,
        so it starts cleared."""
        memset(self.ram, 0, sizeof(self.ram))
        self.pc = 0
        self.rp = 0
        self.dp = 0
        self.k = 0
        self.l = 0
        self.m = 0
        self.n = 0
        self.a = 0
        self.b = 0
        self.tr = 0
        self.trb = 0
        self.dr = 0
        self.sr = 0
        self.si = 0
        self.so = 0
        self.s0a = self.s1a = self.ca = self.za = self.ov0a = self.ov1a = 0
        self.s0b = self.s1b = self.cb = self.zb = self.ov0b = self.ov1b = 0
        self.sp = 0
        self.clock = 0

    # =====================================================================
    # the program
    # =====================================================================

    def load_program(self, bytes data):
        """Instruction ROM: 24-bit words, most significant byte first."""
        cdef int words = len(data) // 3
        cdef int i
        if words - 1 != <int>self.prg_mask:
            raise ValueError("program is %d words, this part holds %d"
                             % (words, self.prg_mask + 1))
        for i in range(words):
            self.prg[i] = ((<uint32_t>data[i * 3] << 16)
                           | (<uint32_t>data[i * 3 + 1] << 8)
                           | <uint32_t>data[i * 3 + 2])
        self.loaded = 1

    def load_data(self, bytes data):
        """Data ROM: 16-bit words, most significant byte first."""
        cdef int words = len(data) // 2
        cdef int i
        if words - 1 != <int>self.drom_mask:
            raise ValueError("data ROM is %d words, this part holds %d"
                             % (words, self.drom_mask + 1))
        for i in range(words):
            self.drom[i] = (<uint16_t>data[i * 2] << 8) | <uint16_t>data[i * 2 + 1]

    # =====================================================================
    # the register tables
    # =====================================================================

    cdef uint16_t _src(self, int which) noexcept:
        """Table 11.  What a source field puts on the internal data bus."""
        if which == 0:
            return self.trb                  # NON also outputs TRB
        if which == 1:
            return self.a
        if which == 2:
            return self.b
        if which == 3:
            return self.tr
        if which == 4:
            return self.dp
        if which == 5:
            return self.rp
        if which == 6:
            return self.drom[self.rp & self.drom_mask]
        if which == 7:
            # SGN: the saturation constant for the sign the auxiliary flag
            # is holding, which is what makes clipping one instruction.
            return 0x8000 if self.s1a else 0x7FFF
        if which == 8:
            self.sr |= SR_RQM                # a program read of DR asks the host
            return self.dr
        if which == 9:
            return self.dr                   # DRNF: the same, without asking
        if which == 10:
            return self.sr
        if which == 11:
            return self.si                   # serial, unused on a cartridge
        if which == 12:
            return self.si
        if which == 13:
            return self.k
        if which == 14:
            return self.l
        return self.ram[self.dp & self.ram_mask]

    cdef void _dst(self, int which, uint16_t value) noexcept:
        """Table 12.  Where a destination field takes it from the bus."""
        if which == 0:
            return
        elif which == 1:
            self.a = value
        elif which == 2:
            self.b = value
        elif which == 3:
            self.tr = value
        elif which == 4:
            self.dp = value
        elif which == 5:
            self.rp = value
        elif which == 6:
            self.dr = value
            self.sr |= SR_RQM                # the answer is ready for the host
        elif which == 7:
            # Only the settings are the program's to change; the request and
            # transfer-state bits belong to the transfer itself.
            self.sr = (self.sr & 0x907C) | (value & ~0x907C)
        elif which == 8:
            self.so = value                  # serial out, low bit first
        elif which == 9:
            self.so = value                  # serial out, high bit first
        elif which == 10:
            self.k = value
        elif which == 11:
            self.k = value                   # @KLR: bus to K, data ROM to L
            self.l = self.drom[self.rp & self.drom_mask]
        elif which == 12:
            # @KLM: RAM with DP bit 6 forced to one goes to K, the bus to L.
            self.k = self.ram[(self.dp | 0x40) & self.ram_mask]
            self.l = value
        elif which == 13:
            self.l = value
        elif which == 14:
            self.trb = value
        else:
            self.ram[self.dp & self.ram_mask] = value

    # =====================================================================
    # the ALU
    # =====================================================================

    cdef void _alu(self, int op, uint16_t p, int use_b) noexcept:
        """Table 6.  Sixteen functions on an accumulator and the P input."""
        cdef uint32_t q = self.b if use_b else self.a
        cdef uint32_t r = 0
        cdef int c_in = (self.cb if use_b else self.ca)
        cdef int carry = 0
        cdef int ov0 = 0
        cdef int arith = 0
        cdef int s0, z, s1, ov1

        if op == 0:
            return
        elif op == 1:
            r = q | p
        elif op == 2:
            r = q & p
        elif op == 3:
            r = q ^ p
        elif op == 4:
            r = q - p
            arith = 1
        elif op == 5:
            r = q + p
            arith = 1
        elif op == 6:
            r = q - p - c_in
            arith = 1
        elif op == 7:
            r = q + p + c_in
            arith = 1
        elif op == 8:
            r = q - 1
            p = 1
            arith = 1
        elif op == 9:
            r = q + 1
            p = 1
            arith = 1
        elif op == 10:
            r = ~q                           # one's complement
        elif op == 11:
            carry = q & 1                    # arithmetic right shift
            r = (q >> 1) | (q & 0x8000)
        elif op == 12:
            carry = (q >> 15) & 1            # left rotate through carry
            r = (q << 1) | c_in
        elif op == 13:
            # What the vacated bits take is not in the data sheet; this is
            # ares's answer, and it is not something to guess at differently.
            r = (q << 2) | 3
        elif op == 14:
            r = (q << 4) | 15
        else:
            r = (q << 8) | (q >> 8)

        if arith:
            # Carry out of a 16-bit add, or the borrow out of a subtract,
            # which is the same bit once the subtraction is done wide.
            carry = (r >> 16) & 1
            if op == 5 or op == 7 or op == 9:
                ov0 = (((q ^ r) & (p ^ r)) >> 15) & 1
            else:
                ov0 = (((q ^ p) & (q ^ r)) >> 15) & 1

        r &= 0xFFFF
        s0 = (r >> 15) & 1
        z = 1 if r == 0 else 0

        # Table 6: the logical functions and the complement clear carry and
        # both overflow flags; the shifts clear the overflow pair and set
        # carry only where the table says a bit falls out.
        if not arith:
            ov0 = 0
        s1 = self.s1b if use_b else self.s1a
        ov1 = self.ov1b if use_b else self.ov1a
        if not arith:
            ov1 = 0
        else:
            # The auxiliary pair, whose rule the data sheet leaves to a
            # manual it does not include.  This is ares's: a further
            # overflow that agrees with the one being carried cancels it,
            # and while one is carried the auxiliary sign holds the sign
            # from before it -- which is what lets three additions in a row
            # still know which way they went.
            if ov0 and ov1:
                ov1 = 1 if s0 == s1 else 0
            else:
                ov1 = ov0 | ov1
        if not ov1:
            s1 = s0

        if use_b:
            self.b = <uint16_t>r
            self.zb = z
            self.s0b = s0
            self.s1b = s1
            self.ov0b = ov0
            self.ov1b = ov1
            self.cb = carry
        else:
            self.a = <uint16_t>r
            self.za = z
            self.s0a = s0
            self.s1a = s1
            self.ov0a = ov0
            self.ov1a = ov1
            self.ca = carry

    # =====================================================================
    # branches
    # =====================================================================

    cdef int _cond(self, int brch) noexcept:
        """Table 13.  Whether a jump is taken."""
        if brch == 0x100 or brch == 0x140:   # JMP, CALL
            return 1
        if brch == 0x080:
            return self.ca == 0
        if brch == 0x082:
            return self.ca == 1
        if brch == 0x084:
            return self.cb == 0
        if brch == 0x086:
            return self.cb == 1
        if brch == 0x088:
            return self.za == 0
        if brch == 0x08A:
            return self.za == 1
        if brch == 0x08C:
            return self.zb == 0
        if brch == 0x08E:
            return self.zb == 1
        if brch == 0x090:
            return self.ov0a == 0
        if brch == 0x092:
            return self.ov0a == 1
        if brch == 0x094:
            return self.ov0b == 0
        if brch == 0x096:
            return self.ov0b == 1
        if brch == 0x098:
            return self.ov1a == 0
        if brch == 0x09A:
            return self.ov1a == 1
        if brch == 0x09C:
            return self.ov1b == 0
        if brch == 0x09E:
            return self.ov1b == 1
        if brch == 0x0A0:
            return self.s0a == 0
        if brch == 0x0A2:
            return self.s0a == 1
        if brch == 0x0A4:
            return self.s0b == 0
        if brch == 0x0A6:
            return self.s0b == 1
        if brch == 0x0A8:
            return self.s1a == 0
        if brch == 0x0AA:
            return self.s1a == 1
        if brch == 0x0AC:
            return self.s1b == 0
        if brch == 0x0AE:
            return self.s1b == 1
        if brch == 0x0B0:
            return (self.dp & 15) == 0
        if brch == 0x0B1:
            return (self.dp & 15) != 0
        if brch == 0x0B2:
            return (self.dp & 15) == 15
        if brch == 0x0B4 or brch == 0x0B6:   # serial input acknowledge
            return 0
        if brch == 0x0B8 or brch == 0x0BA:   # serial output acknowledge
            return 0
        if brch == 0x0BC:
            return 1 if not (self.sr & SR_RQM) else 0
        if brch == 0x0BE:
            return 1 if (self.sr & SR_RQM) else 0
        return 0

    # =====================================================================
    # one instruction
    # =====================================================================

    cdef void step(self) noexcept:
        cdef uint32_t op = self.prg[self.pc & self.prg_mask]
        cdef int kind = (op >> 22) & 3
        cdef int pselect, alu, use_b, dpl, dphm, rpdcr, src, dst
        cdef int brch, na
        cdef uint16_t idb, p
        cdef uint32_t dp_low, dp_high
        cdef int32_t product

        self.pc = (self.pc + 1) & self.prg_mask

        if kind == 2:                        # JP
            brch = (op >> 13) & 0x1FF
            na = (op >> 2) & 0x7FF
            if self._cond(brch):
                if brch == 0x140:            # CALL pushes the return address
                    if self.sp < 4:
                        self.stack[self.sp] = self.pc
                        self.sp += 1
                self.pc = na & self.prg_mask
            return

        if kind == 3:                        # LD: a 16-bit immediate
            self._dst(op & 15, <uint16_t>((op >> 6) & 0xFFFF))
            return

        # OP, and RT which is an OP that returns when it is done.
        pselect = (op >> 20) & 3
        alu = (op >> 16) & 15
        use_b = (op >> 15) & 1
        dpl = (op >> 13) & 3
        dphm = (op >> 9) & 15
        rpdcr = (op >> 8) & 1
        src = (op >> 4) & 15
        dst = op & 15

        idb = self._src(src)
        if pselect == 0:
            p = self.ram[self.dp & self.ram_mask]
        elif pselect == 1:
            p = idb
        elif pselect == 2:
            p = self.m
        else:
            p = self.n

        # "If the accumulator specified in the ASL field is also specified as
        # the destination of the data move, the ALU operation becomes a NOP,
        # as the data move supersedes the ALU operation."
        if not (dst == 1 + use_b):
            self._alu(alu, p, use_b)
        self._dst(dst, idb)

        # Pointer modifications happen after their values have been used.
        dp_low = self.dp & 15
        dp_high = self.dp & ~<uint32_t>15
        if dpl == 1:
            dp_low = (dp_low + 1) & 15
        elif dpl == 2:
            dp_low = (dp_low - 1) & 15
        elif dpl == 3:
            dp_low = 0
        self.dp = <uint16_t>((dp_high ^ (<uint32_t>dphm << 4)) | dp_low)
        if rpdcr:
            self.rp = (self.rp - 1) & self.drom_mask

        # The multiplier runs every instruction, on whatever K and L hold
        # once this instruction's moves have been made -- so an instruction
        # may load both inputs and the next one read the product.  The
        # product is 31 bits: sign and fifteen bits in M, fifteen in N with
        # its lowest bit zero.
        product = (<int32_t><short>self.k) * (<int32_t><short>self.l)
        self.m = <uint16_t>((product >> 15) & 0xFFFF)
        self.n = <uint16_t>((product << 1) & 0xFFFF)

        if kind == 1:                        # RT
            if self.sp > 0:
                self.sp -= 1
                self.pc = self.stack[self.sp] & self.prg_mask

    cdef void run_cycles(self, int cycles) noexcept:
        cdef int i
        if not self.loaded:
            return
        for i in range(cycles):
            self.step()

    # =====================================================================
    # the host's side
    # =====================================================================

    def read_status(self):
        return (self.sr >> 8) & 0xFF

    def read_data(self):
        """The console reads the data register.

        In byte mode it takes one byte; in word mode the first read takes
        the high byte and the second the low one, and only the second ends
        the transfer.
        """
        cdef uint8_t value
        if self.sr & SR_DRC:
            self.sr &= ~SR_RQM
            return self.dr & 0xFF
        if not (self.sr & SR_DRS):
            self.sr |= SR_DRS
            return (self.dr >> 8) & 0xFF
        self.sr &= ~SR_DRS
        self.sr &= ~SR_RQM
        return self.dr & 0xFF

    def write_data(self, uint8_t value):
        if self.sr & SR_DRC:
            self.sr &= ~SR_RQM
            self.dr = (self.dr & 0xFF00) | value
            return
        if not (self.sr & SR_DRS):
            self.sr |= SR_DRS
            self.dr = (self.dr & 0x00FF) | (<uint16_t>value << 8)
            return
        self.sr &= ~SR_DRS
        self.sr &= ~SR_RQM
        self.dr = (self.dr & 0xFF00) | value

    # -- for tests and save states -----------------------------------------

    @property
    def registers(self):
        return dict(pc=self.pc, rp=self.rp, dp=self.dp, k=self.k, l=self.l,
                    m=self.m, n=self.n, a=self.a, b=self.b, tr=self.tr,
                    trb=self.trb, dr=self.dr, sr=self.sr, sp=self.sp)

    @property
    def flags_a(self):
        return dict(s0=self.s0a, s1=self.s1a, c=self.ca, z=self.za,
                    ov0=self.ov0a, ov1=self.ov1a)

    def poke_ram(self, int addr, uint16_t value):
        self.ram[addr & self.ram_mask] = value

    def peek_ram(self, int addr):
        return self.ram[addr & self.ram_mask]

    def poke_program(self, int addr, uint32_t word):
        """For tests: place one instruction without loading a whole ROM."""
        self.prg[addr & self.prg_mask] = word
        self.loaded = 1

    def poke_data(self, int addr, uint16_t value):
        self.drom[addr & self.drom_mask] = value

    def set_registers(self, **kw):
        for name, value in kw.items():
            if name == "a":
                self.a = value
            elif name == "b":
                self.b = value
            elif name == "k":
                self.k = value
            elif name == "l":
                self.l = value
            elif name == "dp":
                self.dp = value
            elif name == "rp":
                self.rp = value
            elif name == "pc":
                self.pc = value
            elif name == "c":
                self.ca = value
            else:
                raise KeyError(name)

    def run(self, int instructions):
        self.run_cycles(instructions)
