# cython: language_level=3
from libc.stdint cimport uint8_t, uint16_t, uint32_t

from snes.board cimport Board


cdef class DSP1(Board):
    cdef int hirom                   # map 21: registers at $6000/$7000

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

    cdef void _dispatch(self) noexcept
    cdef void _note(self, uint8_t kind, uint8_t value) noexcept
    cdef int _is_status(self, uint32_t addr) noexcept
