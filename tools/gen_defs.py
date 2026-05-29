#!/usr/bin/env python3
"""
gen_defs.py — Helix SoC constant generator
===========================================
Single source of truth for all HVX instruction encoding constants.
Generates both:
  rtl/helix_vec_defs.svh       — SystemVerilog `define macros for RTL
  sw/include/helix_vec_defs.h  — C #define macros for firmware

Run from repo root:
  python tools/gen_defs.py

Or via make:
  make defs

Never edit the generated files directly. All changes go here.

ADDING A NEW CONSTANT:
  1. Add an entry to CONSTANTS below.
  2. Run python tools/gen_defs.py.
  3. Commit gen_defs.py and both generated files together.

ADDING A NEW INSTRUCTION:
  1. Add op_id constant(s) to CONSTANTS.
  2. Add a row to FIELD_MACROS_SVH if a new field extraction is needed.
  3. Add the encoding to HVX_INSN_EXAMPLES for documentation.
  4. Regenerate.
"""

import os
import sys
from datetime import date

# ---------------------------------------------------------------------------
# Constant table
# Each entry: (name, value, svh_width, description)
#   name      — constant name, used in both generated files
#   value     — integer value
#   svh_width — bit width for SystemVerilog literal (None = plain integer)
#   description — comment emitted in both files
# ---------------------------------------------------------------------------
CONSTANTS = [
    # Opcode
    ("HVX_OPCODE",     0x2B, 7,    "RISC-V custom-1 opcode"),

    # Vector register file
    ("HVX_VLEN",       128,  None, "vector register width in bits"),
    ("HVX_NQREGS",     8,    None, "number of Q-registers (Q0-Q7)"),

    # Element widths (ew field, bits [26:25])
    (None, None, None, "--- Element widths (ew field [26:25]) ---"),
    ("HVX_EW_8",       0,    2,    "16 lanes of int8  (128/8)"),
    ("HVX_EW_16",      1,    2,    "8 lanes of int16 (128/16)"),
    ("HVX_EW_32",      2,    2,    "4 lanes of int32 (128/32)"),

    # funct3 categories (bits [14:12])
    (None, None, None, "--- funct3 categories (bits [14:12]) ---"),
    ("HVX_CAT_ARITH",  0,    3,    "add, sub, min, max, mul, bitwise, abs"),
    ("HVX_CAT_SHIFT",  1,    3,    "vshl, vshr (reserved v2)"),
    ("HVX_CAT_LOAD",   2,    3,    "vld.128"),
    ("HVX_CAT_STORE",  3,    3,    "vst.128"),
    ("HVX_CAT_MAC",    4,    3,    "vmac, vclracc, vgetacc"),
    ("HVX_CAT_MISC",   5,    3,    "vmovs (broadcast scalar), vmov"),

    # op_id — Arithmetic (CAT_ARITH, bits [31:27])
    (None, None, None, "--- op_id: Arithmetic (funct3=CAT_ARITH) ---"),
    ("HVX_OP_VADD",    0,    5,    "saturating signed add"),
    ("HVX_OP_VSUB",    1,    5,    "saturating signed sub"),
    ("HVX_OP_VMIN",    2,    5,    "element-wise min (signed)"),
    ("HVX_OP_VMAX",    3,    5,    "element-wise max (signed)"),
    ("HVX_OP_VMUL",    4,    5,    "multiply, keep lower half (wrapping)"),
    ("HVX_OP_VMULH",   5,    5,    "multiply, keep upper half (signed)"),
    ("HVX_OP_VAND",    6,    5,    "bitwise AND"),
    ("HVX_OP_VOR",     7,    5,    "bitwise OR"),
    ("HVX_OP_VXOR",    8,    5,    "bitwise XOR"),
    ("HVX_OP_VABS",    9,    5,    "absolute value (saturating)"),

    # op_id — MAC (CAT_MAC)
    # Note: HVX_OP_VMAC=0 shares value with HVX_OP_VADD=0.
    # They are disambiguated at runtime by funct3.
    (None, None, None, "--- op_id: MAC (funct3=CAT_MAC) ---"),
    ("HVX_OP_VMAC",    0,    5,    "ACCX += sum_i(vs1[i]*vs2[i]), signed"),
    ("HVX_OP_VCLRACC", 1,    5,    "ACCX = 0"),
    ("HVX_OP_VGETACC", 2,    5,    "rd = sat32(ACCX >> rs2[5:0])"),

    # op_id — Load/Store
    (None, None, None, "--- op_id: Load/Store (funct3=CAT_LOAD/CAT_STORE) ---"),
    ("HVX_OP_VLD128",  0,    5,    "vd = mem[rs1 & ~0xF]  (16-byte aligned)"),
    ("HVX_OP_VST128",  0,    5,    "mem[rs1 & ~0xF] = vs2"),

    # op_id — Misc (CAT_MISC)
    (None, None, None, "--- op_id: Misc (funct3=CAT_MISC) ---"),
    ("HVX_OP_VMOVS",   0,    5,    "vd = broadcast(rs1[elem_width-1:0])"),
    ("HVX_OP_VMOV",    1,    5,    "vd = vs1"),
]

