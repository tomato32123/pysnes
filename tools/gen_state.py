"""Generate the save-state serialisers for the Cython cores.

Writing save/load by hand invites drift between the two halves, so both are
emitted from one field list per class.  Run this after adding a field:

    python tools/gen_state.py && python build.py
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (module, class, marker to insert before, scalars, 1-D arrays, 2-D arrays, blobs)
# blobs are (attribute, C element type, element count) copied as raw memory.
SPECS = [
    dict(
        module="cpu", cls="CPU",
        marker="    # =====================================================================\n"
               "    # python interface",
        scalars=["a", "x", "y", "s", "d", "pc", "db", "pb", "p", "e",
                 "stopped", "waiting", "ea_wrap", "instructions"],
        arrays=[], arrays2=[], blobs=[],
    ),
    dict(
        module="bus", cls="Bus",
        marker="    # =====================================================================\n"
               "    # python interface",
        scalars=["mdr", "master_clock", "hcount", "line_start", "next_event",
                 "vcount", "field", "frame",
                 "frame_ready", "ticking", "lines_per_frame", "vblank_start",
                 "nmi_enabled", "nmi_flag", "nmi_pending", "irq_mode", "irq_flag",
                 "irq_pending", "irq_line_done", "in_vblank", "in_hblank",
                 "htime", "vtime", "fast_rom", "wrio", "mul_a", "mul_b", "div_a",
                 "div_b", "rd_div", "rd_mpy", "wram_addr", "auto_joypad",
                 "auto_joypad_busy", "joypad_busy_until", "pad_latched",
                 "hdma_enabled", "dma_enabled"],
        arrays=[("ev_time", 6),
                ("pad_state", 4), ("joy", 4), ("pad_shift", 4),
                ("dma_param", 8), ("dma_bbus", 8), ("dma_abus", 8),
                ("dma_size", 8), ("dma_indirect_bank", 8), ("hdma_table", 8),
                ("hdma_line", 8), ("dma_unused", 8), ("hdma_active", 8),
                ("hdma_do_transfer", 8)],
        arrays2=[], blobs=[("wram", "uint8_t", 0x20000)],
    ),
    dict(
        module="ppu", cls="PPU",
        marker="    # -- python helpers ---",
        scalars=["brightness", "forced_blank", "obj_base", "obj_gap", "obj_size_sel",
                 "oam_addr_reload", "oam_addr", "oam_priority_rotation",
                 "oam_latch_active", "oam_latch", "bg_mode", "bg3_priority",
                 "mosaic_size", "bgofs_latch", "bgofs_latch_h", "vmain",
                 "vram_addr", "vram_prefetch", "m7sel", "m7a", "m7b", "m7c", "m7d",
                 "m7x", "m7y", "m7hofs", "m7vofs", "m7_latch", "cgram_addr",
                 "cgram_flip", "cgram_latch", "win1_left", "win1_right",
                 "win2_left", "win2_right", "cgwsel", "cgadsub", "fixed_r",
                 "fixed_g", "fixed_b", "overscan", "obj_interlace",
                 "screen_interlace", "pseudo_hires", "extbg", "hcounter",
                 "vcounter", "field", "latched", "hcounter_latch",
                 "vcounter_latch", "hcounter_flip", "vcounter_flip",
                 "range_over", "time_over", "ppu1_mdr", "ppu2_mdr",
                 "mosaic_start", "mosaic_left"],
        arrays=[("mosaic_enable", 4), ("bg_map_base", 4), ("bg_map_wide", 4),
                ("bg_map_tall", 4), ("bg_chr_base", 4), ("bg_tile_size", 4),
                ("bg_hofs", 4), ("bg_vofs", 4),
                ("win_enabled", 6), ("win_inverted", 6), ("win2_enabled", 6),
                ("win2_inverted", 6), ("win_logic", 6),
                ("main_enable", 5), ("sub_enable", 5), ("main_window", 5),
                ("sub_window", 5)],
        arrays2=[],
        # The framebuffer is derived data, but rewind restores states without
        # rendering, so without it the display freezes while scrubbing back.
        blobs=[("vram", "uint16_t", 0x8000), ("cgram", "uint16_t", 256),
               ("oam", "uint8_t", 544), ("framebuffer", "uint8_t", 512 * 478 * 4)],
    ),
    dict(
        module="apu", cls="APU",
        marker="    # =====================================================================\n"
               "    # python helpers",
        scalars=["pc", "a", "x", "y", "sp", "psw", "ipl_enabled", "clock",
                 "cycle_target",
                 "master_prev", "frac", "dsp_counter", "extra_cycles", "stopped",
                 "dsp_addr"],
        arrays=[("port_in", 4), ("port_out", 4), ("timer_target", 3),
                ("timer_div", 3), ("timer_counter", 3), ("timer_stage", 3),
                ("timer_enabled", 3)],
        arrays2=[], blobs=[("ram", "uint8_t", 0x10000)],
    ),
    dict(
        module="apu", cls="DSP",
        marker="    # -- python side ---",
        scalars=["counter", "noise", "echo_offset", "echo_length", "fir_pos",
                 "last_l", "last_r"],
        arrays=[("brr_addr", 8), ("brr_offset", 8), ("brr_header", 8),
                ("block_pos", 8), ("interp_pos", 8), ("env", 8), ("env_mode", 8),
                ("kon_delay", 8), ("prev1", 8), ("prev2", 8), ("voice_out", 8),
                ("fir_l", 8), ("fir_r", 8)],
        arrays2=[("hist", 8, 4), ("block", 8, 16)],
        blobs=[("reg", "uint8_t", 128)],
    ),
]

BANNER = "    # -- save state (generated by tools/gen_state.py; do not edit) --------\n"
END = "    # -- end generated save state ------------------------------------------\n"


def emit(spec):
    s, a, a2, blobs = spec["scalars"], spec["arrays"], spec["arrays2"], spec["blobs"]
    out = [BANNER, "\n"]

    out.append("    def state_ints(self):\n")
    out.append("        cdef int i, j\n")
    out.append("        v = [%s]\n" % ", ".join("self.%s" % n for n in s))
    for name, n in a:
        out.append("        for i in range(%d):\n            v.append(self.%s[i])\n" % (n, name))
    for name, n, m in a2:
        out.append("        for i in range(%d):\n            for j in range(%d):\n"
                   "                v.append(self.%s[i][j])\n" % (n, m, name))
    out.append("        return v\n\n")

    out.append("    def load_ints(self, v):\n")
    out.append("        cdef int i, j, k = %d\n" % len(s))
    for idx, name in enumerate(s):
        out.append("        self.%s = v[%d]\n" % (name, idx))
    for name, n in a:
        out.append("        for i in range(%d):\n"
                   "            self.%s[i] = v[k + i]\n"
                   "        k += %d\n" % (n, name, n))
    for name, n, m in a2:
        out.append("        for i in range(%d):\n"
                   "            for j in range(%d):\n"
                   "                self.%s[i][j] = v[k + i * %d + j]\n"
                   "        k += %d\n" % (n, m, name, m, n * m))
    out.append("\n")

    out.append("    def state_blobs(self):\n")
    if blobs:
        out.append("        return [%s]\n\n" % ", ".join(
            "PyBytes_FromStringAndSize(<char *>self.%s, %d)" % (name, count * _size(ctype))
            for name, ctype, count in blobs))
    else:
        out.append("        return []\n\n")

    out.append("    def load_blobs(self, blobs):\n")
    if blobs:
        for i, (name, ctype, count) in enumerate(blobs):
            nbytes = count * _size(ctype)
            out.append("        if len(blobs[%d]) != %d:\n"
                       "            raise ValueError('bad %s blob')\n"
                       "        memcpy(<char *>self.%s, <char *><bytes>blobs[%d], %d)\n"
                       % (i, nbytes, name, name, i, nbytes))
    else:
        out.append("        pass\n")
    out.append("\n")
    out.append(END)
    return "".join(out)


def _size(ctype):
    return {"uint8_t": 1, "uint16_t": 2, "uint32_t": 4, "int32_t": 4, "int16_t": 2}[ctype]


NL = chr(10)


def ensure_imports(text):
    """Add the cimports the generated code needs, if they are not there yet."""
    if "cimport PyBytes_FromStringAndSize" not in text:
        text = text.replace(
            "from libc.stdint cimport",
            "from cpython.bytes cimport PyBytes_FromStringAndSize" + NL
            + "from libc.stdint cimport", 1)
    if "from libc.string cimport" not in text:
        text = text.replace(
            "from libc.stdint cimport",
            "from libc.string cimport memcpy" + NL + "from libc.stdint cimport", 1)
    else:
        m = re.search(r"from libc[.]string cimport ([^\n]+)", text)
        if "memcpy" not in m.group(1):
            text = (text[:m.start()]
                    + "from libc.string cimport %s, memcpy" % m.group(1)
                    + text[m.end():])
    return text


def main():
    by_module = {}
    for spec in SPECS:
        by_module.setdefault(spec["module"], []).append(spec)

    for module, specs in by_module.items():
        path = os.path.join(ROOT, "snes", module + ".pyx")
        text = open(path, encoding="utf-8").read()
        # Drop any previously generated blocks so re-running is idempotent.
        # Swallow the blank lines after the old block too, or each run leaves
        # one behind and the file drifts without anything changing.
        text = re.sub(re.escape(BANNER) + r".*?" + re.escape(END) + NL + "*",
                      "", text, flags=re.S)
        for spec in specs:
            marker = spec["marker"]
            if marker not in text:
                raise SystemExit("marker not found in %s for %s" % (module, spec["cls"]))
            text = text.replace(marker, emit(spec) + NL + NL + marker, 1)
        text = ensure_imports(text)
        open(path, "w", encoding="utf-8").write(text)
        print("updated snes/%s.pyx" % module)


if __name__ == "__main__":
    main()
