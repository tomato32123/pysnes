# cython: language_level=3
from libc.stdint cimport uint8_t, uint16_t, uint32_t, int16_t, int32_t, int64_t


cdef class DSP:
    cdef uint8_t reg[128]
    cdef APU apu
    cdef int16_t gauss[512]

    # -- per-voice state ---------------------------------------------------
    cdef uint16_t brr_addr[8]
    cdef int brr_offset[8]
    cdef int32_t buf[8][24]        # decoded samples, ring, kept twice over
    cdef int buf_pos[8]
    cdef int32_t interp_pos[8]
    cdef int32_t env[8]
    cdef int32_t hidden_env[8]     # before clamping; the two-slope gain reads it
    cdef int env_mode[8]
    cdef int kon_delay[8]
    cdef uint8_t envx_out[8]
    cdef int16_t voice_out[8]      # the last output of each voice, for tools

    # -- global ------------------------------------------------------------
    cdef int counter
    cdef int16_t noise
    cdef int echo_offset
    cdef int echo_length
    cdef uint8_t echo_esa           # ESA, latched: where the buffer is now
    cdef uint8_t echo_flg           # FLG, latched: whether writes are allowed
    cdef int32_t echo_hist_l[16]    # eight taps, kept twice over
    cdef int32_t echo_hist_r[16]
    cdef int echo_hist_pos
    cdef int16_t last_l, last_r

    # -- where the chip is in its sample, and what it read on the way --------
    cdef int phase
    cdef int every_other
    cdef uint8_t kon, new_kon, t_koff
    cdef uint8_t t_pmon, t_non, t_eon, t_dir
    cdef uint16_t t_dir_addr, t_brr_next_addr, t_echo_ptr
    cdef uint8_t t_srcn, t_adsr0, t_brr_byte, t_brr_header, t_looped
    cdef int32_t t_pitch, t_output
    cdef int32_t t_main_out[2]
    cdef int32_t t_echo_out[2]
    cdef int32_t t_echo_in[2]
    cdef uint8_t endx_buf, outx_buf, envx_buf
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
    cdef int _counter_poll(self, int rate) noexcept
    cdef void _run_envelope(self, int v) noexcept
    cdef int32_t _interpolate(self, int v) noexcept
    cdef void _decode_brr(self, int v) noexcept
    cdef void _v1(self, int v) noexcept
    cdef void _v2(self, int v) noexcept
    cdef void _v3(self, int v) noexcept
    cdef void _v3a(self, int v) noexcept
    cdef void _v3b(self, int v) noexcept
    cdef void _v3c(self, int v) noexcept
    cdef void _v4(self, int v) noexcept
    cdef void _v5(self, int v) noexcept
    cdef void _v6(self, int v) noexcept
    cdef void _v7(self, int v) noexcept
    cdef void _v8(self, int v) noexcept
    cdef void _v9(self, int v) noexcept
    cdef void _voice_output(self, int v, int ch) noexcept
    cdef int32_t _echo_read(self, int ch) noexcept
    cdef int32_t _fir(self, int i, int ch) noexcept
    cdef int32_t _echo_output(self, int ch) noexcept
    cdef void _echo_write(self, int ch) noexcept
    cdef void _echo_22(self) noexcept
    cdef void _echo_23(self) noexcept
    cdef void _echo_24(self) noexcept
    cdef void _echo_25(self) noexcept
    cdef void _echo_26(self) noexcept
    cdef void _echo_27(self) noexcept
    cdef void _echo_28(self) noexcept
    cdef void _echo_29(self) noexcept
    cdef void _echo_30(self) noexcept
    cdef void _misc_27(self) noexcept
    cdef void _misc_28(self) noexcept
    cdef void _misc_29(self) noexcept
    cdef void _misc_30(self) noexcept


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
    cdef uint8_t aux4, aux5        # $F8 and $F9: registers, not the RAM under them
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