# ---------------------------------------------------------------------------
# SVH-only field extraction macros (not valid C, not generated into .h)
# ---------------------------------------------------------------------------
FIELD_MACROS_SVH = [
    ("HVX_VD(insn)",     "insn[9:7]",   "destination Q-register index"),
    ("HVX_VS1(insn)",    "insn[17:15]", "source Q-register 1 index"),
    ("HVX_VS2(insn)",    "insn[22:20]", "source Q-register 2 index"),
    ("HVX_FUNCT3(insn)", "insn[14:12]", "operation category"),
    ("HVX_EWIDTH(insn)", "insn[26:25]", "element width selector"),
    ("HVX_OPID(insn)",   "insn[31:27]", "operation identifier"),
]

# ---------------------------------------------------------------------------
# Output paths (relative to repo root, where this script is run from)
# ---------------------------------------------------------------------------
OUT_SVH  = os.path.join("rtl", "helix_vec_defs.svh")
OUT_H    = os.path.join("sw", "include", "helix_vec_defs.h")

GENERATED_WARNING = "AUTO-GENERATED by tools/gen_defs.py — do not edit directly."
REGEN_CMD         = "Run: python tools/gen_defs.py  (from repo root)"

# ---------------------------------------------------------------------------
# Generators
# ---------------------------------------------------------------------------

def svh_literal(value, width):
    """Format a value as a SystemVerilog sized literal."""
    if width is None:
        return str(value)
    return f"{width}'d{value}"


def generate_svh():
    today = date.today().isoformat()
    lines = []
    lines.append("// " + "=" * 77)
    lines.append("// helix_vec_defs.svh — Helix SoC Vector Extension Definitions")
    lines.append("// " + "=" * 77)
    lines.append(f"// {GENERATED_WARNING}")
    lines.append(f"// {REGEN_CMD}")
    lines.append(f"// Generated: {today}")
    lines.append("//")
    lines.append("// Opcode space: RISC-V custom-1  (7'b0101011 = 0x2B)")
    lines.append("// PicoRV32 uses custom-0        (7'b0001011 = 0x0B) for IRQ — no conflict.")
    lines.append("//")
    lines.append("// Instruction word layout (32-bit R-type derived):")
    lines.append("//  [31:27]  op_id     — operation within category (5 bits)")
    lines.append("//  [26:25]  ewidth    — element width: 00=int8, 01=int16, 10=int32")
    lines.append("//  [24:23]  2'b00     — reserved, must be zero")
    lines.append("//  [22:20]  vs2[2:0]  — source vector reg 2")
    lines.append("//  [19:18]  2'b00     — reserved, must be zero")
    lines.append("//  [17:15]  vs1[2:0]  — source vector reg 1")
    lines.append("//  [14:12]  funct3    — operation category")
    lines.append("//  [11:10]  2'b00     — reserved, must be zero")
    lines.append("//   [9:7]   vd[2:0]   — destination vector reg")
    lines.append("//   [6:0]   7'b0101011 — custom-1 opcode")
    lines.append("// " + "=" * 77)
    lines.append("")
    lines.append("`ifndef HELIX_VEC_DEFS_SVH")
    lines.append("`define HELIX_VEC_DEFS_SVH")
    lines.append("")

    # Constants
    lines.append("// " + "-" * 77)
    lines.append("// Constants")
    lines.append("// " + "-" * 77)
    for entry in CONSTANTS:
        name, value, width, desc = entry
        if name is None:
            lines.append("")
            lines.append(f"// {desc}")
            continue
        lit = svh_literal(value, width)
        lines.append(f"`define {name:<20} {lit:<12} // {desc}")

    lines.append("")

    # Field extraction macros
    lines.append("// " + "-" * 77)
    lines.append("// Instruction field extraction (apply to a 32-bit insn word)")
    lines.append("// " + "-" * 77)
    for macro, expr, desc in FIELD_MACROS_SVH:
        lines.append(f"`define {macro:<25} {expr:<15} // {desc}")

    lines.append("")
    lines.append("`endif // HELIX_VEC_DEFS_SVH")
    lines.append("")

    return "\n".join(lines)


