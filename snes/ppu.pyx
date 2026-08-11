# cython: language_level=3
"""S-PPU: register file, VRAM/CGRAM/OAM access and the scanline renderer.

This stage implements the complete $2100-$213F register interface and the
memory access semantics (VRAM address remapping, the write-twice latches, the
OAM byte latch, the read prefetch).  Pixel generation is added by the renderer
stage; render_scanline() currently clears the line.
"""

from libc.string cimport memset, memcpy
from cpython.bytes cimport PyBytes_FromStringAndSize
from libc.stdint cimport uint8_t, uint16_t, uint32_t, int16_t, int32_t


cdef enum:
    SCREEN_W = 256
    SCREEN_H = 239


cdef inline uint32_t _remap_vram(uint8_t vmain, uint32_t addr) noexcept:
    """VMAIN bits 2-3 rotate the low address bits so that tile columns can be
    written sequentially."""
    cdef uint32_t mode = vmain & 0x0C
    if mode == 0x00:
        return addr
    if mode == 0x04:
        return (addr & 0xFF00) | ((addr & 0x001F) << 3) | ((addr >> 5) & 7)
    if mode == 0x08:
        return (addr & 0xFE00) | ((addr & 0x003F) << 3) | ((addr >> 6) & 7)
    return (addr & 0xFC00) | ((addr & 0x007F) << 3) | ((addr >> 7) & 7)


cdef inline uint32_t _vram_step(uint8_t vmain) noexcept:
    cdef uint32_t s = vmain & 3
    if s == 0:
        return 1
    if s == 1:
        return 32
    return 128


