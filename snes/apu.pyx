# cython: language_level=3
"""SNES audio subsystem: the SPC700 core, its three timers, and the S-DSP.

The SPC700 runs from its own crystal, so `run_until` converts elapsed S-CPU
master clocks into APU cycles and executes instructions to catch up.  On reset
the 64-byte IPL boot ROM performs the port handshake that lets the S-CPU upload
a sound driver into APU RAM -- without it, most games stall during boot.
"""

from libc.string cimport memset, memcpy
from cpython.bytes cimport PyBytes_FromStringAndSize
from libc.stdint cimport uint8_t, uint16_t, uint32_t, int8_t, int32_t, int64_t


cdef enum:
    MASTER_HZ = 21477272
    APU_HZ    = 1024000
    DSP_DIV   = 32              # APU cycles per 32 kHz sample


cdef enum:
    P_N = 0x80
    P_V = 0x40
    P_P = 0x20                  # direct page selector: 0 -> $00xx, 1 -> $01xx
    P_B = 0x10
    P_H = 0x08
    P_I = 0x04
    P_Z = 0x02
    P_C = 0x01


# The 64-byte IPL boot ROM at $FFC0-$FFFF.
cdef uint8_t IPL_ROM[64]
IPL_ROM[:] = [
    0xCD, 0xEF, 0xBD, 0xE8, 0x00, 0xC6, 0x1D, 0xD0,
    0xFC, 0x8F, 0xAA, 0xF4, 0x8F, 0xBB, 0xF5, 0x78,
    0xCC, 0xF4, 0xD0, 0xFB, 0x2F, 0x19, 0xEB, 0xF4,
    0xD0, 0xFC, 0x7E, 0xF4, 0xD0, 0x0B, 0xE4, 0xF5,
    0xCB, 0xF4, 0xD7, 0x00, 0xFC, 0xD0, 0xF3, 0xAB,
    0x01, 0x10, 0xEF, 0x7E, 0xF4, 0x10, 0xEB, 0xBA,
    0xF6, 0xDA, 0x00, 0xBA, 0xF4, 0xC4, 0xF4, 0xDD,
    0x5D, 0xD0, 0xDB, 0x1F, 0x00, 0x00, 0xC0, 0xFF,
]


# Base cycle count per opcode; taken branches add two.
cdef int CYCLES[256]
CYCLES[:] = [
    2, 8, 4, 5, 3, 4, 3, 6, 2, 6, 5, 4, 5, 4, 6, 8,
    2, 8, 4, 5, 4, 5, 5, 6, 5, 5, 6, 5, 2, 2, 4, 6,
    2, 8, 4, 5, 3, 4, 3, 6, 2, 6, 5, 4, 5, 4, 5, 2,
    2, 8, 4, 5, 4, 5, 5, 6, 5, 5, 6, 5, 2, 2, 3, 8,
    2, 8, 4, 5, 3, 4, 3, 6, 2, 6, 4, 4, 5, 4, 6, 6,
    2, 8, 4, 5, 4, 5, 5, 6, 5, 5, 4, 5, 2, 2, 4, 3,
    2, 8, 4, 5, 3, 4, 3, 6, 2, 6, 4, 4, 5, 4, 5, 5,
    2, 8, 4, 5, 4, 5, 5, 6, 5, 5, 5, 5, 2, 2, 3, 6,
    2, 8, 4, 5, 3, 4, 3, 6, 2, 6, 5, 4, 5, 2, 4, 5,
    2, 8, 4, 5, 4, 5, 5, 6, 5, 5, 5, 5, 2, 2, 12, 5,
    3, 8, 4, 5, 3, 4, 3, 6, 2, 6, 4, 4, 5, 2, 4, 4,
    2, 8, 4, 5, 4, 5, 5, 6, 5, 5, 5, 5, 2, 2, 3, 4,
    3, 8, 4, 5, 4, 5, 4, 7, 2, 5, 6, 4, 5, 2, 4, 9,
    2, 8, 4, 5, 5, 6, 6, 7, 4, 5, 5, 5, 2, 2, 6, 3,
    2, 8, 4, 5, 3, 4, 3, 6, 2, 4, 5, 3, 4, 3, 4, 3,
    2, 8, 4, 5, 4, 5, 5, 6, 3, 4, 5, 4, 2, 2, 6, 3,
]


# -- envelope timing ---------------------------------------------------
# Number of 32 kHz samples between envelope steps for each of the 32 rates,
# plus the phase offset the hardware applies to the shared countdown counter.
cdef int COUNTER_RATE[32]
cdef int COUNTER_OFFSET[32]
COUNTER_RATE[:] = [
       0, 2048, 1536, 1280, 1024,  768,  640,  512,
     384,  320,  256,  192,  160,  128,   96,   80,
      64,   48,   40,   32,   24,   20,   16,   12,
      10,    8,    6,    5,    4,    3,    2,    1,
]
COUNTER_OFFSET[:] = [
       0,    0, 1040,  536,    0, 1040,  536,    0,
    1040,  536,    0, 1040,  536,    0, 1040,  536,
       0, 1040,  536,    0, 1040,  536,    0, 1040,
     536,    0, 1040,  536,    0, 1040,  536,    0,
]

# BRR filter coefficients are applied with integer shifts; see _decode_block.

cdef enum:
    ENV_ATTACK  = 0
    ENV_DECAY   = 1
    ENV_SUSTAIN = 2
    ENV_RELEASE = 3

cdef enum:
    OUT_SAMPLES = 8192          # stereo frames in the output ring buffer


cdef inline int32_t _clamp16(int32_t v) noexcept:
    if v > 32767:
        return 32767
    if v < -32768:
        return -32768
    return v


cdef inline int32_t _clip15(int32_t v) noexcept:
    """The BRR decoder keeps 15 bits and wraps rather than saturating."""
    return <int32_t><int16_t>(<uint16_t>((v & 0x7FFF) << 1)) >> 1


