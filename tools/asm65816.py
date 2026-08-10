"""A small 65816 assembler, so test ROMs can live in this repository.

The opcode table is inverted from tools/disasm.py rather than written out
again, which keeps the assembler and the disassembler from disagreeing about
what any byte means.

Syntax is the usual one:

    .org $8000          set the assembly address (bank:offset, 24-bit)
    label:              define a label
    LDA #$12            8-bit immediate
    LDA #$1234          16-bit immediate
    LDA.w $12           force absolute where direct page would fit
    LDA [$12],Y         long indirect indexed
    .db $01,$02         bytes        .dw $1234    words      .dl $123456  longs
    .text "hi"          ASCII        .fill 16,$00 repeat
    .assert_m16         tell the assembler the M flag is now 0 (16-bit A)

Immediate width follows the assembler's idea of the M and X flags, which
starts 8-bit and is updated by REP/SEP with a constant operand, or by the
.assert_* directives when the flags are changed some other way.
"""

import re
import sys

from tools import disasm

# (mnemonic, mode) -> opcode, inverted from the disassembler's table.
ENCODING = {}
for _op, (_name, _mode) in disasm.OPCODES.items():
    ENCODING[(_name, _mode)] = _op

IMP, ACC = disasm.IMP, disasm.ACC
IMM_M, IMM_X, IMM8 = disasm.IMM_M, disasm.IMM_X, disasm.IMM8
DP, DPX, DPY = disasm.DP, disasm.DPX, disasm.DPY
DPI, DPIX, DPIY = disasm.DPI, disasm.DPIX, disasm.DPIY
DPIL, DPILY = disasm.DPIL, disasm.DPILY
ABS, ABSX, ABSY = disasm.ABS, disasm.ABSX, disasm.ABSY
ABSI, ABSIX, ABSIL = disasm.ABSI, disasm.ABSIX, disasm.ABSIL
LONG, LONGX = disasm.LONG, disasm.LONGX
SR, SRIY = disasm.SR, disasm.SRIY
REL, RELL, MOVE = disasm.REL, disasm.RELL, disasm.MOVE

# Preference order when the operand size was not forced: smallest that fits.
SIZE_GROUPS = [
    ([DP, ABS, LONG], {"b": DP, "w": ABS, "l": LONG}),
    ([DPX, ABSX, LONGX], {"b": DPX, "w": ABSX, "l": LONGX}),
    ([DPY, ABSY], {"b": DPY, "w": ABSY}),
]


class AsmError(Exception):
    pass