def generate_h():
    today = date.today().isoformat()
    lines = []
    lines.append("/*")
    lines.append(" * helix_vec_defs.h — Helix SoC Vector Extension Definitions (C/firmware)")
    lines.append(" * " + "=" * 75)
    lines.append(f" * {GENERATED_WARNING}")
    lines.append(f" * {REGEN_CMD}")
    lines.append(f" * Generated: {today}")
    lines.append(" *")
    lines.append(" * Mirror of rtl/helix_vec_defs.svh for firmware use.")
    lines.append(" * Include this header via helix_vec_asm.h — do not include directly.")
    lines.append(" */")
    lines.append("")
    lines.append("#ifndef HELIX_VEC_DEFS_H")
    lines.append("#define HELIX_VEC_DEFS_H")
    lines.append("")

    lines.append("/* " + "-" * 75 + " */")
    lines.append("/* Constants                                                                  */")
    lines.append("/* " + "-" * 75 + " */")
    lines.append("")

    for entry in CONSTANTS:
        name, value, width, desc = entry
        if name is None:
            lines.append(f"/* {desc} */")
            continue
        # Use hex only for the opcode; everything else is clearer as decimal
        if "OPCODE" in name:
            val_str = f"0x{value:02X}"
        else:
            val_str = str(value)
        lines.append(f"#define {name:<20} {val_str:<6}  /* {desc} */")

    lines.append("")
    lines.append("#endif /* HELIX_VEC_DEFS_H */")
    lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Consistency checks run before writing any file
# ---------------------------------------------------------------------------

def check_consistency():
    """
    Validate the constant table for common mistakes.
    Aborts with an error message if anything looks wrong.
    """
    errors = []
    names_seen = {}

    for entry in CONSTANTS:
        name, value, width, desc = entry
        if name is None:
            continue  # separator

        # Duplicate name check
        if name in names_seen:
            prev_val = names_seen[name]
            if prev_val != value:
                errors.append(
                    f"CONFLICT: '{name}' defined as {prev_val} and {value} — "
                    f"values differ. Shared op_ids across categories are allowed "
                    f"only when values are identical."
                )
            # Same-value duplicates are allowed (e.g. HVX_OP_VMAC=0 == HVX_OP_VADD=0)
        else:
            names_seen[name] = value

        # Width sanity
        if width is not None:
            max_val = (1 << width) - 1
            if value > max_val:
                errors.append(
                    f"OVERFLOW: '{name}' = {value} does not fit in {width} bits "
                    f"(max {max_val})"
                )
            if value < 0:
                errors.append(f"NEGATIVE: '{name}' = {value} — unsigned only")

    # Check opcode is correct
    if "HVX_OPCODE" in names_seen and names_seen["HVX_OPCODE"] != 0x2B:
        errors.append(f"OPCODE: HVX_OPCODE must be 0x2B, got {names_seen['HVX_OPCODE']:#x}")

    if errors:
        print("gen_defs.py: consistency check FAILED:")
        for e in errors:
            print(f"  ERROR: {e}")
        sys.exit(1)

    print(f"gen_defs.py: consistency check passed ({len(names_seen)} unique constants)")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def write_file(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)
    print(f"gen_defs.py: wrote {path}")


def main():
    print(f"gen_defs.py: generating HVX constant definitions")

    check_consistency()

    svh_content = generate_svh()
    h_content   = generate_h()

    write_file(OUT_SVH, svh_content)
    write_file(OUT_H,   h_content)

    print("gen_defs.py: done")
    print(f"  {OUT_SVH}")
    print(f"  {OUT_H}")
    print("")
    print("Next steps:")
    print("  1. Update helix_vec_asm.h to #include \"helix_vec_defs.h\"")
    print("     instead of defining constants directly.")
    print("  2. Add 'make defs' as a prerequisite to your sim/Makefile targets.")


if __name__ == "__main__":
    main()
