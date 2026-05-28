// =============================================================================
// helix_vec_defs.svh — Helix SoC Vector Extension Definitions
// =============================================================================
// Opcode space: RISC-V custom-1  (7'b0101011 = 0x2B)
// PicoRV32 uses custom-0        (7'b0001011 = 0x0B) for IRQ — no conflict.
//
// Instruction word layout (32-bit R-type derived):
//
//  [31:27]  op_id     — specific operation within category (5 bits)
//  [26:25]  ewidth    — element width: 00=int8, 01=int16, 10=int32
//  [24:23]  2'b00     — unused (upper bits of rs2 field, held 0)
//  [22:20]  vs2[2:0]  — source vector reg 2  (lower 3 bits of rs2 [24:20])
//  [19:18]  2'b00     — unused (upper bits of rs1 field, held 0)
//  [17:15]  vs1[2:0]  — source vector reg 1  (lower 3 bits of rs1 [19:15])
//  [14:12]  funct3    — operation category
//  [11:10]  2'b00     — unused (upper bits of rd field, held 0)
//  [9:7]    vd[2:0]   — destination vector reg (lower 3 bits of rd [11:7])
//  [6:0]    7'b0101011 — custom-1 opcode
//
// NOTE: pcpi_rs1 = scalar x[rs1] value → base address for VLD/VST
//       pcpi_rs2 = scalar x[rs2] value → shift amount for VGETACC
// =============================================================================

`ifndef HELIX_VEC_DEFS_SVH
`define HELIX_VEC_DEFS_SVH

// ---------------------------------------------------------------------------
// Opcode
// ---------------------------------------------------------------------------
`define HVX_OPCODE       7'b0101011

// ---------------------------------------------------------------------------
// Instruction field extraction (apply to a 32-bit insn variable)
// ---------------------------------------------------------------------------
`define HVX_VD(insn)      insn[9:7]
`define HVX_VS1(insn)     insn[17:15]
`define HVX_VS2(insn)     insn[22:20]
`define HVX_FUNCT3(insn)  insn[14:12]
`define HVX_EWIDTH(insn)  insn[26:25]
`define HVX_OPID(insn)    insn[31:27]

// ---------------------------------------------------------------------------
// Element width selectors
// ---------------------------------------------------------------------------
`define HVX_EW_8   2'b00   // 16 lanes of int8  (128 / 8)
`define HVX_EW_16  2'b01   //  8 lanes of int16 (128 / 16)
`define HVX_EW_32  2'b10   //  4 lanes of int32 (128 / 32)

// ---------------------------------------------------------------------------
// funct3 — operation categories
// ---------------------------------------------------------------------------
`define HVX_CAT_ARITH  3'b000   // add, sub, min, max, mul, bitwise, abs
`define HVX_CAT_SHIFT  3'b001   // vshl, vshr (reserved v2)
`define HVX_CAT_LOAD   3'b010   // vld.128
`define HVX_CAT_STORE  3'b011   // vst.128
`define HVX_CAT_MAC    3'b100   // vmac, vclracc, vgetacc
`define HVX_CAT_MISC   3'b101   // vmovs (broadcast scalar), vmov

// ---------------------------------------------------------------------------
// op_id — Arithmetic (CAT_ARITH)
// ---------------------------------------------------------------------------
`define HVX_OP_VADD    5'd0   // saturating signed add
`define HVX_OP_VSUB    5'd1   // saturating signed sub
`define HVX_OP_VMIN    5'd2   // element-wise min (signed)
`define HVX_OP_VMAX    5'd3   // element-wise max (signed)
`define HVX_OP_VMUL    5'd4   // multiply, keep lower half (wrapping)
`define HVX_OP_VMULH   5'd5   // multiply, keep upper half (signed)
`define HVX_OP_VAND    5'd6   // bitwise AND
`define HVX_OP_VOR     5'd7   // bitwise OR
`define HVX_OP_VXOR    5'd8   // bitwise XOR
`define HVX_OP_VABS    5'd9   // absolute value (saturating)

// ---------------------------------------------------------------------------
// op_id — MAC (CAT_MAC)
// ---------------------------------------------------------------------------
`define HVX_OP_VMAC    5'd0   // ACCX += sum_i(vs1[i] * vs2[i]), signed
`define HVX_OP_VCLRACC 5'd1   // ACCX = 0
`define HVX_OP_VGETACC 5'd2   // rd = sat32(ACCX >> rs2[5:0])

// ---------------------------------------------------------------------------
// op_id — Load / Store (CAT_LOAD, CAT_STORE)
// ---------------------------------------------------------------------------
`define HVX_OP_VLD128  5'd0   // vd = mem[rs1 & ~0xF]  (16-byte aligned)
`define HVX_OP_VST128  5'd0   // mem[rs1 & ~0xF] = vs2

// ---------------------------------------------------------------------------
// op_id — Misc (CAT_MISC)
// ---------------------------------------------------------------------------
`define HVX_OP_VMOVS   5'd0   // vd = broadcast(rs1[elem_width-1:0])
`define HVX_OP_VMOV    5'd1   // vd = vs1

// ---------------------------------------------------------------------------
// VLEN and register count
// ---------------------------------------------------------------------------
`define HVX_VLEN   128
`define HVX_NQREGS   8        // Q0-Q7

`endif
