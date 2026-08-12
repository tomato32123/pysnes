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
# Opcodes that begin by reading the byte after themselves and throwing it
# away.  Every one-byte instruction does it -- the SPC700 fetches the next
# byte before it knows it does not need it, and the read is a real bus cycle
# that a test ROM can see.  Keeping it as a table rather than a line in each
# of the seventy-six branches means the dispatch stays about what the
# instruction does.
cdef uint8_t DUMMY_PC[256]
cdef int _op
for _op in range(256):
    DUMMY_PC[_op] = 0
for _op in (
    0x00,                                            # NOP
    0x0F, 0x6F, 0x7F, 0xEF, 0xFF,                    # BRK, RET, RETI, SLEEP, STOP
    0x01, 0x11, 0x21, 0x31, 0x41, 0x51, 0x61, 0x71,  # TCALL 0-15
    0x81, 0x91, 0xA1, 0xB1, 0xC1, 0xD1, 0xE1, 0xF1,
    0x20, 0x40, 0x60, 0x80, 0xA0, 0xC0, 0xE0, 0xED,  # flag sets, CLRV, NOTC
    0x1C, 0x1D, 0x3C, 0x3D, 0x5C, 0x7C,              # ASL/ROL/LSR/ROR A, INC/DEC X
    0x9C, 0xBC, 0xDC, 0xFC,                          # DEC/INC A, DEC/INC Y
    0x5D, 0x7D, 0x9D, 0xBD, 0xDD, 0xFD,              # register transfers
    0x0D, 0x2D, 0x4D, 0x6D,                          # PUSH
    0x8E, 0xAE, 0xCE, 0xEE,                          # POP
    0x06, 0x26, 0x46, 0x66, 0x86, 0xA6, 0xE6,        # ALU A, (X)
    0xC6, 0xAF, 0xBF,                                # MOV (X),A / (X)+,A / A,(X)+
    0x19, 0x39, 0x59, 0x79, 0x99, 0xB9,              # (X),(Y) forms
    0x9E, 0x9F, 0xCF, 0xBE, 0xDF, 0xFE,              # DIV, XCN, MUL, DAS, DAA, DBNZ Y
):
    DUMMY_PC[_op] = 1


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
    2, 8, 4, 5, 4, 5, 5, 6, 3, 4, 5, 4, 2, 2, 4, 3,
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
    BRR_BUF = 12                # decoded samples a voice keeps, ring
    ECHO_HIST = 8               # taps the echo filter looks back over