cdef class DSP:
    """S-DSP: 8 BRR voices with ADSR/GAIN envelopes, noise, pitch modulation
    and the 8-tap FIR echo unit.

    Interpolation uses a generated gaussian-windowed sinc kernel normalised so
    each 4-tap group sums to 2048.  That matches the hardware's gain and shape
    closely but is not a bit-exact copy of the on-chip table.
    """

    def __init__(self, APU apu):
        self.apu = apu
        self._build_gauss()
        self.reset()

    def _build_gauss(self):
        """Gaussian-windowed sinc, quantised so every 4-tap group sums to 2048."""
        import math
        raw = []
        for i in range(512):
            # Kernel position in [-2, 2) across the four taps.
            t = (i + 0.5) / 256.0 - 1.0        # -1 .. 1 over each half
            x = t * 2.0
            if abs(x) < 1e-9:
                sinc = 1.0
            else:
                sinc = math.sin(math.pi * x) / (math.pi * x)
            window = math.exp(-0.5 * (x / 1.15) ** 2)
            raw.append(sinc * window)

        # Taps used together for fractional position p are
        # (255-p, 511-p, 256+p, p); normalise each such group to 2048.
        table = [0] * 512
        for p in range(256):
            idx = (255 - p, 511 - p, 256 + p, p)
            vals = [max(raw[j], 0.0) for j in idx]
            total = sum(vals) or 1.0
            scaled = [v * 2048.0 / total for v in vals]
            ints = [int(round(v)) for v in scaled]
            ints[1] += 2048 - sum(ints)         # put the rounding error on the peak
            for j, v in zip(idx, ints):
                table[j] = v
        for i in range(512):
            self.gauss[i] = <int16_t>table[i]

    cdef void reset(self) noexcept:
        cdef int i, v
        memset(self.reg, 0, sizeof(self.reg))
        self.reg[0x6C] = 0xE0            # FLG: reset + mute + echo writes off
        for v in range(8):
            self.brr_addr[v] = 0
            self.brr_offset[v] = 0
            self.brr_header[v] = 0
            self.block_pos[v] = 16
            self.interp_pos[v] = 0
            self.env[v] = 0
            self.env_mode[v] = ENV_RELEASE
            self.kon_delay[v] = 0
            self.prev1[v] = 0
            self.prev2[v] = 0
            self.voice_out[v] = 0
            for i in range(4):
                self.hist[v][i] = 0
            for i in range(16):
                self.block[v][i] = 0
        self.counter = 0
        self.noise = 0x4000
        self.echo_offset = 0
        self.echo_length = 0
        for i in range(8):
            self.fir_l[i] = 0
            self.fir_r[i] = 0
        self.fir_pos = 0
        self.out_write = 0
        self.out_read = 0
        self.out_count = 0
        self.last_l = 0
        self.last_r = 0

    cdef uint8_t read_reg(self, uint8_t addr) noexcept:
        return self.reg[addr & 0x7F]

    cdef void write_reg(self, uint8_t addr, uint8_t value) noexcept:
        cdef int v
        if addr >= 0x80:
            return                        # $80-$FF only mirror the read side
        self.reg[addr] = value
        if addr == 0x4C:                  # KON is edge triggered
            for v in range(8):
                if value & (1 << v):
                    self._key_on(v)
        elif addr == 0x5C:                # KOF is level triggered
            for v in range(8):
                if value & (1 << v):
                    self.env_mode[v] = ENV_RELEASE

    cdef void _key_on(self, int v) noexcept:
        cdef int i
        cdef uint16_t dir_addr = (<uint16_t>self.reg[0x5D] << 8) + <uint16_t>(self.reg[v * 16 + 4]) * 4
        self.brr_addr[v] = (<uint16_t>self.apu.ram[dir_addr]
                            | (<uint16_t>self.apu.ram[<uint16_t>(dir_addr + 1)] << 8))
        self.brr_offset[v] = 0
        self.block_pos[v] = 16            # forces a fresh block decode
        self.interp_pos[v] = 0
        self.prev1[v] = 0
        self.prev2[v] = 0
        self.env[v] = 0
        self.env_mode[v] = ENV_ATTACK
        self.kon_delay[v] = 5             # hardware delays the first output
        for i in range(4):
            self.hist[v][i] = 0
        self.reg[0x7C] &= <uint8_t>~(1 << v)      # clear ENDX

    # -- BRR ---------------------------------------------------------------

    cdef void _decode_block(self, int v) noexcept:
        cdef uint16_t addr = self.brr_addr[v]
        cdef uint8_t header = self.apu.ram[addr]
        cdef int shift = header >> 4
        cdef int filt = (header >> 2) & 3
        cdef int i, nibble
        cdef int32_t s, p1 = self.prev1[v], p2 = self.prev2[v]
        cdef uint8_t byte

        self.brr_header[v] = header
        for i in range(16):
            byte = self.apu.ram[<uint16_t>(addr + 1 + (i >> 1))]
            nibble = (byte >> 4) if (i & 1) == 0 else (byte & 0x0F)
            if nibble > 7:
                nibble -= 16
            if shift <= 12:
                s = (<int32_t>nibble << shift) >> 1
            else:
                s = -2048 if nibble < 0 else 0     # invalid shift saturates

            if filt == 1:
                s += p1 + ((-p1) >> 4)
            elif filt == 2:
                s += (p1 << 1) + ((-(p1 * 3)) >> 5) - p2 + (p2 >> 4)
            elif filt == 3:
                s += (p1 << 1) + ((-(p1 * 13)) >> 6) - p2 + ((p2 * 3) >> 4)

            s = _clip15(_clamp16(s))
            p2 = p1
            p1 = s
            self.block[v][i] = <int16_t>s

        self.prev1[v] = p1
        self.prev2[v] = p2
        self.block_pos[v] = 0

    cdef void _advance_sample(self, int v) noexcept:
        """Push the next decoded sample into the interpolation history."""
        cdef int i
        if self.block_pos[v] >= 16:
            if self.brr_header[v] & 0x01:          # previous block ended
                if self.brr_header[v] & 0x02:      # ...and loops
                    self.brr_addr[v] = self._loop_addr(v)
                else:
                    self.env[v] = 0
                    self.env_mode[v] = ENV_RELEASE
                self.reg[0x7C] |= <uint8_t>(1 << v)
            else:
                self.brr_addr[v] = <uint16_t>(self.brr_addr[v] + 9)
            self._decode_block(v)
        for i in range(3):
            self.hist[v][i] = self.hist[v][i + 1]
        self.hist[v][3] = self.block[v][self.block_pos[v]]
        self.block_pos[v] += 1

    cdef uint16_t _loop_addr(self, int v) noexcept:
        cdef uint16_t dir_addr = (<uint16_t>self.reg[0x5D] << 8) + <uint16_t>(self.reg[v * 16 + 4]) * 4
        return (<uint16_t>self.apu.ram[<uint16_t>(dir_addr + 2)]
                | (<uint16_t>self.apu.ram[<uint16_t>(dir_addr + 3)] << 8))

    # -- envelope ------------------------------------------------------------

    cdef inline int _counter_poll(self, int rate) noexcept:
        if rate == 0:
            return 0
        return 1 if ((self.counter + COUNTER_OFFSET[rate]) % COUNTER_RATE[rate]) == 0 else 0

    cdef void _run_envelope(self, int v) noexcept:
        cdef uint8_t adsr1 = self.reg[v * 16 + 5]
        cdef uint8_t adsr2 = self.reg[v * 16 + 6]
        cdef uint8_t gain = self.reg[v * 16 + 7]
        cdef int32_t e = self.env[v]
        cdef int rate, mode, sustain_level

        if self.env_mode[v] == ENV_RELEASE:
            e -= 8
            if e < 0:
                e = 0
            self.env[v] = e
            return

        if adsr1 & 0x80:                                   # ADSR
            if self.env_mode[v] == ENV_ATTACK:
                rate = ((adsr1 & 0x0F) << 1) + 1
                if rate == 31:
                    e += 1024
                elif self._counter_poll(rate):
                    e += 32
                if e >= 0x7FF:
                    e = 0x7FF
                    self.env_mode[v] = ENV_DECAY
            elif self.env_mode[v] == ENV_DECAY:
                rate = (((adsr1 >> 4) & 7) << 1) + 16
                if self._counter_poll(rate):
                    e -= ((e - 1) >> 8) + 1
                sustain_level = ((adsr2 >> 5) + 1) << 8
                if e <= sustain_level:
                    self.env_mode[v] = ENV_SUSTAIN
            else:                                          # sustain
                rate = adsr2 & 0x1F
                if self._counter_poll(rate):
                    e -= ((e - 1) >> 8) + 1
        else:                                              # GAIN
            if not (gain & 0x80):
                e = (gain & 0x7F) << 4
            else:
                rate = gain & 0x1F
                mode = (gain >> 5) & 3
                if self._counter_poll(rate):
                    if mode == 0:
                        e -= 32
                    elif mode == 1:
                        e -= ((e - 1) >> 8) + 1
                    elif mode == 2:
                        e += 32
                    else:
                        e += 32 if e < 0x600 else 8

        if e < 0:
            e = 0
        elif e > 0x7FF:
            e = 0x7FF
        self.env[v] = e

    # -- one 32 kHz sample -----------------------------------------------------

    cdef void tick(self) noexcept:
        cdef uint8_t flg = self.reg[0x6C]
        cdef uint8_t pmon = self.reg[0x2D]
        cdef uint8_t non = self.reg[0x3D]
        cdef uint8_t eon = self.reg[0x4D]
        cdef int v, offset, rate
        cdef int32_t pitch, sample, out, envval
        cdef int32_t main_l = 0, main_r = 0, echo_in_l = 0, echo_in_r = 0
        cdef int32_t echo_l = 0, echo_r = 0
        cdef int32_t fl, fr, l, r
        cdef uint16_t echo_addr
        cdef int i, tap

        self.counter -= 1
        if self.counter < 0:
            self.counter = 0x77FF

        if flg & 0x80:                                     # soft reset
            for v in range(8):
                self.env_mode[v] = ENV_RELEASE
                self.env[v] = 0

        # Noise generator.
        rate = flg & 0x1F
        if self._counter_poll(rate):
            i = ((<int>self.noise << 13) ^ (<int>self.noise << 14)) & 0x4000
            self.noise = <int16_t>(i ^ ((<int>self.noise >> 1) & 0x3FFF))

        for v in range(8):
            pitch = (<int32_t>self.reg[v * 16 + 2]
                     | (<int32_t>(self.reg[v * 16 + 3] & 0x3F) << 8))
            if (pmon & (1 << v)) and v > 0:
                pitch = (pitch * (self.voice_out[v - 1] + 32768)) >> 15

            self.interp_pos[v] += pitch
            while self.interp_pos[v] >= 0x1000:
                self.interp_pos[v] -= 0x1000
                self._advance_sample(v)

            if self.kon_delay[v] > 0:
                self.kon_delay[v] -= 1
                self.voice_out[v] = 0
                self.reg[v * 16 + 8] = 0
                self.reg[v * 16 + 9] = 0
                continue

            if non & (1 << v):
                sample = <int32_t><int16_t>(<uint16_t>(<int>self.noise << 1))
            else:
                offset = (self.interp_pos[v] >> 4) & 0xFF
                out = (<int32_t>self.gauss[255 - offset] * self.hist[v][0]) >> 11
                out += (<int32_t>self.gauss[511 - offset] * self.hist[v][1]) >> 11
                out += (<int32_t>self.gauss[256 + offset] * self.hist[v][2]) >> 11
                out = <int32_t><int16_t>out
                out += (<int32_t>self.gauss[offset] * self.hist[v][3]) >> 11
                sample = _clamp16(out)

            self._run_envelope(v)
            envval = self.env[v]
            sample = (sample * envval) >> 11
            self.voice_out[v] = <int16_t>sample

            self.reg[v * 16 + 8] = <uint8_t>(envval >> 4)
            self.reg[v * 16 + 9] = <uint8_t>((sample >> 8) & 0xFF)

            l = (sample * <int32_t><signed char>self.reg[v * 16 + 0]) >> 7
            r = (sample * <int32_t><signed char>self.reg[v * 16 + 1]) >> 7
            main_l += l
            main_r += r
            if eon & (1 << v):
                echo_in_l += l
                echo_in_r += r

        # -- echo ------------------------------------------------------------
        self.echo_length = (<int>(self.reg[0x7D] & 0x0F)) * 2048
        if self.echo_length == 0:
            self.echo_length = 4
        echo_addr = <uint16_t>((<int>self.reg[0x6D] << 8) + self.echo_offset)

        fl = <int32_t><int16_t>(<uint16_t>(self.apu.ram[echo_addr]
                                           | (<uint16_t>self.apu.ram[<uint16_t>(echo_addr + 1)] << 8)))
        fr = <int32_t><int16_t>(<uint16_t>(self.apu.ram[<uint16_t>(echo_addr + 2)]
                                           | (<uint16_t>self.apu.ram[<uint16_t>(echo_addr + 3)] << 8)))
        self.fir_l[self.fir_pos] = fl
        self.fir_r[self.fir_pos] = fr

        for tap in range(8):
            i = (self.fir_pos - 7 + tap) & 7
            echo_l += (self.fir_l[i] * <int32_t><signed char>self.reg[(tap << 4) + 0x0F]) >> 6
            echo_r += (self.fir_r[i] * <int32_t><signed char>self.reg[(tap << 4) + 0x0F]) >> 6
        echo_l = _clamp16(echo_l)
        echo_r = _clamp16(echo_r)
        self.fir_pos = (self.fir_pos + 1) & 7

        if not (flg & 0x20):                       # echo writes enabled
            l = _clamp16(echo_in_l + ((echo_l * <int32_t><signed char>self.reg[0x0D]) >> 7))
            r = _clamp16(echo_in_r + ((echo_r * <int32_t><signed char>self.reg[0x0D]) >> 7))
            self.apu.ram[echo_addr] = <uint8_t>(l & 0xFF)
            self.apu.ram[<uint16_t>(echo_addr + 1)] = <uint8_t>((l >> 8) & 0xFF)
            self.apu.ram[<uint16_t>(echo_addr + 2)] = <uint8_t>(r & 0xFF)
            self.apu.ram[<uint16_t>(echo_addr + 3)] = <uint8_t>((r >> 8) & 0xFF)

        self.echo_offset += 4
        if self.echo_offset >= self.echo_length:
            self.echo_offset = 0

        # -- master mix ---------------------------------------------------------
        l = (main_l * <int32_t><signed char>self.reg[0x0C]) >> 7
        r = (main_r * <int32_t><signed char>self.reg[0x1C]) >> 7
        l += (echo_l * <int32_t><signed char>self.reg[0x2C]) >> 7
        r += (echo_r * <int32_t><signed char>self.reg[0x3C]) >> 7
        l = _clamp16(l)
        r = _clamp16(r)
        if flg & 0x40:                              # mute
            l = 0
            r = 0

        self.last_l = <int16_t>l
        self.last_r = <int16_t>r
        self.out_buf[self.out_write * 2 + 0] = <int16_t>l
        self.out_buf[self.out_write * 2 + 1] = <int16_t>r
        self.out_write = (self.out_write + 1) % OUT_SAMPLES
        if self.out_count < OUT_SAMPLES:
            self.out_count += 1
        else:                                       # ring full: drop the oldest
            self.out_read = (self.out_read + 1) % OUT_SAMPLES



    # -- save state (generated by tools/gen_state.py; do not edit) --------

    def state_ints(self):
        cdef int i, j
        v = [self.counter, self.noise, self.echo_offset, self.echo_length, self.fir_pos, self.last_l, self.last_r]
        for i in range(8):
            v.append(self.brr_addr[i])
        for i in range(8):
            v.append(self.brr_offset[i])
        for i in range(8):
            v.append(self.brr_header[i])
        for i in range(8):
            v.append(self.block_pos[i])
        for i in range(8):
            v.append(self.interp_pos[i])
        for i in range(8):
            v.append(self.env[i])
        for i in range(8):
            v.append(self.env_mode[i])
        for i in range(8):
            v.append(self.kon_delay[i])
        for i in range(8):
            v.append(self.prev1[i])
        for i in range(8):
            v.append(self.prev2[i])
        for i in range(8):
            v.append(self.voice_out[i])
        for i in range(8):
            v.append(self.fir_l[i])
        for i in range(8):
            v.append(self.fir_r[i])
        for i in range(8):
            for j in range(4):
                v.append(self.hist[i][j])
        for i in range(8):
            for j in range(16):
                v.append(self.block[i][j])
        return v

    def load_ints(self, v):
        cdef int i, j, k = 7
        self.counter = v[0]
        self.noise = v[1]
        self.echo_offset = v[2]
        self.echo_length = v[3]
        self.fir_pos = v[4]
        self.last_l = v[5]
        self.last_r = v[6]
        for i in range(8):
            self.brr_addr[i] = v[k + i]
        k += 8
        for i in range(8):
            self.brr_offset[i] = v[k + i]
        k += 8
        for i in range(8):
            self.brr_header[i] = v[k + i]
        k += 8
        for i in range(8):
            self.block_pos[i] = v[k + i]
        k += 8
        for i in range(8):
            self.interp_pos[i] = v[k + i]
        k += 8
        for i in range(8):
            self.env[i] = v[k + i]
        k += 8
        for i in range(8):
            self.env_mode[i] = v[k + i]
        k += 8
        for i in range(8):
            self.kon_delay[i] = v[k + i]
        k += 8
        for i in range(8):
            self.prev1[i] = v[k + i]
        k += 8
        for i in range(8):
            self.prev2[i] = v[k + i]
        k += 8
        for i in range(8):
            self.voice_out[i] = v[k + i]
        k += 8
        for i in range(8):
            self.fir_l[i] = v[k + i]
        k += 8
        for i in range(8):
            self.fir_r[i] = v[k + i]
        k += 8
        for i in range(8):
            for j in range(4):
                self.hist[i][j] = v[k + i * 4 + j]
        k += 32
        for i in range(8):
            for j in range(16):
                self.block[i][j] = v[k + i * 16 + j]
        k += 128

    def state_blobs(self):
        return [PyBytes_FromStringAndSize(<char *>self.reg, 128)]

    def load_blobs(self, blobs):
        if len(blobs[0]) != 128:
            raise ValueError('bad reg blob')
        memcpy(<char *>self.reg, <char *><bytes>blobs[0], 128)

    # -- end generated save state ------------------------------------------

    # -- python side -----------------------------------------------------------

    def pending_samples(self):
        return self.out_count

    def take_samples(self, int max_frames):
        """Pop up to `max_frames` stereo frames as little-endian s16 bytes."""
        cdef int n = self.out_count if self.out_count < max_frames else max_frames
        cdef int i, idx, l, r
        out = bytearray(n * 4)
        for i in range(n):
            idx = (self.out_read + i) % OUT_SAMPLES
            l = self.out_buf[idx * 2 + 0]
            r = self.out_buf[idx * 2 + 1]
            out[i * 4 + 0] = l & 0xFF
            out[i * 4 + 1] = (l >> 8) & 0xFF
            out[i * 4 + 2] = r & 0xFF
            out[i * 4 + 3] = (r >> 8) & 0xFF
        self.out_read = (self.out_read + n) % OUT_SAMPLES
        self.out_count -= n
        return bytes(out)

    @property
    def registers(self):
        return bytes(bytearray([self.reg[i] for i in range(128)]))

    @property
    def voice_state(self):
        return [dict(env=self.env[v], mode=self.env_mode[v], out=self.voice_out[v],
                     addr=self.brr_addr[v]) for v in range(8)]


