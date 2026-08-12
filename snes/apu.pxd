# cython: language_level=3
from libc.stdint cimport uint8_t, uint16_t, uint32_t, int16_t, int32_t, int64_t


cdef class DSP:
    cdef uint8_t reg[128]
    cdef APU apu
    cdef int16_t gauss[512]

    # -- per-voice state ---------------------------------------------------
    cdef uint16_t brr_addr[8]
    cdef int brr_offset[8]
    cdef uint8_t brr_header[8]
    cdef int block_pos[8]
    cdef int16_t block[8][16]
    cdef int32_t hist[8][4]
    cdef int32_t interp_pos[8]
    cdef int32_t env[8]
    cdef int32_t hidden_env[8]     # before clamping; the two-slope gain reads it
    cdef int env_mode[8]
    cdef int kon_delay[8]
    cdef int32_t prev1[8]
    cdef int32_t prev2[8]
    cdef int16_t voice_out[8]

    # -- global ------------------------------------------------------------
    cdef int counter
    cdef int16_t noise
    cdef int echo_offset
    cdef int echo_length
    cdef uint8_t echo_esa           # ESA, latched: where the buffer is now
    cdef uint8_t echo_flg           # FLG, latched: whether writes are allowed
    cdef int32_t fir_l[8]
    cdef int32_t fir_r[8]
    cdef int fir_pos
    cdef int16_t last_l, last_r
    cdef int solo                   # -1 = normal mix, else only this voice
    cdef int echo_enabled           # diagnostics: force the echo unit off
    cdef int kon_count[8]           # diagnostics: key-on events per voice

    # -- output ring -------------------------------------------------------
    cdef int16_t out_buf[16384]
    cdef int out_write, out_read, out_count

    cdef void reset(self) noexcept
    cdef uint8_t read_reg(self, uint8_t addr) noexcept
    cdef void write_reg(self, uint8_t addr, uint8_t value) noexcept
    cdef void tick(self) noexcept          # one 32 kHz sample
    cdef void _key_on(self, int v) noexcept
    cdef void _decode_block(self, int v) noexcept
    cdef void _advance_sample(self, int v) noexcept
    cdef uint16_t _loop_addr(self, int v) noexcept
    cdef int _counter_poll(self, int rate) noexcept
    cdef void _run_envelope(self, int v) noexcept


cdef class APU:
    # -- SPC700 registers -------------------------------------------------
    cdef uint16_t pc
    cdef uint8_t a, x, y, sp, psw

    # -- memory -----------------------------------------------------------
    cdef uint8_t ram[0x10000]
    cdef uint8_t ipl[64]
    cdef int ipl_enabled

    # -- S-CPU <-> APU communication ports ($2140-$2143 <-> $F4-$F7) ------
    cdef uint8_t port_in[4]      # written by the S-CPU, read by the SPC700
    cdef uint8_t port_out[4]     # written by the SPC700, read by the S-CPU

    # -- timers -----------------------------------------------------------
    # Each timer prescales the 1.024 MHz core clock (/128 for T0 and T1,
    # /16 for T2), counts up to its 8-bit target, and then bumps a 4-bit
    # counter that the SPC700 reads and clears at $FD-$FF.
    cdef uint8_t timer_target[3]
    cdef uint8_t timer_div[3]
    cdef uint8_t timer_counter[3]
    cdef int32_t timer_stage[3]
    cdef int timer_enabled[3]

    # -- clocking ---------------------------------------------------------
    cdef int64_t clock              # APU cycles executed so far
    cdef int64_t cycle_target       # absolute target, so overshoot is carried
    cdef int64_t master_prev
    cdef int64_t frac
    cdef public int64_t master_hz
    cdef int32_t dsp_counter        # APU cycles until the next 32 kHz sample
    cdef int extra_cycles           # added by taken branches
    cdef int idle_tail              # cycles of the last opcode not yet placed

    # -- access log, for comparing an opcode's bus cycles against hardware --
    cdef int log_on
    cdef int log_n
    cdef uint8_t log_kind[32]       # 0 idle, 1 read, 2 write
    cdef uint16_t log_addr[32]
    cdef int stopped                # STOP/SLEEP executed

    cdef uint8_t dsp_addr
    cdef readonly DSP dsp

    cdef void reset(self) noexcept
    cdef void run_until(self, int64_t master_clock) noexcept
    cdef void step(self) noexcept                    # one SPC700 instruction
    cdef void execute(self, uint8_t op) noexcept
    cdef void tick(self, int cycles) noexcept        # advance timers/DSP
    cdef void cycle(self, int n) noexcept            # ... and the SPC clock
    cdef void idle(self) noexcept                    # a cycle touching nothing
    cdef void idles(self, int n) noexcept
    cdef void _log(self, int kind, uint16_t addr) noexcept
    cdef void store_abs(self, uint16_t addr, uint8_t value) noexcept
    cdef void store_dp(self, uint8_t offset, uint8_t value) noexcept
    cdef uint8_t read(self, uint16_t addr) noexcept
    cdef void write(self, uint16_t addr, uint8_t value) noexcept
    cdef uint8_t cpu_read_port(self, int index) noexcept
    cdef void cpu_write_port(self, int index, uint8_t value) noexcept

    # -- internals ---------------------------------------------------------
    cdef uint8_t fetch(self) noexcept
    cdef uint16_t fetch16(self) noexcept
    cdef uint16_t dp(self, uint8_t offset) noexcept
    cdef void push(self, uint8_t value) noexcept
    cdef uint8_t pull(self) noexcept
    cdef void nz8(self, uint8_t v) noexcept
    cdef void nz16(self, uint16_t v) noexcept
    cdef void setf(self, int mask, int on) noexcept
    cdef uint8_t alu_or(self, uint8_t a, uint8_t b) noexcept
    cdef uint8_t alu_and(self, uint8_t a, uint8_t b) noexcept
    cdef uint8_t alu_eor(self, uint8_t a, uint8_t b) noexcept
    cdef uint8_t alu_adc(self, uint8_t a, uint8_t b) noexcept
    cdef uint8_t alu_sbc(self, uint8_t a, uint8_t b) noexcept
    cdef void alu_cmp(self, uint8_t a, uint8_t b) noexcept
    cdef uint8_t alu_asl(self, uint8_t v) noexcept
    cdef uint8_t alu_lsr(self, uint8_t v) noexcept
    cdef uint8_t alu_rol(self, uint8_t v) noexcept
    cdef uint8_t alu_ror(self, uint8_t v) noexcept
    cdef uint8_t alu_inc(self, uint8_t v) noexcept
    cdef uint8_t alu_dec(self, uint8_t v) noexcept
    cdef void branch(self, int taken) noexcept
    cdef uint16_t read16(self, uint16_t addr) noexcept
