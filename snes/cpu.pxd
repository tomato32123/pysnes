# cython: language_level=3
from libc.stdint cimport uint8_t, uint16_t, uint32_t, int32_t, int64_t

from snes.bus cimport Bus


cdef class CPU:
    cdef readonly Bus bus

    cdef uint16_t a, x, y, s, d, pc
    cdef uint8_t db, pb, p
    cdef int e                       # emulation mode

    cdef int stopped                 # STP
    cdef int waiting                 # WAI
    cdef readonly int64_t instructions

    # Effective-address wrap rule for the operand currently being accessed:
    # 0 = linear 24-bit, 1 = wrap inside the bank, 2 = wrap inside the
    # direct page (emulation mode with DL == 0).
    cdef int ea_wrap

    cdef void reset(self) noexcept
    cdef void step(self) noexcept
    cdef void execute(self, uint8_t op) noexcept
    cdef void interrupt(self, uint16_t vector, int is_brk) noexcept

    # -- bus primitives ----------------------------------------------------
    cdef void io(self) noexcept
    cdef uint8_t read(self, uint32_t addr) noexcept
    cdef void write(self, uint32_t addr, uint8_t value) noexcept
    cdef uint8_t fetch(self) noexcept
    cdef uint16_t fetch16(self) noexcept
    cdef void push(self, uint8_t value) noexcept
    cdef uint8_t pull(self) noexcept
    cdef void push16(self, uint16_t value) noexcept
    cdef uint16_t pull16(self) noexcept
    cdef uint32_t nxt(self, uint32_t addr) noexcept
    cdef uint16_t load(self, uint32_t addr, int wide) noexcept
    cdef void store(self, uint32_t addr, uint16_t value, int wide) noexcept

    # -- addressing modes --------------------------------------------------
    cdef uint32_t am_imm(self, int wide) noexcept
    cdef uint32_t am_dp(self) noexcept
    cdef uint32_t am_dpx(self) noexcept
    cdef uint32_t am_dpy(self) noexcept
    cdef uint32_t am_abs(self) noexcept
    cdef uint32_t am_absx(self, int always) noexcept
    cdef uint32_t am_absy(self, int always) noexcept
    cdef uint32_t am_long(self) noexcept
    cdef uint32_t am_longx(self) noexcept
    cdef uint32_t am_dpi(self) noexcept
    cdef uint32_t am_dpix(self) noexcept
    cdef uint32_t am_dpiy(self, int always) noexcept
    cdef uint32_t am_dpil(self) noexcept
    cdef uint32_t am_dpily(self) noexcept
    cdef uint32_t am_sr(self) noexcept
    cdef uint32_t am_sriy(self) noexcept

    # -- ALU ----------------------------------------------------------------
    cdef void set_nz(self, uint16_t value, int wide) noexcept
    cdef void set_flag(self, int mask, int on) noexcept
    cdef void op_adc(self, uint16_t data, int wide) noexcept
    cdef void op_sbc(self, uint16_t data, int wide) noexcept
    cdef void op_cmp(self, uint16_t reg, uint16_t data, int wide) noexcept
    cdef void op_bit(self, uint16_t data, int wide) noexcept
    cdef uint16_t alu_asl(self, uint16_t v, int wide) noexcept
    cdef uint16_t alu_lsr(self, uint16_t v, int wide) noexcept
    cdef uint16_t alu_rol(self, uint16_t v, int wide) noexcept
    cdef uint16_t alu_ror(self, uint16_t v, int wide) noexcept
    cdef void rmw(self, uint32_t addr, int kind, int wide) noexcept
    cdef void branch(self, int taken) noexcept
    cdef void apply_index_width(self) noexcept
    cdef uint16_t _acc_read(self, int wide) noexcept
    cdef uint16_t _acc_write(self, uint16_t value, int wide) noexcept
    cdef uint16_t _ora(self, uint16_t data, int wide) noexcept
    cdef uint16_t _and(self, uint16_t data, int wide) noexcept
    cdef uint16_t _eor(self, uint16_t data, int wide) noexcept
    cdef void _lda(self, uint16_t data, int wide) noexcept
