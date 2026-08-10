# cython: language_level=3
from libc.stdint cimport uint8_t, uint16_t, uint32_t, int16_t, int32_t

cdef class PPU:
    # -- memories ---------------------------------------------------------
    cdef uint16_t vram[0x8000]      # 64 KB, addressed as 32 K words
    cdef uint16_t cgram[256]
    cdef uint8_t oam[544]

    # -- $2100 INIDISP ----------------------------------------------------
    cdef int brightness
    cdef int forced_blank

    # -- $2101 OBSEL ------------------------------------------------------
    cdef uint32_t obj_base          # word address of sprite chr
    cdef uint32_t obj_gap           # offset added for the second name table
    cdef int obj_size_sel

    # -- $2102/$2103 OAM address ------------------------------------------
    cdef uint32_t oam_addr_reload
    cdef uint32_t oam_addr
    cdef int oam_priority_rotation
    cdef int oam_latch_active
    cdef uint8_t oam_latch

    # -- $2105 BGMODE / $2106 MOSAIC --------------------------------------
    cdef int bg_mode
    cdef int bg3_priority
    cdef int mosaic_size
    cdef int mosaic_enable[4]

    # -- $2107-$210C per-layer configuration ------------------------------
    cdef uint32_t bg_map_base[4]    # word address of the tilemap
    cdef int bg_map_wide[4]         # 32 or 64 tiles horizontally
    cdef int bg_map_tall[4]
    cdef uint32_t bg_chr_base[4]    # word address of tile data
    cdef int bg_tile_size[4]        # 0 = 8x8, 1 = 16x16

    # -- $210D-$2114 scroll ------------------------------------------------
    cdef uint16_t bg_hofs[4]
    cdef uint16_t bg_vofs[4]
    cdef uint8_t bgofs_latch
    cdef uint8_t bgofs_latch_h

    # -- $2115-$2119 VRAM access -------------------------------------------
    cdef uint8_t vmain
    cdef uint32_t vram_addr
    cdef uint16_t vram_prefetch

    # -- $211A-$2120 mode 7 -------------------------------------------------
    cdef uint8_t m7sel
    cdef int16_t m7a, m7b, m7c, m7d
    cdef int16_t m7x, m7y           # centre
    cdef int16_t m7hofs, m7vofs
    cdef uint8_t m7_latch

    # -- $2121/$2122 CGRAM access -------------------------------------------
    cdef uint32_t cgram_addr
    cdef int cgram_flip
    cdef uint8_t cgram_latch

    # -- $2123-$212B windows ------------------------------------------------
    cdef int win_enabled[6]         # BG1-4, OBJ, COLOR : window 1 enabled
    cdef int win_inverted[6]
    cdef int win2_enabled[6]
    cdef int win2_inverted[6]
    cdef int win_logic[6]           # 0=OR 1=AND 2=XOR 3=XNOR
    cdef uint8_t win1_left, win1_right
    cdef uint8_t win2_left, win2_right

    # -- $212C-$212F layer enables ------------------------------------------
    cdef int main_enable[5]         # BG1-4, OBJ
    cdef int sub_enable[5]
    cdef int main_window[5]
    cdef int sub_window[5]

    # -- $2130-$2132 colour math --------------------------------------------
    cdef uint8_t cgwsel
    cdef uint8_t cgadsub
    cdef int fixed_r, fixed_g, fixed_b

    # -- $2133 SETINI --------------------------------------------------------
    cdef int overscan
    cdef int obj_interlace
    cdef int screen_interlace
    cdef int pseudo_hires
    cdef int extbg

    # -- counters / status ---------------------------------------------------
    cdef int hcounter, vcounter, field
    cdef int latched
    cdef uint16_t hcounter_latch, vcounter_latch
    cdef int hcounter_flip, vcounter_flip
    cdef int range_over, time_over
    cdef uint8_t ppu1_mdr, ppu2_mdr
    cdef int dbg_lines, dbg_lines_enabled, dbg_lines_blank

    # -- per-scanline render buffers -------------------------------------------
    cdef uint16_t bg_idx[4][256]     # CGRAM index, 0 = transparent
    cdef uint8_t bg_pri[4][256]      # tilemap priority bit
    cdef uint16_t obj_idx[256]
    cdef uint8_t obj_pri[256]        # 0-3, 0xFF = no sprite
    cdef uint8_t obj_pal[256]        # sprite palette group, for colour math
    cdef uint8_t win_mask[6][256]    # BG1-4, OBJ, COLOR
    cdef uint16_t main_buf[256]
    cdef uint16_t sub_buf[256]
    cdef uint8_t main_src[256]       # 0-3 BG, 4 OBJ, 5 backdrop
    cdef uint8_t sub_src[256]
    cdef int bg_bpp[4]
    cdef int bg_pal_base[4]

    # -- output --------------------------------------------------------------
    cdef readonly object framebuffer_obj
    cdef uint32_t *framebuffer

    cdef void reset(self) noexcept
    cdef uint8_t read_reg(self, uint32_t addr) noexcept
    cdef void write_reg(self, uint32_t addr, uint8_t value) noexcept
    cdef void render_scanline(self, int line) noexcept
    cdef void latch_counters(self) noexcept

    cdef void _write_hofs(self, int n, uint8_t value) noexcept
    cdef void _write_vofs(self, int n, uint8_t value) noexcept
    cdef void _write_winsel(self, int layer, uint8_t bits) noexcept
    cdef void _render_bg(self, int bg, int line, int bpp, int pal_base) noexcept
    cdef void _render_mode7(self, int line) noexcept
    cdef void _render_objects(self, int line) noexcept
    cdef void _compute_windows(self, int line) noexcept
    cdef void _clear_layers(self) noexcept
    cdef void _paint(self, int layer, int prio, int to_sub) noexcept
    cdef int _mosaic_y(self, int bg, int line) noexcept
    cdef void _mosaic_x(self, int bg) noexcept
    cdef int _region(self, int mode, int inside) noexcept
    cdef int _region_black(self, int mode, int inside) noexcept
    cdef int _order_mode0(self, int order[16][2]) noexcept
    cdef int _order_mode1(self, int order[16][2]) noexcept
    cdef int _order_mode23(self, int order[16][2]) noexcept
    cdef int _order_mode6(self, int order[16][2]) noexcept
    cdef int _order_mode7(self, int order[16][2]) noexcept
    cdef int _push(self, int order[16][2], int n, int layer, int prio) noexcept