# The interpolation kernel, as it is in the chip's mask ROM.
#
# The DSP reads the four coefficients for fractional position p as
# gauss[255-p], gauss[511-p], gauss[256+p] and gauss[p], applying them to the
# oldest through newest of four samples.  It is a gaussian rather than a
# windowed sinc -- hence the chip's name for it, and why the SNES sounds soft
# on high-pitched samples.
#
# This used to be generated: a gaussian with its width solved to put the peak
# on the real table's 1305, with each group of four taps normalised to sum to
# exactly 2048.  It was close, and being close was enough to sound right and
# not enough to be right.  The real table's groups sum to 2047, 2048 or 2049,
# and that one unit is the whole of the difference -- a voice whose samples are
# small comes out a couple of units off, which is inaudible and is exactly what
# a chip comparing its output against hardware notices.
#
# Transcribed from blargg's S-DSP.  There is no deriving it.
cdef int16_t GAUSS[512]
GAUSS[:] = [
       0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
       1,    1,    1,    1,    1,    1,    1,    1,    1,    1,    1,    2,    2,    2,    2,    2,
       2,    2,    3,    3,    3,    3,    3,    4,    4,    4,    4,    4,    5,    5,    5,    5,
       6,    6,    6,    6,    7,    7,    7,    8,    8,    8,    9,    9,    9,   10,   10,   10,
      11,   11,   11,   12,   12,   13,   13,   14,   14,   15,   15,   15,   16,   16,   17,   17,
      18,   19,   19,   20,   20,   21,   21,   22,   23,   23,   24,   24,   25,   26,   27,   27,
      28,   29,   29,   30,   31,   32,   32,   33,   34,   35,   36,   36,   37,   38,   39,   40,
      41,   42,   43,   44,   45,   46,   47,   48,   49,   50,   51,   52,   53,   54,   55,   56,
      58,   59,   60,   61,   62,   64,   65,   66,   67,   69,   70,   71,   73,   74,   76,   77,
      78,   80,   81,   83,   84,   86,   87,   89,   90,   92,   94,   95,   97,   99,  100,  102,
     104,  106,  107,  109,  111,  113,  115,  117,  118,  120,  122,  124,  126,  128,  130,  132,
     134,  137,  139,  141,  143,  145,  147,  150,  152,  154,  156,  159,  161,  163,  166,  168,
     171,  173,  175,  178,  180,  183,  186,  188,  191,  193,  196,  199,  201,  204,  207,  210,
     212,  215,  218,  221,  224,  227,  230,  233,  236,  239,  242,  245,  248,  251,  254,  257,
     260,  263,  267,  270,  273,  276,  280,  283,  286,  290,  293,  297,  300,  304,  307,  311,
     314,  318,  321,  325,  328,  332,  336,  339,  343,  347,  351,  354,  358,  362,  366,  370,
     374,  378,  381,  385,  389,  393,  397,  401,  405,  410,  414,  418,  422,  426,  430,  434,
     439,  443,  447,  451,  456,  460,  464,  469,  473,  477,  482,  486,  491,  495,  499,  504,
     508,  513,  517,  522,  527,  531,  536,  540,  545,  550,  554,  559,  563,  568,  573,  577,
     582,  587,  592,  596,  601,  606,  611,  615,  620,  625,  630,  635,  640,  644,  649,  654,
     659,  664,  669,  674,  678,  683,  688,  693,  698,  703,  708,  713,  718,  723,  728,  732,
     737,  742,  747,  752,  757,  762,  767,  772,  777,  782,  787,  792,  797,  802,  806,  811,
     816,  821,  826,  831,  836,  841,  846,  851,  855,  860,  865,  870,  875,  880,  884,  889,
     894,  899,  904,  908,  913,  918,  923,  927,  932,  937,  941,  946,  951,  955,  960,  965,
     969,  974,  978,  983,  988,  992,  997, 1001, 1005, 1010, 1014, 1019, 1023, 1027, 1032, 1036,
    1040, 1045, 1049, 1053, 1057, 1061, 1066, 1070, 1074, 1078, 1082, 1086, 1090, 1094, 1098, 1102,
    1106, 1109, 1113, 1117, 1121, 1125, 1128, 1132, 1136, 1139, 1143, 1146, 1150, 1153, 1157, 1160,
    1164, 1167, 1170, 1174, 1177, 1180, 1183, 1186, 1190, 1193, 1196, 1199, 1202, 1205, 1207, 1210,
    1213, 1216, 1219, 1221, 1224, 1227, 1229, 1232, 1234, 1237, 1239, 1241, 1244, 1246, 1248, 1251,
    1253, 1255, 1257, 1259, 1261, 1263, 1265, 1267, 1269, 1270, 1272, 1274, 1275, 1277, 1279, 1280,
    1282, 1283, 1284, 1286, 1287, 1288, 1290, 1291, 1292, 1293, 1294, 1295, 1296, 1297, 1297, 1298,
    1299, 1300, 1300, 1301, 1302, 1302, 1303, 1303, 1303, 1304, 1304, 1304, 1304, 1304, 1305, 1305
]


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
        cdef int j
        for j in range(512):
            self.gauss[j] = GAUSS[j]

    cdef void reset(self) noexcept:
        cdef int i, v
        memset(self.reg, 0, sizeof(self.reg))
        self.reg[0x6C] = 0xE0            # FLG: reset + mute + echo writes off
        for v in range(8):
            self.brr_addr[v] = 0
            self.brr_offset[v] = 1
            self.buf_pos[v] = 0
            self.interp_pos[v] = 0
            self.env[v] = 0
            self.hidden_env[v] = 0
            self.env_mode[v] = ENV_RELEASE
            self.kon_delay[v] = 0
            self.envx_out[v] = 0
            self.voice_out[v] = 0
            for i in range(BRR_BUF * 2):
                self.buf[v][i] = 0
        self.counter = 0
        self.noise = 0x4000
        self.echo_offset = 0
        self.echo_length = 0
        self.echo_esa = 0
        self.echo_flg = 0xE0
        for i in range(ECHO_HIST * 2):
            self.echo_hist_l[i] = 0
            self.echo_hist_r[i] = 0
        self.echo_hist_pos = 0
        self.phase = 0
        self.every_other = 1     # the chip comes out of reset mid-pair
        self.kon = 0
        self.new_kon = 0
        self.t_koff = 0
        self.t_pmon = 0
        self.t_non = 0
        self.t_eon = 0
        self.t_dir = 0
        self.t_dir_addr = 0
        self.t_srcn = 0
        self.t_brr_next_addr = 0
        self.t_adsr0 = 0
        self.t_brr_byte = 0
        self.t_brr_header = 0
        self.t_pitch = 0
        self.t_output = 0
        self.t_looped = 0
        self.t_echo_ptr = 0
        self.endx_buf = 0
        self.outx_buf = 0
        self.envx_buf = 0
        for i in range(2):
            self.t_main_out[i] = 0
            self.t_echo_out[i] = 0
            self.t_echo_in[i] = 0
        self.out_write = 0
        self.out_read = 0
        self.out_count = 0
        self.solo = -1
        self.echo_enabled = 1
        for i in range(8):
            self.kon_count[i] = 0
        self.last_l = 0
        self.last_r = 0

    cdef uint8_t read_reg(self, uint8_t addr) noexcept:
        return self.reg[addr & 0x7F]

    cdef void write_reg(self, uint8_t addr, uint8_t value) noexcept:
        cdef int low
        if addr >= 0x80:
            return                        # $80-$FF only mirror the read side
        self.reg[addr] = value
        low = addr & 0x0F
        # Three registers are not simply stored.  ENVX and OUTX go into the
        # buffers the pipeline writes back from, so a write lands only if the
        # pipeline is not about to overwrite it; KON is held aside until the
        # sample boundary that reads it; and ENDX clears whatever is written.
        if low == 8:
            self.envx_buf = value
        elif low == 9:
            self.outx_buf = value
        elif low == 0x0C:
            if addr == 0x4C:
                self.new_kon = value
            elif addr == 0x7C:
                self.endx_buf = 0
                self.reg[0x7C] = 0

    # =====================================================================
    # the pipeline
    # =====================================================================
    #
    # The chip does not compute a sample and then move on.  It walks 32 steps
    # per sample, and at any moment eight voices are each at a different one:
    # while voice 0 is being written out, voice 2 is reading its BRR header and
    # voice 5 is having its envelope run.  Almost everything here that a lump
    # of per-sample code gets wrong is a consequence of that -- a register read
    # at step 2 and used at step 25 does not see a write that landed at step 10.
    #
    # The step numbering, and which voice is where on each one, is the chip's.

    cdef inline int _counter_poll(self, int rate) noexcept:
        if rate == 0:
            return 0
        return 1 if ((self.counter + COUNTER_OFFSET[rate]) % COUNTER_RATE[rate]) == 0 else 0

    cdef inline int32_t _interpolate(self, int v) noexcept:
        """Four taps of a gaussian kernel across the voice's ring of decoded
        samples.  The third tap is truncated to sixteen bits before the fourth
        is added, and the result loses its low bit."""
        cdef int base = ((self.interp_pos[v] >> 12) + self.buf_pos[v])
        cdef int offset = (self.interp_pos[v] >> 4) & 0xFF
        cdef int32_t out
        out = (<int32_t>self.gauss[255 - offset] * self.buf[v][base + 0]) >> 11
        out += (<int32_t>self.gauss[511 - offset] * self.buf[v][base + 1]) >> 11
        out += (<int32_t>self.gauss[256 + offset] * self.buf[v][base + 2]) >> 11
        out = <int32_t><int16_t>out
        out += (<int32_t>self.gauss[offset] * self.buf[v][base + 3]) >> 11
        return _clamp16(out) & ~1

    cdef void _decode_brr(self, int v) noexcept:
        """Four samples out of one BRR byte pair, into the voice's ring."""
        cdef int nybbles = (<int>self.t_brr_byte << 8) | self.apu.ram[
            <uint16_t>(self.brr_addr[v] + self.brr_offset[v] + 1)]
        cdef int header = self.t_brr_header
        cdef int shift = header >> 4
        cdef int filt = header & 0x0C
        cdef int pos = self.buf_pos[v]
        cdef int i, p1, p2
        cdef int32_t sm

        self.buf_pos[v] += 4
        if self.buf_pos[v] >= BRR_BUF:
            self.buf_pos[v] = 0

        for i in range(4):
            sm = <int32_t><int16_t>nybbles >> 12
            nybbles = (nybbles << 4) & 0xFFFFFFF
            sm = (sm << shift) >> 1
            if shift >= 0x0D:             # an invalid shift keeps only the sign
                sm = (sm >> 25) << 11
            p1 = self.buf[v][pos + BRR_BUF - 1]
            p2 = self.buf[v][pos + BRR_BUF - 2] >> 1
            if filt >= 8:
                sm += p1
                sm -= p2
                if filt == 8:
                    sm += p2 >> 4
                    sm += (p1 * -3) >> 6
                else:
                    sm += (p1 * -13) >> 7
                    sm += (p2 * 3) >> 4
            elif filt:
                sm += p1 >> 1
                sm += (-p1) >> 5
            sm = <int32_t><int16_t>(_clamp16(sm) * 2)
            self.buf[v][pos] = sm
            self.buf[v][pos + BRR_BUF] = sm
            pos += 1

    cdef void _run_envelope(self, int v) noexcept:
        """One step of a voice's envelope.

        The shape matters as much as the arithmetic.  The next value and its
        rate are worked out first, then the two mode changes are decided, and
        only the *storing* of the value is gated on the rate counter.  Putting
        the mode changes inside the branch that computes the value -- which is
        the obvious way to write it -- means they can only happen while that
        branch is running, and one of them is not supposed to be that way: a
        voice climbing under GAIN still leaves attack for decay when it tops
        out, even though nothing about GAIN is attacking.
        """
        cdef int32_t e = self.env[v]
        cdef int rate = 0, mode
        cdef int env_data

        if self.env_mode[v] == ENV_RELEASE:
            e -= 8
            if e < 0:
                e = 0
            self.env[v] = e
            return

        env_data = self.reg[v * 16 + 6]
        if self.t_adsr0 & 0x80:                            # ADSR
            if self.env_mode[v] >= ENV_DECAY:
                e = (e - 1) - ((e - 1) >> 8)
                rate = env_data & 0x1F
                if self.env_mode[v] == ENV_DECAY:
                    rate = ((self.t_adsr0 >> 3) & 0x0E) + 0x10
            else:                                          # attack
                rate = ((self.t_adsr0 & 0x0F) << 1) + 1
                e += 0x20 if rate < 31 else 0x400
        else:                                              # GAIN
            env_data = self.reg[v * 16 + 7]
            mode = env_data >> 5
            if mode < 4:                                   # direct
                e = env_data * 0x10
                rate = 31
            else:
                rate = env_data & 0x1F
                if mode == 4:                              # linear decrease
                    e -= 0x20
                elif mode < 6:                             # exponential
                    e = (e - 1) - ((e - 1) >> 8)
                else:                                      # linear increase
                    e += 0x20
                    # The two-slope form changes gradient on the value before
                    # it was clamped, not after, so it reads the one kept aside.
                    if mode > 6 and <uint32_t>self.hidden_env[v] >= 0x600:
                        e += 8 - 0x20

        # Sustain is reached when the top three bits of the envelope match the
        # level asked for, not when it falls below a threshold.
        if (e >> 8) == (env_data >> 5) and self.env_mode[v] == ENV_DECAY:
            self.env_mode[v] = ENV_SUSTAIN

        self.hidden_env[v] = e

        # Unsigned, so a linear decrease going below zero lands here too.
        if <uint32_t>e > 0x7FF:
            e = 0 if e < 0 else 0x7FF
            if self.env_mode[v] == ENV_ATTACK:
                self.env_mode[v] = ENV_DECAY

        if self._counter_poll(rate):
            self.env[v] = e

    # -- the voice steps ----------------------------------------------------

    cdef inline void _v1(self, int v) noexcept:
        self.t_dir_addr = <uint16_t>((<int>self.t_dir << 8) + (<int>self.t_srcn << 2))
        self.t_srcn = self.reg[v * 16 + 4]

    cdef inline void _v2(self, int v) noexcept:
        cdef uint16_t entry = self.t_dir_addr
        if not self.kon_delay[v]:
            entry = <uint16_t>(entry + 2)
        self.t_brr_next_addr = <uint16_t>(self.apu.ram[entry]
                                          | (<uint16_t>self.apu.ram[<uint16_t>(entry + 1)] << 8))
        self.t_adsr0 = self.reg[v * 16 + 5]
        self.t_pitch = self.reg[v * 16 + 2]

    cdef inline void _v3a(self, int v) noexcept:
        self.t_pitch += (<int>(self.reg[v * 16 + 3] & 0x3F)) << 8

    cdef inline void _v3b(self, int v) noexcept:
        self.t_brr_byte = self.apu.ram[<uint16_t>(self.brr_addr[v] + self.brr_offset[v])]
        self.t_brr_header = self.apu.ram[self.brr_addr[v]]

    cdef void _v3c(self, int v) noexcept:
        cdef int32_t output
        cdef int vbit = 1 << v

        if self.t_pmon & vbit:
            self.t_pitch += ((self.t_output >> 5) * self.t_pitch) >> 10

        if self.kon_delay[v]:
            if self.kon_delay[v] == 5:
                self.brr_addr[v] = self.t_brr_next_addr
                self.brr_offset[v] = 1
                self.buf_pos[v] = 0
                self.t_brr_header = 0     # the header is ignored on this sample
            self.env[v] = 0
            self.hidden_env[v] = 0
            # Decoding is held off until the last three samples of the delay.
            self.kon_delay[v] -= 1
            self.interp_pos[v] = 0x4000 if (self.kon_delay[v] & 3) else 0
            self.t_pitch = 0

        output = self._interpolate(v)
        if self.t_non & vbit:
            output = <int32_t><int16_t>(<uint16_t>(<int>self.noise * 2))
        self.t_output = ((output * self.env[v]) >> 11) & ~1
        self.voice_out[v] = <int16_t>self.t_output
        self.envx_out[v] = <uint8_t>(self.env[v] >> 4)

        # A block that ends without looping, or a soft reset, silences at once.
        if (self.reg[0x6C] & 0x80) or (self.t_brr_header & 3) == 1:
            self.env_mode[v] = ENV_RELEASE
            self.env[v] = 0

        if self.every_other:
            if self.t_koff & vbit:
                self.env_mode[v] = ENV_RELEASE
            if self.kon & vbit:
                self.kon_delay[v] = 5
                self.env_mode[v] = ENV_ATTACK
                self.kon_count[v] += 1

        if not self.kon_delay[v]:
            self._run_envelope(v)

    cdef inline void _voice_output(self, int v, int ch) noexcept:
        cdef int32_t amp
        if self.solo >= 0 and v != self.solo:
            return
        amp = (self.t_output * <int32_t><signed char>self.reg[v * 16 + ch]) >> 7
        self.t_main_out[ch] = _clamp16(self.t_main_out[ch] + amp)
        if self.t_eon & (1 << v):
            self.t_echo_out[ch] = _clamp16(self.t_echo_out[ch] + amp)

    cdef void _v4(self, int v) noexcept:
        self.t_looped = 0
        if self.interp_pos[v] >= 0x4000:
            self._decode_brr(v)
            self.brr_offset[v] += 2
            if self.brr_offset[v] >= 9:
                self.brr_addr[v] = <uint16_t>(self.brr_addr[v] + 9)
                if self.t_brr_header & 1:
                    self.brr_addr[v] = self.t_brr_next_addr
                    self.t_looped = <uint8_t>(1 << v)
                self.brr_offset[v] = 1

        self.interp_pos[v] = (self.interp_pos[v] & 0x3FFF) + self.t_pitch
        if self.interp_pos[v] > 0x7FFF:
            self.interp_pos[v] = 0x7FFF
        self._voice_output(v, 0)

    cdef inline void _v5(self, int v) noexcept:
        cdef int endx
        self._voice_output(v, 1)
        # ENDX, OUTX and ENVX do not take a write made one or two steps before
        # the pipeline writes them, which is what these buffers are for.
        endx = self.reg[0x7C] | self.t_looped
        if self.kon_delay[v] == 5:
            endx &= ~(1 << v)
        self.endx_buf = <uint8_t>endx

    cdef inline void _v6(self, int v) noexcept:
        self.outx_buf = <uint8_t>((self.t_output >> 8) & 0xFF)

    cdef inline void _v7(self, int v) noexcept:
        self.reg[0x7C] = self.endx_buf
        self.envx_buf = self.envx_out[v]

    cdef inline void _v8(self, int v) noexcept:
        self.reg[v * 16 + 9] = self.outx_buf

    cdef inline void _v9(self, int v) noexcept:
        self.reg[v * 16 + 8] = self.envx_buf

    cdef inline void _v3(self, int v) noexcept:
        self._v3a(v)
        self._v3b(v)
        self._v3c(v)

    # -- the echo steps -----------------------------------------------------

    cdef inline int32_t _echo_read(self, int ch) noexcept:
        cdef uint16_t a = <uint16_t>(self.t_echo_ptr + ch * 2)
        return <int32_t><int16_t>(<uint16_t>(self.apu.ram[a]
                                             | (<uint16_t>self.apu.ram[<uint16_t>(a + 1)] << 8))) >> 1

    cdef inline int32_t _fir(self, int i, int ch) noexcept:
        cdef int j = self.echo_hist_pos + i + 1
        cdef int32_t s = self.echo_hist_l[j] if ch == 0 else self.echo_hist_r[j]
        return (s * <int32_t><signed char>self.reg[(i << 4) + 0x0F]) >> 6

    cdef void _echo_22(self) noexcept:
        self.echo_hist_pos += 1
        if self.echo_hist_pos >= ECHO_HIST:
            self.echo_hist_pos = 0
        self.t_echo_ptr = <uint16_t>((<int>self.echo_esa << 8) + self.echo_offset)
        self.echo_hist_l[self.echo_hist_pos] = self._echo_read(0)
        self.echo_hist_l[self.echo_hist_pos + ECHO_HIST] = self.echo_hist_l[self.echo_hist_pos]
        self.t_echo_in[0] = self._fir(0, 0)
        self.t_echo_in[1] = self._fir(0, 1)

    cdef void _echo_23(self) noexcept:
        self.t_echo_in[0] += self._fir(1, 0) + self._fir(2, 0)
        self.t_echo_in[1] += self._fir(1, 1) + self._fir(2, 1)
        self.echo_hist_r[self.echo_hist_pos] = self._echo_read(1)
        self.echo_hist_r[self.echo_hist_pos + ECHO_HIST] = self.echo_hist_r[self.echo_hist_pos]

    cdef void _echo_24(self) noexcept:
        self.t_echo_in[0] += self._fir(3, 0) + self._fir(4, 0) + self._fir(5, 0)
        self.t_echo_in[1] += self._fir(3, 1) + self._fir(4, 1) + self._fir(5, 1)

    cdef void _echo_25(self) noexcept:
        cdef int32_t l = self.t_echo_in[0] + self._fir(6, 0)
        cdef int32_t r = self.t_echo_in[1] + self._fir(6, 1)
        l = <int32_t><int16_t>l
        r = <int32_t><int16_t>r
        l += <int32_t><int16_t>self._fir(7, 0)
        r += <int32_t><int16_t>self._fir(7, 1)
        self.t_echo_in[0] = _clamp16(l) & ~1
        self.t_echo_in[1] = _clamp16(r) & ~1

    cdef inline int32_t _echo_output(self, int ch) noexcept:
        cdef int32_t out = <int32_t><int16_t>(
            (self.t_main_out[ch] * <int32_t><signed char>self.reg[0x0C + ch * 0x10]) >> 7)
        if self.echo_enabled:
            out += <int32_t><int16_t>(
                (self.t_echo_in[ch] * <int32_t><signed char>self.reg[0x2C + ch * 0x10]) >> 7)
        return _clamp16(out)

    cdef void _echo_26(self) noexcept:
        cdef int32_t l, r
        self.t_main_out[0] = self._echo_output(0)
        l = self.t_echo_out[0] + <int32_t><int16_t>(
            (self.t_echo_in[0] * <int32_t><signed char>self.reg[0x0D]) >> 7)
        r = self.t_echo_out[1] + <int32_t><int16_t>(
            (self.t_echo_in[1] * <int32_t><signed char>self.reg[0x0D]) >> 7)
        self.t_echo_out[0] = _clamp16(l) & ~1
        self.t_echo_out[1] = _clamp16(r) & ~1

    cdef void _echo_27(self) noexcept:
        cdef int32_t l = self.t_main_out[0]
        cdef int32_t r = self._echo_output(1)
        self.t_main_out[0] = 0
        self.t_main_out[1] = 0
        if self.reg[0x6C] & 0x40:                # mute
            l = 0
            r = 0
        self.last_l = <int16_t>l
        self.last_r = <int16_t>r
        if self.out_count < OUT_SAMPLES:
            self.out_buf[self.out_write * 2] = <int16_t>l
            self.out_buf[self.out_write * 2 + 1] = <int16_t>r
            self.out_write = (self.out_write + 1) % OUT_SAMPLES
            self.out_count += 1

    cdef void _echo_28(self) noexcept:
        self.echo_flg = self.reg[0x6C]

    cdef inline void _echo_write(self, int ch) noexcept:
        cdef uint16_t a
        if not (self.echo_flg & 0x20):
            a = <uint16_t>(self.t_echo_ptr + ch * 2)
            self.apu.ram[a] = <uint8_t>(self.t_echo_out[ch] & 0xFF)
            self.apu.ram[<uint16_t>(a + 1)] = <uint8_t>((self.t_echo_out[ch] >> 8) & 0xFF)
        self.t_echo_out[ch] = 0

    cdef void _echo_29(self) noexcept:
        # Where the buffer is, and how long, are settled here -- after this
        # sample has already read and written through the pointer built at step
        # 22.  A program that moves the buffer sees the move next sample, and
        # one that shortens it sees that only when the pass comes round again.
        self.echo_esa = self.reg[0x6D]
        if self.echo_offset == 0:
            self.echo_length = (<int>(self.reg[0x7D] & 0x0F)) * 0x800
        self.echo_offset += 4
        if self.echo_offset >= self.echo_length:
            self.echo_offset = 0
        self._echo_write(0)
        self.echo_flg = self.reg[0x6C]

    cdef void _echo_30(self) noexcept:
        self._echo_write(1)

    # -- the steps that belong to no voice ----------------------------------

    cdef void _misc_27(self) noexcept:
        self.t_pmon = self.reg[0x2D] & 0xFE      # voice 0 has nothing before it

    cdef void _misc_28(self) noexcept:
        self.t_non = self.reg[0x3D]
        self.t_eon = self.reg[0x4D]
        self.t_dir = self.reg[0x5D]

    cdef void _misc_29(self) noexcept:
        self.every_other ^= 1
        if self.every_other:
            self.new_kon &= ~self.kon

    cdef void _misc_30(self) noexcept:
        cdef int fb
        if self.every_other:
            self.kon = self.new_kon
            self.t_koff = self.reg[0x5C]
        self.counter -= 1
        if self.counter < 0:
            self.counter = 0x77FF
        if self._counter_poll(self.reg[0x6C] & 0x1F):
            fb = ((<int>self.noise << 13) ^ (<int>self.noise << 14)) & 0x4000
            self.noise = <int16_t>(fb ^ ((<int>self.noise >> 1) & 0x3FFF))

    # -- one step -----------------------------------------------------------

    cdef void tick(self) noexcept:
        """One of the chip's 32 steps.  Which voices are doing what on each is
        the table the hardware runs; the shape of it is why a voice's output
        appears several steps after its envelope was decided."""
        cdef int p = self.phase
        self.phase = (p + 1) & 31

        if p == 0:
            self._v5(0); self._v2(1)
        elif p == 1:
            self._v6(0); self._v3(1)
        elif p == 2:
            self._v7(0); self._v1(3); self._v4(1)
        elif p == 3:
            self._v8(0); self._v5(1); self._v2(2)
        elif p == 4:
            self._v9(0); self._v6(1); self._v3(2)
        elif p == 5:
            self._v7(1); self._v1(4); self._v4(2)
        elif p == 6:
            self._v8(1); self._v5(2); self._v2(3)
        elif p == 7:
            self._v9(1); self._v6(2); self._v3(3)
        elif p == 8:
            self._v7(2); self._v1(5); self._v4(3)
        elif p == 9:
            self._v8(2); self._v5(3); self._v2(4)
        elif p == 10:
            self._v9(2); self._v6(3); self._v3(4)
        elif p == 11:
            self._v7(3); self._v1(6); self._v4(4)
        elif p == 12:
            self._v8(3); self._v5(4); self._v2(5)
        elif p == 13:
            self._v9(3); self._v6(4); self._v3(5)
        elif p == 14:
            self._v7(4); self._v1(7); self._v4(5)
        elif p == 15:
            self._v8(4); self._v5(5); self._v2(6)
        elif p == 16:
            self._v9(4); self._v6(5); self._v3(6)
        elif p == 17:
            self._v7(5); self._v1(0); self._v4(6)
        elif p == 18:
            self._v8(5); self._v5(6); self._v2(7)
        elif p == 19:
            self._v9(5); self._v6(6); self._v3(7)
        elif p == 20:
            self._v7(6); self._v1(1); self._v4(7)
        elif p == 21:
            self._v8(6); self._v5(7); self._v2(0)
        elif p == 22:
            self._v3a(0); self._v9(6); self._v6(7); self._echo_22()
        elif p == 23:
            self._v7(7); self._echo_23()
        elif p == 24:
            self._v8(7); self._echo_24()
        elif p == 25:
            self._v3b(0); self._v9(7); self._echo_25()
        elif p == 26:
            self._echo_26()
        elif p == 27:
            self._misc_27(); self._echo_27()
        elif p == 28:
            self._misc_28(); self._echo_28()
        elif p == 29:
            self._misc_29(); self._echo_29()
        elif p == 30:
            self._misc_30(); self._v3c(0); self._echo_30()
        else:
            self._v4(0); self._v1(2)

    def set_solo(self, int v):
        self.solo = v

    def set_echo(self, int on):
        self.echo_enabled = on

    def kon_counts(self):
        return [self.kon_count[i] for i in range(8)]

    def reset_kon_counts(self):
        cdef int i
        for i in range(8):
            self.kon_count[i] = 0



    # -- save state (generated by tools/gen_state.py; do not edit) --------

    def state_ints(self):
        cdef int i, j
        v = [self.counter, self.noise, self.echo_offset, self.echo_length, self.echo_esa, self.echo_flg, self.echo_hist_pos, self.last_l, self.last_r, self.phase, self.every_other, self.kon, self.new_kon, self.t_koff, self.t_pmon, self.t_non, self.t_eon, self.t_dir, self.t_dir_addr, self.t_brr_next_addr, self.t_echo_ptr, self.t_srcn, self.t_adsr0, self.t_brr_byte, self.t_brr_header, self.t_looped, self.t_pitch, self.t_output, self.endx_buf, self.outx_buf, self.envx_buf]
        for i in range(8):
            v.append(self.brr_addr[i])
        for i in range(8):
            v.append(self.brr_offset[i])
        for i in range(8):
            v.append(self.buf_pos[i])
        for i in range(8):
            v.append(self.interp_pos[i])
        for i in range(8):
            v.append(self.env[i])
        for i in range(8):
            v.append(self.hidden_env[i])
        for i in range(8):
            v.append(self.env_mode[i])
        for i in range(8):
            v.append(self.kon_delay[i])
        for i in range(8):
            v.append(self.envx_out[i])
        for i in range(8):
            v.append(self.voice_out[i])
        for i in range(16):
            v.append(self.echo_hist_l[i])
        for i in range(16):
            v.append(self.echo_hist_r[i])
        for i in range(2):
            v.append(self.t_main_out[i])
        for i in range(2):
            v.append(self.t_echo_out[i])
        for i in range(2):
            v.append(self.t_echo_in[i])
        for i in range(8):
            for j in range(24):
                v.append(self.buf[i][j])
        return v

    def load_ints(self, v):
        cdef int i, j, k = 31
        self.counter = v[0]
        self.noise = v[1]
        self.echo_offset = v[2]
        self.echo_length = v[3]
        self.echo_esa = v[4]
        self.echo_flg = v[5]
        self.echo_hist_pos = v[6]
        self.last_l = v[7]
        self.last_r = v[8]
        self.phase = v[9]
        self.every_other = v[10]
        self.kon = v[11]
        self.new_kon = v[12]
        self.t_koff = v[13]
        self.t_pmon = v[14]
        self.t_non = v[15]
        self.t_eon = v[16]
        self.t_dir = v[17]
        self.t_dir_addr = v[18]
        self.t_brr_next_addr = v[19]
        self.t_echo_ptr = v[20]
        self.t_srcn = v[21]
        self.t_adsr0 = v[22]
        self.t_brr_byte = v[23]
        self.t_brr_header = v[24]
        self.t_looped = v[25]
        self.t_pitch = v[26]
        self.t_output = v[27]
        self.endx_buf = v[28]
        self.outx_buf = v[29]
        self.envx_buf = v[30]
        for i in range(8):
            self.brr_addr[i] = v[k + i]
        k += 8
        for i in range(8):
            self.brr_offset[i] = v[k + i]
        k += 8
        for i in range(8):
            self.buf_pos[i] = v[k + i]
        k += 8
        for i in range(8):
            self.interp_pos[i] = v[k + i]
        k += 8
        for i in range(8):
            self.env[i] = v[k + i]
        k += 8
        for i in range(8):
            self.hidden_env[i] = v[k + i]
        k += 8
        for i in range(8):
            self.env_mode[i] = v[k + i]
        k += 8
        for i in range(8):
            self.kon_delay[i] = v[k + i]
        k += 8
        for i in range(8):
            self.envx_out[i] = v[k + i]
        k += 8
        for i in range(8):
            self.voice_out[i] = v[k + i]
        k += 8
        for i in range(16):
            self.echo_hist_l[i] = v[k + i]
        k += 16
        for i in range(16):
            self.echo_hist_r[i] = v[k + i]
        k += 16
        for i in range(2):
            self.t_main_out[i] = v[k + i]
        k += 2
        for i in range(2):
            self.t_echo_out[i] = v[k + i]
        k += 2
        for i in range(2):
            self.t_echo_in[i] = v[k + i]
        k += 2
        for i in range(8):
            for j in range(24):
                self.buf[i][j] = v[k + i * 24 + j]
        k += 192

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
                     addr=self.brr_addr[v], offset=self.brr_offset[v],
                     kon_delay=self.kon_delay[v], interp=self.interp_pos[v],
                     buf_pos=self.buf_pos[v],
                     buf=[self.buf[v][i] for i in range(4)],
                     t_output=self.t_output, outx_buf=self.outx_buf,
                     phase=self.phase) for v in range(8)]


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
        self.cycle_target = 0
        self.master_prev = 0
        self.frac = 0
        self.master_hz = MASTER_HZ
        self.dsp_counter = DSP_DIV
        self.extra_cycles = 0
        self.idle_tail = 0
        self.log_on = 0
        self.log_n = 0
        self.stopped = 0
        self.dsp_addr = 0
        self.aux4 = 0
        self.aux5 = 0
        self.dsp.reset()

    # =====================================================================
    # clocking
    # =====================================================================

    cdef void run_until(self, int64_t master_clock) noexcept:
        """Catch the SPC700 up with the S-CPU's position on the master clock.

        The target is absolute rather than relative to self.clock.  An
        instruction runs 2-12 cycles, so the loop always overshoots slightly;
        rebasing on the overshot clock each call let that error accumulate,
        which ran the APU 5% fast -- audibly wrong pitch and tempo, since this
        is called once per scanline.  Carrying an absolute target lets the
        next call simply wait for the overshoot to be paid off."""
        cdef int64_t delta = master_clock - self.master_prev
        if delta <= 0:
            return
        self.master_prev = master_clock
        self.frac += delta * APU_HZ
        self.cycle_target += self.frac // self.master_hz
        self.frac %= self.master_hz
        while self.clock < self.cycle_target:
            if self.stopped:
                self.tick(<int>(self.cycle_target - self.clock))
                self.clock = self.cycle_target
                return
            self.step()

    cdef void tick(self, int cycles) noexcept:
        cdef int i
        cdef int32_t period
        cdef uint8_t target

        # The DSP is clocked at the SPC700's rate and takes 32 of those to
        # produce a sample, so one step per cycle is the hardware's own
        # arrangement rather than a subdivision of ours.
        for i in range(cycles):
            self.dsp.tick()

        # Three stages, and only the last two belong to the timer.  Stage one
        # is a scaler off the SPC700's own clock -- 128 for the first two
        # timers, 16 for the third -- and it free-runs whether or not the
        # timer is enabled, which is what makes the first tick after an enable
        # land wherever the scaler happened to be rather than a whole period
        # later.  Stages two and three are the divisor and the four-bit output
        # counter, and those are the ones an enable resets.
        for i in range(3):
            period = 128 if i < 2 else 16
            self.timer_stage[i] += cycles
            while self.timer_stage[i] >= period:
                self.timer_stage[i] -= period
                if not self.timer_enabled[i]:
                    continue
                self.timer_div[i] += 1
                target = self.timer_target[i]      # 0 behaves as 256
                if self.timer_div[i] == target:
                    self.timer_div[i] = 0
                    self.timer_counter[i] = (self.timer_counter[i] + 1) & 0x0F

    cdef inline void cycle(self, int n) noexcept:
        """Advance the SPC700's own clock, and everything clocked off it."""
        self.clock += n
        self.tick(n)

    cdef inline void _log(self, int kind, uint16_t addr) noexcept:
        if self.log_on and self.log_n < 32:
            self.log_kind[self.log_n] = <uint8_t>kind
            self.log_addr[self.log_n] = addr
            self.log_n += 1

    cdef inline void idle(self) noexcept:
        """A cycle the processor spends on itself, touching no memory."""
        self._log(0, 0)
        self.cycle(1)

    cdef inline void idles(self, int n) noexcept:
        cdef int i
        for i in range(n):
            self.idle()

    cdef inline void store_abs(self, uint16_t addr, uint8_t value) noexcept:
        """A store: the destination is read first, and the byte discarded."""
        self.read(addr)
        self.write(addr, value)

    cdef inline void store_dp(self, uint8_t offset, uint8_t value) noexcept:
        cdef uint16_t addr = self.dp(offset)
        self.read(addr)
        self.write(addr, value)

    cdef void step(self) noexcept:
        """One instruction, with each access charged where it happens.

        The SPC700 spends one cycle per bus access, so fetch, read and write
        each move the clock as they go.  What is left over is the opcode's
        internal work, and it is paid at the end.  That is not where hardware
        always puts an idle cycle, but it is much closer than charging the
        whole instruction after it has finished -- which is what this did, and
        which makes a read of a timer or a port see the state from before the
        instruction started no matter which cycle the read was on.

        The per-opcode totals are unchanged: whatever the accesses did not
        spend is spent here, so an instruction still takes exactly what the
        cycle table says.  test_apu_timing asserts that for all 256.
        """
        cdef int64_t start = self.clock
        cdef uint8_t op
        cdef int total, spent, _pad
        self.log_n = 0
        self.extra_cycles = 0
        op = self.fetch()
        if DUMMY_PC[op]:
            self.read(self.pc)
        self.execute(op)
        total = CYCLES[op] + self.extra_cycles
        spent = <int>(self.clock - start)
        # What is left is the opcode's internal work that has not been placed
        # yet.  Recording it is how the remaining work is measured: an opcode
        # whose tail is zero has every one of its cycles accounted for where
        # it belongs, and one with a tail still has that many to place.
        self.idle_tail = total - spent
        if spent < total:
            for _pad in range(total - spent):
                self.idle()

    # =====================================================================
    # SPC700 address space
    # =====================================================================

    cdef uint8_t read(self, uint16_t addr) noexcept:
        cdef int i
        cdef uint8_t val
        # An access takes a cycle, and it happens at the end of it, so the
        # clock moves first: a read of a timer or a port must see the state
        # as of the cycle it lands on, not as of the start of the instruction.
        self._log(1, addr)
        self.cycle(1)
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
            # $F0 and $F1 are write-only, and so are the three timer targets:
            # they read back zero rather than what was written.  The value is
            # kept in RAM underneath, which is what a write to any of these
            # addresses also updates, but nothing can see it through here.
            if i == 8:
                return self.aux4
            if i == 9:
                return self.aux5
            # $F0, $F1 and the three timer targets are write-only: they read
            # back zero rather than what was written.  Every address in this
            # page is a register -- none of it reads the RAM underneath, which
            # is what makes it possible to tell the page from memory.
            return 0
        if addr >= 0xFFC0 and self.ipl_enabled:
            return self.ipl[addr - 0xFFC0]
        return self.ram[addr]

    cdef void write(self, uint16_t addr, uint8_t value) noexcept:
        cdef int i, t
        self._log(2, addr)
        self.cycle(1)
        if 0x00F0 <= addr <= 0x00FF:
            i = addr - 0x00F0
            # The write reaches the RAM under the register page as well as the
            # register.  Nothing can read it back through here, but the DSP
            # fetches its samples straight out of that RAM and would see it.
            self.ram[addr] = value
            if i == 1:                            # $F1 CONTROL
                for t in range(3):
                    if (value >> t) & 1:
                        # Only the 0 -> 1 transition resets anything, and it
                        # resets the divisor and the output counter but not
                        # the scaler feeding them.  Writing a bit that is
                        # already set does nothing at all, and writing zero
                        # stops the timer without clearing what it had
                        # counted, so a program can stop it and read the
                        # count afterwards.
                        if not self.timer_enabled[t]:
                            self.timer_div[t] = 0
                            self.timer_counter[t] = 0
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
                return
            if i == 8:
                self.aux4 = value
            elif i == 9:
                self.aux5 = value
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
            # Two cycles to take it, and they are spent before the jump, not
            # added to a bill at the end.  extra_cycles still carries them so
            # the instruction's budget knows it is a four-cycle branch.
            self.idle()
            self.idle()
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
            v = self.fetch()
            self.idle()
            self.a = self.alu_or(self.a, self.read(self.dp(<uint8_t>(v + self.x))))
        elif op == 0x05:
            self.a = self.alu_or(self.a, self.read(self.fetch16()))
        elif op == 0x15:
            addr = self.fetch16()
            self.idle()
            self.a = self.alu_or(self.a, self.read(<uint16_t>(addr + self.x)))
        elif op == 0x16:
            addr = self.fetch16()
            self.idle()
            self.a = self.alu_or(self.a, self.read(<uint16_t>(addr + self.y)))
        elif op == 0x06:
            self.a = self.alu_or(self.a, self.read(self.dp(self.x)))
        elif op == 0x07:
            v = self.fetch()
            self.idle()
            v = <uint8_t>(v + self.x)
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.a = self.alu_or(self.a, self.read(addr))
        elif op == 0x17:
            v = self.fetch()
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.idle()
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
            v = self.fetch()
            self.idle()
            self.a = self.alu_and(self.a, self.read(self.dp(<uint8_t>(v + self.x))))
        elif op == 0x25:
            self.a = self.alu_and(self.a, self.read(self.fetch16()))
        elif op == 0x35:
            addr = self.fetch16()
            self.idle()
            self.a = self.alu_and(self.a, self.read(<uint16_t>(addr + self.x)))
        elif op == 0x36:
            addr = self.fetch16()
            self.idle()
            self.a = self.alu_and(self.a, self.read(<uint16_t>(addr + self.y)))
        elif op == 0x26:
            self.a = self.alu_and(self.a, self.read(self.dp(self.x)))
        elif op == 0x27:
            v = self.fetch()
            self.idle()
            v = <uint8_t>(v + self.x)
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.a = self.alu_and(self.a, self.read(addr))
        elif op == 0x37:
            v = self.fetch()
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.idle()
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
            v = self.fetch()
            self.idle()
            self.a = self.alu_eor(self.a, self.read(self.dp(<uint8_t>(v + self.x))))
        elif op == 0x45:
            self.a = self.alu_eor(self.a, self.read(self.fetch16()))
        elif op == 0x55:
            addr = self.fetch16()
            self.idle()
            self.a = self.alu_eor(self.a, self.read(<uint16_t>(addr + self.x)))
        elif op == 0x56:
            addr = self.fetch16()
            self.idle()
            self.a = self.alu_eor(self.a, self.read(<uint16_t>(addr + self.y)))
        elif op == 0x46:
            self.a = self.alu_eor(self.a, self.read(self.dp(self.x)))
        elif op == 0x47:
            v = self.fetch()
            self.idle()
            v = <uint8_t>(v + self.x)
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.a = self.alu_eor(self.a, self.read(addr))
        elif op == 0x57:
            v = self.fetch()
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.idle()
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
            v = self.fetch()
            self.idle()
            self.alu_cmp(self.a, self.read(self.dp(<uint8_t>(v + self.x))))
        elif op == 0x65:
            self.alu_cmp(self.a, self.read(self.fetch16()))
        elif op == 0x75:
            addr = self.fetch16()
            self.idle()
            self.alu_cmp(self.a, self.read(<uint16_t>(addr + self.x)))
        elif op == 0x76:
            addr = self.fetch16()
            self.idle()
            self.alu_cmp(self.a, self.read(<uint16_t>(addr + self.y)))
        elif op == 0x66:
            self.alu_cmp(self.a, self.read(self.dp(self.x)))
        elif op == 0x67:
            v = self.fetch()
            self.idle()
            v = <uint8_t>(v + self.x)
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.alu_cmp(self.a, self.read(addr))
        elif op == 0x77:
            v = self.fetch()
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.idle()
            self.alu_cmp(self.a, self.read(<uint16_t>(addr + self.y)))
        elif op == 0x69:                                    # CMP dd, ds
            v = self.read(self.dp(self.fetch()))
            self.alu_cmp(self.read(self.dp(self.fetch())), v)
            self.idle()
        elif op == 0x78:                                    # CMP d, #i
            v = self.fetch()
            self.alu_cmp(self.read(self.dp(self.fetch())), v)
            self.idle()
        elif op == 0x79:                                    # CMP (X), (Y)
            v = self.read(self.dp(self.y))
            self.alu_cmp(self.read(self.dp(self.x)), v)
            self.idle()

        # ---- ADC ---------------------------------------------------------------
        elif op == 0x88:
            self.a = self.alu_adc(self.a, self.fetch())
        elif op == 0x84:
            self.a = self.alu_adc(self.a, self.read(self.dp(self.fetch())))
        elif op == 0x94:
            v = self.fetch()
            self.idle()
            self.a = self.alu_adc(self.a, self.read(self.dp(<uint8_t>(v + self.x))))
        elif op == 0x85:
            self.a = self.alu_adc(self.a, self.read(self.fetch16()))
        elif op == 0x95:
            addr = self.fetch16()
            self.idle()
            self.a = self.alu_adc(self.a, self.read(<uint16_t>(addr + self.x)))
        elif op == 0x96:
            addr = self.fetch16()
            self.idle()
            self.a = self.alu_adc(self.a, self.read(<uint16_t>(addr + self.y)))
        elif op == 0x86:
            self.a = self.alu_adc(self.a, self.read(self.dp(self.x)))
        elif op == 0x87:
            v = self.fetch()
            self.idle()
            v = <uint8_t>(v + self.x)
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.a = self.alu_adc(self.a, self.read(addr))
        elif op == 0x97:
            v = self.fetch()
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.idle()
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
            v = self.fetch()
            self.idle()
            self.a = self.alu_sbc(self.a, self.read(self.dp(<uint8_t>(v + self.x))))
        elif op == 0xA5:
            self.a = self.alu_sbc(self.a, self.read(self.fetch16()))
        elif op == 0xB5:
            addr = self.fetch16()
            self.idle()
            self.a = self.alu_sbc(self.a, self.read(<uint16_t>(addr + self.x)))
        elif op == 0xB6:
            addr = self.fetch16()
            self.idle()
            self.a = self.alu_sbc(self.a, self.read(<uint16_t>(addr + self.y)))
        elif op == 0xA6:
            self.a = self.alu_sbc(self.a, self.read(self.dp(self.x)))
        elif op == 0xA7:
            v = self.fetch()
            self.idle()
            v = <uint8_t>(v + self.x)
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.a = self.alu_sbc(self.a, self.read(addr))
        elif op == 0xB7:
            v = self.fetch()
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.idle()
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
            v = self.fetch()
            self.idle()
            self.a = self.read(self.dp(<uint8_t>(v + self.x))); self.nz8(self.a)
        elif op == 0xE5:
            self.a = self.read(self.fetch16()); self.nz8(self.a)
        elif op == 0xF5:
            addr = self.fetch16()
            self.idle()
            self.a = self.read(<uint16_t>(addr + self.x)); self.nz8(self.a)
        elif op == 0xF6:
            addr = self.fetch16()
            self.idle()
            self.a = self.read(<uint16_t>(addr + self.y)); self.nz8(self.a)
        elif op == 0xE6:
            self.a = self.read(self.dp(self.x)); self.nz8(self.a)
        elif op == 0xBF:                                    # MOV A, (X)+
            self.a = self.read(self.dp(self.x))
            self.idle()
            self.x = <uint8_t>(self.x + 1)
            self.nz8(self.a)
        elif op == 0xE7:
            v = self.fetch()
            self.idle()
            v = <uint8_t>(v + self.x)
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.a = self.read(addr); self.nz8(self.a)
        elif op == 0xF7:
            v = self.fetch()
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.idle()
            self.a = self.read(<uint16_t>(addr + self.y)); self.nz8(self.a)
        elif op == 0xCD:
            self.x = self.fetch(); self.nz8(self.x)
        elif op == 0xF8:
            self.x = self.read(self.dp(self.fetch())); self.nz8(self.x)
        elif op == 0xF9:
            v = self.fetch()
            self.idle()
            self.x = self.read(self.dp(<uint8_t>(v + self.y))); self.nz8(self.x)
        elif op == 0xE9:
            self.x = self.read(self.fetch16()); self.nz8(self.x)
        elif op == 0x8D:
            self.y = self.fetch(); self.nz8(self.y)
        elif op == 0xEB:
            self.y = self.read(self.dp(self.fetch())); self.nz8(self.y)
        elif op == 0xFB:
            v = self.fetch()
            self.idle()
            self.y = self.read(self.dp(<uint8_t>(v + self.x))); self.nz8(self.y)
        elif op == 0xEC:
            self.y = self.read(self.fetch16()); self.nz8(self.y)

        # ---- MOV out of A / X / Y ------------------------------------------------------
        # A store reads its destination first and throws the byte away.  The
        # cycle was always charged; what was missing is that it is a real bus
        # access, which is the whole of what mem_access_times is looking at.
        # The two indirect-increment forms are the documented exceptions: one
        # spends the cycle idle instead.
        elif op == 0xC4:
            self.store_dp(self.fetch(), self.a)
        elif op == 0xD4:
            v = self.fetch()
            self.idle()
            self.store_dp(<uint8_t>(v + self.x), self.a)
        elif op == 0xC5:
            self.store_abs(self.fetch16(), self.a)
        elif op == 0xD5:
            addr = self.fetch16()
            self.idle()
            self.store_abs(<uint16_t>(addr + self.x), self.a)
        elif op == 0xD6:
            addr = self.fetch16()
            self.idle()
            self.store_abs(<uint16_t>(addr + self.y), self.a)
        elif op == 0xC6:
            self.store_dp(self.x, self.a)
        elif op == 0xAF:                                    # MOV (X)+, A
            self.idle()                                     # not a dummy read
            self.write(self.dp(self.x), self.a)
            self.x = <uint8_t>(self.x + 1)
        elif op == 0xC7:
            v = <uint8_t>(self.fetch() + self.x)
            self.idle()
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.store_abs(addr, self.a)
        elif op == 0xD7:
            v = self.fetch()
            addr = self.read(self.dp(v)) | (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8)
            self.idle()
            self.store_abs(<uint16_t>(addr + self.y), self.a)
        elif op == 0xD8:
            self.store_dp(self.fetch(), self.x)
        elif op == 0xD9:
            v = self.fetch()
            self.idle()
            self.store_dp(<uint8_t>(v + self.y), self.x)
        elif op == 0xC9:
            self.store_abs(self.fetch16(), self.x)
        elif op == 0xCB:
            self.store_dp(self.fetch(), self.y)
        elif op == 0xDB:
            v = self.fetch()
            self.idle()
            self.store_dp(<uint8_t>(v + self.x), self.y)
        elif op == 0xCC:
            self.store_abs(self.fetch16(), self.y)
        elif op == 0x8F:                                    # MOV d, #i
            v = self.fetch()
            self.store_dp(self.fetch(), v)
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
            v = self.fetch()
            self.idle()
            addr = self.dp(<uint8_t>(v + self.x)); self.write(addr, self.alu_inc(self.read(addr)))
        elif op == 0xAC:
            addr = self.fetch16(); self.write(addr, self.alu_inc(self.read(addr)))
        elif op == 0x8B:
            addr = self.dp(self.fetch()); self.write(addr, self.alu_dec(self.read(addr)))
        elif op == 0x9B:
            v = self.fetch()
            self.idle()
            addr = self.dp(<uint8_t>(v + self.x)); self.write(addr, self.alu_dec(self.read(addr)))
        elif op == 0x8C:
            addr = self.fetch16(); self.write(addr, self.alu_dec(self.read(addr)))

        # ---- shifts / rotates -------------------------------------------------------------------
        elif op == 0x1C:
            self.a = self.alu_asl(self.a)
        elif op == 0x0B:
            addr = self.dp(self.fetch()); self.write(addr, self.alu_asl(self.read(addr)))
        elif op == 0x1B:
            v = self.fetch()
            self.idle()
            addr = self.dp(<uint8_t>(v + self.x)); self.write(addr, self.alu_asl(self.read(addr)))
        elif op == 0x0C:
            addr = self.fetch16(); self.write(addr, self.alu_asl(self.read(addr)))
        elif op == 0x5C:
            self.a = self.alu_lsr(self.a)
        elif op == 0x4B:
            addr = self.dp(self.fetch()); self.write(addr, self.alu_lsr(self.read(addr)))
        elif op == 0x5B:
            v = self.fetch()
            self.idle()
            addr = self.dp(<uint8_t>(v + self.x)); self.write(addr, self.alu_lsr(self.read(addr)))
        elif op == 0x4C:
            addr = self.fetch16(); self.write(addr, self.alu_lsr(self.read(addr)))
        elif op == 0x3C:
            self.a = self.alu_rol(self.a)
        elif op == 0x2B:
            addr = self.dp(self.fetch()); self.write(addr, self.alu_rol(self.read(addr)))
        elif op == 0x3B:
            v = self.fetch()
            self.idle()
            addr = self.dp(<uint8_t>(v + self.x)); self.write(addr, self.alu_rol(self.read(addr)))
        elif op == 0x2C:
            addr = self.fetch16(); self.write(addr, self.alu_rol(self.read(addr)))
        elif op == 0x7C:
            self.a = self.alu_ror(self.a)
        elif op == 0x6B:
            addr = self.dp(self.fetch()); self.write(addr, self.alu_ror(self.read(addr)))
        elif op == 0x7B:
            v = self.fetch()
            self.idle()
            addr = self.dp(<uint8_t>(v + self.x)); self.write(addr, self.alu_ror(self.read(addr)))
        elif op == 0x6C:
            addr = self.fetch16(); self.write(addr, self.alu_ror(self.read(addr)))
        elif op == 0x9F:                                    # XCN A
            self.idles(3)
            self.a = <uint8_t>((self.a >> 4) | (self.a << 4))
            self.nz8(self.a)

        # ---- 16-bit ops -----------------------------------------------------------------------------
        elif op == 0xBA:                                    # MOVW YA, d
            v = self.fetch()
            self.a = self.read(self.dp(v))
            self.idle()
            self.y = self.read(self.dp(<uint8_t>(v + 1)))
            self.nz16(<uint16_t>((self.y << 8) | self.a))
        elif op == 0xDA:                                    # MOVW d, YA
            v = self.fetch()
            self.read(self.dp(v))
            self.write(self.dp(v), self.a)
            self.write(self.dp(<uint8_t>(v + 1)), self.y)
        # INCW and DECW work a byte at a time: the low byte is read, adjusted
        # and written back before the high byte is read at all, so the bus
        # sees read, write, read, write -- not both reads and then both
        # writes.  A program watching the address bus can tell the difference,
        # and so can hardware that is being written to through it.
        elif op == 0x3A or op == 0x1A:                      # INCW / DECW d
            v = self.fetch()
            w = <uint16_t>(self.read(self.dp(v)) + (1 if op == 0x3A else -1))
            self.write(self.dp(v), <uint8_t>(w & 0xFF))
            w = <uint16_t>(w + (<uint16_t>self.read(self.dp(<uint8_t>(v + 1))) << 8))
            self.write(self.dp(<uint8_t>(v + 1)), <uint8_t>(w >> 8))
            self.nz16(w)
        elif op == 0x7A:                                    # ADDW YA, d
            v = self.fetch()
            o1 = self.read(self.dp(v))
            self.idle()
            o2 = self.read(self.dp(<uint8_t>(v + 1)))
            self.psw &= ~P_C
            self.a = self.alu_adc(self.a, o1)
            self.y = self.alu_adc(self.y, o2)
            self.setf(P_Z, ((self.y << 8) | self.a) == 0)
        elif op == 0x9A:                                    # SUBW YA, d
            v = self.fetch()
            o1 = self.read(self.dp(v))
            self.idle()
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
            self.idles(7)
            big = <uint32_t>self.y * <uint32_t>self.a
            self.a = <uint8_t>(big & 0xFF)
            self.y = <uint8_t>((big >> 8) & 0xFF)
            self.nz8(self.y)
        elif op == 0x9E:                                    # DIV YA, X
            self.idles(10)
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
            self.idle()
            if (self.psw & P_C) or self.a > 0x99:
                self.a = <uint8_t>(self.a + 0x60)
                self.psw |= P_C
            if (self.psw & P_H) or (self.a & 15) > 9:
                self.a = <uint8_t>(self.a + 0x06)
            self.nz8(self.a)
        elif op == 0xBE:                                    # DAS A
            self.idle()
            if not (self.psw & P_C) or self.a > 0x99:
                self.a = <uint8_t>(self.a - 0x60)
                self.psw &= ~P_C
            if not (self.psw & P_H) or (self.a & 15) > 9:
                self.a = <uint8_t>(self.a - 0x06)
            self.nz8(self.a)

        # ---- stack -------------------------------------------------------------------------------------
        # A push spends its last cycle doing nothing; a pull spends its
        # second cycle that way, before the stack is touched.
        elif op == 0x2D:
            self.push(self.a); self.idle()
        elif op == 0x4D:
            self.push(self.x); self.idle()
        elif op == 0x6D:
            self.push(self.y); self.idle()
        elif op == 0x0D:
            self.push(self.psw); self.idle()
        elif op == 0xAE:
            self.idle(); self.a = self.pull()
        elif op == 0xCE:
            self.idle(); self.x = self.pull()
        elif op == 0xEE:
            self.idle(); self.y = self.pull()
        elif op == 0x8E:
            self.idle(); self.psw = self.pull()

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
            self.idle()
            bit = op >> 5
            self.branch(1 if (v >> bit) & 1 else 0)
        elif (op == 0x13 or op == 0x33 or op == 0x53 or op == 0x73 or
              op == 0x93 or op == 0xB3 or op == 0xD3 or op == 0xF3):   # BBC d.0-7, r
            v = self.read(self.dp(self.fetch()))
            self.idle()
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
            self.idle()
            self.branch(1 if v != self.a else 0)
        elif op == 0xDE:                                    # CBNE d+X, r
            v = self.fetch()
            self.idle()
            v = self.read(self.dp(<uint8_t>(v + self.x)))
            self.idle()
            self.branch(1 if v != self.a else 0)
        elif op == 0x6E:                                    # DBNZ d, r
            addr = self.dp(self.fetch())
            v = <uint8_t>(self.read(addr) - 1)
            self.write(addr, v)
            self.branch(1 if v != 0 else 0)
        elif op == 0xFE:                                    # DBNZ Y, r
            self.idle()
            self.y = <uint8_t>(self.y - 1)
            self.branch(1 if self.y != 0 else 0)

        # ---- jumps / calls ----------------------------------------------------------------------------------
        elif op == 0x5F:                                    # JMP !a
            self.pc = self.fetch16()
        elif op == 0x1F:                                    # JMP [!a+X]
            addr = self.fetch16()
            self.idle()
            addr = <uint16_t>(addr + self.x)
            self.pc = self.read16(addr)
        elif op == 0x3F:                                    # CALL !a
            addr = self.fetch16()
            self.idle()
            self.push(<uint8_t>(self.pc >> 8))
            self.push(<uint8_t>(self.pc & 0xFF))
            self.idles(2)
            self.pc = addr
        elif op == 0x4F:                                    # PCALL u
            v = self.fetch()
            self.idle()
            self.push(<uint8_t>(self.pc >> 8))
            self.push(<uint8_t>(self.pc & 0xFF))
            self.idle()
            self.pc = <uint16_t>(0xFF00 | v)
        elif (op == 0x01 or op == 0x11 or op == 0x21 or op == 0x31 or
              op == 0x41 or op == 0x51 or op == 0x61 or op == 0x71 or
              op == 0x81 or op == 0x91 or op == 0xA1 or op == 0xB1 or
              op == 0xC1 or op == 0xD1 or op == 0xE1 or op == 0xF1):   # TCALL 0-15
            addr = <uint16_t>(0xFFDE - ((op >> 4) << 1))
            self.idle()
            self.push(<uint8_t>(self.pc >> 8))
            self.push(<uint8_t>(self.pc & 0xFF))
            self.idle()
            self.pc = self.read16(addr)
        elif op == 0x6F:                                    # RET
            self.idle()
            self.pc = self.pull()
            self.pc |= <uint16_t>self.pull() << 8
        elif op == 0x7F:                                    # RETI
            self.idle()
            self.psw = self.pull()
            self.pc = self.pull()
            self.pc |= <uint16_t>self.pull() << 8
        elif op == 0x0F:                                    # BRK
            self.push(<uint8_t>(self.pc >> 8))
            self.push(<uint8_t>(self.pc & 0xFF))
            self.push(self.psw)
            self.idle()
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
                self.idle()
                self.setf(P_C, (self.psw & P_C) or v2)
            elif op == 0x2A:                                # OR1 C, /m.b
                self.idle()
                self.setf(P_C, (self.psw & P_C) or (not v2))
            elif op == 0x4A:                                # AND1 C, m.b
                self.setf(P_C, (self.psw & P_C) and v2)
            elif op == 0x6A:                                # AND1 C, /m.b
                self.setf(P_C, (self.psw & P_C) and (not v2))
            elif op == 0x8A:                                # EOR1 C, m.b
                self.idle()
                self.setf(P_C, ((1 if (self.psw & P_C) else 0) ^ v2) != 0)
            elif op == 0xAA:                                # MOV1 C, m.b
                self.setf(P_C, v2)
            elif op == 0xCA:                                # MOV1 m.b, C
                self.idle()
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
            self.read(addr)
            self.write(addr, v | self.a)
        elif op == 0x4E:                                    # TCLR1 !a
            addr = self.fetch16()
            v = self.read(addr)
            self.nz8(<uint8_t>(self.a - v))
            self.read(addr)
            self.write(addr, v & <uint8_t>(~self.a))

        # ---- flag control ---------------------------------------------------------------------------------------
        elif op == 0x60:
            self.psw &= ~P_C
        elif op == 0x80:
            self.psw |= P_C
        elif op == 0xED:
            self.idle()
            self.psw ^= P_C
        elif op == 0xE0:
            self.psw &= ~(P_V | P_H)
        elif op == 0x20:
            self.psw &= ~P_P
        elif op == 0x40:
            self.psw |= P_P
        elif op == 0xA0:
            self.idle()
            self.psw |= P_I
        elif op == 0xC0:
            self.idle()
            self.psw &= ~P_I

        # ---- halt / nop --------------------------------------------------------------------------------------------
        elif op == 0x00:                                    # NOP
            pass
        elif op == 0xEF or op == 0xFF:                      # SLEEP / STOP
            self.idle()
            self.stopped = 1

    # =====================================================================
    # S-CPU side ($2140-$2143)
    # =====================================================================

    cdef uint8_t cpu_read_port(self, int index) noexcept:
        return self.port_out[index & 3]

    cdef void cpu_write_port(self, int index, uint8_t value) noexcept:
        self.port_in[index & 3] = value





    # -- test helpers -------------------------------------------------------

    def poke_ram(self, int addr, data):
        cdef int i
        for i in range(len(data)):
            self.ram[(addr + i) & 0xFFFF] = data[i]

    def dsp_write(self, int addr, int value):
        self.dsp.write_reg(<uint8_t>addr, <uint8_t>value)

    def dsp_step(self, int n):
        """Advance the DSP by n of its steps, for looking inside a sample."""
        cdef int i
        for i in range(n):
            self.dsp.tick()

    def dsp_tick(self, int n):
        """Advance the DSP by n samples -- 32 of its steps each."""
        cdef int i
        for i in range(n * 32):
            self.dsp.tick()

    @staticmethod
    def cycle_table():
        """The per-opcode totals, so a test can check that moving the
        accesses around inside an instruction did not change its length."""
        return [CYCLES[i] for i in range(256)]



    # -- save state (generated by tools/gen_state.py; do not edit) --------

    def state_ints(self):
        cdef int i, j
        v = [self.pc, self.a, self.x, self.y, self.sp, self.psw, self.ipl_enabled, self.clock, self.cycle_target, self.master_prev, self.frac, self.dsp_counter, self.extra_cycles, self.stopped, self.dsp_addr, self.aux4, self.aux5]
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
        cdef int i, j, k = 17
        self.pc = v[0]
        self.a = v[1]
        self.x = v[2]
        self.y = v[3]
        self.sp = v[4]
        self.psw = v[5]
        self.ipl_enabled = v[6]
        self.clock = v[7]
        self.cycle_target = v[8]
        self.master_prev = v[9]
        self.frac = v[10]
        self.dsp_counter = v[11]
        self.extra_cycles = v[12]
        self.stopped = v[13]
        self.dsp_addr = v[14]
        self.aux4 = v[15]
        self.aux5 = v[16]
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
                    stopped=self.stopped, ipl=self.ipl_enabled,
                    extra_cycles=self.extra_cycles, idle_tail=self.idle_tail)

    def access_log(self, int on=-1):
        """The bus cycles of the last instruction, as (kind, address) with
        kind 'i', 'r' or 'w'.  Pass 1 or 0 to turn recording on or off."""
        cdef int i
        if on >= 0:
            self.log_on = on
            return None
        return [('irw'[self.log_kind[i]], self.log_addr[i])
                for i in range(self.log_n)]

    def set_pc(self, int addr):
        """Point the SPC700 at an address, so a test can run one opcode."""
        self.pc = <uint16_t>addr

    @property
    def ram_bytes(self):
        return bytes(bytearray([self.ram[i] for i in range(0x10000)]))

    def do_step(self):
        self.step()

    def do_reset(self):
        self.reset()
