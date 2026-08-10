# cython: language_level=3
"""WDC 65816 (Ricoh 5A22 S-CPU) interpreter.

Timing is bus-access driven: every memory access charges the master-clock cost
of that address, and instructions add explicit internal cycles (`io()`) where
the real core has them.  The idle-cycle rules follow the 65816 datasheet's
notes -- indexed reads pay an extra cycle when the index crosses a page or when
the index registers are 16-bit, direct-page modes pay one when DL is non-zero,
and taken branches pay one more when they cross a page in emulation mode.
"""

from cpython.bytes cimport PyBytes_FromStringAndSize
from libc.string cimport memcpy
from libc.stdint cimport uint8_t, uint16_t, uint32_t, int8_t, int16_t, int32_t, int64_t
from libc.stdlib cimport malloc, free

from snes.bus cimport Bus


cdef enum:
    FLAG_C = 0x01
    FLAG_Z = 0x02
    FLAG_I = 0x04
    FLAG_D = 0x08
    FLAG_X = 0x10          # 8-bit index registers when set
    FLAG_B = 0x10          # break flag, emulation mode only
    FLAG_M = 0x20          # 8-bit accumulator when set
    FLAG_V = 0x40
    FLAG_N = 0x80


cdef enum:
    VEC_NATIVE_COP = 0xFFE4
    VEC_NATIVE_BRK = 0xFFE6
    VEC_NATIVE_NMI = 0xFFEA
    VEC_NATIVE_IRQ = 0xFFEE
    VEC_EMU_COP    = 0xFFF4
    VEC_EMU_NMI    = 0xFFFA
    VEC_EMU_RESET  = 0xFFFC
    VEC_EMU_IRQ    = 0xFFFE