cdef class PPU:

    def __init__(self):
        # INIDISP brightness is a 4-bit level where 0 is black and 15 is full,
        # so a channel scales by brightness/15 -- not by (brightness+1)/16,
        # which would leave level 0 showing a sixteenth of the colour.
        cdef int level, value
        for level in range(16):
            for value in range(32):
                self.light[level][value] = <uint8_t>((value * level + 7) // 15)
        self.framebuffer_obj = bytearray(SCREEN_W * SCREEN_H * 4)
        self.framebuffer = <uint32_t *><unsigned char *>self.framebuffer_obj
        self.reset()

    cdef void reset(self) noexcept:
        cdef int i
        memset(self.vram, 0, sizeof(self.vram))
        memset(self.cgram, 0, sizeof(self.cgram))
        memset(self.oam, 0, sizeof(self.oam))

        self.brightness = 0
        self.forced_blank = 1
        self.obj_base = 0
        self.obj_gap = 0
        self.obj_size_sel = 0
        self.oam_addr_reload = 0
        self.oam_addr = 0
        self.oam_priority_rotation = 0
        self.oam_latch_active = 0
        self.oam_latch = 0
        self.bg_mode = 0
        self.bg3_priority = 0
        self.mosaic_size = 0
        for i in range(4):
            self.mosaic_enable[i] = 0
            self.bg_map_base[i] = 0
            self.bg_map_wide[i] = 0
            self.bg_map_tall[i] = 0
            self.bg_chr_base[i] = 0
            self.bg_tile_size[i] = 0
            self.bg_hofs[i] = 0
            self.bg_vofs[i] = 0
        self.bgofs_latch = 0
        self.bgofs_latch_h = 0
        self.vmain = 0
        self.vram_addr = 0
        self.vram_prefetch = 0
        self.m7sel = 0
        self.m7a = 0
        self.m7b = 0
        self.m7c = 0
        self.m7d = 0
        self.m7x = 0
        self.m7y = 0
        self.m7hofs = 0
        self.m7vofs = 0
        self.m7_latch = 0
        self.cgram_addr = 0
        self.cgram_flip = 0
        self.cgram_latch = 0
        for i in range(6):
            self.win_enabled[i] = 0
            self.win_inverted[i] = 0
            self.win2_enabled[i] = 0
            self.win2_inverted[i] = 0
            self.win_logic[i] = 0
        self.win1_left = 0
        self.win1_right = 0
        self.win2_left = 0
        self.win2_right = 0
        for i in range(5):
            self.main_enable[i] = 0
            self.sub_enable[i] = 0
            self.main_window[i] = 0
            self.sub_window[i] = 0
        self.cgwsel = 0
        self.cgadsub = 0
        self.fixed_r = 0
        self.fixed_g = 0
        self.fixed_b = 0
        self.overscan = 0
        self.obj_interlace = 0
        self.screen_interlace = 0
        self.pseudo_hires = 0
        self.extbg = 0
        self.hcounter = 0
        self.vcounter = 0
        self.vdisp = 225
        self.field = 0
        self.latched = 0
        self.hcounter_latch = 0
        self.vcounter_latch = 0
        self.hcounter_flip = 0
        self.vcounter_flip = 0
        self.range_over = 0
        self.time_over = 0
        self.ppu1_mdr = 0
        self.ppu2_mdr = 0
        self.dbg_lines = 0
        self.dbg_lines_enabled = 0
        self.dbg_lines_blank = 0
        memset(self.framebuffer, 0, SCREEN_W * SCREEN_H * 4)

    cdef void latch_counters(self) noexcept:
        self.hcounter_latch = <uint16_t>self.hcounter
        self.vcounter_latch = <uint16_t>self.vcounter
        self.latched = 1

    # -------------------------------------------------- access windows ---
    #
    # While a line is being drawn the PPU owns its memories, so the CPU cannot
    # reach them.  Well-behaved software only touches VRAM, CGRAM and OAM
    # during V-blank or forced blank; letting a write through outside those
    # windows hides a bug that real hardware would show.

    cdef inline int _display_active(self) noexcept:
        """True while the PPU is drawing a visible line."""
        if self.forced_blank:
            return 0
        return 1 if (0 < self.vcounter < self.vdisp) else 0

    cdef inline int _cgram_blocked(self) noexcept:
        """CGRAM is reachable in the margins of a visible line, unlike VRAM."""
        if not self._display_active():
            return 0
        return 1 if (22 <= self.hcounter < 274) else 0

    # =====================================================================
    # register writes
    # =====================================================================

    cdef void write_reg(self, uint32_t addr, uint8_t value) noexcept:
        cdef uint32_t reg = addr & 0x3F
        cdef int n
        cdef uint32_t va
        cdef uint8_t latch_bit

        if reg == 0x00:                                   # INIDISP
            if self.forced_blank and not (value & 0x80):
                self.oam_addr = self.oam_addr_reload
                self.oam_latch_active = 0
            self.forced_blank = 1 if (value & 0x80) else 0
            self.brightness = value & 0x0F

        elif reg == 0x01:                                 # OBSEL
            self.obj_base = (<uint32_t>(value & 0x07)) << 13
            self.obj_gap = (<uint32_t>(((value >> 3) & 3) + 1)) << 12
            self.obj_size_sel = (value >> 5) & 7

        elif reg == 0x02:                                 # OAMADDL
            self.oam_addr_reload = (self.oam_addr_reload & 0x200) | (<uint32_t>value << 1)
            self.oam_addr = self.oam_addr_reload
            self.oam_latch_active = 0
        elif reg == 0x03:                                 # OAMADDH
            self.oam_addr_reload = ((<uint32_t>(value & 1)) << 9) | (self.oam_addr_reload & 0x1FE)
            self.oam_priority_rotation = (value >> 7) & 1
            self.oam_addr = self.oam_addr_reload
            self.oam_latch_active = 0

        elif reg == 0x04:                                 # OAMDATA
            # The address still advances, but the byte goes to whatever entry
            # sprite evaluation is holding rather than the one asked for.
            # Without a per-dot evaluator the honest approximation is to drop
            # the write and keep the address moving.
            if self._display_active():
                self.oam_addr = (self.oam_addr + 1) & 0x3FF
                return
            latch_bit = self.oam_addr & 1
            va = self.oam_addr
            self.oam_addr = (self.oam_addr + 1) & 0x3FF
            if latch_bit == 0:
                self.oam_latch = value
            if va & 0x200:
                # The 32-byte high table is written a byte at a time.
                if va < 544:
                    self.oam[va] = value
            elif latch_bit:
                self.oam[(va & 0x3FE) + 0] = self.oam_latch
                self.oam[(va & 0x3FE) + 1] = value

        elif reg == 0x05:                                 # BGMODE
            self.bg_mode = value & 7
            self.bg3_priority = (value >> 3) & 1
            for n in range(4):
                self.bg_tile_size[n] = (value >> (4 + n)) & 1

        elif reg == 0x06:                                 # MOSAIC
            for n in range(4):
                self.mosaic_enable[n] = (value >> n) & 1
            self.mosaic_size = (value >> 4) & 0x0F

        elif 0x07 <= reg <= 0x0A:                         # BGnSC
            n = reg - 0x07
            self.bg_map_base[n] = (<uint32_t>(value & 0x7C)) << 8
            self.bg_map_wide[n] = value & 1
            self.bg_map_tall[n] = (value >> 1) & 1

        elif reg == 0x0B:                                 # BG12NBA
            self.bg_chr_base[0] = (<uint32_t>(value & 0x0F)) << 12
            self.bg_chr_base[1] = (<uint32_t>(value >> 4)) << 12
        elif reg == 0x0C:                                 # BG34NBA
            self.bg_chr_base[2] = (<uint32_t>(value & 0x0F)) << 12
            self.bg_chr_base[3] = (<uint32_t>(value >> 4)) << 12

        elif reg == 0x0D:                                 # BG1HOFS / M7HOFS
            self.m7hofs = <int16_t>_sign13((<uint16_t>value << 8) | self.m7_latch)
            self.m7_latch = value
            self._write_hofs(0, value)
        elif reg == 0x0E:                                 # BG1VOFS / M7VOFS
            self.m7vofs = <int16_t>_sign13((<uint16_t>value << 8) | self.m7_latch)
            self.m7_latch = value
            self._write_vofs(0, value)
        elif reg == 0x0F:
            self._write_hofs(1, value)
        elif reg == 0x10:
            self._write_vofs(1, value)
        elif reg == 0x11:
            self._write_hofs(2, value)
        elif reg == 0x12:
            self._write_vofs(2, value)
        elif reg == 0x13:
            self._write_hofs(3, value)
        elif reg == 0x14:
            self._write_vofs(3, value)

        elif reg == 0x15:                                 # VMAIN
            self.vmain = value
        elif reg == 0x16:                                 # VMADDL
            self.vram_addr = (self.vram_addr & 0x7F00) | value
            self.vram_prefetch = self.vram[_remap_vram(self.vmain, self.vram_addr) & 0x7FFF]
        elif reg == 0x17:                                 # VMADDH
            self.vram_addr = (self.vram_addr & 0x00FF) | ((<uint32_t>value & 0x7F) << 8)
            self.vram_prefetch = self.vram[_remap_vram(self.vmain, self.vram_addr) & 0x7FFF]
        elif reg == 0x18:                                 # VMDATAL
            if self._display_active():
                return
            va = _remap_vram(self.vmain, self.vram_addr) & 0x7FFF
            self.vram[va] = (self.vram[va] & 0xFF00) | value
            if not (self.vmain & 0x80):
                self.vram_addr = (self.vram_addr + _vram_step(self.vmain)) & 0x7FFF
        elif reg == 0x19:                                 # VMDATAH
            if self._display_active():
                return
            va = _remap_vram(self.vmain, self.vram_addr) & 0x7FFF
            self.vram[va] = (self.vram[va] & 0x00FF) | (<uint16_t>value << 8)
            if self.vmain & 0x80:
                self.vram_addr = (self.vram_addr + _vram_step(self.vmain)) & 0x7FFF

        elif reg == 0x1A:                                 # M7SEL
            self.m7sel = value
        elif reg == 0x1B:
            self.m7a = <int16_t>((<uint16_t>value << 8) | self.m7_latch); self.m7_latch = value
        elif reg == 0x1C:
            self.m7b = <int16_t>((<uint16_t>value << 8) | self.m7_latch); self.m7_latch = value
        elif reg == 0x1D:
            self.m7c = <int16_t>((<uint16_t>value << 8) | self.m7_latch); self.m7_latch = value
        elif reg == 0x1E:
            self.m7d = <int16_t>((<uint16_t>value << 8) | self.m7_latch); self.m7_latch = value
        elif reg == 0x1F:
            self.m7x = <int16_t>_sign13((<uint16_t>value << 8) | self.m7_latch); self.m7_latch = value
        elif reg == 0x20:
            self.m7y = <int16_t>_sign13((<uint16_t>value << 8) | self.m7_latch); self.m7_latch = value

        elif reg == 0x21:                                 # CGADD
            self.cgram_addr = value
            self.cgram_flip = 0
        elif reg == 0x22:                                 # CGDATA
            if self._cgram_blocked():
                return
            if not self.cgram_flip:
                self.cgram_latch = value
                self.cgram_flip = 1
            else:
                self.cgram[self.cgram_addr & 0xFF] = ((<uint16_t>(value & 0x7F)) << 8) | self.cgram_latch
                self.cgram_addr = (self.cgram_addr + 1) & 0xFF
                self.cgram_flip = 0

        elif reg == 0x23:                                 # W12SEL
            self._write_winsel(0, value & 0x0F)
            self._write_winsel(1, value >> 4)
        elif reg == 0x24:                                 # W34SEL
            self._write_winsel(2, value & 0x0F)
            self._write_winsel(3, value >> 4)
        elif reg == 0x25:                                 # WOBJSEL
            self._write_winsel(4, value & 0x0F)
            self._write_winsel(5, value >> 4)
        elif reg == 0x26:
            self.win1_left = value
        elif reg == 0x27:
            self.win1_right = value
        elif reg == 0x28:
            self.win2_left = value
        elif reg == 0x29:
            self.win2_right = value
        elif reg == 0x2A:                                 # WBGLOG
            for n in range(4):
                self.win_logic[n] = (value >> (n * 2)) & 3
        elif reg == 0x2B:                                 # WOBJLOG
            self.win_logic[4] = value & 3
            self.win_logic[5] = (value >> 2) & 3

        elif reg == 0x2C:                                 # TM
            for n in range(5):
                self.main_enable[n] = (value >> n) & 1
        elif reg == 0x2D:                                 # TS
            for n in range(5):
                self.sub_enable[n] = (value >> n) & 1
        elif reg == 0x2E:                                 # TMW
            for n in range(5):
                self.main_window[n] = (value >> n) & 1
        elif reg == 0x2F:                                 # TSW
            for n in range(5):
                self.sub_window[n] = (value >> n) & 1

        elif reg == 0x30:                                 # CGWSEL
            self.cgwsel = value
        elif reg == 0x31:                                 # CGADSUB
            self.cgadsub = value
        elif reg == 0x32:                                 # COLDATA
            if value & 0x20:
                self.fixed_r = value & 0x1F
            if value & 0x40:
                self.fixed_g = value & 0x1F
            if value & 0x80:
                self.fixed_b = value & 0x1F
        elif reg == 0x33:                                 # SETINI
            self.screen_interlace = value & 1
            self.obj_interlace = (value >> 1) & 1
            self.overscan = (value >> 2) & 1
            self.pseudo_hires = (value >> 3) & 1
            self.extbg = (value >> 6) & 1

    cdef inline void _write_hofs(self, int n, uint8_t value) noexcept:
        self.bg_hofs[n] = ((<uint16_t>value << 8)
                           | (self.bgofs_latch & 0xF8)
                           | (self.bgofs_latch_h & 0x07))
        self.bgofs_latch = value
        self.bgofs_latch_h = value

    cdef inline void _write_vofs(self, int n, uint8_t value) noexcept:
        self.bg_vofs[n] = (<uint16_t>value << 8) | self.bgofs_latch
        self.bgofs_latch = value

    cdef inline void _write_winsel(self, int layer, uint8_t bits) noexcept:
        self.win_inverted[layer] = bits & 1
        self.win_enabled[layer] = (bits >> 1) & 1
        self.win2_inverted[layer] = (bits >> 2) & 1
        self.win2_enabled[layer] = (bits >> 3) & 1

    # =====================================================================
    # register reads
    # =====================================================================

    cdef uint8_t read_reg(self, uint32_t addr) noexcept:
        cdef uint32_t reg = addr & 0x3F
        cdef int32_t product
        cdef uint32_t va
        cdef uint8_t result

        if reg == 0x34 or reg == 0x35 or reg == 0x36:     # MPYL/MPYM/MPYH
            product = (<int32_t>self.m7a) * (<int32_t><signed char>(self.m7b >> 8))
            result = <uint8_t>((product >> ((reg - 0x34) * 8)) & 0xFF)
            self.ppu1_mdr = result
            return result

        if reg == 0x37:                                   # SLHV
            self.latch_counters()
            return self.ppu2_mdr

        if reg == 0x38:                                   # OAMDATAREAD
            va = self.oam_addr
            self.oam_addr = (self.oam_addr + 1) & 0x3FF
            result = self.oam[va] if va < 544 else 0
            self.ppu1_mdr = result
            return result

        if reg == 0x39:                                   # VMDATALREAD
            result = <uint8_t>(self.vram_prefetch & 0xFF)
            if not (self.vmain & 0x80):
                self.vram_addr = (self.vram_addr + _vram_step(self.vmain)) & 0x7FFF
                self.vram_prefetch = self.vram[_remap_vram(self.vmain, self.vram_addr) & 0x7FFF]
            self.ppu1_mdr = result
            return result

        if reg == 0x3A:                                   # VMDATAHREAD
            result = <uint8_t>(self.vram_prefetch >> 8)
            if self.vmain & 0x80:
                self.vram_addr = (self.vram_addr + _vram_step(self.vmain)) & 0x7FFF
                self.vram_prefetch = self.vram[_remap_vram(self.vmain, self.vram_addr) & 0x7FFF]
            self.ppu1_mdr = result
            return result

        if reg == 0x3B:                                   # CGDATAREAD
            if not self.cgram_flip:
                result = <uint8_t>(self.cgram[self.cgram_addr & 0xFF] & 0xFF)
                self.cgram_flip = 1
            else:
                result = <uint8_t>((self.cgram[self.cgram_addr & 0xFF] >> 8) & 0x7F)
                result |= self.ppu2_mdr & 0x80
                self.cgram_addr = (self.cgram_addr + 1) & 0xFF
                self.cgram_flip = 0
            self.ppu2_mdr = result
            return result

        if reg == 0x3C:                                   # OPHCT
            if not self.hcounter_flip:
                result = <uint8_t>(self.hcounter_latch & 0xFF)
            else:
                result = (self.ppu2_mdr & 0xFE) | <uint8_t>((self.hcounter_latch >> 8) & 1)
            self.hcounter_flip ^= 1
            self.ppu2_mdr = result
            return result

        if reg == 0x3D:                                   # OPVCT
            if not self.vcounter_flip:
                result = <uint8_t>(self.vcounter_latch & 0xFF)
            else:
                result = (self.ppu2_mdr & 0xFE) | <uint8_t>((self.vcounter_latch >> 8) & 1)
            self.vcounter_flip ^= 1
            self.ppu2_mdr = result
            return result

        if reg == 0x3E:                                   # STAT77
            result = 0x01                                  # PPU1 version
            if self.range_over:
                result |= 0x40
            if self.time_over:
                result |= 0x80
            result |= self.ppu1_mdr & 0x10
            self.ppu1_mdr = result
            return result

        if reg == 0x3F:                                   # STAT78
            result = 0x03                                  # PPU2 version
            if self.pal:
                result |= 0x10                             # 50 Hz part
            if self.field:
                result |= 0x80
            if self.latched:
                result |= 0x40
            result |= self.ppu2_mdr & 0x20
            self.latched = 0
            self.hcounter_flip = 0
            self.vcounter_flip = 0
            self.ppu2_mdr = result
            return result

        # $2100-$2133 are write-only: reading returns the last PPU bus value.
        return self.ppu1_mdr

    # =====================================================================
    # rendering
    # =====================================================================
    #
    # A row is drawn in spans rather than all at once.  The bus calls
    # catch_up() before every PPU register write, so the pixels to the left of
    # the write are produced from the old register state and those to its right
    # from the new one.  That is what makes a mid-scanline change visible.
    #
    # Sprites are the exception: the hardware evaluates them during the
    # previous line's H-blank, so they are latched once in begin_line() and an
    # OAM write part-way through a line does not affect it.

    cdef inline int _mosaic_x(self, int bg, int x) noexcept:
        """Snap a screen coordinate to the left edge of its mosaic block.

        Sampling at the snapped coordinate gives the same result as a
        post-pass over the whole line, and works when only part of the line
        is being drawn.
        """
        cdef int size
        if not self.mosaic_enable[bg] or self.mosaic_size == 0:
            return x
        size = self.mosaic_size + 1
        return x - (x % size)

    cdef inline int _mosaic_y(self, int bg, int line) noexcept:
        if not self.mosaic_enable[bg] or self.mosaic_size == 0:
            return line
        return line - (line % (self.mosaic_size + 1))

    cdef void begin_line(self, int row) noexcept:
        """Start a new output row.  row < 0 means nothing is being displayed."""
        cdef int i
        self.render_row = row
        self.rendered_x = 0
        if row < 0 or row >= SCREEN_H:
            return
        for i in range(SCREEN_W):
            self.obj_idx[i] = 0
            self.obj_pri[i] = 0xFF
            self.obj_pal[i] = 0
        if not self.forced_blank:
            self._render_objects(row)

    cdef void catch_up(self, int x) noexcept:
        """Draw up to, but not including, screen column x."""
        if self.render_row < 0:
            return
        if x > SCREEN_W:
            x = SCREEN_W
        if x <= self.rendered_x:
            return
        self._render_span(self.rendered_x, x)
        self.rendered_x = x

    cdef void end_line(self) noexcept:
        self.catch_up(SCREEN_W)
        self.render_row = -1

    cdef void render_scanline(self, int line) noexcept:
        """Draw a whole row in one go; used by tools that step frame by frame."""
        self.begin_line(line)
        self.end_line()

    # ---------------------------------------------------------------- span ---

    cdef void _render_span(self, int x0, int x1) noexcept:
        cdef int line = self.render_row
        cdef int x, i, b, order_len
        cdef uint32_t *row
        cdef int order[16][2]

        if line < 0 or line >= SCREEN_H:
            return
        row = self.framebuffer + line * SCREEN_W

        if self.forced_blank:
            for x in range(x0, x1):
                row[x] = 0xFF000000
            return

        for b in range(4):
            for x in range(x0, x1):
                self.bg_idx[b][x] = 0
                self.bg_pri[b][x] = 0

        self._compute_windows(x0, x1)

        # Direct colour only reaches a layer that is 8 bits deep, which is BG1
        # in modes 3, 4 and 7 and nothing at all in the others.
        self.direct_active = (1 if ((self.cgwsel & 0x01)
                                    and (self.bg_mode == 3 or self.bg_mode == 4
                                         or self.bg_mode == 7)) else 0)

        if self.bg_mode == 0:
            self._render_bg(0, line, 2, 0, x0, x1)
            self._render_bg(1, line, 2, 32, x0, x1)
            self._render_bg(2, line, 2, 64, x0, x1)
            self._render_bg(3, line, 2, 96, x0, x1)
            order_len = self._order_mode0(order)
        elif self.bg_mode == 1:
            self._render_bg(0, line, 4, 0, x0, x1)
            self._render_bg(1, line, 4, 0, x0, x1)
            self._render_bg(2, line, 2, 0, x0, x1)
            order_len = self._order_mode1(order)
        elif self.bg_mode == 2:
            self._render_bg(0, line, 4, 0, x0, x1)
            self._render_bg(1, line, 4, 0, x0, x1)
            order_len = self._order_mode23(order)      # BG3 supplies offsets
        elif self.bg_mode == 3:
            self._render_bg(0, line, 8, 0, x0, x1)
            self._render_bg(1, line, 4, 0, x0, x1)
            order_len = self._order_mode23(order)
        elif self.bg_mode == 4:
            self._render_bg(0, line, 8, 0, x0, x1)
            self._render_bg(1, line, 2, 0, x0, x1)
            order_len = self._order_mode23(order)
        elif self.bg_mode == 5:
            self._render_bg(0, line, 4, 0, x0, x1)
            self._render_bg(1, line, 2, 0, x0, x1)
            order_len = self._order_mode23(order)
        elif self.bg_mode == 6:
            self._render_bg(0, line, 4, 0, x0, x1)
            order_len = self._order_mode6(order)
        else:
            self._render_mode7(line, x0, x1)
            if self.extbg:
                order_len = self._order_mode7_extbg(order)
            else:
                order_len = self._order_mode7(order)

        for x in range(x0, x1):
            self.main_buf[x] = self.cgram[0]
            self.sub_buf[x] = self.cgram[0]
            self.main_src[x] = 5
            self.sub_src[x] = 5

        for i in range(order_len):
            self._paint(order[i][0], order[i][1], 0, x0, x1)
            self._paint(order[i][0], order[i][1], 1, x0, x1)

        self._compose(row, x0, x1)

    # --------------------------------------------------- offset-per-tile ---
    #
    # In modes 2, 4 and 6, BG3 is not drawn.  Its tilemap instead supplies a
    # scroll offset for each 8-pixel column of BG1 and BG2, which is how those
    # modes bend a layer column by column.
    #
    # An entry carries the offset in its low bits, with bit 13 meaning "apply
    # to BG1" and bit 14 "apply to BG2".  Modes 2 and 6 read two entries, one
    # row apart, for the horizontal and vertical offsets; mode 4 reads one and
    # takes bit 15 to say which of the two it is.  The leftmost column has no
    # entry and keeps the layer's own scroll.

    cdef uint16_t _bg3_entry(self, int tile_x, int tile_y) noexcept:
        cdef uint32_t base = self.bg_map_base[2]
        cdef uint32_t screen = 0
        if self.bg_map_wide[2] and (tile_x & 0x20):
            screen += 0x400
        if self.bg_map_tall[2] and (tile_y & 0x20):
            screen += 0x800 if self.bg_map_wide[2] else 0x400
        return self.vram[(base + screen + ((tile_y & 0x1F) << 5) + (tile_x & 0x1F)) & 0x7FFF]

    cdef void _opt_offsets(self, int bg, int x, int *out_h, int *out_v) noexcept:
        cdef int col = x >> 3
        cdef int h = self.bg_hofs[bg]
        cdef int v = self.bg_vofs[bg]
        cdef int applies = 0x2000 if bg == 0 else 0x4000
        cdef int tile_x, tile_y
        cdef uint16_t he, ve

        if col == 0:
            out_h[0] = h
            out_v[0] = v
            return

        tile_x = (((col - 1) << 3) + self.bg_hofs[2]) >> 3
        tile_y = self.bg_vofs[2] >> 3
        he = self._bg3_entry(tile_x, tile_y)

        # The offset is the low 13 bits; bits 13-15 are the apply flags and the
        # mode 4 direction bit, and must not leak into the scroll value.
        if self.bg_mode == 4:
            if he & applies:
                if he & 0x8000:
                    v = he & 0x1FFF
                else:
                    h = ((he & 0x1FFF) & ~7) | (self.bg_hofs[bg] & 7)
        else:
            ve = self._bg3_entry(tile_x, tile_y + 1)
            if he & applies:
                h = ((he & 0x1FFF) & ~7) | (self.bg_hofs[bg] & 7)
            if ve & applies:
                v = ve & 0x1FFF
        out_h[0] = h
        out_v[0] = v

    # ------------------------------------------------------------------ BG ---

    cdef void _render_bg(self, int bg, int line, int bpp, int pal_base,
                         int x0, int x1) noexcept:
        cdef int tile_shift = 3 + self.bg_tile_size[bg]
        cdef int base_y = self._mosaic_y(bg, line)
        cdef int y = base_y + self.bg_vofs[bg]
        cdef int hofs = self.bg_hofs[bg]
        cdef int opt = 1 if (bg < 2 and (self.bg_mode == 2 or self.bg_mode == 4
                                         or self.bg_mode == 6)) else 0
        cdef int opt_h, opt_v
        cdef uint32_t map_base = self.bg_map_base[bg]
        cdef uint32_t chr_base = self.bg_chr_base[bg]
        cdef int words_per_tile = bpp * 4
        cdef int x, sx, tile_x, tile_y, screen, sub_x, sub_y
        cdef uint32_t map_addr, chr_addr
        cdef uint16_t entry, plane
        cdef int tile_num, palette, prio, hflip, vflip, row_in, col, colour
        cdef int px_in_tile, py_in_tile

        for x in range(x0, x1):
            if opt:
                self._opt_offsets(bg, x, &opt_h, &opt_v)
                hofs = opt_h
                y = base_y + opt_v
            sx = self._mosaic_x(bg, x) + hofs
            tile_x = sx >> tile_shift
            tile_y = y >> tile_shift

            screen = 0
            if self.bg_map_wide[bg] and (tile_x & 0x20):
                screen += 0x400
            if self.bg_map_tall[bg] and (tile_y & 0x20):
                screen += 0x800 if self.bg_map_wide[bg] else 0x400
            map_addr = (map_base + screen + ((tile_y & 0x1F) << 5) + (tile_x & 0x1F)) & 0x7FFF

            entry = self.vram[map_addr]
            tile_num = entry & 0x03FF
            palette = (entry >> 10) & 7
            prio = (entry >> 13) & 1
            hflip = (entry >> 14) & 1
            vflip = (entry >> 15) & 1

            px_in_tile = sx & ((1 << tile_shift) - 1)
            py_in_tile = y & ((1 << tile_shift) - 1)
            if hflip:
                px_in_tile = ((1 << tile_shift) - 1) - px_in_tile
            if vflip:
                py_in_tile = ((1 << tile_shift) - 1) - py_in_tile

            if self.bg_tile_size[bg]:
                sub_x = (px_in_tile >> 3) & 1
                sub_y = (py_in_tile >> 3) & 1
                tile_num = (tile_num + sub_y * 16 + sub_x) & 0x03FF
            row_in = py_in_tile & 7
            col = px_in_tile & 7

            chr_addr = (chr_base + tile_num * words_per_tile + row_in) & 0x7FFF
            plane = self.vram[chr_addr]
            colour = ((plane >> (7 - col)) & 1) | (((plane >> (15 - col)) & 1) << 1)
            if bpp >= 4:
                plane = self.vram[(chr_addr + 8) & 0x7FFF]
                colour |= (((plane >> (7 - col)) & 1) << 2) | (((plane >> (15 - col)) & 1) << 3)
            if bpp == 8:
                plane = self.vram[(chr_addr + 16) & 0x7FFF]
                colour |= (((plane >> (7 - col)) & 1) << 4) | (((plane >> (15 - col)) & 1) << 5)
                plane = self.vram[(chr_addr + 24) & 0x7FFF]
                colour |= (((plane >> (7 - col)) & 1) << 6) | (((plane >> (15 - col)) & 1) << 7)

            if colour:
                if bpp == 8:
                    self.bg_idx[bg][x] = colour
                    if self.direct_active:
                        self.bg_direct[x] = self._direct(colour, palette)
                else:
                    self.bg_idx[bg][x] = pal_base + palette * (1 << bpp) + colour
                self.bg_pri[bg][x] = prio

    # ------------------------------------------------------- direct colour ---
    #
    # With $2130 bit 0 set, an 8bpp layer stops being an index into CGRAM and
    # becomes a colour in its own right.  The eight pixel bits carry three of
    # blue, three of green and three of red -- the low bit of each is filled
    # from the tilemap's palette field, which is why the same pixel value can
    # be three different shades depending on the tile that carried it.
    #
    # Mode 7 has no tilemap palette bits, so there the low bits are zero.

    cdef inline uint16_t _direct(self, int pixel, int palette) noexcept:
        cdef uint16_t r = <uint16_t>(((pixel & 0x07) << 2) | ((palette & 1) << 1))
        cdef uint16_t g = <uint16_t>(((pixel & 0x38) >> 1) | (palette & 2))
        cdef uint16_t b = <uint16_t>(((pixel & 0xC0) >> 3) | ((palette & 4) << 1))
        return r | (g << 5) | (b << 10)

    # -------------------------------------------------------------- mode 7 ---

    cdef void _render_mode7(self, int line, int x0, int x1) noexcept:
        cdef int y = self._mosaic_y(0, line)
        cdef int32_t a = self.m7a, b = self.m7b, c = self.m7c, d = self.m7d
        cdef int32_t cx = self.m7x, cy = self.m7y
        cdef int32_t ox = <int32_t>self.m7hofs - cx
        cdef int32_t oy = <int32_t>self.m7vofs - cy
        cdef int32_t ty = (255 - y) if (self.m7sel & 0x02) else y
        cdef int32_t sy = oy + ty
        cdef int32_t px_base = a * ox + b * sy + (cx << 8)
        cdef int32_t py_base = c * ox + d * sy + (cy << 8)
        cdef int x, tx, colour, outside
        cdef int32_t px, py
        cdef uint32_t tile, addr

        for x in range(x0, x1):
            tx = self._mosaic_x(0, x)
            if self.m7sel & 0x01:
                tx = 255 - tx
            px = (px_base + a * tx) >> 8
            py = (py_base + c * tx) >> 8

            outside = 0
            if (px | py) & ~1023:
                if (self.m7sel & 0xC0) == 0x80:
                    continue
                if (self.m7sel & 0xC0) == 0xC0:
                    outside = 1
                px &= 1023
                py &= 1023

            if outside:
                tile = 0
            else:
                tile = self.vram[(((py >> 3) & 127) * 128 + ((px >> 3) & 127)) & 0x7FFF] & 0xFF
            addr = (tile * 64 + (py & 7) * 8 + (px & 7)) & 0x7FFF
            colour = self.vram[addr] >> 8
            if colour:
                self.bg_idx[0][x] = colour
                self.bg_pri[0][x] = 0
                if self.direct_active:
                    self.bg_direct[x] = self._direct(colour, 0)
            # With EXTBG the same fetch also feeds BG2, which reads bit 7 as a
            # priority and the rest as its palette index.  BG1 still sees all
            # eight bits.
            if self.extbg and (colour & 0x7F):
                self.bg_idx[1][x] = colour & 0x7F
                self.bg_pri[1][x] = colour >> 7

    # ------------------------------------------------------------- windows ---

    cdef void _compute_windows(self, int x0, int x1) noexcept:
        cdef int layer, x, in1, in2, r
        cdef int l1 = self.win1_left, r1 = self.win1_right
        cdef int l2 = self.win2_left, r2 = self.win2_right

        for layer in range(6):
            if not self.win_enabled[layer] and not self.win2_enabled[layer]:
                for x in range(x0, x1):
                    self.win_mask[layer][x] = 0
                continue
            for x in range(x0, x1):
                in1 = 1 if (l1 <= x <= r1) else 0
                if self.win_inverted[layer]:
                    in1 = 1 - in1
                in2 = 1 if (l2 <= x <= r2) else 0
                if self.win2_inverted[layer]:
                    in2 = 1 - in2

                if self.win_enabled[layer] and self.win2_enabled[layer]:
                    if self.win_logic[layer] == 0:
                        r = in1 | in2
                    elif self.win_logic[layer] == 1:
                        r = in1 & in2
                    elif self.win_logic[layer] == 2:
                        r = in1 ^ in2
                    else:
                        r = 1 - (in1 ^ in2)
                elif self.win_enabled[layer]:
                    r = in1
                else:
                    r = in2
                self.win_mask[layer][x] = r

    # ------------------------------------------------------------- compose ---

    cdef void _paint(self, int layer, int prio, int to_sub, int x0, int x1) noexcept:
        cdef int x
        cdef uint16_t idx, colour
        cdef int enabled, windowed

        if to_sub:
            enabled = self.sub_enable[layer]
            windowed = self.sub_window[layer]
        else:
            enabled = self.main_enable[layer]
            windowed = self.main_window[layer]
        if not enabled:
            return

        if layer == 4:
            for x in range(x0, x1):
                if self.obj_pri[x] != prio:
                    continue
                if windowed and self.win_mask[4][x]:
                    continue
                idx = self.obj_idx[x]
                if idx == 0:
                    continue
                if to_sub:
                    self.sub_buf[x] = self.cgram[idx]
                    self.sub_src[x] = 4
                else:
                    self.main_buf[x] = self.cgram[idx]
                    self.main_src[x] = 4
        else:
            for x in range(x0, x1):
                idx = self.bg_idx[layer][x]
                if idx == 0 or self.bg_pri[layer][x] != prio:
                    continue
                if windowed and self.win_mask[layer][x]:
                    continue
                if self.direct_active and layer == 0:
                    colour = self.bg_direct[x]
                else:
                    colour = self.cgram[idx]
                if to_sub:
                    self.sub_buf[x] = colour
                    self.sub_src[x] = layer
                else:
                    self.main_buf[x] = colour
                    self.main_src[x] = layer

    cdef void _compose(self, uint32_t *row, int x0, int x1) noexcept:
        cdef int x, i, sub_used, math_here, clip_here, halve, subtract
        cdef int r, g, b, sr, sg, sb
        cdef uint16_t main, sub, fixed
        cdef int bright = self.brightness

        fixed = <uint16_t>(self.fixed_r | (self.fixed_g << 5) | (self.fixed_b << 10))
        subtract = 1 if (self.cgadsub & 0x80) else 0
        sub_used = 1 if (self.cgwsel & 0x02) else 0

        for x in range(x0, x1):
            main = self.main_buf[x]

            clip_here = self._region_black(self.cgwsel >> 6, self.win_mask[5][x])
            if clip_here:
                main = 0

            math_here = self._region(self.cgwsel >> 4, self.win_mask[5][x])
            if math_here and not clip_here:
                i = self.main_src[x]
                if i == 5:
                    math_here = 1 if (self.cgadsub & 0x20) else 0
                elif i == 4:
                    math_here = 1 if ((self.cgadsub & 0x10) and self.obj_pal[x] >= 4) else 0
                else:
                    math_here = 1 if (self.cgadsub & (1 << i)) else 0

            if math_here:
                if sub_used:
                    sub = self.sub_buf[x]
                    halve = 1 if ((self.cgadsub & 0x40) and self.sub_src[x] != 5) else 0
                else:
                    sub = fixed
                    halve = 1 if (self.cgadsub & 0x40) else 0

                r = main & 0x1F
                g = (main >> 5) & 0x1F
                b = (main >> 10) & 0x1F
                sr = sub & 0x1F
                sg = (sub >> 5) & 0x1F
                sb = (sub >> 10) & 0x1F
                if subtract:
                    r -= sr
                    g -= sg
                    b -= sb
                    if r < 0: r = 0
                    if g < 0: g = 0
                    if b < 0: b = 0
                else:
                    r += sr
                    g += sg
                    b += sb
                if halve:
                    r >>= 1
                    g >>= 1
                    b >>= 1
                if r > 31: r = 31
                if g > 31: g = 31
                if b > 31: b = 31
            else:
                r = main & 0x1F
                g = (main >> 5) & 0x1F
                b = (main >> 10) & 0x1F

            if bright != 15:
                r = self.light[bright][r]
                g = self.light[bright][g]
                b = self.light[bright][b]

            row[x] = (0xFF000000
                      | (<uint32_t>((r << 3) | (r >> 2)) << 16)
                      | (<uint32_t>((g << 3) | (g >> 2)) << 8)
                      | <uint32_t>((b << 3) | (b >> 2)))

    cdef void _render_objects(self, int line) noexcept:
        """Evaluate and draw the sprites for one line.

        The hardware makes two passes.  The first walks all 128 entries in
        order from the first-sprite index, keeping the first 32 that touch this
        line and raising range-over if more do.  The second walks that list
        backwards counting 8-pixel tiles, stopping at 34 and raising time-over.

        Walking the list backwards is also what gives the priority order: a
        sprite earlier in the list is drawn later, so it ends up in front.
        """
        cdef int widths[8][2]
        cdef int heights[8][2]
        cdef int collected[32]
        cdef int i, s, sx, sy, w, h, size_bit, count, k
        cdef int tile, palette, prio, hflip, vflip
        cdef int px, py, col, tx, ty, colour, screen_x, row_in
        cdef int first, tiles, columns, allowed, drawn
        cdef uint32_t chr_addr, base_tile
        cdef uint16_t plane
        cdef uint8_t hi

        widths[0][0] = 8;  widths[0][1] = 16
        widths[1][0] = 8;  widths[1][1] = 32
        widths[2][0] = 8;  widths[2][1] = 64
        widths[3][0] = 16; widths[3][1] = 32
        widths[4][0] = 16; widths[4][1] = 64
        widths[5][0] = 32; widths[5][1] = 64
        widths[6][0] = 16; widths[6][1] = 32
        widths[7][0] = 16; widths[7][1] = 32
        for i in range(8):
            heights[i][0] = widths[i][0]
            heights[i][1] = widths[i][1]
        heights[6][0] = 32; heights[6][1] = 64        # 16x32 / 32x64
        heights[7][0] = 32; heights[7][1] = 32        # 16x32 / 32x32

        # Priority rotation moves the start of the scan, which changes both
        # which sprites survive the 32 limit and which of them is in front.
        first = ((self.oam_addr_reload >> 2) & 0x7F) if self.oam_priority_rotation else 0

        # -- pass one: which sprites touch this line ------------------------
        count = 0
        for i in range(128):
            s = (first + i) & 0x7F
            hi = self.oam[512 + (s >> 2)]
            size_bit = (hi >> (((s & 3) << 1) + 1)) & 1
            w = widths[self.obj_size_sel][size_bit]
            h = heights[self.obj_size_sel][size_bit]

            sx = self.oam[s * 4 + 0]
            if (hi >> ((s & 3) << 1)) & 1:
                sx -= 256
            sy = self.oam[s * 4 + 1]

            # Range evaluation looks at Y alone: a sprite whose X puts it
            # off the side still occupies one of the 32 slots.
            py = line - sy
            if py < 0:
                py += 256
            if py < 0 or py >= h:
                continue

            if count == 32:
                self.range_over = 1
                break
            collected[count] = s
            count += 1

        # -- pass two: count tiles backwards, drawing as we go ---------------
        tiles = 0
        for k in range(count - 1, -1, -1):
            s = collected[k]
            hi = self.oam[512 + (s >> 2)]
            size_bit = (hi >> (((s & 3) << 1) + 1)) & 1
            w = widths[self.obj_size_sel][size_bit]
            h = heights[self.obj_size_sel][size_bit]

            sx = self.oam[s * 4 + 0]
            if (hi >> ((s & 3) << 1)) & 1:
                sx -= 256
            sy = self.oam[s * 4 + 1]
            base_tile = self.oam[s * 4 + 2]
            i = self.oam[s * 4 + 3]
            base_tile |= (<uint32_t>(i & 1)) << 8
            palette = (i >> 1) & 7
            prio = (i >> 4) & 3
            hflip = (i >> 6) & 1
            vflip = (i >> 7) & 1

            py = line - sy
            if py < 0:
                py += 256
            if vflip:
                py = h - 1 - py
            ty = py >> 3
            row_in = py & 7

            # Only the 8-pixel columns that land on screen are fetched.
            columns = 0
            for col in range(0, w, 8):
                screen_x = sx + col
                if screen_x > -8 and screen_x < SCREEN_W:
                    columns += 1

            allowed = columns
            if tiles + columns > 34:
                self.time_over = 1
                allowed = 34 - tiles
                if allowed < 0:
                    allowed = 0
            tiles += columns

            drawn = 0
            for col in range(0, w, 8):
                screen_x = sx + col
                if screen_x <= -8 or screen_x >= SCREEN_W:
                    continue
                if drawn >= allowed:
                    break
                drawn += 1
                for px in range(col, col + 8):
                    screen_x = sx + px
                    if screen_x < 0 or screen_x >= SCREEN_W:
                        continue
                    tx = ((w - 1 - px) if hflip else px)
                    tile = (base_tile + ty * 16 + (tx >> 3)) & 0x1FF
                    chr_addr = self.obj_base + ((tile & 0xFF) << 4)
                    if tile & 0x100:
                        chr_addr += self.obj_gap
                    chr_addr = (chr_addr + row_in) & 0x7FFF

                    i = tx & 7
                    plane = self.vram[chr_addr]
                    colour = ((plane >> (7 - i)) & 1) | (((plane >> (15 - i)) & 1) << 1)
                    plane = self.vram[(chr_addr + 8) & 0x7FFF]
                    colour |= (((plane >> (7 - i)) & 1) << 2) | (((plane >> (15 - i)) & 1) << 3)
                    if colour:
                        self.obj_idx[screen_x] = 128 + palette * 16 + colour
                        self.obj_pri[screen_x] = prio
                        self.obj_pal[screen_x] = palette

    cdef inline int _region(self, int mode, int inside) noexcept:
        """CGWSEL bits 5-4, colour-math enable: 0=always 1=inside 2=outside 3=never."""
        mode &= 3
        if mode == 0:
            return 1
        if mode == 1:
            return inside
        if mode == 2:
            return 1 - inside
        return 0

    cdef inline int _region_black(self, int mode, int inside) noexcept:
        """CGWSEL bits 7-6, force-main-black: 0=never 1=inside 2=outside 3=always.
        Note the 0 and 3 cases are the reverse of the colour-math field."""
        mode &= 3
        if mode == 0:
            return 0
        if mode == 1:
            return inside
        if mode == 2:
            return 1 - inside
        return 1

    # -- paint orders, lowest priority first --------------------------------

    cdef int _order_mode0(self, int order[16][2]) noexcept:
        cdef int n = 0
        n = self._push(order, n, 3, 0); n = self._push(order, n, 2, 0)
        n = self._push(order, n, 4, 0)
        n = self._push(order, n, 3, 1); n = self._push(order, n, 2, 1)
        n = self._push(order, n, 4, 1)
        n = self._push(order, n, 1, 0); n = self._push(order, n, 0, 0)
        n = self._push(order, n, 4, 2)
        n = self._push(order, n, 1, 1); n = self._push(order, n, 0, 1)
        n = self._push(order, n, 4, 3)
        return n

    cdef int _order_mode1(self, int order[16][2]) noexcept:
        cdef int n = 0
        if not self.bg3_priority:
            n = self._push(order, n, 2, 0)
            n = self._push(order, n, 4, 0)
            n = self._push(order, n, 2, 1)
            n = self._push(order, n, 4, 1)
            n = self._push(order, n, 1, 0); n = self._push(order, n, 0, 0)
            n = self._push(order, n, 4, 2)
            n = self._push(order, n, 1, 1); n = self._push(order, n, 0, 1)
            n = self._push(order, n, 4, 3)
        else:
            n = self._push(order, n, 2, 0)
            n = self._push(order, n, 4, 0)
            n = self._push(order, n, 4, 1)
            n = self._push(order, n, 1, 0); n = self._push(order, n, 0, 0)
            n = self._push(order, n, 4, 2)
            n = self._push(order, n, 1, 1); n = self._push(order, n, 0, 1)
            n = self._push(order, n, 4, 3)
            n = self._push(order, n, 2, 1)
        return n

    cdef int _order_mode23(self, int order[16][2]) noexcept:
        cdef int n = 0
        n = self._push(order, n, 1, 0)
        n = self._push(order, n, 4, 0)
        n = self._push(order, n, 0, 0)
        n = self._push(order, n, 4, 1)
        n = self._push(order, n, 1, 1)
        n = self._push(order, n, 4, 2)
        n = self._push(order, n, 0, 1)
        n = self._push(order, n, 4, 3)
        return n

    cdef int _order_mode6(self, int order[16][2]) noexcept:
        cdef int n = 0
        n = self._push(order, n, 0, 0)
        n = self._push(order, n, 4, 0)
        n = self._push(order, n, 4, 1)
        n = self._push(order, n, 0, 1)
        n = self._push(order, n, 4, 2)
        n = self._push(order, n, 4, 3)
        return n

    cdef int _order_mode7(self, int order[16][2]) noexcept:
        cdef int n = 0
        n = self._push(order, n, 4, 0)
        n = self._push(order, n, 0, 0)
        n = self._push(order, n, 4, 1)
        n = self._push(order, n, 4, 2)
        n = self._push(order, n, 4, 3)
        return n

    cdef int _order_mode7_extbg(self, int order[16][2]) noexcept:
        """BG2 straddles BG1: its low-priority half sits behind and its
        high-priority half in front."""
        cdef int n = 0
        n = self._push(order, n, 4, 0)
        n = self._push(order, n, 1, 0)
        n = self._push(order, n, 4, 1)
        n = self._push(order, n, 0, 0)
        n = self._push(order, n, 4, 2)
        n = self._push(order, n, 1, 1)
        n = self._push(order, n, 4, 3)
        return n

    cdef inline int _push(self, int order[16][2], int n, int layer, int prio) noexcept:
        order[n][0] = layer
        order[n][1] = prio
        return n + 1







    # -- save state (generated by tools/gen_state.py; do not edit) --------

    def state_ints(self):
        cdef int i, j
        v = [self.brightness, self.forced_blank, self.obj_base, self.obj_gap, self.obj_size_sel, self.oam_addr_reload, self.oam_addr, self.oam_priority_rotation, self.oam_latch_active, self.oam_latch, self.bg_mode, self.bg3_priority, self.mosaic_size, self.bgofs_latch, self.bgofs_latch_h, self.vmain, self.vram_addr, self.vram_prefetch, self.m7sel, self.m7a, self.m7b, self.m7c, self.m7d, self.m7x, self.m7y, self.m7hofs, self.m7vofs, self.m7_latch, self.cgram_addr, self.cgram_flip, self.cgram_latch, self.win1_left, self.win1_right, self.win2_left, self.win2_right, self.cgwsel, self.cgadsub, self.fixed_r, self.fixed_g, self.fixed_b, self.overscan, self.obj_interlace, self.screen_interlace, self.pseudo_hires, self.extbg, self.hcounter, self.vcounter, self.field, self.latched, self.hcounter_latch, self.vcounter_latch, self.hcounter_flip, self.vcounter_flip, self.range_over, self.time_over, self.ppu1_mdr, self.ppu2_mdr]
        for i in range(4):
            v.append(self.mosaic_enable[i])
        for i in range(4):
            v.append(self.bg_map_base[i])
        for i in range(4):
            v.append(self.bg_map_wide[i])
        for i in range(4):
            v.append(self.bg_map_tall[i])
        for i in range(4):
            v.append(self.bg_chr_base[i])
        for i in range(4):
            v.append(self.bg_tile_size[i])
        for i in range(4):
            v.append(self.bg_hofs[i])
        for i in range(4):
            v.append(self.bg_vofs[i])
        for i in range(6):
            v.append(self.win_enabled[i])
        for i in range(6):
            v.append(self.win_inverted[i])
        for i in range(6):
            v.append(self.win2_enabled[i])
        for i in range(6):
            v.append(self.win2_inverted[i])
        for i in range(6):
            v.append(self.win_logic[i])
        for i in range(5):
            v.append(self.main_enable[i])
        for i in range(5):
            v.append(self.sub_enable[i])
        for i in range(5):
            v.append(self.main_window[i])
        for i in range(5):
            v.append(self.sub_window[i])
        return v

    def load_ints(self, v):
        cdef int i, j, k = 57
        self.brightness = v[0]
        self.forced_blank = v[1]
        self.obj_base = v[2]
        self.obj_gap = v[3]
        self.obj_size_sel = v[4]
        self.oam_addr_reload = v[5]
        self.oam_addr = v[6]
        self.oam_priority_rotation = v[7]
        self.oam_latch_active = v[8]
        self.oam_latch = v[9]
        self.bg_mode = v[10]
        self.bg3_priority = v[11]
        self.mosaic_size = v[12]
        self.bgofs_latch = v[13]
        self.bgofs_latch_h = v[14]
        self.vmain = v[15]
        self.vram_addr = v[16]
        self.vram_prefetch = v[17]
        self.m7sel = v[18]
        self.m7a = v[19]
        self.m7b = v[20]
        self.m7c = v[21]
        self.m7d = v[22]
        self.m7x = v[23]
        self.m7y = v[24]
        self.m7hofs = v[25]
        self.m7vofs = v[26]
        self.m7_latch = v[27]
        self.cgram_addr = v[28]
        self.cgram_flip = v[29]
        self.cgram_latch = v[30]
        self.win1_left = v[31]
        self.win1_right = v[32]
        self.win2_left = v[33]
        self.win2_right = v[34]
        self.cgwsel = v[35]
        self.cgadsub = v[36]
        self.fixed_r = v[37]
        self.fixed_g = v[38]
        self.fixed_b = v[39]
        self.overscan = v[40]
        self.obj_interlace = v[41]
        self.screen_interlace = v[42]
        self.pseudo_hires = v[43]
        self.extbg = v[44]
        self.hcounter = v[45]
        self.vcounter = v[46]
        self.field = v[47]
        self.latched = v[48]
        self.hcounter_latch = v[49]
        self.vcounter_latch = v[50]
        self.hcounter_flip = v[51]
        self.vcounter_flip = v[52]
        self.range_over = v[53]
        self.time_over = v[54]
        self.ppu1_mdr = v[55]
        self.ppu2_mdr = v[56]
        for i in range(4):
            self.mosaic_enable[i] = v[k + i]
        k += 4
        for i in range(4):
            self.bg_map_base[i] = v[k + i]
        k += 4
        for i in range(4):
            self.bg_map_wide[i] = v[k + i]
        k += 4
        for i in range(4):
            self.bg_map_tall[i] = v[k + i]
        k += 4
        for i in range(4):
            self.bg_chr_base[i] = v[k + i]
        k += 4
        for i in range(4):
            self.bg_tile_size[i] = v[k + i]
        k += 4
        for i in range(4):
            self.bg_hofs[i] = v[k + i]
        k += 4
        for i in range(4):
            self.bg_vofs[i] = v[k + i]
        k += 4
        for i in range(6):
            self.win_enabled[i] = v[k + i]
        k += 6
        for i in range(6):
            self.win_inverted[i] = v[k + i]
        k += 6
        for i in range(6):
            self.win2_enabled[i] = v[k + i]
        k += 6
        for i in range(6):
            self.win2_inverted[i] = v[k + i]
        k += 6
        for i in range(6):
            self.win_logic[i] = v[k + i]
        k += 6
        for i in range(5):
            self.main_enable[i] = v[k + i]
        k += 5
        for i in range(5):
            self.sub_enable[i] = v[k + i]
        k += 5
        for i in range(5):
            self.main_window[i] = v[k + i]
        k += 5
        for i in range(5):
            self.sub_window[i] = v[k + i]
        k += 5

    def state_blobs(self):
        return [PyBytes_FromStringAndSize(<char *>self.vram, 65536), PyBytes_FromStringAndSize(<char *>self.cgram, 512), PyBytes_FromStringAndSize(<char *>self.oam, 544), PyBytes_FromStringAndSize(<char *>self.framebuffer, 244736)]

    def load_blobs(self, blobs):
        if len(blobs[0]) != 65536:
            raise ValueError('bad vram blob')
        memcpy(<char *>self.vram, <char *><bytes>blobs[0], 65536)
        if len(blobs[1]) != 512:
            raise ValueError('bad cgram blob')
        memcpy(<char *>self.cgram, <char *><bytes>blobs[1], 512)
        if len(blobs[2]) != 544:
            raise ValueError('bad oam blob')
        memcpy(<char *>self.oam, <char *><bytes>blobs[2], 544)
        if len(blobs[3]) != 244736:
            raise ValueError('bad framebuffer blob')
        memcpy(<char *>self.framebuffer, <char *><bytes>blobs[3], 244736)

    # -- end generated save state ------------------------------------------

    # -- python helpers ----------------------------------------------------

    def dump(self):
        lines = [
            "INIDISP  forced_blank=%d brightness=%d" % (self.forced_blank, self.brightness),
            "BGMODE   mode=%d bg3prio=%d tilesize=%d%d%d%d"
            % (self.bg_mode, self.bg3_priority, self.bg_tile_size[0],
               self.bg_tile_size[1], self.bg_tile_size[2], self.bg_tile_size[3]),
            "BG map   %s  (wide %s tall %s)"
            % ([hex(self.bg_map_base[i]) for i in range(4)],
               [self.bg_map_wide[i] for i in range(4)],
               [self.bg_map_tall[i] for i in range(4)]),
            "BG chr   %s" % [hex(self.bg_chr_base[i]) for i in range(4)],
            "BG scrl  h=%s v=%s" % ([self.bg_hofs[i] for i in range(4)],
                                    [self.bg_vofs[i] for i in range(4)]),
            "TM=%s TS=%s TMW=%s TSW=%s"
            % ([self.main_enable[i] for i in range(5)],
               [self.sub_enable[i] for i in range(5)],
               [self.main_window[i] for i in range(5)],
               [self.sub_window[i] for i in range(5)]),
            "CGWSEL=$%02X CGADSUB=$%02X fixed=(%d,%d,%d)"
            % (self.cgwsel, self.cgadsub, self.fixed_r, self.fixed_g, self.fixed_b),
            "OBSEL    base=$%04X gap=$%04X size=%d"
            % (self.obj_base, self.obj_gap, self.obj_size_sel),
            "VRAM     addr=$%04X vmain=$%02X   CGRAM addr=$%02X"
            % (self.vram_addr, self.vmain, self.cgram_addr),
        ]
        return chr(10).join(lines)

    def dbg_counts(self):
        return dict(lines=self.dbg_lines, enabled=self.dbg_lines_enabled,
                    blank=self.dbg_lines_blank)

    def dbg_reset(self):
        self.dbg_lines = 0
        self.dbg_lines_enabled = 0
        self.dbg_lines_blank = 0

    def vram_nonzero(self):
        cdef int i, n = 0
        for i in range(0x8000):
            if self.vram[i]:
                n += 1
        return n

    def cgram_nonzero(self):
        cdef int i, n = 0
        for i in range(256):
            if self.cgram[i]:
                n += 1
        return n

    def oam_nonzero(self):
        cdef int i, n = 0
        for i in range(544):
            if self.oam[i]:
                n += 1
        return n

    @property
    def vram_bytes(self):
        return bytes(bytearray([(self.vram[i >> 1] >> (8 * (i & 1))) & 0xFF
                                for i in range(0x10000)]))

    @property
    def cgram_list(self):
        return [self.cgram[i] for i in range(256)]

    @property
    def oam_bytes(self):
        return bytes(bytearray([self.oam[i] for i in range(544)]))


cdef inline int32_t _sign13(uint16_t v) noexcept:
    """Sign-extend a 13-bit mode 7 offset/centre value."""
    v &= 0x1FFF
    return <int32_t>v - 0x2000 if (v & 0x1000) else <int32_t>v
