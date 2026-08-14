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
                 "stopped", "waiting", "ea_wrap", "instructions",
                 # The interrupt decision is latched a cycle before an
                 # instruction ends, so a state saved between the latch and
                 # the boundary has to carry it or the interrupt is lost.
                 "take_nmi", "take_irq"],
        arrays=[], arrays2=[], blobs=[],
    ),
    dict(
        module="bus", cls="Bus",
        marker="    # =====================================================================\n"
               "    # python interface",
        scalars=["mdr", "master_clock", "hcount", "line_start", "next_event",
                 # A multiply takes eight steps, so a state saved during one
                 # must carry how far it got.
                 "mul_shifter", "mul_steps", "mul_clock",
                 "vcount", "field", "frame",
                 "frame_ready", "ticking", "lines_per_frame", "vblank_start",
                 "nmi_enabled", "nmi_flag", "nmi_pending", "irq_mode", "irq_flag",
                 "irq_pending", "irq_line_done", "timer_irq", "in_vblank", "in_hblank",
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
                 "test_timers_disable", "test_ram_writable",
                 "test_ram_disable", "test_timers_enable",
                 "cycle_target",
                 "master_prev", "frac", "dsp_counter", "extra_cycles", "stopped",
                 "dsp_addr", "aux4", "aux5"],
        arrays=[("port_in", 4), ("port_out", 4), ("timer_target", 3),
                ("timer_div", 3), ("timer_counter", 3), ("timer_stage", 3),
                ("timer_enabled", 3)],
        arrays2=[], blobs=[("ram", "uint8_t", 0x10000)],
    ),
    dict(
        module="apu", cls="DSP",
        marker="    # -- python side ---",
        scalars=["counter", "noise", "echo_offset", "echo_length",
                 "echo_esa", "echo_flg", "echo_hist_pos", "last_l", "last_r",
                 "phase", "every_other", "kon", "new_kon", "t_koff",
                 "t_pmon", "t_non", "t_eon", "t_dir", "t_dir_addr",
                 "t_brr_next_addr", "t_echo_ptr", "t_srcn", "t_adsr0",
                 "t_brr_byte", "t_brr_header", "t_looped", "t_pitch",
                 "t_output", "endx_buf", "outx_buf", "envx_buf"],
        arrays=[("brr_addr", 8), ("brr_offset", 8), ("buf_pos", 8),
                ("interp_pos", 8), ("env", 8), ("hidden_env", 8),
                ("env_mode", 8), ("kon_delay", 8), ("envx_out", 8), ("voice_out", 8),
                ("echo_hist_l", 16), ("echo_hist_r", 16),
                ("t_main_out", 2), ("t_echo_out", 2), ("t_echo_in", 2)],
        arrays2=[("buf", 8, 24)],
        blobs=[("reg", "uint8_t", 128)],
    ),
    dict(
        module='sa1', cls='SA1',
        marker="    # -- introspection ---",
        scalars=['bwram_mask', 'ccnt', 'scnt', 'sie', 'sic', 'cie', 'cic', 'crv', 'cnv', 'civ', 'snv', 'siv', 'sa1_irq', 'sa1_nmi', 'scpu_irq', 'dma_irq_scpu', 'dma_irq_sa1', 'timer_irq', 'stopped', 'bmaps', 'bmap', 'sbwe', 'cbwe', 'siwp', 'ciwp', 'math_ctl', 'math_a', 'math_b', 'math_result', 'math_overflow', 'vbd', 'vda', 'vbit', 'tmc', 'timer_h', 'timer_v', 'timer_base', 'timer_seen', 'dcnt', 'cdma', 'dsa', 'dda', 'dtc', 'cc_line', 'n_cc1', 'n_cc2', 'n_dma', 'n_math', 'n_varlen', 'n_timer_irq'],
        arrays=[('mmc', 4), ('brf', 16)],
        arrays2=[],
        blobs=[('iram', 'uint8_t', 2048)],
    ),
    dict(
        module='sdd1', cls='SDD1',
        marker="    # -- introspection ---",
        scalars=['dma_enable', 'dma_arm', 'out_len', 'out_pos', 'active', 'in_addr', 'in_stream', 'valid_bits', 'bitplane_type', 'high_context_bits', 'low_context_bits', 'dma_seen', 'dma_armed_seen', 'last_channel', 'last_enable', 'last_arm', 'last_addr', 'last_count'],
        arrays=[('mmc', 4), ('bit_ctr', 8), ('context_state', 32), ('context_mps', 32), ('prev_bits', 8)],
        arrays2=[],
        blobs=[('out', 'uint8_t', 65536)],
    ),
    dict(
        module='superfx', cls='SuperFX',
        marker="    # -- introspection ---",
        scalars=['r14_modified', 'r15_modified', 'sfr', 'pbr', 'rombr', 'rambr', 'cbr', 'scbr', 'colr', 'bramr', 'vcr', 'clsr', 'pipeline', 'ramaddr', 'scmr_ht', 'scmr_ron', 'scmr_ran', 'scmr_md', 'por_obj', 'por_freezehigh', 'por_highnibble', 'por_dither', 'por_transparent', 'cfgr_irq', 'cfgr_ms0', 'sreg', 'dreg', 'romcl', 'romdr', 'ramcl', 'ramar', 'ramdr', 'rom_mask', 'ram_mask', 'gsu_clock', 'target'],
        arrays=[('r', 16), ('cache_buffer', 512), ('cache_valid', 32), ('pc_offset', 2), ('pc_bitpend', 2)],
        arrays2=[('pc_data', 2, 8)],
        blobs=[],
    ),
    dict(
        module='spc7110', cls='SPC7110',
        marker="    # -- introspection ---",
        scalars=['prom_size', 'drom_base', 'drom_size', 'r4801', 'r4802', 'r4803', 'r4804', 'r4805', 'r4806', 'r4807', 'r4809', 'r480a', 'r480b', 'r480c', 'dcu_mode', 'dcu_address', 'dcu_offset', 'r4810', 'r4811', 'r4812', 'r4813', 'r4814', 'r4815', 'r4816', 'r4817', 'r4818', 'r481a', 'r4820', 'r4821', 'r4822', 'r4823', 'r4824', 'r4825', 'r4826', 'r4827', 'r4828', 'r4829', 'r482a', 'r482b', 'r482c', 'r482d', 'r482e', 'r482f', 'r4830', 'r4831', 'r4832', 'r4833', 'r4834', 'bpp', 'offset', 'bits', 'range_', 'input_', 'output', 'pixels', 'colormap', 'result',
                 # The clock keeps its own time and its own exchange state.
                 'rtc_state', 'rtc_reading', 'rtc_index', 'rtc_reads',
                 'rtc_touches', 'rtc_seconds', 'rtc_last_clock', 'rtc_dirty'],
        arrays=[('dcu_tile', 32), ('rtc', 16)],
        arrays2=[('ctx_prediction', 5, 15), ('ctx_swap', 5, 15)],
        blobs=[],
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


# -- completeness ----------------------------------------------------------
#
# The reason this file exists is that a hand-written serialiser drifts from the
# class it serialises.  A generated one drifts too, in a quieter way: a field
# added to the .pxd and not to the spec above is simply left out of every save
# state, and nothing complains.  That is exactly how the cartridge boards came
# to be missing from save states entirely.
#
# So the specs are checked against the declarations.  Anything in a .pxd that
# is not serialised has to be named here, with a reason.

EXCLUDED = {
    # Derived, constant, or scratch -- with the reason, because "it looked
    # unimportant" is how a field goes missing for a year.
    ("cpu", "CPU"): {
        "bus",                                   # the object it runs on
        "insn_log", "bus_log", "insn_cap", "bus_cap", "insn_len", "bus_len",
        "tracing", "trace_wrap",                 # the tracer, not the machine
    },
    ("bus", "Bus"): {
        "cart", "ppu", "apu", "board",           # the objects it drives
        "page_kind", "page_base",                # rebuilt from cart and board
        "pal",                                   # a property of the cartridge
        "nmi_count", "irq_count",                # counters, for tools
        "pad_state_next",
    },
    ("ppu", "PPU"): {
        "light_rgb",                         # a table rebuilt from brightness
        "framebuffer_obj",                       # the buffer behind framebuffer
        "vdisp", "pal", "light",                 # constants
        "dbg_lines", "dbg_lines_enabled", "dbg_lines_blank",
        # Everything below is scratch for the line being drawn.  A state is
        # taken between frames, when none of it is live.
        "bg_idx", "bg_pri", "obj_idx", "obj_pri", "obj_pal", "win_mask",
        "bg_idx_hi", "bg_pri_hi", "true_hires", "main_buf", "sub_buf",
        "main_src", "sub_src", "bg_bpp", "bg_pal_base", "bg_direct",
        "direct_active", "hires", "out_row", "src_line", "render_row",
        "rendered_x",
        "prev_main", "prev_blacked", "prev_math", "prev_halve", "prev_blend",
    },
    ("apu", "APU"): {
        "dsp", "ipl",                            # the DSP has its own state
        "master_hz",                             # a constant
        "idle_tail", "log_on", "log_n", "log_kind", "log_addr",   # tooling
    },
    ("apu", "DSP"): {
        "apu", "gauss",                          # parent, and a constant table
        "solo", "echo_enabled",                  # debug switches
        "kon_count",                             # a counter, for tools
        "out_buf", "out_write", "out_read", "out_count",   # the audio ring
    },
    # Boards: pointers into the cartridge, and buffers handled by extra_state.
    ("sa1", "SA1"): {"cart", "space", "cpu", "bwram", "name", "unsupported",
                     "clock", "irq_line"},
    ("sdd1", "SDD1"): {"cart", "name", "unsupported", "clock", "irq_line"},
    ("superfx", "SuperFX"): {"cart", "rom", "ram", "ram_data", "name",
                             "unsupported", "clock", "irq_line"},
    ("spc7110", "SPC7110"): {"cart", "rom", "name", "unsupported", "clock",
                             "irq_line",
                             "has_rtc",          # read from the cartridge header
                             "rtc_trace", "rtc_trace_len"},  # a trace for tools
}


def declared_fields(module, cls):
    """Every data member of a cdef class, from its .pxd."""
    import re
    text = open(os.path.join(ROOT, "snes", module + ".pxd")).read()
    import re as _re
    m = _re.search(r"^cdef class %s\s*[(:]" % _re.escape(cls), text, _re.M)
    if not m:
        return None
    body = text[m.end():]
    body = body.split("\ncdef class", 1)[0]
    out = []
    for line in body.splitlines():
        line = line.split("#")[0].strip()
        if not line.startswith("cdef ") or "(" in line:
            continue
        decl = line[5:].strip()
        for kw in ("public ", "readonly "):
            if decl.startswith(kw):
                decl = decl[len(kw):]
        m = re.match(r"((?:const |unsigned )*[\w]+)\s+(.*)$", decl)
        if not m:
            continue
        for part in m.group(2).split(","):
            part = part.strip().lstrip("*")
            nm = re.match(r"(\w+)", part)
            if nm:
                out.append(nm.group(1))
    return out


def check_complete():
    """Fail loudly if a declared field is neither serialised nor excused."""
    problems = []
    for spec in SPECS:
        key = (spec["module"], spec["cls"])
        declared = declared_fields(*key)
        if declared is None:
            continue
        covered = set(spec["scalars"])
        covered |= {n for n, _ in spec["arrays"]}
        covered |= {n for n, _a, _b in spec["arrays2"]}
        covered |= {n for n, _t, _c in spec["blobs"]}
        covered |= EXCLUDED.get(key, set())
        missing = [f for f in declared if f not in covered]
        if missing:
            problems.append("%s.%s: %s" % (key[0], key[1], ", ".join(missing)))
    if problems:
        raise SystemExit("fields declared but not saved (add them to SPECS, or "
                         "to EXCLUDED with a reason):\n  " + "\n  ".join(problems))
    print("all declared fields are accounted for")


def main():
    check_complete()
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