class Assembler:
    def __init__(self):
        self.labels = {}
        self.m16 = False
        self.x16 = False

    # -- entry point --------------------------------------------------------

    def assemble(self, source, origin=0x008000):
        """Two passes: collect label addresses, then emit."""
        lines = self._parse(source)
        for final in (False, True):
            self.pc = origin
            self.m16 = False
            self.x16 = False
            out = {}
            for lineno, label, mnem, operand in lines:
                if label:
                    if not final:
                        self.labels[label] = self.pc
                    elif self.labels.get(label) != self.pc:
                        raise AsmError("line %d: label %s moved between passes"
                                       % (lineno, label))
                if mnem is None:
                    continue
                try:
                    data = self._emit(mnem, operand, final)
                except AsmError as exc:
                    raise AsmError("line %d: %s" % (lineno, exc))
                if data is not None:
                    if final:
                        for i, byte in enumerate(data):
                            out[self.pc + i] = byte
                    self.pc += len(data)
        return out

    def _parse(self, source):
        lines = []
        for lineno, raw in enumerate(source.splitlines(), 1):
            text = raw.split(";", 1)[0].rstrip()
            if not text.strip():
                continue
            label = None
            m = re.match(r"^([A-Za-z_.][A-Za-z0-9_]*):\s*(.*)$", text)
            if m:
                label, text = m.group(1), m.group(2)
            text = text.strip()
            if not text:
                lines.append((lineno, label, None, None))
                continue
            parts = text.split(None, 1)
            lines.append((lineno, label, parts[0], parts[1].strip() if len(parts) > 1 else ""))
        return lines

    # -- expressions ---------------------------------------------------------

    def _value(self, text, final):
        text = text.strip()
        if not text:
            raise AsmError("expected a value")
        total, op = 0, "+"
        for token in re.findall(r"[+\-]|[^+\-\s]+", text):
            if token in "+-":
                op = token
                continue
            v = self._atom(token, final)
            total = total + v if op == "+" else total - v
        return total

    def _atom(self, token, final):
        if token.startswith("$"):
            return int(token[1:], 16)
        if token.startswith("%"):
            return int(token[1:], 2)
        if token.startswith("<") or token.startswith(">") or token.startswith("^"):
            v = self._atom(token[1:], final)
            return {"<": v & 0xFF, ">": (v >> 8) & 0xFF, "^": (v >> 16) & 0xFF}[token[0]]
        if re.match(r"^\d+$", token):
            return int(token, 10)
        if token in self.labels:
            return self.labels[token]
        if final:
            raise AsmError("unknown label %r" % token)
        return 0x8000                 # placeholder wide enough for pass one

    # -- operand decoding -----------------------------------------------------

    def _decode(self, operand, final):
        """Return (mode-candidates, value).  Candidates are ordered by size."""
        text = operand.strip()
        if text == "" :
            return [IMP], 0
        if text.upper() == "A":
            return [ACC], 0
        if text.startswith("#"):
            return ["#"], self._value(text[1:], final)

        m = re.match(r"^\[(.+?)\]\s*,\s*[Yy]$", text)
        if m:
            return [DPILY], self._value(m.group(1), final)
        m = re.match(r"^\[(.+?)\]$", text)
        if m:
            v = self._value(m.group(1), final)
            return [DPIL, ABSIL], v
        m = re.match(r"^\((.+?)\s*,\s*[Ss]\)\s*,\s*[Yy]$", text)
        if m:
            return [SRIY], self._value(m.group(1), final)
        m = re.match(r"^\((.+?)\s*,\s*[Xx]\)$", text)
        if m:
            v = self._value(m.group(1), final)
            return [DPIX, ABSIX], v
        m = re.match(r"^\((.+?)\)\s*,\s*[Yy]$", text)
        if m:
            return [DPIY], self._value(m.group(1), final)
        m = re.match(r"^\((.+?)\)$", text)
        if m:
            v = self._value(m.group(1), final)
            return [DPI, ABSI], v
        m = re.match(r"^(.+?)\s*,\s*[Ss]$", text)
        if m:
            return [SR], self._value(m.group(1), final)
        m = re.match(r"^(.+?)\s*,\s*[Xx]$", text)
        if m:
            return [DPX, ABSX, LONGX], self._value(m.group(1), final)
        m = re.match(r"^(.+?)\s*,\s*[Yy]$", text)
        if m:
            return [DPY, ABSY], self._value(m.group(1), final)
        if "," in text:                                   # MVN/MVP
            a, b = text.split(",", 1)
            return [MOVE], (self._value(a, final), self._value(b, final))
        return [DP, ABS, LONG], self._value(text, final)

    # -- emission --------------------------------------------------------------

    def _emit(self, mnem, operand, final):
        upper = mnem.upper()
        if upper.startswith("."):
            return self._directive(upper, operand, final)

        forced = None
        if "." in upper:
            upper, suffix = upper.split(".", 1)
            forced = suffix.lower()
            if forced not in ("b", "w", "l"):
                raise AsmError("bad size suffix .%s" % forced)

        candidates, value = self._decode(operand, final)

        if candidates == ["#"]:
            data = self._emit_immediate(upper, value, forced)
            # Track the widths REP/SEP establish so later immediates size
            # themselves correctly without the source having to say so.
            if upper == "REP":
                if value & 0x20: self.m16 = True
                if value & 0x10: self.x16 = True
            elif upper == "SEP":
                if value & 0x20: self.m16 = False
                if value & 0x10: self.x16 = False
            return data

        # Branches take a label, not an address mode.
        if (upper, REL) in ENCODING and candidates and candidates[0] in (DP, ABS, LONG):
            return self._emit_branch(upper, value, REL, final)
        if (upper, RELL) in ENCODING and candidates and candidates[0] in (DP, ABS, LONG):
            return self._emit_branch(upper, value, RELL, final)

        if candidates == [MOVE]:
            opcode = ENCODING.get((upper, MOVE))
            if opcode is None:
                raise AsmError("%s takes no block-move operand" % upper)
            dst, src = value
            return bytes([opcode, dst & 0xFF, src & 0xFF])

        chosen = self._choose(upper, candidates, value, forced)
        opcode = ENCODING[(upper, chosen)]
        size = disasm.LENGTH[chosen] - 1
        return bytes([opcode] + [(value >> (8 * i)) & 0xFF for i in range(size)])

    def _choose(self, upper, candidates, value, forced):
        usable = [c for c in candidates if (upper, c) in ENCODING]
        if not usable:
            raise AsmError("%s does not accept that addressing mode" % upper)
        if forced:
            for group, table in SIZE_GROUPS:
                if usable[0] in group and forced in table and (upper, table[forced]) in ENCODING:
                    return table[forced]
            raise AsmError("%s cannot be forced to .%s" % (upper, forced))
        for c in usable:                     # smallest that can hold the value
            width = disasm.LENGTH[c] - 1
            if value < (1 << (8 * width)):
                return c
        # Silently truncating here would emit a store to a completely
        # different address, which is very hard to see afterwards.
        raise AsmError("$%X does not fit any addressing mode %s accepts "
                       "(widest is %s)" % (value, upper, usable[-1]))

    def _emit_immediate(self, upper, value, forced):
        for mode in (IMM_M, IMM_X, IMM8):
            if (upper, mode) in ENCODING:
                opcode = ENCODING[(upper, mode)]
                if mode == IMM8:
                    wide = False
                elif forced:
                    wide = forced == "w"
                else:
                    wide = self.m16 if mode == IMM_M else self.x16
                if wide:
                    return bytes([opcode, value & 0xFF, (value >> 8) & 0xFF])
                return bytes([opcode, value & 0xFF])
        raise AsmError("%s takes no immediate operand" % upper)

    def _emit_branch(self, upper, target, mode, final):
        opcode = ENCODING[(upper, mode)]
        size = disasm.LENGTH[mode]
        delta = target - (self.pc + size)
        if mode == REL:
            if final and not -128 <= delta <= 127:
                raise AsmError("%s out of range by %d bytes" % (upper, delta))
            return bytes([opcode, delta & 0xFF])
        return bytes([opcode, delta & 0xFF, (delta >> 8) & 0xFF])

    # -- directives --------------------------------------------------------------

    def _directive(self, name, operand, final):
        if name == ".ORG":
            self.pc = self._value(operand, final)
            return None
        if name in (".DB", ".BYTE"):
            return bytes(self._value(p, final) & 0xFF for p in operand.split(","))
        if name in (".DW", ".WORD"):
            out = bytearray()
            for p in operand.split(","):
                v = self._value(p, final)
                out += bytes([v & 0xFF, (v >> 8) & 0xFF])
            return bytes(out)
        if name in (".DL", ".LONG"):
            out = bytearray()
            for p in operand.split(","):
                v = self._value(p, final)
                out += bytes([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF])
            return bytes(out)
        if name == ".TEXT":
            m = re.match(r'^"(.*)"$', operand.strip())
            if not m:
                raise AsmError(".text needs a quoted string")
            return m.group(1).encode("ascii")
        if name == ".FILL":
            count, _, val = operand.partition(",")
            n = self._value(count, final)
            v = self._value(val, final) & 0xFF if val.strip() else 0
            return bytes([v]) * n
        if name == ".ASSERT_M8":
            self.m16 = False; return None
        if name == ".ASSERT_M16":
            self.m16 = True; return None
        if name == ".ASSERT_X8":
            self.x16 = False; return None
        if name == ".ASSERT_X16":
            self.x16 = True; return None
        raise AsmError("unknown directive %s" % name)


def assemble(source, origin=0x008000):
    return Assembler().assemble(source, origin)
