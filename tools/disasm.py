"""65816 disassembler, used for execution traces while debugging the core."""

IMP, ACC, IMM_M, IMM_X, IMM8 = "imp", "acc", "imm_m", "imm_x", "imm8"
DP, DPX, DPY, DPI, DPIX, DPIY, DPIL, DPILY = "dp", "dpx", "dpy", "dpi", "dpix", "dpiy", "dpil", "dpily"
ABS, ABSX, ABSY, ABSI, ABSIX, ABSIL = "abs", "absx", "absy", "absi", "absix", "absil"
LONG, LONGX, SR, SRIY, REL, RELL, MOVE = "long", "longx", "sr", "sriy", "rel", "rell", "move"

LENGTH = {
    IMP: 1, ACC: 1, IMM8: 2, DP: 2, DPX: 2, DPY: 2, DPI: 2, DPIX: 2, DPIY: 2,
    DPIL: 2, DPILY: 2, SR: 2, SRIY: 2, REL: 2,
    ABS: 3, ABSX: 3, ABSY: 3, ABSI: 3, ABSIX: 3, ABSIL: 3, RELL: 3, MOVE: 3,
    LONG: 4, LONGX: 4,
}

# opcode -> (mnemonic, addressing mode)
OPCODES = {}


def _fill(pairs):
    for opcode, name, mode in pairs:
        OPCODES[opcode] = (name, mode)


# The eight accumulator ALU groups share one addressing pattern; only the base
# opcode and mnemonic differ.
_ALU_MODES = [(0x01, DPIX), (0x03, SR), (0x05, DP), (0x07, DPIL), (0x09, IMM_M),
              (0x0D, ABS), (0x0F, LONG), (0x11, DPIY), (0x12, DPI), (0x13, SRIY),
              (0x15, DPX), (0x17, DPILY), (0x19, ABSY), (0x1D, ABSX), (0x1F, LONGX)]
for base, mnem in ((0x00, "ORA"), (0x20, "AND"), (0x40, "EOR"), (0x60, "ADC"),
                   (0x80, "STA"), (0xA0, "LDA"), (0xC0, "CMP"), (0xE0, "SBC")):
    for off, mode in _ALU_MODES:
        if mnem == "STA" and off == 0x09:      # $89 is BIT #, not STA #
            continue
        OPCODES[base + off] = (mnem, mode)

_fill([
    (0x00, "BRK", IMM8), (0x02, "COP", IMM8), (0x42, "WDM", IMM8),
    (0x04, "TSB", DP), (0x0C, "TSB", ABS), (0x14, "TRB", DP), (0x1C, "TRB", ABS),
    (0x06, "ASL", DP), (0x0A, "ASL", ACC), (0x0E, "ASL", ABS), (0x16, "ASL", DPX), (0x1E, "ASL", ABSX),
    (0x26, "ROL", DP), (0x2A, "ROL", ACC), (0x2E, "ROL", ABS), (0x36, "ROL", DPX), (0x3E, "ROL", ABSX),
    (0x46, "LSR", DP), (0x4A, "LSR", ACC), (0x4E, "LSR", ABS), (0x56, "LSR", DPX), (0x5E, "LSR", ABSX),
    (0x66, "ROR", DP), (0x6A, "ROR", ACC), (0x6E, "ROR", ABS), (0x76, "ROR", DPX), (0x7E, "ROR", ABSX),
    (0x1A, "INC", ACC), (0xE6, "INC", DP), (0xEE, "INC", ABS), (0xF6, "INC", DPX), (0xFE, "INC", ABSX),
    (0x3A, "DEC", ACC), (0xC6, "DEC", DP), (0xCE, "DEC", ABS), (0xD6, "DEC", DPX), (0xDE, "DEC", ABSX),
    (0x08, "PHP", IMP), (0x28, "PLP", IMP), (0x48, "PHA", IMP), (0x68, "PLA", IMP),
    (0x5A, "PHY", IMP), (0x7A, "PLY", IMP), (0xDA, "PHX", IMP), (0xFA, "PLX", IMP),
    (0x8B, "PHB", IMP), (0xAB, "PLB", IMP), (0x0B, "PHD", IMP), (0x2B, "PLD", IMP),
    (0x4B, "PHK", IMP), (0xF4, "PEA", ABS), (0xD4, "PEI", DP), (0x62, "PER", RELL),
    (0x10, "BPL", REL), (0x30, "BMI", REL), (0x50, "BVC", REL), (0x70, "BVS", REL),
    (0x80, "BRA", REL), (0x90, "BCC", REL), (0xB0, "BCS", REL), (0xD0, "BNE", REL),
    (0xF0, "BEQ", REL), (0x82, "BRL", RELL),
    (0x18, "CLC", IMP), (0x38, "SEC", IMP), (0x58, "CLI", IMP), (0x78, "SEI", IMP),
    (0xB8, "CLV", IMP), (0xD8, "CLD", IMP), (0xF8, "SED", IMP),
    (0xC2, "REP", IMM8), (0xE2, "SEP", IMM8), (0xFB, "XCE", IMP),
    (0x20, "JSR", ABS), (0x22, "JSL", LONG), (0xFC, "JSR", ABSIX),
    (0x4C, "JMP", ABS), (0x5C, "JML", LONG), (0x6C, "JMP", ABSI),
    (0x7C, "JMP", ABSIX), (0xDC, "JML", ABSIL),
    (0x60, "RTS", IMP), (0x6B, "RTL", IMP), (0x40, "RTI", IMP),
    (0x24, "BIT", DP), (0x2C, "BIT", ABS), (0x34, "BIT", DPX), (0x3C, "BIT", ABSX),
    (0x89, "BIT", IMM_M),
    (0xA0, "LDY", IMM_X), (0xA4, "LDY", DP), (0xAC, "LDY", ABS), (0xB4, "LDY", DPX), (0xBC, "LDY", ABSX),
    (0xA2, "LDX", IMM_X), (0xA6, "LDX", DP), (0xAE, "LDX", ABS), (0xB6, "LDX", DPY), (0xBE, "LDX", ABSY),
    (0x84, "STY", DP), (0x8C, "STY", ABS), (0x94, "STY", DPX),
    (0x86, "STX", DP), (0x8E, "STX", ABS), (0x96, "STX", DPY),
    (0x64, "STZ", DP), (0x74, "STZ", DPX), (0x9C, "STZ", ABS), (0x9E, "STZ", ABSX),
    (0xC0, "CPY", IMM_X), (0xC4, "CPY", DP), (0xCC, "CPY", ABS),
    (0xE0, "CPX", IMM_X), (0xE4, "CPX", DP), (0xEC, "CPX", ABS),
    (0xE8, "INX", IMP), (0xC8, "INY", IMP), (0xCA, "DEX", IMP), (0x88, "DEY", IMP),
    (0xAA, "TAX", IMP), (0xA8, "TAY", IMP), (0x8A, "TXA", IMP), (0x98, "TYA", IMP),
    (0xBA, "TSX", IMP), (0x9A, "TXS", IMP), (0x9B, "TXY", IMP), (0xBB, "TYX", IMP),
    (0x5B, "TCD", IMP), (0x7B, "TDC", IMP), (0x1B, "TCS", IMP), (0x3B, "TSC", IMP),
    (0xEB, "XBA", IMP), (0xEA, "NOP", IMP), (0xCB, "WAI", IMP), (0xDB, "STP", IMP),
    (0x54, "MVN", MOVE), (0x44, "MVP", MOVE),
])