cdef class APU:
    """SPC700 CPU + timers + DSP, clocked independently of the S-CPU."""

    def __init__(self):
        cdef int i
        for i in range(64):
            self.ipl[i] = IPL_ROM[i]
        self.dsp = DSP(self)
        self.reset()

    cdef void reset(self) noexcept:
        cdef int i
        memset(self.ram, 0, sizeof(self.ram))
        self.a = 0
        self.x = 0
        self.y = 0
        self.sp = 0xEF
        self.psw = 0x02
        self.ipl_enabled = 1
        self.pc = (<uint16_t>self.ipl[0x3E]) | (<uint16_t>self.ipl[0x3F] << 8)
        for i in range(4):
            self.port_in[i] = 0
            self.port_out[i] = 0
        for i in range(3):
            self.timer_target[i] = 0
            self.timer_div[i] = 0
            self.timer_counter[i] = 0
            self.timer_stage[i] = 0
            self.timer_enabled[i] = 0
        self.clock = 0
        self.master_prev = 0
        self.frac = 0
        self.dsp_counter = DSP_DIV
        self.extra_cycles = 0
        self.stopped = 0
        self.dsp_addr = 0
        self.dsp.reset()

    # =====================================================================
    # clocking
    # =====================================================================

    cdef void run_until(self, int64_t master_clock) noexcept:
        cdef int64_t delta = master_clock - self.master_prev
        cdef int64_t target
        if delta <= 0:
            return
        self.master_prev = master_clock
        self.frac += delta * APU_HZ
        target = self.clock + self.frac // MASTER_HZ
        self.frac %= MASTER_HZ
        while self.clock < target:
            if self.stopped:
                self.tick(<int>(target - self.clock))
                self.clock = target
                return
            self.step()

    cdef void tick(self, int cycles) noexcept:
        cdef int i
        cdef int32_t period
        cdef uint8_t target

        self.dsp_counter -= cycles
        while self.dsp_counter <= 0:
            self.dsp_counter += DSP_DIV
            self.dsp.tick()

        for i in range(3):
            if not self.timer_enabled[i]:
                continue
            period = 128 if i < 2 else 16
            self.timer_stage[i] += cycles
            while self.timer_stage[i] >= period:
                self.timer_stage[i] -= period
                self.timer_div[i] += 1
                target = self.timer_target[i]      # 0 behaves as 256
                if self.timer_div[i] == target:
                    self.timer_div[i] = 0
                    self.timer_counter[i] = (self.timer_counter[i] + 1) & 0x0F

    cdef void step(self) noexcept:
        cdef uint8_t op = self.fetch()
        cdef int cycles
        self.extra_cycles = 0
        self.execute(op)
        cycles = CYCLES[op] + self.extra_cycles
        self.clock += cycles
        self.tick(cycles)

    # =====================================================================
    # SPC700 address space
    # =====================================================================

    cdef uint8_t read(self, uint16_t addr) noexcept:
        cdef int i
        cdef uint8_t val
        if 0x00F0 <= addr <= 0x00FF:
            i = addr - 0x00F0
            if i == 2:
                return self.dsp_addr
            if i == 3:
                return self.dsp.read_reg(self.dsp_addr)
            if 4 <= i <= 7:
                return self.port_in[i - 4]
            if 13 <= i <= 15:                    # $FD-$FF: read clears
                val = self.timer_counter[i - 13] & 0x0F
                self.timer_counter[i - 13] = 0
                return val
            return self.ram[addr]
        if addr >= 0xFFC0 and self.ipl_enabled:
            return self.ipl[addr - 0xFFC0]
        return self.ram[addr]

    cdef void write(self, uint16_t addr, uint8_t value) noexcept:
        cdef int i, t
        if 0x00F0 <= addr <= 0x00FF:
            i = addr - 0x00F0
            if i == 1:                            # $F1 CONTROL
                for t in range(3):
                    if (value >> t) & 1:
                        if not self.timer_enabled[t]:
                            self.timer_div[t] = 0
                            self.timer_counter[t] = 0
                            self.timer_stage[t] = 0
                        self.timer_enabled[t] = 1
                    else:
                        self.timer_enabled[t] = 0
                if value & 0x10:                  # clear input ports 0/1
                    self.port_in[0] = 0
                    self.port_in[1] = 0
                if value & 0x20:                  # clear input ports 2/3
                    self.port_in[2] = 0
                    self.port_in[3] = 0
                self.ipl_enabled = 1 if (value & 0x80) else 0
                self.ram[addr] = value
                return
            if i == 2:
                self.dsp_addr = value
                return
            if i == 3:
                self.dsp.write_reg(self.dsp_addr, value)
                return
            if 4 <= i <= 7:                       # visible to the S-CPU
                self.port_out[i - 4] = value
                return
            if 10 <= i <= 12:                     # $FA-$FC timer targets
                self.timer_target[i - 10] = value
                self.ram[addr] = value
                return
            self.ram[addr] = value
            return
        self.ram[addr] = value

    cdef uint16_t read16(self, uint16_t addr) noexcept:
        cdef uint16_t lo = self.read(addr)
        return lo | (<uint16_t>self.read(<uint16_t>(addr + 1)) << 8)

    # =====================================================================
    # primitives
    # =====================================================================

    cdef inline uint8_t fetch(self) noexcept:
        cdef uint8_t v = self.read(self.pc)
        self.pc = <uint16_t>(self.pc + 1)
        return v

    cdef inline uint16_t fetch16(self) noexcept:
        cdef uint16_t lo = self.fetch()
        return lo | (<uint16_t>self.fetch() << 8)

    cdef inline uint16_t dp(self, uint8_t offset) noexcept:
        return (0x0100 if (self.psw & P_P) else 0x0000) | offset

    cdef inline void push(self, uint8_t value) noexcept:
        self.write(0x0100 | self.sp, value)
        self.sp -= 1

    cdef inline uint8_t pull(self) noexcept:
        self.sp += 1
        return self.read(0x0100 | self.sp)

    cdef inline void nz8(self, uint8_t v) noexcept:
        self.psw &= ~(P_N | P_Z)
        if v == 0:
            self.psw |= P_Z
        if v & 0x80:
            self.psw |= P_N

    cdef inline void nz16(self, uint16_t v) noexcept:
        self.psw &= ~(P_N | P_Z)
        if v == 0:
            self.psw |= P_Z
        if v & 0x8000:
            self.psw |= P_N

    cdef inline void setf(self, int mask, int on) noexcept:
        if on:
            self.psw |= mask
        else:
            self.psw &= ~mask

    # =====================================================================
    # ALU
    # =====================================================================

    cdef inline uint8_t alu_or(self, uint8_t a, uint8_t b) noexcept:
        a = a | b
        self.nz8(a)
        return a

    cdef inline uint8_t alu_and(self, uint8_t a, uint8_t b) noexcept:
        a = a & b
        self.nz8(a)
        return a

    cdef inline uint8_t alu_eor(self, uint8_t a, uint8_t b) noexcept:
        a = a ^ b
        self.nz8(a)
        return a

    cdef inline uint8_t alu_adc(self, uint8_t a, uint8_t b) noexcept:
        cdef int32_t z = <int32_t>a + <int32_t>b + (1 if (self.psw & P_C) else 0)
        self.setf(P_C, z > 0xFF)
        self.setf(P_H, ((a ^ b ^ <uint32_t>z) & 0x10) != 0)
        self.setf(P_V, (~(a ^ b) & (a ^ <uint32_t>z) & 0x80) != 0)
        self.nz8(<uint8_t>z)
        return <uint8_t>z

    cdef inline uint8_t alu_sbc(self, uint8_t a, uint8_t b) noexcept:
        return self.alu_adc(a, <uint8_t>(~b))

    cdef inline void alu_cmp(self, uint8_t a, uint8_t b) noexcept:
        cdef int32_t z = <int32_t>a - <int32_t>b
        self.setf(P_C, z >= 0)
        self.nz8(<uint8_t>z)

    cdef inline uint8_t alu_asl(self, uint8_t v) noexcept:
        self.setf(P_C, (v & 0x80) != 0)
        v = <uint8_t>(v << 1)
        self.nz8(v)
        return v

    cdef inline uint8_t alu_lsr(self, uint8_t v) noexcept:
        self.setf(P_C, (v & 0x01) != 0)
        v = v >> 1
        self.nz8(v)
        return v

    cdef inline uint8_t alu_rol(self, uint8_t v) noexcept:
        cdef int c = 1 if (self.psw & P_C) else 0
        self.setf(P_C, (v & 0x80) != 0)
        v = <uint8_t>((v << 1) | c)
        self.nz8(v)
        return v

    cdef inline uint8_t alu_ror(self, uint8_t v) noexcept:
        cdef int c = 1 if (self.psw & P_C) else 0
        self.setf(P_C, (v & 0x01) != 0)
        v = <uint8_t>((v >> 1) | (c << 7))
        self.nz8(v)
        return v

    cdef inline uint8_t alu_inc(self, uint8_t v) noexcept:
        v = <uint8_t>(v + 1)
        self.nz8(v)
        return v

    cdef inline uint8_t alu_dec(self, uint8_t v) noexcept:
        v = <uint8_t>(v - 1)
        self.nz8(v)
        return v

    cdef inline void branch(self, int taken) noexcept:
        cdef int8_t offset = <int8_t>self.fetch()
        if taken:
            self.pc = <uint16_t>(self.pc + offset)
            self.extra_cycles += 2

    # =====================================================================
    # instruction dispatch
    # =====================================================================

    cdef void execute(self, uint8_t op) noexcept:
        cdef uint8_t v, v2, o1, o2, bit
        cdef uint16_t addr, ptr, w, ya
        cdef int32_t z
        cdef uint32_t big

        # ---- OR ----------------------------------------------------------
        if op == 0x08:
            self.a = self.alu_or(self.a, self.fetch())
        elif op == 0x04:
            self.a = self.alu_or(self.a, self.read(self.dp(self.fetch())))
        elif op == 0x14:
            self.a = self.alu_or(self.a, self.read(self.dp(<uint8_t>(self.fetch() + self.x))))
        elif op == 0x05:
            self.a = self.alu_or(self.a, self.read(self.fetch16()))
        elif op == 0x15:
            self.a = self.alu_or(self.a, self.read(<uint16_t>(self.fetch16() + self.x)))
        elif op == 0x16:
            self.a = self.alu_or(self.a, self.read(<uint16_t>(self.fetch16() + self.y)))
        elif op == 0x06:
            self.a = self.alu_or(self.a, self.read(self.dp(self.x)))
        elif op == 0x07:
            v = <uint8_t>(self.fetch() + self.x)
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.a = self.alu_or(self.a, self.read(addr))
        elif op == 0x17:
            v = self.fetch()
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.a = self.alu_or(self.a, self.read(<uint16_t>(addr + self.y)))
        elif op == 0x09:                                    # OR dd, ds
            v = self.read(self.dp(self.fetch()))
            addr = self.dp(self.fetch())
            self.write(addr, self.alu_or(self.read(addr), v))
        elif op == 0x18:                                    # OR d, #i
            v = self.fetch()
            addr = self.dp(self.fetch())
            self.write(addr, self.alu_or(self.read(addr), v))
        elif op == 0x19:                                    # OR (X), (Y)
            v = self.read(self.dp(self.y))
            addr = self.dp(self.x)
            self.write(addr, self.alu_or(self.read(addr), v))

        # ---- AND ----------------------------------------------------------
        elif op == 0x28:
            self.a = self.alu_and(self.a, self.fetch())
        elif op == 0x24:
            self.a = self.alu_and(self.a, self.read(self.dp(self.fetch())))
        elif op == 0x34:
            self.a = self.alu_and(self.a, self.read(self.dp(<uint8_t>(self.fetch() + self.x))))
        elif op == 0x25:
            self.a = self.alu_and(self.a, self.read(self.fetch16()))
        elif op == 0x35:
            self.a = self.alu_and(self.a, self.read(<uint16_t>(self.fetch16() + self.x)))
        elif op == 0x36:
            self.a = self.alu_and(self.a, self.read(<uint16_t>(self.fetch16() + self.y)))
        elif op == 0x26:
            self.a = self.alu_and(self.a, self.read(self.dp(self.x)))
        elif op == 0x27:
            v = <uint8_t>(self.fetch() + self.x)
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.a = self.alu_and(self.a, self.read(addr))
        elif op == 0x37:
            v = self.fetch()
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.a = self.alu_and(self.a, self.read(<uint16_t>(addr + self.y)))
        elif op == 0x29:
            v = self.read(self.dp(self.fetch()))
            addr = self.dp(self.fetch())
            self.write(addr, self.alu_and(self.read(addr), v))
        elif op == 0x38:
            v = self.fetch()
            addr = self.dp(self.fetch())
            self.write(addr, self.alu_and(self.read(addr), v))
        elif op == 0x39:
            v = self.read(self.dp(self.y))
            addr = self.dp(self.x)
            self.write(addr, self.alu_and(self.read(addr), v))

        # ---- EOR ------------------------------------------------------------
        elif op == 0x48:
            self.a = self.alu_eor(self.a, self.fetch())
        elif op == 0x44:
            self.a = self.alu_eor(self.a, self.read(self.dp(self.fetch())))
        elif op == 0x54:
            self.a = self.alu_eor(self.a, self.read(self.dp(<uint8_t>(self.fetch() + self.x))))
        elif op == 0x45:
            self.a = self.alu_eor(self.a, self.read(self.fetch16()))
        elif op == 0x55:
            self.a = self.alu_eor(self.a, self.read(<uint16_t>(self.fetch16() + self.x)))
        elif op == 0x56:
            self.a = self.alu_eor(self.a, self.read(<uint16_t>(self.fetch16() + self.y)))
        elif op == 0x46:
            self.a = self.alu_eor(self.a, self.read(self.dp(self.x)))
        elif op == 0x47:
            v = <uint8_t>(self.fetch() + self.x)
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.a = self.alu_eor(self.a, self.read(addr))
        elif op == 0x57:
            v = self.fetch()
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.a = self.alu_eor(self.a, self.read(<uint16_t>(addr + self.y)))
        elif op == 0x49:
            v = self.read(self.dp(self.fetch()))
            addr = self.dp(self.fetch())
            self.write(addr, self.alu_eor(self.read(addr), v))
        elif op == 0x58:
            v = self.fetch()
            addr = self.dp(self.fetch())
            self.write(addr, self.alu_eor(self.read(addr), v))
        elif op == 0x59:
            v = self.read(self.dp(self.y))
            addr = self.dp(self.x)
            self.write(addr, self.alu_eor(self.read(addr), v))

        # ---- CMP A -------------------------------------------------------------
        elif op == 0x68:
            self.alu_cmp(self.a, self.fetch())
        elif op == 0x64:
            self.alu_cmp(self.a, self.read(self.dp(self.fetch())))
        elif op == 0x74:
            self.alu_cmp(self.a, self.read(self.dp(<uint8_t>(self.fetch() + self.x))))
        elif op == 0x65:
            self.alu_cmp(self.a, self.read(self.fetch16()))
        elif op == 0x75:
            self.alu_cmp(self.a, self.read(<uint16_t>(self.fetch16() + self.x)))
        elif op == 0x76:
            self.alu_cmp(self.a, self.read(<uint16_t>(self.fetch16() + self.y)))
        elif op == 0x66:
            self.alu_cmp(self.a, self.read(self.dp(self.x)))
        elif op == 0x67:
            v = <uint8_t>(self.fetch() + self.x)
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.alu_cmp(self.a, self.read(addr))
        elif op == 0x77:
            v = self.fetch()
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.alu_cmp(self.a, self.read(<uint16_t>(addr + self.y)))
        elif op == 0x69:                                    # CMP dd, ds
            v = self.read(self.dp(self.fetch()))
            self.alu_cmp(self.read(self.dp(self.fetch())), v)
        elif op == 0x78:                                    # CMP d, #i
            v = self.fetch()
            self.alu_cmp(self.read(self.dp(self.fetch())), v)
        elif op == 0x79:                                    # CMP (X), (Y)
            v = self.read(self.dp(self.y))
            self.alu_cmp(self.read(self.dp(self.x)), v)

        # ---- ADC ---------------------------------------------------------------
        elif op == 0x88:
            self.a = self.alu_adc(self.a, self.fetch())
        elif op == 0x84:
            self.a = self.alu_adc(self.a, self.read(self.dp(self.fetch())))
        elif op == 0x94:
            self.a = self.alu_adc(self.a, self.read(self.dp(<uint8_t>(self.fetch() + self.x))))
        elif op == 0x85:
            self.a = self.alu_adc(self.a, self.read(self.fetch16()))
        elif op == 0x95:
            self.a = self.alu_adc(self.a, self.read(<uint16_t>(self.fetch16() + self.x)))
        elif op == 0x96:
            self.a = self.alu_adc(self.a, self.read(<uint16_t>(self.fetch16() + self.y)))
        elif op == 0x86:
            self.a = self.alu_adc(self.a, self.read(self.dp(self.x)))
        elif op == 0x87:
            v = <uint8_t>(self.fetch() + self.x)
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.a = self.alu_adc(self.a, self.read(addr))
        elif op == 0x97:
            v = self.fetch()
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.a = self.alu_adc(self.a, self.read(<uint16_t>(addr + self.y)))
        elif op == 0x89:
            v = self.read(self.dp(self.fetch()))
            addr = self.dp(self.fetch())
            self.write(addr, self.alu_adc(self.read(addr), v))
        elif op == 0x98:
            v = self.fetch()
            addr = self.dp(self.fetch())
            self.write(addr, self.alu_adc(self.read(addr), v))
        elif op == 0x99:
            v = self.read(self.dp(self.y))
            addr = self.dp(self.x)
            self.write(addr, self.alu_adc(self.read(addr), v))

        # ---- SBC -----------------------------------------------------------------
        elif op == 0xA8:
            self.a = self.alu_sbc(self.a, self.fetch())
        elif op == 0xA4:
            self.a = self.alu_sbc(self.a, self.read(self.dp(self.fetch())))
        elif op == 0xB4:
            self.a = self.alu_sbc(self.a, self.read(self.dp(<uint8_t>(self.fetch() + self.x))))
        elif op == 0xA5:
            self.a = self.alu_sbc(self.a, self.read(self.fetch16()))
        elif op == 0xB5:
            self.a = self.alu_sbc(self.a, self.read(<uint16_t>(self.fetch16() + self.x)))
        elif op == 0xB6:
            self.a = self.alu_sbc(self.a, self.read(<uint16_t>(self.fetch16() + self.y)))
        elif op == 0xA6:
            self.a = self.alu_sbc(self.a, self.read(self.dp(self.x)))
        elif op == 0xA7:
            v = <uint8_t>(self.fetch() + self.x)
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.a = self.alu_sbc(self.a, self.read(addr))
        elif op == 0xB7:
            v = self.fetch()
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.a = self.alu_sbc(self.a, self.read(<uint16_t>(addr + self.y)))
        elif op == 0xA9:
            v = self.read(self.dp(self.fetch()))
            addr = self.dp(self.fetch())
            self.write(addr, self.alu_sbc(self.read(addr), v))
        elif op == 0xB8:
            v = self.fetch()
            addr = self.dp(self.fetch())
            self.write(addr, self.alu_sbc(self.read(addr), v))
        elif op == 0xB9:
            v = self.read(self.dp(self.y))
            addr = self.dp(self.x)
            self.write(addr, self.alu_sbc(self.read(addr), v))

        # ---- CMP X / CMP Y ----------------------------------------------------------
        elif op == 0xC8:
            self.alu_cmp(self.x, self.fetch())
        elif op == 0x3E:
            self.alu_cmp(self.x, self.read(self.dp(self.fetch())))
        elif op == 0x1E:
            self.alu_cmp(self.x, self.read(self.fetch16()))
        elif op == 0xAD:
            self.alu_cmp(self.y, self.fetch())
        elif op == 0x7E:
            self.alu_cmp(self.y, self.read(self.dp(self.fetch())))
        elif op == 0x5E:
            self.alu_cmp(self.y, self.read(self.fetch16()))

        # ---- MOV into A / X / Y ------------------------------------------------------
        elif op == 0xE8:
            self.a = self.fetch(); self.nz8(self.a)
        elif op == 0xE4:
            self.a = self.read(self.dp(self.fetch())); self.nz8(self.a)
        elif op == 0xF4:
            self.a = self.read(self.dp(<uint8_t>(self.fetch() + self.x))); self.nz8(self.a)
        elif op == 0xE5:
            self.a = self.read(self.fetch16()); self.nz8(self.a)
        elif op == 0xF5:
            self.a = self.read(<uint16_t>(self.fetch16() + self.x)); self.nz8(self.a)
        elif op == 0xF6:
            self.a = self.read(<uint16_t>(self.fetch16() + self.y)); self.nz8(self.a)
        elif op == 0xE6:
            self.a = self.read(self.dp(self.x)); self.nz8(self.a)
        elif op == 0xBF:                                    # MOV A, (X)+
            self.a = self.read(self.dp(self.x))
            self.x = <uint8_t>(self.x + 1)
            self.nz8(self.a)
        elif op == 0xE7:
            v = <uint8_t>(self.fetch() + self.x)
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.a = self.read(addr); self.nz8(self.a)
        elif op == 0xF7:
            v = self.fetch()
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.a = self.read(<uint16_t>(addr + self.y)); self.nz8(self.a)
        elif op == 0xCD:
            self.x = self.fetch(); self.nz8(self.x)
        elif op == 0xF8:
            self.x = self.read(self.dp(self.fetch())); self.nz8(self.x)
        elif op == 0xF9:
            self.x = self.read(self.dp(<uint8_t>(self.fetch() + self.y))); self.nz8(self.x)
        elif op == 0xE9:
            self.x = self.read(self.fetch16()); self.nz8(self.x)
        elif op == 0x8D:
            self.y = self.fetch(); self.nz8(self.y)
        elif op == 0xEB:
            self.y = self.read(self.dp(self.fetch())); self.nz8(self.y)
        elif op == 0xFB:
            self.y = self.read(self.dp(<uint8_t>(self.fetch() + self.x))); self.nz8(self.y)
        elif op == 0xEC:
            self.y = self.read(self.fetch16()); self.nz8(self.y)

        # ---- MOV out of A / X / Y ------------------------------------------------------
        elif op == 0xC4:
            self.write(self.dp(self.fetch()), self.a)
        elif op == 0xD4:
            self.write(self.dp(<uint8_t>(self.fetch() + self.x)), self.a)
        elif op == 0xC5:
            self.write(self.fetch16(), self.a)
        elif op == 0xD5:
            self.write(<uint16_t>(self.fetch16() + self.x), self.a)
        elif op == 0xD6:
            self.write(<uint16_t>(self.fetch16() + self.y), self.a)
        elif op == 0xC6:
            self.write(self.dp(self.x), self.a)
        elif op == 0xAF:                                    # MOV (X)+, A
            self.write(self.dp(self.x), self.a)
            self.x = <uint8_t>(self.x + 1)
        elif op == 0xC7:
            v = <uint8_t>(self.fetch() + self.x)
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.write(addr, self.a)
        elif op == 0xD7:
            v = self.fetch()
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.write(<uint16_t>(addr + self.y), self.a)
        elif op == 0xD8:
            self.write(self.dp(self.fetch()), self.x)
        elif op == 0xD9:
            self.write(self.dp(<uint8_t>(self.fetch() + self.y)), self.x)
        elif op == 0xC9:
            self.write(self.fetch16(), self.x)
        elif op == 0xCB:
            self.write(self.dp(self.fetch()), self.y)
        elif op == 0xDB:
            self.write(self.dp(<uint8_t>(self.fetch() + self.x)), self.y)
        elif op == 0xCC:
            self.write(self.fetch16(), self.y)
        elif op == 0x8F:                                    # MOV d, #i
            v = self.fetch()
            self.write(self.dp(self.fetch()), v)
        elif op == 0xFA:                                    # MOV dd, ds
            v = self.read(self.dp(self.fetch()))
            self.write(self.dp(self.fetch()), v)

        # ---- register transfers -----------------------------------------------------------
        elif op == 0x7D:
            self.a = self.x; self.nz8(self.a)
        elif op == 0x5D:
            self.x = self.a; self.nz8(self.x)
        elif op == 0xDD:
            self.a = self.y; self.nz8(self.a)
        elif op == 0xFD:
            self.y = self.a; self.nz8(self.y)
        elif op == 0x9D:
            self.x = self.sp; self.nz8(self.x)
        elif op == 0xBD:
            self.sp = self.x

        # ---- inc / dec ----------------------------------------------------------------------
        elif op == 0xBC:
            self.a = self.alu_inc(self.a)
        elif op == 0x9C:
            self.a = self.alu_dec(self.a)
        elif op == 0x3D:
            self.x = self.alu_inc(self.x)
        elif op == 0x1D:
            self.x = self.alu_dec(self.x)
        elif op == 0xFC:
            self.y = self.alu_inc(self.y)
        elif op == 0xDC:
            self.y = self.alu_dec(self.y)
        elif op == 0xAB:
            addr = self.dp(self.fetch()); self.write(addr, self.alu_inc(self.read(addr)))
        elif op == 0xBB:
            addr = self.dp(<uint8_t>(self.fetch() + self.x)); self.write(addr, self.alu_inc(self.read(addr)))
        elif op == 0xAC:
            addr = self.fetch16(); self.write(addr, self.alu_inc(self.read(addr)))
        elif op == 0x8B:
            addr = self.dp(self.fetch()); self.write(addr, self.alu_dec(self.read(addr)))
        elif op == 0x9B:
            addr = self.dp(<uint8_t>(self.fetch() + self.x)); self.write(addr, self.alu_dec(self.read(addr)))
        elif op == 0x8C:
            addr = self.fetch16(); self.write(addr, self.alu_dec(self.read(addr)))

        # ---- shifts / rotates -------------------------------------------------------------------
        elif op == 0x1C:
            self.a = self.alu_asl(self.a)
        elif op == 0x0B:
            addr = self.dp(self.fetch()); self.write(addr, self.alu_asl(self.read(addr)))
        elif op == 0x1B:
            addr = self.dp(<uint8_t>(self.fetch() + self.x)); self.write(addr, self.alu_asl(self.read(addr)))
        elif op == 0x0C:
            addr = self.fetch16(); self.write(addr, self.alu_asl(self.read(addr)))
        elif op == 0x5C:
            self.a = self.alu_lsr(self.a)
        elif op == 0x4B:
            addr = self.dp(self.fetch()); self.write(addr, self.alu_lsr(self.read(addr)))
        elif op == 0x5B:
            addr = self.dp(<uint8_t>(self.fetch() + self.x)); self.write(addr, self.alu_lsr(self.read(addr)))
        elif op == 0x4C:
            addr = self.fetch16(); self.write(addr, self.alu_lsr(self.read(addr)))
        elif op == 0x3C:
            self.a = self.alu_rol(self.a)
        elif op == 0x2B:
            addr = self.dp(self.fetch()); self.write(addr, self.alu_rol(self.read(addr)))
        elif op == 0x3B:
            addr = self.dp(<uint8_t>(self.fetch() + self.x)); self.write(addr, self.alu_rol(self.read(addr)))
        elif op == 0x2C:
            addr = self.fetch16(); self.write(addr, self.alu_rol(self.read(addr)))
        elif op == 0x7C:
            self.a = self.alu_ror(self.a)
        elif op == 0x6B:
            addr = self.dp(self.fetch()); self.write(addr, self.alu_ror(self.read(addr)))
        elif op == 0x7B:
            addr = self.dp(<uint8_t>(self.fetch() + self.x)); self.write(addr, self.alu_ror(self.read(addr)))
        elif op == 0x6C:
            addr = self.fetch16(); self.write(addr, self.alu_ror(self.read(addr)))
        elif op == 0x9F:                                    # XCN A
            self.a = <uint8_t>((self.a >> 4) | (self.a << 4))
            self.nz8(self.a)

        # ---- 16-bit ops -----------------------------------------------------------------------------
        elif op == 0xBA:                                    # MOVW YA, d
            v = self.fetch()
            self.a = self.read(self.dp(v))
            self.y = self.read(self.dp(<uint8_t>(v + 1)))
            self.nz16(<uint16_t>((self.y << 8) | self.a))
        elif op == 0xDA:                                    # MOVW d, YA
            v = self.fetch()
            self.write(self.dp(v), self.a)
            self.write(self.dp(<uint8_t>(v + 1)), self.y)
        elif op == 0x3A:                                    # INCW d
            v = self.fetch()
            w = <uint16_t>((self.read(self.dp(v))
                            | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)) + 1)
            self.write(self.dp(v), <uint8_t>(w & 0xFF))
            self.write(self.dp(<uint8_t>(v + 1)), <uint8_t>(w >> 8))
            self.nz16(w)
        elif op == 0x1A:                                    # DECW d
            v = self.fetch()
            w = <uint16_t>((self.read(self.dp(v))
                            | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)) - 1)
            self.write(self.dp(v), <uint8_t>(w & 0xFF))
            self.write(self.dp(<uint8_t>(v + 1)), <uint8_t>(w >> 8))
            self.nz16(w)
        elif op == 0x7A:                                    # ADDW YA, d
            v = self.fetch()
            o1 = self.read(self.dp(v))
            o2 = self.read(self.dp(<uint8_t>(v + 1)))
            self.psw &= ~P_C
            self.a = self.alu_adc(self.a, o1)
            self.y = self.alu_adc(self.y, o2)
            self.setf(P_Z, ((self.y << 8) | self.a) == 0)
        elif op == 0x9A:                                    # SUBW YA, d
            v = self.fetch()
            o1 = self.read(self.dp(v))
            o2 = self.read(self.dp(<uint8_t>(v + 1)))
            self.psw |= P_C
            self.a = self.alu_sbc(self.a, o1)
            self.y = self.alu_sbc(self.y, o2)
            self.setf(P_Z, ((self.y << 8) | self.a) == 0)
        elif op == 0x5A:                                    # CMPW YA, d
            v = self.fetch()
            w = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            z = <int32_t>((self.y << 8) | self.a) - <int32_t>w
            self.setf(P_C, z >= 0)
            self.nz16(<uint16_t>(z & 0xFFFF))
        elif op == 0xCF:                                    # MUL YA
            big = <uint32_t>self.y * <uint32_t>self.a
            self.a = <uint8_t>(big & 0xFF)
            self.y = <uint8_t>((big >> 8) & 0xFF)
            self.nz8(self.y)
        elif op == 0x9E:                                    # DIV YA, X
            ya = <uint16_t>((self.y << 8) | self.a)
            self.setf(P_H, (self.x & 15) <= (self.y & 15))
            self.setf(P_V, self.y >= self.x)
            if self.x == 0:
                self.a = 0xFF
                self.y = 0xFF
            elif self.y < (self.x << 1):
                self.a = <uint8_t>(ya // self.x)
                self.y = <uint8_t>(ya % self.x)
            else:
                big = <uint32_t>(<int32_t>ya - (<int32_t>self.x << 9))
                self.a = <uint8_t>(255 - big // <uint32_t>(256 - self.x))
                self.y = <uint8_t>(self.x + big % <uint32_t>(256 - self.x))
            self.nz8(self.a)

        # ---- decimal adjust ---------------------------------------------------------------------------
        elif op == 0xDF:                                    # DAA A
            if (self.psw & P_C) or self.a > 0x99:
                self.a = <uint8_t>(self.a + 0x60)
                self.psw |= P_C
            if (self.psw & P_H) or (self.a & 15) > 9:
                self.a = <uint8_t>(self.a + 0x06)
            self.nz8(self.a)
        elif op == 0xBE:                                    # DAS A
            if not (self.psw & P_C) or self.a > 0x99:
                self.a = <uint8_t>(self.a - 0x60)
                self.psw &= ~P_C
            if not (self.psw & P_H) or (self.a & 15) > 9:
                self.a = <uint8_t>(self.a - 0x06)
            self.nz8(self.a)

        # ---- stack -------------------------------------------------------------------------------------
        elif op == 0x2D:
            self.push(self.a)
        elif op == 0x4D:
            self.push(self.x)
        elif op == 0x6D:
            self.push(self.y)
        elif op == 0x0D:
            self.push(self.psw)
        elif op == 0xAE:
            self.a = self.pull()
        elif op == 0xCE:
            self.x = self.pull()
        elif op == 0xEE:
            self.y = self.pull()
        elif op == 0x8E:
            self.psw = self.pull()

        # ---- branches ------------------------------------------------------------------------------------
        elif op == 0x2F:
            self.branch(1)
        elif op == 0x10:
            self.branch(not (self.psw & P_N))
        elif op == 0x30:
            self.branch(1 if (self.psw & P_N) else 0)
        elif op == 0x50:
            self.branch(not (self.psw & P_V))
        elif op == 0x70:
            self.branch(1 if (self.psw & P_V) else 0)
        elif op == 0x90:
            self.branch(not (self.psw & P_C))
        elif op == 0xB0:
            self.branch(1 if (self.psw & P_C) else 0)
        elif op == 0xD0:
            self.branch(not (self.psw & P_Z))
        elif op == 0xF0:
            self.branch(1 if (self.psw & P_Z) else 0)

        # ---- bit-test branches: BBS/BBC d.bit, r ------------------------------------------------------------
        elif (op == 0x03 or op == 0x23 or op == 0x43 or op == 0x63 or
              op == 0x83 or op == 0xA3 or op == 0xC3 or op == 0xE3):   # BBS d.0-7, r
            v = self.read(self.dp(self.fetch()))
            bit = op >> 5
            self.branch(1 if (v >> bit) & 1 else 0)
        elif (op == 0x13 or op == 0x33 or op == 0x53 or op == 0x73 or
              op == 0x93 or op == 0xB3 or op == 0xD3 or op == 0xF3):   # BBC d.0-7, r
            v = self.read(self.dp(self.fetch()))
            bit = op >> 5
            self.branch(0 if (v >> bit) & 1 else 1)

        # ---- SET1 / CLR1 d.bit ----------------------------------------------------------------------------
        elif (op == 0x02 or op == 0x22 or op == 0x42 or op == 0x62 or
              op == 0x82 or op == 0xA2 or op == 0xC2 or op == 0xE2):   # SET1 d.0-7
            addr = self.dp(self.fetch())
            self.write(addr, self.read(addr) | <uint8_t>(1 << (op >> 5)))
        elif (op == 0x12 or op == 0x32 or op == 0x52 or op == 0x72 or
              op == 0x92 or op == 0xB2 or op == 0xD2 or op == 0xF2):   # CLR1 d.0-7
            addr = self.dp(self.fetch())
            self.write(addr, self.read(addr) & <uint8_t>(~(1 << (op >> 5))))

        # ---- compare-and-branch --------------------------------------------------------------------------
        elif op == 0x2E:                                    # CBNE d, r
            v = self.read(self.dp(self.fetch()))
            self.branch(1 if v != self.a else 0)
        elif op == 0xDE:                                    # CBNE d+X, r
            v = self.read(self.dp(<uint8_t>(self.fetch() + self.x)))
            self.branch(1 if v != self.a else 0)
        elif op == 0x6E:                                    # DBNZ d, r
            addr = self.dp(self.fetch())
            v = <uint8_t>(self.read(addr) - 1)
            self.write(addr, v)
            self.branch(1 if v != 0 else 0)
        elif op == 0xFE:                                    # DBNZ Y, r
            self.y = <uint8_t>(self.y - 1)
            self.branch(1 if self.y != 0 else 0)

        # ---- jumps / calls ----------------------------------------------------------------------------------
        elif op == 0x5F:                                    # JMP !a
            self.pc = self.fetch16()
        elif op == 0x1F:                                    # JMP [!a+X]
            addr = <uint16_t>(self.fetch16() + self.x)
            self.pc = self.read16(addr)
        elif op == 0x3F:                                    # CALL !a
            addr = self.fetch16()
            self.push(<uint8_t>(self.pc >> 8))
            self.push(<uint8_t>(self.pc & 0xFF))
            self.pc = addr
        elif op == 0x4F:                                    # PCALL u
            v = self.fetch()
            self.push(<uint8_t>(self.pc >> 8))
            self.push(<uint8_t>(self.pc & 0xFF))
            self.pc = <uint16_t>(0xFF00 | v)
        elif (op == 0x01 or op == 0x11 or op == 0x21 or op == 0x31 or
              op == 0x41 or op == 0x51 or op == 0x61 or op == 0x71 or
              op == 0x81 or op == 0x91 or op == 0xA1 or op == 0xB1 or
              op == 0xC1 or op == 0xD1 or op == 0xE1 or op == 0xF1):   # TCALL 0-15
            addr = <uint16_t>(0xFFDE - ((op >> 4) << 1))
            self.push(<uint8_t>(self.pc >> 8))
            self.push(<uint8_t>(self.pc & 0xFF))
            self.pc = self.read16(addr)
        elif op == 0x6F:                                    # RET
            self.pc = self.pull()
            self.pc |= <uint16_t>self.pull() << 8
        elif op == 0x7F:                                    # RETI
            self.psw = self.pull()
            self.pc = self.pull()
            self.pc |= <uint16_t>self.pull() << 8
        elif op == 0x0F:                                    # BRK
            self.push(<uint8_t>(self.pc >> 8))
            self.push(<uint8_t>(self.pc & 0xFF))
            self.push(self.psw)
            self.psw |= P_B
            self.psw &= ~P_I
            self.pc = self.read16(0xFFDE)

        # ---- carry-bit operations -----------------------------------------------------------------------------
        elif op == 0x0A or op == 0x2A or op == 0x4A or op == 0x6A or \
             op == 0x8A or op == 0xAA or op == 0xCA or op == 0xEA:
            w = self.fetch16()
            addr = w & 0x1FFF
            bit = <uint8_t>(w >> 13)
            v = self.read(addr)
            v2 = (v >> bit) & 1
            if op == 0x0A:                                  # OR1 C, m.b
                self.setf(P_C, (self.psw & P_C) or v2)
            elif op == 0x2A:                                # OR1 C, /m.b
                self.setf(P_C, (self.psw & P_C) or (not v2))
            elif op == 0x4A:                                # AND1 C, m.b
                self.setf(P_C, (self.psw & P_C) and v2)
            elif op == 0x6A:                                # AND1 C, /m.b
                self.setf(P_C, (self.psw & P_C) and (not v2))
            elif op == 0x8A:                                # EOR1 C, m.b
                self.setf(P_C, ((1 if (self.psw & P_C) else 0) ^ v2) != 0)
            elif op == 0xAA:                                # MOV1 C, m.b
                self.setf(P_C, v2)
            elif op == 0xCA:                                # MOV1 m.b, C
                if self.psw & P_C:
                    v |= <uint8_t>(1 << bit)
                else:
                    v &= <uint8_t>(~(1 << bit))
                self.write(addr, v)
            else:                                           # $EA NOT1 m.b
                self.write(addr, v ^ <uint8_t>(1 << bit))

        elif op == 0x0E:                                    # TSET1 !a
            addr = self.fetch16()
            v = self.read(addr)
            self.nz8(<uint8_t>(self.a - v))
            self.write(addr, v | self.a)
        elif op == 0x4E:                                    # TCLR1 !a
            addr = self.fetch16()
            v = self.read(addr)
            self.nz8(<uint8_t>(self.a - v))
            self.write(addr, v & <uint8_t>(~self.a))

        # ---- flag control ---------------------------------------------------------------------------------------
        elif op == 0x60:
            self.psw &= ~P_C
        elif op == 0x80:
            self.psw |= P_C
        elif op == 0xED:
            self.psw ^= P_C
        elif op == 0xE0:
            self.psw &= ~(P_V | P_H)
        elif op == 0x20:
            self.psw &= ~P_P
        elif op == 0x40:
            self.psw |= P_P
        elif op == 0xA0:
            self.psw |= P_I
        elif op == 0xC0:
            self.psw &= ~P_I

        # ---- halt / nop --------------------------------------------------------------------------------------------
        elif op == 0x00:                                    # NOP
            pass
        elif op == 0xEF or op == 0xFF:                      # SLEEP / STOP
            self.stopped = 1

    # =====================================================================
    # S-CPU side ($2140-$2143)
    # =====================================================================

    cdef uint8_t cpu_read_port(self, int index) noexcept:
        return self.port_out[index & 3]

    cdef void cpu_write_port(self, int index, uint8_t value) noexcept:
        self.port_in[index & 3] = value



    # -- save state (generated by tools/gen_state.py; do not edit) --------

    def state_ints(self):
        cdef int i, j
        v = [self.pc, self.a, self.x, self.y, self.sp, self.psw, self.ipl_enabled, self.clock, self.master_prev, self.frac, self.dsp_counter, self.extra_cycles, self.stopped, self.dsp_addr]
        for i in range(4):
            v.append(self.port_in[i])
        for i in range(4):
            v.append(self.port_out[i])
        for i in range(3):
            v.append(self.timer_target[i])
        for i in range(3):
            v.append(self.timer_div[i])
        for i in range(3):
            v.append(self.timer_counter[i])
        for i in range(3):
            v.append(self.timer_stage[i])
        for i in range(3):
            v.append(self.timer_enabled[i])
        return v

    def load_ints(self, v):
        cdef int i, j, k = 14
        self.pc = v[0]
        self.a = v[1]
        self.x = v[2]
        self.y = v[3]
        self.sp = v[4]
        self.psw = v[5]
        self.ipl_enabled = v[6]
        self.clock = v[7]
        self.master_prev = v[8]
        self.frac = v[9]
        self.dsp_counter = v[10]
        self.extra_cycles = v[11]
        self.stopped = v[12]
        self.dsp_addr = v[13]
        for i in range(4):
            self.port_in[i] = v[k + i]
        k += 4
        for i in range(4):
            self.port_out[i] = v[k + i]
        k += 4
        for i in range(3):
            self.timer_target[i] = v[k + i]
        k += 3
        for i in range(3):
            self.timer_div[i] = v[k + i]
        k += 3
        for i in range(3):
            self.timer_counter[i] = v[k + i]
        k += 3
        for i in range(3):
            self.timer_stage[i] = v[k + i]
        k += 3
        for i in range(3):
            self.timer_enabled[i] = v[k + i]
        k += 3

    def state_blobs(self):
        return [PyBytes_FromStringAndSize(<char *>self.ram, 65536)]

    def load_blobs(self, blobs):
        if len(blobs[0]) != 65536:
            raise ValueError('bad ram blob')
        memcpy(<char *>self.ram, <char *><bytes>blobs[0], 65536)

    # -- end generated save state ------------------------------------------

    # =====================================================================
    # python helpers
    # =====================================================================

    @property
    def ports_to_cpu(self):
        return tuple(self.port_out[i] for i in range(4))

    @property
    def ports_from_cpu(self):
        return tuple(self.port_in[i] for i in range(4))

    @property
    def regs(self):
        return dict(pc=self.pc, a=self.a, x=self.x, y=self.y,
                    sp=self.sp, psw=self.psw, clock=self.clock,
                    stopped=self.stopped, ipl=self.ipl_enabled)

    @property
    def ram_bytes(self):
        return bytes(bytearray([self.ram[i] for i in range(0x10000)]))

    def do_step(self):
        self.step()

    def do_reset(self):
        self.reset()