cdef class CPU:

    def __init__(self, Bus bus):
        self.bus = bus
        self.tracing = 0
        self.insn_log = NULL
        self.bus_log = NULL
        self.insn_cap = 0
        self.bus_cap = 0
        self.trace_wrap = 0
        self.reset()

    def __dealloc__(self):
        if self.insn_log != NULL:
            free(self.insn_log)
        if self.bus_log != NULL:
            free(self.bus_log)

    cdef void reset(self) noexcept:
        self.a = 0
        self.x = 0
        self.y = 0
        self.s = 0x01FF
        self.d = 0
        self.db = 0
        self.pb = 0
        self.p = FLAG_M | FLAG_X | FLAG_I
        self.e = 1
        self.stopped = 0
        self.waiting = 0
        self.instructions = 0
        self.ea_wrap = 0
        self.insn_len = 0
        self.bus_len = 0
        self.pc = (<uint16_t>self.bus.read8(VEC_EMU_RESET)
                   | (<uint16_t>self.bus.read8(VEC_EMU_RESET + 1) << 8))

    # =====================================================================
    # primitive bus access
    # =====================================================================

    cdef inline void io(self) noexcept:
        self.bus.tick(6)

    cdef inline uint8_t read(self, uint32_t addr) noexcept:
        cdef uint8_t value
        self.bus.tick(<int>self.bus.speed(addr))
        value = self.bus.read8(addr)
        if self.tracing >= 2:
            self._log_bus(addr, value, 0)
        return value

    cdef inline void write(self, uint32_t addr, uint8_t value) noexcept:
        self.bus.tick(<int>self.bus.speed(addr))
        self.bus.write8(addr, value)
        if self.tracing >= 2:
            self._log_bus(addr, value, 1)

    cdef void _log_bus(self, uint32_t addr, uint8_t value, int write) noexcept:
        cdef int i
        if self.bus_len >= self.bus_cap:
            if not self.trace_wrap:
                return
            for i in range(self.bus_cap - 1):
                self.bus_log[i] = self.bus_log[i + 1]
            self.bus_len = self.bus_cap - 1
        self.bus_log[self.bus_len].clock = self.bus.master_clock
        self.bus_log[self.bus_len].addr = addr
        self.bus_log[self.bus_len].value = value
        self.bus_log[self.bus_len].write = <unsigned char>write
        self.bus_len += 1

    cdef void _log_insn(self, uint8_t op) noexcept:
        cdef int i
        if self.insn_len >= self.insn_cap:
            if not self.trace_wrap:
                return
            for i in range(self.insn_cap - 1):
                self.insn_log[i] = self.insn_log[i + 1]
            self.insn_len = self.insn_cap - 1
        self.insn_log[self.insn_len].clock = self.bus.master_clock
        self.insn_log[self.insn_len].pc = self.pc
        self.insn_log[self.insn_len].a = self.a
        self.insn_log[self.insn_len].x = self.x
        self.insn_log[self.insn_len].y = self.y
        self.insn_log[self.insn_len].s = self.s
        self.insn_log[self.insn_len].d = self.d
        self.insn_log[self.insn_len].pb = self.pb
        self.insn_log[self.insn_len].db = self.db
        self.insn_log[self.insn_len].p = self.p
        self.insn_log[self.insn_len].e = <unsigned char>self.e
        self.insn_log[self.insn_len].op = op
        self.insn_len += 1

    cdef inline uint8_t fetch(self) noexcept:
        cdef uint32_t addr = (<uint32_t>self.pb << 16) | self.pc
        self.pc = (self.pc + 1) & 0xFFFF
        return self.read(addr)

    cdef inline uint16_t fetch16(self) noexcept:
        cdef uint16_t lo = self.fetch()
        return lo | (<uint16_t>self.fetch() << 8)

    cdef inline void push(self, uint8_t value) noexcept:
        self.write(self.s, value)
        if self.e:
            self.s = 0x0100 | ((self.s - 1) & 0xFF)
        else:
            self.s = (self.s - 1) & 0xFFFF

    cdef inline uint8_t pull(self) noexcept:
        if self.e:
            self.s = 0x0100 | ((self.s + 1) & 0xFF)
        else:
            self.s = (self.s + 1) & 0xFFFF
        return self.read(self.s)

    cdef inline void push16(self, uint16_t value) noexcept:
        self.push(<uint8_t>(value >> 8))
        self.push(<uint8_t>(value & 0xFF))

    cdef inline uint16_t pull16(self) noexcept:
        cdef uint16_t lo = self.pull()
        return lo | (<uint16_t>self.pull() << 8)

    # -- operand access honouring the current wrap rule --------------------

    cdef inline uint32_t nxt(self, uint32_t addr) noexcept:
        if self.ea_wrap == 0:
            return (addr + 1) & 0xFFFFFF
        if self.ea_wrap == 1:
            return (addr & 0xFF0000) | ((addr + 1) & 0xFFFF)
        return (addr & 0xFFFF00) | ((addr + 1) & 0xFF)

    cdef inline uint16_t load(self, uint32_t addr, int wide) noexcept:
        cdef uint16_t v = self.read(addr)
        if wide:
            v |= <uint16_t>self.read(self.nxt(addr)) << 8
        return v

    cdef inline void store(self, uint32_t addr, uint16_t value, int wide) noexcept:
        self.write(addr, <uint8_t>(value & 0xFF))
        if wide:
            self.write(self.nxt(addr), <uint8_t>(value >> 8))

    # =====================================================================
    # addressing modes -- each returns a 24-bit effective address
    # =====================================================================

    cdef inline uint32_t am_imm(self, int wide) noexcept:
        cdef uint32_t addr = (<uint32_t>self.pb << 16) | self.pc
        self.pc = (self.pc + (2 if wide else 1)) & 0xFFFF
        self.ea_wrap = 1
        return addr

    cdef inline uint32_t am_dp(self) noexcept:
        cdef uint16_t off = self.fetch()
        if self.d & 0xFF:
            self.io()
        if self.e and (self.d & 0xFF) == 0:
            self.ea_wrap = 2
            return (self.d & 0xFF00) | off
        self.ea_wrap = 1
        return (self.d + off) & 0xFFFF

    cdef inline uint32_t am_dpx(self) noexcept:
        cdef uint16_t off = self.fetch()
        if self.d & 0xFF:
            self.io()
        self.io()
        if self.e and (self.d & 0xFF) == 0:
            self.ea_wrap = 2
            return (self.d & 0xFF00) | ((off + self.x) & 0xFF)
        self.ea_wrap = 1
        return (self.d + off + self.x) & 0xFFFF

    cdef inline uint32_t am_dpy(self) noexcept:
        cdef uint16_t off = self.fetch()
        if self.d & 0xFF:
            self.io()
        self.io()
        if self.e and (self.d & 0xFF) == 0:
            self.ea_wrap = 2
            return (self.d & 0xFF00) | ((off + self.y) & 0xFF)
        self.ea_wrap = 1
        return (self.d + off + self.y) & 0xFFFF

    cdef inline uint32_t am_abs(self) noexcept:
        cdef uint32_t addr = self.fetch16()
        self.ea_wrap = 0
        return ((<uint32_t>self.db << 16) + addr) & 0xFFFFFF

    cdef inline uint32_t am_absx(self, int always) noexcept:
        cdef uint32_t base = self.fetch16()
        cdef uint32_t sum = (base + self.x) & 0xFFFF
        if always or (self.p & FLAG_X) == 0 or ((base ^ sum) & 0xFF00):
            self.io()
        self.ea_wrap = 0
        return ((<uint32_t>self.db << 16) + base + self.x) & 0xFFFFFF

    cdef inline uint32_t am_absy(self, int always) noexcept:
        cdef uint32_t base = self.fetch16()
        cdef uint32_t sum = (base + self.y) & 0xFFFF
        if always or (self.p & FLAG_X) == 0 or ((base ^ sum) & 0xFF00):
            self.io()
        self.ea_wrap = 0
        return ((<uint32_t>self.db << 16) + base + self.y) & 0xFFFFFF

    cdef inline uint32_t am_long(self) noexcept:
        cdef uint32_t lo = self.fetch()
        cdef uint32_t hi = self.fetch()
        cdef uint32_t bank = self.fetch()
        self.ea_wrap = 0
        return (bank << 16) | (hi << 8) | lo

    cdef inline uint32_t am_longx(self) noexcept:
        cdef uint32_t base = self.am_long()
        self.ea_wrap = 0
        return (base + self.x) & 0xFFFFFF

    cdef inline uint32_t am_dpi(self) noexcept:
        """(dp)"""
        cdef uint32_t ptr = self.am_dp()
        cdef uint32_t lo = self.read(ptr)
        cdef uint32_t hi = self.read(self.nxt(ptr))
        self.ea_wrap = 0
        return ((<uint32_t>self.db << 16) + ((hi << 8) | lo)) & 0xFFFFFF

    cdef inline uint32_t am_dpix(self) noexcept:
        """(dp,X)"""
        cdef uint32_t ptr = self.am_dpx()
        cdef uint32_t lo = self.read(ptr)
        cdef uint32_t hi = self.read(self.nxt(ptr))
        self.ea_wrap = 0
        return ((<uint32_t>self.db << 16) + ((hi << 8) | lo)) & 0xFFFFFF

    cdef inline uint32_t am_dpiy(self, int always) noexcept:
        """(dp),Y"""
        cdef uint32_t ptr = self.am_dp()
        cdef uint32_t lo = self.read(ptr)
        cdef uint32_t hi = self.read(self.nxt(ptr))
        cdef uint32_t base = (hi << 8) | lo
        cdef uint32_t sum = (base + self.y) & 0xFFFF
        if always or (self.p & FLAG_X) == 0 or ((base ^ sum) & 0xFF00):
            self.io()
        self.ea_wrap = 0
        return ((<uint32_t>self.db << 16) + base + self.y) & 0xFFFFFF

    cdef inline uint32_t am_dpil(self) noexcept:
        """[dp]"""
        cdef uint32_t ptr = self.am_dp()
        cdef uint32_t a1 = self.nxt(ptr)
        cdef uint32_t a2 = self.nxt(a1)
        cdef uint32_t lo = self.read(ptr)
        cdef uint32_t hi = self.read(a1)
        cdef uint32_t bank = self.read(a2)
        self.ea_wrap = 0
        return (bank << 16) | (hi << 8) | lo

    cdef inline uint32_t am_dpily(self) noexcept:
        """[dp],Y"""
        cdef uint32_t base = self.am_dpil()
        self.ea_wrap = 0
        return (base + self.y) & 0xFFFFFF

    cdef inline uint32_t am_sr(self) noexcept:
        """sr,S"""
        cdef uint16_t off = self.fetch()
        self.io()
        self.ea_wrap = 1
        return (self.s + off) & 0xFFFF

    cdef inline uint32_t am_sriy(self) noexcept:
        """(sr,S),Y"""
        cdef uint16_t off = self.fetch()
        self.io()
        cdef uint32_t ptr = (self.s + off) & 0xFFFF
        cdef uint32_t lo = self.read(ptr)
        cdef uint32_t hi = self.read((ptr + 1) & 0xFFFF)
        self.io()
        self.ea_wrap = 0
        return ((<uint32_t>self.db << 16) + ((hi << 8) | lo) + self.y) & 0xFFFFFF

    # =====================================================================
    # flag helpers
    # =====================================================================

    cdef inline void set_nz(self, uint16_t value, int wide) noexcept:
        self.p &= ~(FLAG_N | FLAG_Z)
        if wide:
            if value == 0:
                self.p |= FLAG_Z
            if value & 0x8000:
                self.p |= FLAG_N
        else:
            if (value & 0xFF) == 0:
                self.p |= FLAG_Z
            if value & 0x80:
                self.p |= FLAG_N

    cdef inline void set_flag(self, int mask, int on) noexcept:
        if on:
            self.p |= mask
        else:
            self.p &= ~mask

    # =====================================================================
    # ALU
    # =====================================================================

    cdef void op_adc(self, uint16_t data, int wide) noexcept:
        cdef int32_t result
        cdef int carry = 1 if (self.p & FLAG_C) else 0
        cdef uint32_t acc

        if not wide:
            acc = self.a & 0xFF
            if not (self.p & FLAG_D):
                result = <int32_t>(acc + (data & 0xFF) + carry)
            else:
                result = <int32_t>((acc & 0x0F) + (data & 0x0F) + carry)
                if result > 0x09:
                    result += 0x06
                carry = 1 if result > 0x0F else 0
                result = <int32_t>((acc & 0xF0) + (data & 0xF0)
                                   + (<uint32_t>carry << 4) + (result & 0x0F))
            self.set_flag(FLAG_V, (~(acc ^ data) & (acc ^ <uint32_t>result) & 0x80) != 0)
            if (self.p & FLAG_D) and result > 0x9F:
                result += 0x60
            self.set_flag(FLAG_C, result > 0xFF)
            self.a = (self.a & 0xFF00) | <uint16_t>(result & 0xFF)
            self.set_nz(<uint16_t>(result & 0xFF), 0)
        else:
            acc = self.a
            if not (self.p & FLAG_D):
                result = <int32_t>(acc + data + carry)
            else:
                result = <int32_t>((acc & 0x000F) + (data & 0x000F) + carry)
                if result > 0x0009:
                    result += 0x0006
                carry = 1 if result > 0x000F else 0
                result = <int32_t>((acc & 0x00F0) + (data & 0x00F0)
                                   + (<uint32_t>carry << 4) + (result & 0x000F))
                if result > 0x009F:
                    result += 0x0060
                carry = 1 if result > 0x00FF else 0
                result = <int32_t>((acc & 0x0F00) + (data & 0x0F00)
                                   + (<uint32_t>carry << 8) + (result & 0x00FF))
                if result > 0x09FF:
                    result += 0x0600
                carry = 1 if result > 0x0FFF else 0
                result = <int32_t>((acc & 0xF000) + (data & 0xF000)
                                   + (<uint32_t>carry << 12) + (result & 0x0FFF))
            self.set_flag(FLAG_V, (~(acc ^ data) & (acc ^ <uint32_t>result) & 0x8000) != 0)
            if (self.p & FLAG_D) and result > 0x9FFF:
                result += 0x6000
            self.set_flag(FLAG_C, result > 0xFFFF)
            self.a = <uint16_t>(result & 0xFFFF)
            self.set_nz(self.a, 1)

    cdef void op_sbc(self, uint16_t data, int wide) noexcept:
        cdef int32_t result
        cdef int carry = 1 if (self.p & FLAG_C) else 0
        cdef uint32_t acc

        if not wide:
            data = (~data) & 0xFF
            acc = self.a & 0xFF
            if not (self.p & FLAG_D):
                result = <int32_t>(acc + data + carry)
            else:
                result = <int32_t>((acc & 0x0F) + (data & 0x0F) + carry)
                if result <= 0x0F:
                    result -= 0x06
                carry = 1 if result > 0x0F else 0
                result = <int32_t>((acc & 0xF0) + (data & 0xF0)
                                   + (<uint32_t>carry << 4) + (result & 0x0F))
            self.set_flag(FLAG_V, (~(acc ^ data) & (acc ^ <uint32_t>result) & 0x80) != 0)
            if (self.p & FLAG_D) and result <= 0xFF:
                result -= 0x60
            self.set_flag(FLAG_C, result > 0xFF)
            self.a = (self.a & 0xFF00) | <uint16_t>(result & 0xFF)
            self.set_nz(<uint16_t>(result & 0xFF), 0)
        else:
            data = (~data) & 0xFFFF
            acc = self.a
            if not (self.p & FLAG_D):
                result = <int32_t>(acc + data + carry)
            else:
                result = <int32_t>((acc & 0x000F) + (data & 0x000F) + carry)
                if result <= 0x000F:
                    result -= 0x0006
                carry = 1 if result > 0x000F else 0
                result = <int32_t>((acc & 0x00F0) + (data & 0x00F0)
                                   + (<uint32_t>carry << 4) + (result & 0x000F))
                if result <= 0x00FF:
                    result -= 0x0060
                carry = 1 if result > 0x00FF else 0
                result = <int32_t>((acc & 0x0F00) + (data & 0x0F00)
                                   + (<uint32_t>carry << 8) + (result & 0x00FF))
                if result <= 0x0FFF:
                    result -= 0x0600
                carry = 1 if result > 0x0FFF else 0
                result = <int32_t>((acc & 0xF000) + (data & 0xF000)
                                   + (<uint32_t>carry << 12) + (result & 0x0FFF))
            self.set_flag(FLAG_V, (~(acc ^ data) & (acc ^ <uint32_t>result) & 0x8000) != 0)
            if (self.p & FLAG_D) and result <= 0xFFFF:
                result -= 0x6000
            self.set_flag(FLAG_C, result > 0xFFFF)
            self.a = <uint16_t>(result & 0xFFFF)
            self.set_nz(self.a, 1)

    cdef inline void op_cmp(self, uint16_t reg, uint16_t data, int wide) noexcept:
        cdef int32_t result
        if wide:
            result = <int32_t>reg - <int32_t>data
            self.set_flag(FLAG_C, result >= 0)
            self.set_nz(<uint16_t>(result & 0xFFFF), 1)
        else:
            result = <int32_t>(reg & 0xFF) - <int32_t>(data & 0xFF)
            self.set_flag(FLAG_C, result >= 0)
            self.set_nz(<uint16_t>(result & 0xFF), 0)

    cdef inline void op_bit(self, uint16_t data, int wide) noexcept:
        if wide:
            self.set_flag(FLAG_N, (data & 0x8000) != 0)
            self.set_flag(FLAG_V, (data & 0x4000) != 0)
            self.set_flag(FLAG_Z, (self.a & data) == 0)
        else:
            self.set_flag(FLAG_N, (data & 0x80) != 0)
            self.set_flag(FLAG_V, (data & 0x40) != 0)
            self.set_flag(FLAG_Z, ((self.a & data) & 0xFF) == 0)

    cdef inline uint16_t alu_asl(self, uint16_t v, int wide) noexcept:
        if wide:
            self.set_flag(FLAG_C, (v & 0x8000) != 0)
            v = <uint16_t>(v << 1)
        else:
            self.set_flag(FLAG_C, (v & 0x80) != 0)
            v = <uint16_t>((v << 1) & 0xFF)
        self.set_nz(v, wide)
        return v

    cdef inline uint16_t alu_lsr(self, uint16_t v, int wide) noexcept:
        self.set_flag(FLAG_C, (v & 1) != 0)
        if wide:
            v = v >> 1
        else:
            v = (v & 0xFF) >> 1
        self.set_nz(v, wide)
        return v

    cdef inline uint16_t alu_rol(self, uint16_t v, int wide) noexcept:
        cdef int carry = 1 if (self.p & FLAG_C) else 0
        if wide:
            self.set_flag(FLAG_C, (v & 0x8000) != 0)
            v = <uint16_t>((v << 1) | carry)
        else:
            self.set_flag(FLAG_C, (v & 0x80) != 0)
            v = <uint16_t>(((v << 1) | carry) & 0xFF)
        self.set_nz(v, wide)
        return v

    cdef inline uint16_t alu_ror(self, uint16_t v, int wide) noexcept:
        cdef int carry = 1 if (self.p & FLAG_C) else 0
        self.set_flag(FLAG_C, (v & 1) != 0)
        if wide:
            v = <uint16_t>((v >> 1) | (carry << 15))
        else:
            v = <uint16_t>(((v & 0xFF) >> 1) | (carry << 7))
        self.set_nz(v, wide)
        return v

    # -- read-modify-write on memory ---------------------------------------

    cdef inline void rmw(self, uint32_t addr, int kind, int wide) noexcept:
        """kind: 0 ASL, 1 LSR, 2 ROL, 3 ROR, 4 INC, 5 DEC, 6 TSB, 7 TRB"""
        cdef uint16_t v = self.load(addr, wide)
        self.io()
        if kind == 0:
            v = self.alu_asl(v, wide)
        elif kind == 1:
            v = self.alu_lsr(v, wide)
        elif kind == 2:
            v = self.alu_rol(v, wide)
        elif kind == 3:
            v = self.alu_ror(v, wide)
        elif kind == 4:
            v = <uint16_t>(v + 1) if wide else <uint16_t>((v + 1) & 0xFF)
            self.set_nz(v, wide)
        elif kind == 5:
            v = <uint16_t>(v - 1) if wide else <uint16_t>((v - 1) & 0xFF)
            self.set_nz(v, wide)
        elif kind == 6:
            self.set_flag(FLAG_Z, ((self.a & v) & (0xFFFF if wide else 0xFF)) == 0)
            v = v | (self.a if wide else (self.a & 0xFF))
        else:
            self.set_flag(FLAG_Z, ((self.a & v) & (0xFFFF if wide else 0xFF)) == 0)
            v = v & ~(self.a if wide else (self.a & 0xFF))
        # RMW writes the high byte first.
        if wide:
            self.write(self.nxt(addr), <uint8_t>(v >> 8))
        self.write(addr, <uint8_t>(v & 0xFF))

    # =====================================================================
    # control flow helpers
    # =====================================================================

    cdef inline void branch(self, int taken) noexcept:
        cdef int8_t offset = <int8_t>self.fetch()
        cdef uint16_t target
        if not taken:
            return
        target = <uint16_t>((self.pc + offset) & 0xFFFF)
        self.io()
        if self.e and ((self.pc ^ target) & 0xFF00):
            self.io()
        self.pc = target

    cdef void interrupt(self, uint16_t vector, int is_brk) noexcept:
        cdef uint8_t pushed = self.p
        self.io()
        self.io()
        if not self.e:
            self.push(self.pb)
        else:
            # In emulation mode bit 4 of the pushed status is the B flag; it
            # must not disturb the live X (index width) bit.
            pushed = (self.p | FLAG_B) if is_brk else (self.p & ~FLAG_B)
        self.push16(self.pc)
        self.push(pushed)
        self.p |= FLAG_I
        self.p &= ~FLAG_D
        self.pb = 0
        self.pc = (<uint16_t>self.read(vector)
                   | (<uint16_t>self.read(vector + 1) << 8))

    cdef inline void apply_index_width(self) noexcept:
        if self.p & FLAG_X:
            self.x &= 0xFF
            self.y &= 0xFF

    # =====================================================================
    # step
    # =====================================================================

    cdef void step(self) noexcept:
        cdef uint8_t op

        if self.stopped:
            self.bus.tick(6)
            return

        if self.waiting:
            if self.bus.nmi_pending or self.bus.irq_pending:
                self.waiting = 0
                self.io()
            else:
                self.bus.tick(6)
                return

        if self.bus.nmi_pending:
            self.bus.nmi_pending = 0
            if self.e:
                self.interrupt(VEC_EMU_NMI, 0)
            else:
                self.interrupt(VEC_NATIVE_NMI, 0)
            return

        if self.bus.irq_pending and not (self.p & FLAG_I):
            if self.e:
                self.interrupt(VEC_EMU_IRQ, 0)
            else:
                self.interrupt(VEC_NATIVE_IRQ, 0)
            return

        if self.tracing:
            # State before the fetch, so a record describes the machine as the
            # instruction saw it.
            self._log_insn(self.bus.read8_fast((<uint32_t>self.pb << 16) | self.pc))
        op = self.fetch()
        self.instructions += 1
        self.execute(op)

    # =====================================================================
    # instruction dispatch
    # =====================================================================

    cdef void execute(self, uint8_t op) noexcept:
        cdef int m = 0 if (self.e or (self.p & FLAG_M)) else 1   # 16-bit accumulator
        cdef int xw = 0 if (self.e or (self.p & FLAG_X)) else 1  # 16-bit index
        cdef uint32_t ea, ptr, tmp32
        cdef uint16_t v16, target
        cdef uint8_t v8, src_bank, dst_bank
        cdef int i

        # ---- ORA ---------------------------------------------------------
        if op == 0x09:
            self.a = self._ora(self.load(self.am_imm(m), m), m)
        elif op == 0x05:
            self.a = self._ora(self.load(self.am_dp(), m), m)
        elif op == 0x15:
            self.a = self._ora(self.load(self.am_dpx(), m), m)
        elif op == 0x0D:
            self.a = self._ora(self.load(self.am_abs(), m), m)
        elif op == 0x1D:
            self.a = self._ora(self.load(self.am_absx(0), m), m)
        elif op == 0x19:
            self.a = self._ora(self.load(self.am_absy(0), m), m)
        elif op == 0x0F:
            self.a = self._ora(self.load(self.am_long(), m), m)
        elif op == 0x1F:
            self.a = self._ora(self.load(self.am_longx(), m), m)
        elif op == 0x01:
            self.a = self._ora(self.load(self.am_dpix(), m), m)
        elif op == 0x11:
            self.a = self._ora(self.load(self.am_dpiy(0), m), m)
        elif op == 0x12:
            self.a = self._ora(self.load(self.am_dpi(), m), m)
        elif op == 0x07:
            self.a = self._ora(self.load(self.am_dpil(), m), m)
        elif op == 0x17:
            self.a = self._ora(self.load(self.am_dpily(), m), m)
        elif op == 0x03:
            self.a = self._ora(self.load(self.am_sr(), m), m)
        elif op == 0x13:
            self.a = self._ora(self.load(self.am_sriy(), m), m)

        # ---- AND ---------------------------------------------------------
        elif op == 0x29:
            self.a = self._and(self.load(self.am_imm(m), m), m)
        elif op == 0x25:
            self.a = self._and(self.load(self.am_dp(), m), m)
        elif op == 0x35:
            self.a = self._and(self.load(self.am_dpx(), m), m)
        elif op == 0x2D:
            self.a = self._and(self.load(self.am_abs(), m), m)
        elif op == 0x3D:
            self.a = self._and(self.load(self.am_absx(0), m), m)
        elif op == 0x39:
            self.a = self._and(self.load(self.am_absy(0), m), m)
        elif op == 0x2F:
            self.a = self._and(self.load(self.am_long(), m), m)
        elif op == 0x3F:
            self.a = self._and(self.load(self.am_longx(), m), m)
        elif op == 0x21:
            self.a = self._and(self.load(self.am_dpix(), m), m)
        elif op == 0x31:
            self.a = self._and(self.load(self.am_dpiy(0), m), m)
        elif op == 0x32:
            self.a = self._and(self.load(self.am_dpi(), m), m)
        elif op == 0x27:
            self.a = self._and(self.load(self.am_dpil(), m), m)
        elif op == 0x37:
            self.a = self._and(self.load(self.am_dpily(), m), m)
        elif op == 0x23:
            self.a = self._and(self.load(self.am_sr(), m), m)
        elif op == 0x33:
            self.a = self._and(self.load(self.am_sriy(), m), m)

        # ---- EOR ---------------------------------------------------------
        elif op == 0x49:
            self.a = self._eor(self.load(self.am_imm(m), m), m)
        elif op == 0x45:
            self.a = self._eor(self.load(self.am_dp(), m), m)
        elif op == 0x55:
            self.a = self._eor(self.load(self.am_dpx(), m), m)
        elif op == 0x4D:
            self.a = self._eor(self.load(self.am_abs(), m), m)
        elif op == 0x5D:
            self.a = self._eor(self.load(self.am_absx(0), m), m)
        elif op == 0x59:
            self.a = self._eor(self.load(self.am_absy(0), m), m)
        elif op == 0x4F:
            self.a = self._eor(self.load(self.am_long(), m), m)
        elif op == 0x5F:
            self.a = self._eor(self.load(self.am_longx(), m), m)
        elif op == 0x41:
            self.a = self._eor(self.load(self.am_dpix(), m), m)
        elif op == 0x51:
            self.a = self._eor(self.load(self.am_dpiy(0), m), m)
        elif op == 0x52:
            self.a = self._eor(self.load(self.am_dpi(), m), m)
        elif op == 0x47:
            self.a = self._eor(self.load(self.am_dpil(), m), m)
        elif op == 0x57:
            self.a = self._eor(self.load(self.am_dpily(), m), m)
        elif op == 0x43:
            self.a = self._eor(self.load(self.am_sr(), m), m)
        elif op == 0x53:
            self.a = self._eor(self.load(self.am_sriy(), m), m)

        # ---- ADC ---------------------------------------------------------
        elif op == 0x69:
            self.op_adc(self.load(self.am_imm(m), m), m)
        elif op == 0x65:
            self.op_adc(self.load(self.am_dp(), m), m)
        elif op == 0x75:
            self.op_adc(self.load(self.am_dpx(), m), m)
        elif op == 0x6D:
            self.op_adc(self.load(self.am_abs(), m), m)
        elif op == 0x7D:
            self.op_adc(self.load(self.am_absx(0), m), m)
        elif op == 0x79:
            self.op_adc(self.load(self.am_absy(0), m), m)
        elif op == 0x6F:
            self.op_adc(self.load(self.am_long(), m), m)
        elif op == 0x7F:
            self.op_adc(self.load(self.am_longx(), m), m)
        elif op == 0x61:
            self.op_adc(self.load(self.am_dpix(), m), m)
        elif op == 0x71:
            self.op_adc(self.load(self.am_dpiy(0), m), m)
        elif op == 0x72:
            self.op_adc(self.load(self.am_dpi(), m), m)
        elif op == 0x67:
            self.op_adc(self.load(self.am_dpil(), m), m)
        elif op == 0x77:
            self.op_adc(self.load(self.am_dpily(), m), m)
        elif op == 0x63:
            self.op_adc(self.load(self.am_sr(), m), m)
        elif op == 0x73:
            self.op_adc(self.load(self.am_sriy(), m), m)

        # ---- SBC ---------------------------------------------------------
        elif op == 0xE9:
            self.op_sbc(self.load(self.am_imm(m), m), m)
        elif op == 0xE5:
            self.op_sbc(self.load(self.am_dp(), m), m)
        elif op == 0xF5:
            self.op_sbc(self.load(self.am_dpx(), m), m)
        elif op == 0xED:
            self.op_sbc(self.load(self.am_abs(), m), m)
        elif op == 0xFD:
            self.op_sbc(self.load(self.am_absx(0), m), m)
        elif op == 0xF9:
            self.op_sbc(self.load(self.am_absy(0), m), m)
        elif op == 0xEF:
            self.op_sbc(self.load(self.am_long(), m), m)
        elif op == 0xFF:
            self.op_sbc(self.load(self.am_longx(), m), m)
        elif op == 0xE1:
            self.op_sbc(self.load(self.am_dpix(), m), m)
        elif op == 0xF1:
            self.op_sbc(self.load(self.am_dpiy(0), m), m)
        elif op == 0xF2:
            self.op_sbc(self.load(self.am_dpi(), m), m)
        elif op == 0xE7:
            self.op_sbc(self.load(self.am_dpil(), m), m)
        elif op == 0xF7:
            self.op_sbc(self.load(self.am_dpily(), m), m)
        elif op == 0xE3:
            self.op_sbc(self.load(self.am_sr(), m), m)
        elif op == 0xF3:
            self.op_sbc(self.load(self.am_sriy(), m), m)

        # ---- CMP ---------------------------------------------------------
        elif op == 0xC9:
            self.op_cmp(self.a, self.load(self.am_imm(m), m), m)
        elif op == 0xC5:
            self.op_cmp(self.a, self.load(self.am_dp(), m), m)
        elif op == 0xD5:
            self.op_cmp(self.a, self.load(self.am_dpx(), m), m)
        elif op == 0xCD:
            self.op_cmp(self.a, self.load(self.am_abs(), m), m)
        elif op == 0xDD:
            self.op_cmp(self.a, self.load(self.am_absx(0), m), m)
        elif op == 0xD9:
            self.op_cmp(self.a, self.load(self.am_absy(0), m), m)
        elif op == 0xCF:
            self.op_cmp(self.a, self.load(self.am_long(), m), m)
        elif op == 0xDF:
            self.op_cmp(self.a, self.load(self.am_longx(), m), m)
        elif op == 0xC1:
            self.op_cmp(self.a, self.load(self.am_dpix(), m), m)
        elif op == 0xD1:
            self.op_cmp(self.a, self.load(self.am_dpiy(0), m), m)
        elif op == 0xD2:
            self.op_cmp(self.a, self.load(self.am_dpi(), m), m)
        elif op == 0xC7:
            self.op_cmp(self.a, self.load(self.am_dpil(), m), m)
        elif op == 0xD7:
            self.op_cmp(self.a, self.load(self.am_dpily(), m), m)
        elif op == 0xC3:
            self.op_cmp(self.a, self.load(self.am_sr(), m), m)
        elif op == 0xD3:
            self.op_cmp(self.a, self.load(self.am_sriy(), m), m)

        # ---- CPX / CPY ----------------------------------------------------
        elif op == 0xE0:
            self.op_cmp(self.x, self.load(self.am_imm(xw), xw), xw)
        elif op == 0xE4:
            self.op_cmp(self.x, self.load(self.am_dp(), xw), xw)
        elif op == 0xEC:
            self.op_cmp(self.x, self.load(self.am_abs(), xw), xw)
        elif op == 0xC0:
            self.op_cmp(self.y, self.load(self.am_imm(xw), xw), xw)
        elif op == 0xC4:
            self.op_cmp(self.y, self.load(self.am_dp(), xw), xw)
        elif op == 0xCC:
            self.op_cmp(self.y, self.load(self.am_abs(), xw), xw)

        # ---- LDA ----------------------------------------------------------
        elif op == 0xA9:
            self._lda(self.load(self.am_imm(m), m), m)
        elif op == 0xA5:
            self._lda(self.load(self.am_dp(), m), m)
        elif op == 0xB5:
            self._lda(self.load(self.am_dpx(), m), m)
        elif op == 0xAD:
            self._lda(self.load(self.am_abs(), m), m)
        elif op == 0xBD:
            self._lda(self.load(self.am_absx(0), m), m)
        elif op == 0xB9:
            self._lda(self.load(self.am_absy(0), m), m)
        elif op == 0xAF:
            self._lda(self.load(self.am_long(), m), m)
        elif op == 0xBF:
            self._lda(self.load(self.am_longx(), m), m)
        elif op == 0xA1:
            self._lda(self.load(self.am_dpix(), m), m)
        elif op == 0xB1:
            self._lda(self.load(self.am_dpiy(0), m), m)
        elif op == 0xB2:
            self._lda(self.load(self.am_dpi(), m), m)
        elif op == 0xA7:
            self._lda(self.load(self.am_dpil(), m), m)
        elif op == 0xB7:
            self._lda(self.load(self.am_dpily(), m), m)
        elif op == 0xA3:
            self._lda(self.load(self.am_sr(), m), m)
        elif op == 0xB3:
            self._lda(self.load(self.am_sriy(), m), m)

        # ---- LDX / LDY ------------------------------------------------------
        elif op == 0xA2:
            self.x = self.load(self.am_imm(xw), xw); self.set_nz(self.x, xw)
        elif op == 0xA6:
            self.x = self.load(self.am_dp(), xw); self.set_nz(self.x, xw)
        elif op == 0xB6:
            self.x = self.load(self.am_dpy(), xw); self.set_nz(self.x, xw)
        elif op == 0xAE:
            self.x = self.load(self.am_abs(), xw); self.set_nz(self.x, xw)
        elif op == 0xBE:
            self.x = self.load(self.am_absy(0), xw); self.set_nz(self.x, xw)
        elif op == 0xA0:
            self.y = self.load(self.am_imm(xw), xw); self.set_nz(self.y, xw)
        elif op == 0xA4:
            self.y = self.load(self.am_dp(), xw); self.set_nz(self.y, xw)
        elif op == 0xB4:
            self.y = self.load(self.am_dpx(), xw); self.set_nz(self.y, xw)
        elif op == 0xAC:
            self.y = self.load(self.am_abs(), xw); self.set_nz(self.y, xw)
        elif op == 0xBC:
            self.y = self.load(self.am_absx(0), xw); self.set_nz(self.y, xw)

        # ---- STA ------------------------------------------------------------
        elif op == 0x85:
            self.store(self.am_dp(), self.a, m)
        elif op == 0x95:
            self.store(self.am_dpx(), self.a, m)
        elif op == 0x8D:
            self.store(self.am_abs(), self.a, m)
        elif op == 0x9D:
            self.store(self.am_absx(1), self.a, m)
        elif op == 0x99:
            self.store(self.am_absy(1), self.a, m)
        elif op == 0x8F:
            self.store(self.am_long(), self.a, m)
        elif op == 0x9F:
            self.store(self.am_longx(), self.a, m)
        elif op == 0x81:
            self.store(self.am_dpix(), self.a, m)
        elif op == 0x91:
            self.store(self.am_dpiy(1), self.a, m)
        elif op == 0x92:
            self.store(self.am_dpi(), self.a, m)
        elif op == 0x87:
            self.store(self.am_dpil(), self.a, m)
        elif op == 0x97:
            self.store(self.am_dpily(), self.a, m)
        elif op == 0x83:
            self.store(self.am_sr(), self.a, m)
        elif op == 0x93:
            self.store(self.am_sriy(), self.a, m)

        # ---- STX / STY / STZ -------------------------------------------------
        elif op == 0x86:
            self.store(self.am_dp(), self.x, xw)
        elif op == 0x96:
            self.store(self.am_dpy(), self.x, xw)
        elif op == 0x8E:
            self.store(self.am_abs(), self.x, xw)
        elif op == 0x84:
            self.store(self.am_dp(), self.y, xw)
        elif op == 0x94:
            self.store(self.am_dpx(), self.y, xw)
        elif op == 0x8C:
            self.store(self.am_abs(), self.y, xw)
        elif op == 0x64:
            self.store(self.am_dp(), 0, m)
        elif op == 0x74:
            self.store(self.am_dpx(), 0, m)
        elif op == 0x9C:
            self.store(self.am_abs(), 0, m)
        elif op == 0x9E:
            self.store(self.am_absx(1), 0, m)

        # ---- BIT --------------------------------------------------------------
        elif op == 0x89:
            # immediate BIT only affects Z
            v16 = self.load(self.am_imm(m), m)
            self.set_flag(FLAG_Z, ((self.a & v16) & (0xFFFF if m else 0xFF)) == 0)
        elif op == 0x24:
            self.op_bit(self.load(self.am_dp(), m), m)
        elif op == 0x34:
            self.op_bit(self.load(self.am_dpx(), m), m)
        elif op == 0x2C:
            self.op_bit(self.load(self.am_abs(), m), m)
        elif op == 0x3C:
            self.op_bit(self.load(self.am_absx(0), m), m)

        # ---- shifts / rotates on A ---------------------------------------------
        elif op == 0x0A:
            self.io(); self.a = self._acc_write(self.alu_asl(self._acc_read(m), m), m)
        elif op == 0x4A:
            self.io(); self.a = self._acc_write(self.alu_lsr(self._acc_read(m), m), m)
        elif op == 0x2A:
            self.io(); self.a = self._acc_write(self.alu_rol(self._acc_read(m), m), m)
        elif op == 0x6A:
            self.io(); self.a = self._acc_write(self.alu_ror(self._acc_read(m), m), m)
        elif op == 0x1A:                                    # INC A
            self.io()
            v16 = <uint16_t>(self._acc_read(m) + 1)
            if not m:
                v16 &= 0xFF
            self.set_nz(v16, m)
            self.a = self._acc_write(v16, m)
        elif op == 0x3A:                                    # DEC A
            self.io()
            v16 = <uint16_t>(self._acc_read(m) - 1)
            if not m:
                v16 &= 0xFF
            self.set_nz(v16, m)
            self.a = self._acc_write(v16, m)

        # ---- shifts / rotates / inc / dec on memory -----------------------------
        elif op == 0x06:
            self.rmw(self.am_dp(), 0, m)
        elif op == 0x16:
            self.rmw(self.am_dpx(), 0, m)
        elif op == 0x0E:
            self.rmw(self.am_abs(), 0, m)
        elif op == 0x1E:
            self.rmw(self.am_absx(1), 0, m)
        elif op == 0x46:
            self.rmw(self.am_dp(), 1, m)
        elif op == 0x56:
            self.rmw(self.am_dpx(), 1, m)
        elif op == 0x4E:
            self.rmw(self.am_abs(), 1, m)
        elif op == 0x5E:
            self.rmw(self.am_absx(1), 1, m)
        elif op == 0x26:
            self.rmw(self.am_dp(), 2, m)
        elif op == 0x36:
            self.rmw(self.am_dpx(), 2, m)
        elif op == 0x2E:
            self.rmw(self.am_abs(), 2, m)
        elif op == 0x3E:
            self.rmw(self.am_absx(1), 2, m)
        elif op == 0x66:
            self.rmw(self.am_dp(), 3, m)
        elif op == 0x76:
            self.rmw(self.am_dpx(), 3, m)
        elif op == 0x6E:
            self.rmw(self.am_abs(), 3, m)
        elif op == 0x7E:
            self.rmw(self.am_absx(1), 3, m)
        elif op == 0xE6:
            self.rmw(self.am_dp(), 4, m)
        elif op == 0xF6:
            self.rmw(self.am_dpx(), 4, m)
        elif op == 0xEE:
            self.rmw(self.am_abs(), 4, m)
        elif op == 0xFE:
            self.rmw(self.am_absx(1), 4, m)
        elif op == 0xC6:
            self.rmw(self.am_dp(), 5, m)
        elif op == 0xD6:
            self.rmw(self.am_dpx(), 5, m)
        elif op == 0xCE:
            self.rmw(self.am_abs(), 5, m)
        elif op == 0xDE:
            self.rmw(self.am_absx(1), 5, m)
        elif op == 0x04:
            self.rmw(self.am_dp(), 6, m)                    # TSB dp
        elif op == 0x0C:
            self.rmw(self.am_abs(), 6, m)                   # TSB abs
        elif op == 0x14:
            self.rmw(self.am_dp(), 7, m)                    # TRB dp
        elif op == 0x1C:
            self.rmw(self.am_abs(), 7, m)                   # TRB abs

        # ---- index inc / dec ---------------------------------------------------
        elif op == 0xE8:
            self.io()
            self.x = <uint16_t>(self.x + 1) if xw else <uint16_t>((self.x + 1) & 0xFF)
            self.set_nz(self.x, xw)
        elif op == 0xCA:
            self.io()
            self.x = <uint16_t>(self.x - 1) if xw else <uint16_t>((self.x - 1) & 0xFF)
            self.set_nz(self.x, xw)
        elif op == 0xC8:
            self.io()
            self.y = <uint16_t>(self.y + 1) if xw else <uint16_t>((self.y + 1) & 0xFF)
            self.set_nz(self.y, xw)
        elif op == 0x88:
            self.io()
            self.y = <uint16_t>(self.y - 1) if xw else <uint16_t>((self.y - 1) & 0xFF)
            self.set_nz(self.y, xw)

        # ---- branches -----------------------------------------------------------
        elif op == 0x10:
            self.branch(not (self.p & FLAG_N))
        elif op == 0x30:
            self.branch(1 if (self.p & FLAG_N) else 0)
        elif op == 0x50:
            self.branch(not (self.p & FLAG_V))
        elif op == 0x70:
            self.branch(1 if (self.p & FLAG_V) else 0)
        elif op == 0x90:
            self.branch(not (self.p & FLAG_C))
        elif op == 0xB0:
            self.branch(1 if (self.p & FLAG_C) else 0)
        elif op == 0xD0:
            self.branch(not (self.p & FLAG_Z))
        elif op == 0xF0:
            self.branch(1 if (self.p & FLAG_Z) else 0)
        elif op == 0x80:
            self.branch(1)
        elif op == 0x82:                                    # BRL
            v16 = self.fetch16()
            self.io()
            self.pc = <uint16_t>((self.pc + <int16_t>v16) & 0xFFFF)

        # ---- jumps / calls --------------------------------------------------------
        elif op == 0x4C:                                    # JMP abs
            self.pc = self.fetch16()
        elif op == 0x5C:                                    # JML long
            v16 = self.fetch16()
            self.pb = self.fetch()
            self.pc = v16
        elif op == 0x6C:                                    # JMP (abs)
            ptr = self.fetch16()
            self.pc = (<uint16_t>self.read(ptr)
                       | (<uint16_t>self.read((ptr + 1) & 0xFFFF) << 8))
        elif op == 0x7C:                                    # JMP (abs,X)
            ptr = self.fetch16()
            self.io()
            ptr = ((<uint32_t>self.pb << 16) | ((ptr + self.x) & 0xFFFF))
            self.pc = (<uint16_t>self.read(ptr)
                       | (<uint16_t>self.read((ptr & 0xFF0000)
                                              | ((ptr + 1) & 0xFFFF)) << 8))
        elif op == 0xDC:                                    # JML [abs]
            ptr = self.fetch16()
            self.pc = (<uint16_t>self.read(ptr)
                       | (<uint16_t>self.read((ptr + 1) & 0xFFFF) << 8))
            self.pb = self.read((ptr + 2) & 0xFFFF)
        elif op == 0x20:                                    # JSR abs
            v16 = self.fetch16()
            self.io()
            self.push16(<uint16_t>((self.pc - 1) & 0xFFFF))
            self.pc = v16
        elif op == 0xFC:                                    # JSR (abs,X)
            v16 = self.fetch16()
            self.push16(<uint16_t>((self.pc - 1) & 0xFFFF))
            self.io()
            ptr = (<uint32_t>self.pb << 16) | ((v16 + self.x) & 0xFFFF)
            self.pc = (<uint16_t>self.read(ptr)
                       | (<uint16_t>self.read((ptr & 0xFF0000)
                                              | ((ptr + 1) & 0xFFFF)) << 8))
        elif op == 0x22:                                    # JSL long
            v16 = self.fetch16()
            self.push(self.pb)
            self.io()
            src_bank = self.fetch()
            self.push16(<uint16_t>((self.pc - 1) & 0xFFFF))
            self.pb = src_bank
            self.pc = v16
        elif op == 0x60:                                    # RTS
            self.io(); self.io()
            self.pc = <uint16_t>((self.pull16() + 1) & 0xFFFF)
            self.io()
        elif op == 0x6B:                                    # RTL
            self.io(); self.io()
            self.pc = <uint16_t>((self.pull16() + 1) & 0xFFFF)
            self.pb = self.pull()
        elif op == 0x40:                                    # RTI
            self.io(); self.io()
            self.p = self.pull()
            if self.e:
                self.p |= FLAG_M | FLAG_X
            self.pc = self.pull16()
            if not self.e:
                self.pb = self.pull()
            self.apply_index_width()

        # ---- stack ------------------------------------------------------------------
        elif op == 0x48:                                    # PHA
            self.io()
            if m:
                self.push(<uint8_t>(self.a >> 8))
            self.push(<uint8_t>(self.a & 0xFF))
        elif op == 0x68:                                    # PLA
            self.io(); self.io()
            if m:
                self.a = self.pull16()
            else:
                self.a = (self.a & 0xFF00) | self.pull()
            self.set_nz(self.a, m)
        elif op == 0xDA:                                    # PHX
            self.io()
            if xw:
                self.push(<uint8_t>(self.x >> 8))
            self.push(<uint8_t>(self.x & 0xFF))
        elif op == 0xFA:                                    # PLX
            self.io(); self.io()
            if xw:
                self.x = self.pull16()
            else:
                self.x = self.pull()
            self.set_nz(self.x, xw)
        elif op == 0x5A:                                    # PHY
            self.io()
            if xw:
                self.push(<uint8_t>(self.y >> 8))
            self.push(<uint8_t>(self.y & 0xFF))
        elif op == 0x7A:                                    # PLY
            self.io(); self.io()
            if xw:
                self.y = self.pull16()
            else:
                self.y = self.pull()
            self.set_nz(self.y, xw)
        elif op == 0x08:                                    # PHP
            self.io()
            self.push(self.p)
        elif op == 0x28:                                    # PLP
            self.io(); self.io()
            self.p = self.pull()
            if self.e:
                self.p |= FLAG_M | FLAG_X
            self.apply_index_width()
        elif op == 0x8B:                                    # PHB
            self.io()
            self.push(self.db)
        elif op == 0xAB:                                    # PLB
            self.io(); self.io()
            self.db = self.pull()
            self.set_nz(self.db, 0)
        elif op == 0x0B:                                    # PHD
            self.io()
            self.push16(self.d)
        elif op == 0x2B:                                    # PLD
            self.io(); self.io()
            self.d = self.pull16()
            self.set_nz(self.d, 1)
        elif op == 0x4B:                                    # PHK
            self.io()
            self.push(self.pb)
        elif op == 0xF4:                                    # PEA
            self.push16(self.fetch16())
        elif op == 0xD4:                                    # PEI
            ea = self.am_dp()
            self.push16(self.load(ea, 1))
        elif op == 0x62:                                    # PER
            v16 = self.fetch16()
            self.io()
            self.push16(<uint16_t>((self.pc + <int16_t>v16) & 0xFFFF))

        # ---- flags ---------------------------------------------------------------------
        elif op == 0x18:
            self.io(); self.p &= ~FLAG_C
        elif op == 0x38:
            self.io(); self.p |= FLAG_C
        elif op == 0x58:
            self.io(); self.p &= ~FLAG_I
        elif op == 0x78:
            self.io(); self.p |= FLAG_I
        elif op == 0xB8:
            self.io(); self.p &= ~FLAG_V
        elif op == 0xD8:
            self.io(); self.p &= ~FLAG_D
        elif op == 0xF8:
            self.io(); self.p |= FLAG_D
        elif op == 0xC2:                                    # REP
            v8 = self.fetch()
            self.io()
            self.p &= ~v8
            if self.e:
                self.p |= FLAG_M | FLAG_X
            self.apply_index_width()
        elif op == 0xE2:                                    # SEP
            v8 = self.fetch()
            self.io()
            self.p |= v8
            self.apply_index_width()
        elif op == 0xFB:                                    # XCE
            self.io()
            i = self.e
            self.e = 1 if (self.p & FLAG_C) else 0
            self.set_flag(FLAG_C, i)
            if self.e:
                self.p |= FLAG_M | FLAG_X
                self.s = 0x0100 | (self.s & 0xFF)
            self.apply_index_width()

        # ---- transfers -------------------------------------------------------------------
        elif op == 0xAA:                                    # TAX
            self.io()
            self.x = self.a if xw else (self.a & 0xFF)
            self.set_nz(self.x, xw)
        elif op == 0xA8:                                    # TAY
            self.io()
            self.y = self.a if xw else (self.a & 0xFF)
            self.set_nz(self.y, xw)
        elif op == 0x8A:                                    # TXA
            self.io()
            if m:
                self.a = self.x
            else:
                self.a = (self.a & 0xFF00) | (self.x & 0xFF)
            self.set_nz(self.a, m)
        elif op == 0x98:                                    # TYA
            self.io()
            if m:
                self.a = self.y
            else:
                self.a = (self.a & 0xFF00) | (self.y & 0xFF)
            self.set_nz(self.a, m)
        elif op == 0xBA:                                    # TSX
            self.io()
            self.x = self.s if xw else (self.s & 0xFF)
            self.set_nz(self.x, xw)
        elif op == 0x9A:                                    # TXS
            self.io()
            self.s = 0x0100 | (self.x & 0xFF) if self.e else self.x
        elif op == 0x9B:                                    # TXY
            self.io()
            self.y = self.x if xw else (self.x & 0xFF)
            self.set_nz(self.y, xw)
        elif op == 0xBB:                                    # TYX
            self.io()
            self.x = self.y if xw else (self.y & 0xFF)
            self.set_nz(self.x, xw)
        elif op == 0x5B:                                    # TCD
            self.io()
            self.d = self.a
            self.set_nz(self.d, 1)
        elif op == 0x7B:                                    # TDC
            self.io()
            self.a = self.d
            self.set_nz(self.a, 1)
        elif op == 0x1B:                                    # TCS
            self.io()
            self.s = 0x0100 | (self.a & 0xFF) if self.e else self.a
        elif op == 0x3B:                                    # TSC
            self.io()
            self.a = self.s
            self.set_nz(self.a, 1)
        elif op == 0xEB:                                    # XBA
            self.io(); self.io()
            self.a = <uint16_t>((self.a >> 8) | (self.a << 8))
            self.set_nz(self.a, 0)

        # ---- block moves ---------------------------------------------------------------------
        elif op == 0x54 or op == 0x44:                      # MVN / MVP
            dst_bank = self.fetch()
            src_bank = self.fetch()
            self.db = dst_bank
            v8 = self.read((<uint32_t>src_bank << 16) | self.x)
            self.write((<uint32_t>dst_bank << 16) | self.y, v8)
            self.io(); self.io()
            if op == 0x54:                                  # MVN increments
                if xw:
                    self.x = <uint16_t>(self.x + 1)
                    self.y = <uint16_t>(self.y + 1)
                else:
                    self.x = (self.x & 0xFF00) | ((self.x + 1) & 0xFF)
                    self.y = (self.y & 0xFF00) | ((self.y + 1) & 0xFF)
            else:                                           # MVP decrements
                if xw:
                    self.x = <uint16_t>(self.x - 1)
                    self.y = <uint16_t>(self.y - 1)
                else:
                    self.x = (self.x & 0xFF00) | ((self.x - 1) & 0xFF)
                    self.y = (self.y & 0xFF00) | ((self.y - 1) & 0xFF)
            self.a = <uint16_t>(self.a - 1)
            if self.a != 0xFFFF:
                self.pc = <uint16_t>((self.pc - 3) & 0xFFFF)

        # ---- misc -----------------------------------------------------------------------------
        elif op == 0xEA:                                    # NOP
            self.io()
        elif op == 0x42:                                    # WDM
            self.fetch()
        elif op == 0x00:                                    # BRK
            self.fetch()                                    # signature byte
            if self.e:
                self.interrupt(VEC_EMU_IRQ, 1)
            else:
                self.interrupt(VEC_NATIVE_BRK, 1)
        elif op == 0x02:                                    # COP
            self.fetch()
            if self.e:
                self.interrupt(VEC_EMU_COP, 0)
            else:
                self.interrupt(VEC_NATIVE_COP, 0)
        elif op == 0xCB:                                    # WAI
            self.io(); self.io()
            self.waiting = 1
        elif op == 0xDB:                                    # STP
            self.io(); self.io()
            self.stopped = 1
        else:
            self.io()

    # -- small helpers used by the dispatch ------------------------------------

    cdef inline uint16_t _acc_read(self, int wide) noexcept:
        return self.a if wide else (self.a & 0xFF)

    cdef inline uint16_t _acc_write(self, uint16_t value, int wide) noexcept:
        if wide:
            return value
        return (self.a & 0xFF00) | (value & 0xFF)

    cdef inline uint16_t _ora(self, uint16_t data, int wide) noexcept:
        cdef uint16_t r
        if wide:
            r = self.a | data
        else:
            r = (self.a & 0xFF00) | ((self.a | data) & 0xFF)
        self.set_nz(r, wide)
        return r

    cdef inline uint16_t _and(self, uint16_t data, int wide) noexcept:
        cdef uint16_t r
        if wide:
            r = self.a & data
        else:
            r = (self.a & 0xFF00) | ((self.a & data) & 0xFF)
        self.set_nz(r, wide)
        return r

    cdef inline uint16_t _eor(self, uint16_t data, int wide) noexcept:
        cdef uint16_t r
        if wide:
            r = self.a ^ data
        else:
            r = (self.a & 0xFF00) | ((self.a ^ data) & 0xFF)
        self.set_nz(r, wide)
        return r

    cdef inline void _lda(self, uint16_t data, int wide) noexcept:
        if wide:
            self.a = data
        else:
            self.a = (self.a & 0xFF00) | (data & 0xFF)
        self.set_nz(self.a, wide)





    # -- save state (generated by tools/gen_state.py; do not edit) --------

    def state_ints(self):
        cdef int i, j
        v = [self.a, self.x, self.y, self.s, self.d, self.pc, self.db, self.pb, self.p, self.e, self.stopped, self.waiting, self.ea_wrap, self.instructions]
        return v

    def load_ints(self, v):
        cdef int i, j, k = 14
        self.a = v[0]
        self.x = v[1]
        self.y = v[2]
        self.s = v[3]
        self.d = v[4]
        self.pc = v[5]
        self.db = v[6]
        self.pb = v[7]
        self.p = v[8]
        self.e = v[9]
        self.stopped = v[10]
        self.waiting = v[11]
        self.ea_wrap = v[12]
        self.instructions = v[13]

    def state_blobs(self):
        return []

    def load_blobs(self, blobs):
        pass

    # -- end generated save state ------------------------------------------

    # =====================================================================
    # python interface
    # =====================================================================

    # -- deterministic trace -------------------------------------------------

    def trace_start(self, int capacity=200000, int level=1, bint wrap=False):
        """level 1 records instructions, level 2 also records every bus access."""
        self.trace_stop()
        self.insn_cap = capacity
        self.bus_cap = capacity * 4 if level >= 2 else 1
        self.insn_log = <InsnRec *>malloc(self.insn_cap * sizeof(InsnRec))
        self.bus_log = <BusRec *>malloc(self.bus_cap * sizeof(BusRec))
        if self.insn_log == NULL or self.bus_log == NULL:
            self.trace_stop()
            raise MemoryError("could not allocate the trace buffers")
        self.insn_len = 0
        self.bus_len = 0
        self.trace_wrap = 1 if wrap else 0
        self.tracing = level

    def trace_stop(self):
        self.tracing = 0
        if self.insn_log != NULL:
            free(self.insn_log)
            self.insn_log = NULL
        if self.bus_log != NULL:
            free(self.bus_log)
            self.bus_log = NULL
        self.insn_cap = 0
        self.bus_cap = 0

    def trace_reset(self):
        self.insn_len = 0
        self.bus_len = 0

    @property
    def trace_full(self):
        return self.insn_len >= self.insn_cap

    def trace_instructions(self):
        """[(clock, pb, pc, op, a, x, y, s, d, db, p, e), ...]"""
        cdef int i
        out = []
        for i in range(self.insn_len):
            out.append((self.insn_log[i].clock, self.insn_log[i].pb, self.insn_log[i].pc,
                        self.insn_log[i].op, self.insn_log[i].a, self.insn_log[i].x,
                        self.insn_log[i].y, self.insn_log[i].s, self.insn_log[i].d,
                        self.insn_log[i].db, self.insn_log[i].p, self.insn_log[i].e))
        return out

    def trace_bus(self):
        """[(clock, addr, value, is_write), ...]"""
        cdef int i
        out = []
        for i in range(self.bus_len):
            out.append((self.bus_log[i].clock, self.bus_log[i].addr,
                        self.bus_log[i].value, bool(self.bus_log[i].write)))
        return out

    @property
    def regs(self):
        return dict(a=self.a, x=self.x, y=self.y, s=self.s, d=self.d,
                    pc=self.pc, db=self.db, pb=self.pb, p=self.p, e=self.e,
                    stopped=self.stopped, waiting=self.waiting)

    @property
    def flags(self):
        names = "czidxmvn"
        return "".join(names[i].upper() if (self.p >> i) & 1 else names[i]
                       for i in range(8))[::-1]

    def set_regs(self, **kw):
        for key, value in kw.items():
            if key == "a": self.a = value
            elif key == "x": self.x = value
            elif key == "y": self.y = value
            elif key == "s": self.s = value
            elif key == "d": self.d = value
            elif key == "pc": self.pc = value
            elif key == "db": self.db = value
            elif key == "pb": self.pb = value
            elif key == "p": self.p = value
            elif key == "e": self.e = value
            else: raise KeyError(key)

    def do_reset(self):
        self.reset()

    def do_step(self):
        self.step()