FORMAT = {
    IMP: "", ACC: "A",
    DP: "${0:02X}", DPX: "${0:02X},X", DPY: "${0:02X},Y",
    DPI: "(${0:02X})", DPIX: "(${0:02X},X)", DPIY: "(${0:02X}),Y",
    DPIL: "[${0:02X}]", DPILY: "[${0:02X}],Y",
    SR: "${0:02X},S", SRIY: "(${0:02X},S),Y",
    ABS: "${0:04X}", ABSX: "${0:04X},X", ABSY: "${0:04X},Y",
    ABSI: "(${0:04X})", ABSIX: "(${0:04X},X)", ABSIL: "[${0:04X}]",
    LONG: "${0:06X}", LONGX: "${0:06X},X",
    IMM8: "#${0:02X}",
}


def length(opcode, m16=False, x16=False):
    name, mode = OPCODES.get(opcode, ("???", IMP))
    if mode == IMM_M:
        return 3 if m16 else 2
    if mode == IMM_X:
        return 3 if x16 else 2
    return LENGTH[mode]


def disassemble(read, pb, pc, m16=False, x16=False):
    """`read(addr24)` must be side-effect free.  Returns (text, size)."""
    def at(i):
        return read(((pb << 16) | ((pc + i) & 0xFFFF)) & 0xFFFFFF)

    opcode = at(0)
    name, mode = OPCODES.get(opcode, ("???", IMP))
    size = length(opcode, m16, x16)
    operand = 0
    for i in range(size - 1):
        operand |= at(1 + i) << (8 * i)

    if mode in (IMM_M, IMM_X):
        text = ("#$%04X" % operand) if size == 3 else ("#$%02X" % operand)
    elif mode == REL:
        target = (pc + 2 + ((operand ^ 0x80) - 0x80)) & 0xFFFF
        text = "$%04X" % target
    elif mode == RELL:
        target = (pc + 3 + ((operand ^ 0x8000) - 0x8000)) & 0xFFFF
        text = "$%04X" % target
    elif mode == MOVE:
        text = "$%02X,$%02X" % (operand & 0xFF, operand >> 8)
    else:
        text = FORMAT[mode].format(operand)

    raw = " ".join("%02X" % at(i) for i in range(size))
    return "%-11s %s %s" % (raw, name, text), size


def trace_line(sys_obj):
    """One formatted trace line for the machine's current position."""
    cpu = sys_obj.cpu
    r = cpu.regs
    e = r["e"]
    m16 = not e and not (r["p"] & 0x20)
    x16 = not e and not (r["p"] & 0x10)
    text, _ = disassemble(sys_obj.bus.read, r["pb"], r["pc"], m16, x16)
    return ("%02X:%04X  %-30s A:%04X X:%04X Y:%04X S:%04X D:%04X DB:%02X %s"
            % (r["pb"], r["pc"], text, r["a"], r["x"], r["y"], r["s"], r["d"],
               r["db"], cpu.flags))
