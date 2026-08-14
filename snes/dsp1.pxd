# cython: language_level=3
from libc.stdint cimport uint8_t, uint16_t, uint32_t, int64_t

from snes.board cimport Board
from snes.necdsp cimport NECDSP


cdef class DSP1(Board):
    cdef int hirom                   # map 21: registers at $6000/$7000

    # The processor, once there is a program to put in it.  Without one the
    # board still answers -- it has to, or the console hangs on the status
    # register -- but it answers nothing and counts what it was asked.
    cdef NECDSP core
    cdef int64_t last_clock
    cdef int64_t owed

    # -- the register pair the console talks through ------------------------
    cdef uint8_t sr                  # status: bit 7 says a transfer may happen
    cdef uint8_t command             # the byte that started the exchange
    cdef int have_command

    cdef uint8_t params[32]          # bytes written since the command
    cdef int param_len
    cdef int param_want              # how many this command takes, -1 unknown

    cdef uint8_t result[32]          # bytes the console will read back
    cdef int result_len
    cdef int result_pos

    # -- what the cartridge asked for, for tooling --------------------------
    # The raw access stream: one byte of kind (0 write, 1 read) and one of
    # value, per access.  Which bytes of an exchange are the command, its
    # parameters and its answer cannot be known without the documentation --
    # but the console's own alternation between writing and reading marks
    # the boundaries, so the stream is recorded and read back afterwards
    # rather than interpreted here.
    cdef uint8_t trace_kind[16384]
    cdef uint8_t trace_value[16384]
    cdef int trace_len
    cdef uint32_t unknown_count
    cdef uint32_t uncomputed[256]   # per command, how often its answer was faked
    cdef uint32_t approximated[256] # per command, how often it was answered by guesswork

    # The view the projection commands work in, set by command $02.
    cdef double view_fx, view_fy, view_fz
    cdef double view_lfe, view_les
    cdef double view_aas, view_azs
    cdef double view_vof, view_vva
    cdef int raster_line

    cdef int _p16(self, int i) noexcept
    cdef void _r16(self, int i, int value) noexcept
    cdef void _raster_row(self) noexcept
    cdef void _dispatch(self) noexcept
    cdef void _note(self, uint8_t kind, uint8_t value) noexcept
    cdef int _is_status(self, uint32_t addr) noexcept
