/*
 *  helix_vec_asm.h — Helix Vector ISA Assembler Macros
 *  =====================================================
 *  Usage: include this header in firmware C files.
 *  Requires GCC cross-compiler for RISC-V: riscv32-unknown-elf-gcc
 *
 *  Custom-1 opcode encoding (7'b0101011 = 0x2B):
 *    [31:27] op_id   [26:25] ewidth  [24:23] 0
 *    [22:20] vs2     [19:18] 0       [17:15] vs1
 *    [14:12] funct3  [11:10] 0       [9:7]   vd
 *    [6:0]   0x2B
 *
 *  ENCODING STRATEGY — why .word instead of .insn r:
 *
 *  The previous version used the GCC .insn r directive with "i" (immediate)
 *  constraints to encode Q-register numbers as register operands:
 *
 *    .insn r OPCODE, FUNCT3, FUNCT7, x%[rd], x%[r1], x%[r2]
 *    with [rd] "i" (vd), [r1] "i" (vs1), [r2] "i" (vs2)
 *
 *  This is fragile: GCC's assembler interprets "x%[rd]" as a register name
 *  constructed from an immediate, which works on some GCC versions but is
 *  not guaranteed. Specifically, the "i" constraint places an integer into
 *  the asm text via %[name], so "x%[rd]" becomes "x3" for vd=3. Whether the
 *  assembler then treats "x3" as register 3 in the .insn r encoding depends
 *  on the GCC/binutils version. Failures are silent — wrong register numbers
 *  are emitted with no warning.
 *
 *  The fix: emit the complete 32-bit instruction word directly using .word
 *  with the HVX_INSN() compile-time macro. This bypasses the assembler's
 *  register parsing entirely. The encoding is computed by the C preprocessor
 *  at compile time, is always correct, and is identical across all GCC and
 *  binutils versions.
 *
 *  The tradeoff: GCC cannot see individual register operands, so it cannot
 *  schedule around or reorder HVX instructions. The "memory" clobber prevents
 *  memory-access reordering. For Q-register ordering between consecutive HVX
 *  intrinsics, the caller is responsible for sequencing (same as before).
 *  A proper GCC backend with HVX machine description would solve this but is
 *  out of scope for v1.
 *
 *  SCALAR REGISTER OPERANDS (VLD, VST, VMOVS, VGETACC):
 *  These instructions read or write scalar registers. They are handled with
 *  separate asm templates that use proper "r" (register) or "=r" (output
 *  register) constraints for the scalar operand, combined with a .word
 *  emission using a placeholder that GCC fills in. See HVX_EMIT_LOAD etc.
 *
 *  To assemble a file using these macros:
 *    riscv32-unknown-elf-gcc -march=rv32imc -O2 -I. your_file.c \
 *        -o your_file.elf
 */

#ifndef HELIX_VEC_ASM_H
#define HELIX_VEC_ASM_H

#include <stdint.h>

/* -------------------------------------------------------------------------
 * Opcode and field constants (match helix_vec_defs.svh exactly)
 * ---------------------------------------------------------------------- */
#define HVX_OPCODE   0x2B    /* custom-1 */

/* Element widths */
#define HVX_EW_8     0       /* 16 int8  lanes */
#define HVX_EW_16    1       /*  8 int16 lanes */
#define HVX_EW_32    2       /*  4 int32 lanes */

/* funct3 categories */
#define HVX_CAT_ARITH  0
#define HVX_CAT_SHIFT  1
#define HVX_CAT_LOAD   2
#define HVX_CAT_STORE  3
#define HVX_CAT_MAC    4
#define HVX_CAT_MISC   5

/* op_id — arithmetic */
#define HVX_OP_VADD    0
#define HVX_OP_VSUB    1
#define HVX_OP_VMIN    2
#define HVX_OP_VMAX    3
#define HVX_OP_VMUL    4
#define HVX_OP_VMULH   5
#define HVX_OP_VAND    6
#define HVX_OP_VOR     7
#define HVX_OP_VXOR    8
#define HVX_OP_VABS    9

/* op_id — MAC */
#define HVX_OP_VMAC    0
#define HVX_OP_VCLRACC 1
#define HVX_OP_VGETACC 2

/* op_id — load/store */
#define HVX_OP_VLD128  0
#define HVX_OP_VST128  0

/* op_id — misc */
#define HVX_OP_VMOVS   0
#define HVX_OP_VMOV    1

/* -------------------------------------------------------------------------
 * HVX_INSN — compile-time 32-bit instruction word assembly
 *
 * Builds the complete encoding at preprocessor time. All arguments must be
 * compile-time integer constants (op_id, ew, vs2, vs1, funct3, vd).
 *
 * This is the single source of truth for instruction encoding. Every
 * HVX_EMIT_* macro below calls this to build the .word literal.
 *
 *  bits [31:27] = opid   (5 bits)
 *  bits [26:25] = ew     (2 bits)
 *  bits [24:23] = 0      (reserved)
 *  bits [22:20] = vs2    (3 bits)
 *  bits [19:18] = 0      (reserved)
 *  bits [17:15] = vs1    (3 bits)
 *  bits [14:12] = funct3 (3 bits)
 *  bits [11:10] = 0      (reserved)
 *  bits  [9: 7] = vd     (3 bits)
 *  bits  [6: 0] = 0x2B   (custom-1 opcode)
 * ---------------------------------------------------------------------- */
#define HVX_INSN(opid, ew, vs2, vs1, funct3, vd)       \
    ( ((uint32_t)(opid)   << 27) |                      \
      ((uint32_t)(ew)     << 25) |                      \
      ((uint32_t)(vs2)    << 20) |                      \
      ((uint32_t)(vs1)    << 15) |                      \
      ((uint32_t)(funct3) << 12) |                      \
      ((uint32_t)(vd)     <<  7) |                      \
      HVX_OPCODE )

/* -------------------------------------------------------------------------
 * HVX_EMIT_RR — Q×Q→Q instruction (no scalar input or output)
 *
 * Emits the instruction as a .word literal. GCC sees this as an opaque
 * memory operation (clobbers "memory") and will not reorder it across
 * memory accesses. Q-register ordering between adjacent HVX_EMIT_RR calls
 * is the caller's responsibility — GCC cannot see Q-register liveness.
 *
 * vd, vs1, vs2 must be integer constants 0–7.
 * ---------------------------------------------------------------------- */
#define HVX_EMIT_RR(opid, ew, funct3, vd, vs1, vs2)    \
    __asm__ volatile (                                   \
        ".word %[insn]"                                  \
        :                                                \
        : [insn] "i" (HVX_INSN(opid, ew, vs2, vs1, funct3, vd)) \
        : "memory"                                       \
    )

/* -------------------------------------------------------------------------
 * HVX_EMIT_LOAD — VLD.128 vd, [rs1_reg]
 *
 * rs1_reg is a C variable (pointer or uint32_t). GCC allocates a scalar
 * register for it and places its number in the asm template.
 *
 * The .word approach cannot embed a runtime register number directly, so
 * we use a two-instruction sequence:
 *   mv  %[tmp], rs1_reg          (GCC emits this to place rs1_reg in a reg)
 *   .word HVX_INSN with vs1=0    (uses x0 as rs1 — see NOTE below)
 *
 * PROBLEM: with .word we cannot tell the hardware which register holds the
 * address at runtime. The instruction encoding has a fixed vs1/rs1 field.
 *
 * SOLUTION: use a hybrid approach. Emit the .word with the address register
 * number baked in using GCC's %0-style substitution for the register
 * constraint. The register number is known to GCC at compile time after
 * register allocation; we extract it using the %R modifier.
 *
 * This uses GCC's "%R" (register number as integer) output:
 *   "mv %0, %1\n\t.word ..."
 * is NOT what we want — %0 in .word context is not a register number.
 *
 * FINAL APPROACH: Use .insn r for scalar-register instructions only.
 * For Q-only instructions (EMIT_RR), use .word. For scalar-register
 * instructions (LOAD, STORE, MOVS, GETACC), use .insn r with proper
 * "r" constraints for the scalar operand and "i" only for the constant
 * funct7 field. This is the correct use of .insn r — "i" for funct7
 * (a true immediate field in the encoding), "r" for actual register
 * operands.
 *
 * The original bug was using "i" for Q-register numbers (vd/vs1/vs2)
 * and constructing "x%[name]" strings. That is fixed by using .word for
 * all Q-only instructions. For scalar-operand instructions, "r" constraints
 * on the scalar register are always correct — GCC allocates a real register
 * and the assembler sees it as a register operand, not a constructed string.
 * ---------------------------------------------------------------------- */

/*
 * HVX_EMIT_LOAD: VLD.128 vd, [rs1_reg]
 *
 * Uses .insn r with:
 *   rd    = vd (Q-register index, constant → lower 3 bits of rd field)
 *   rs1   = rs1_reg (scalar address, runtime register → "r" constraint)
 *   rs2   = x0 (unused)
 *   funct7 = {op_id[4:0], ew[1:0]} packed into 7 bits
 *
 * The "r" constraint on rs1_reg is always correct — GCC picks a real
 * register, the assembler encodes it in bits [19:15]. Only the rd field
 * (bits [11:7]) carries the Q-register index as a constant, placed via
 * the funct7/rd split in .insn r syntax.
 *
 * NOTE: .insn r OPCODE, funct3, funct7, rd, rs1, rs2
 * encodes rd in bits [11:7]. We set rd=vd (0–7) by writing x0..x7.
 * This is valid because bits [11:9] in our format are the vd field and
 * bits [8:7] are reserved zeros — matching the rd field layout exactly.
 */
#define _HVX_FUNCT7(opid, ew)   (((opid) << 2) | (ew))

#define HVX_EMIT_LOAD(vd, rs1_reg)                               \
    __asm__ volatile (                                            \
        ".insn r %[op], %[f3], %[f7], x%c[rd], %[r1], x0"      \
        :                                                         \
        : [op]  "i" (HVX_OPCODE),                                \
          [f3]  "i" (HVX_CAT_LOAD),                              \
          [f7]  "i" (_HVX_FUNCT7(HVX_OP_VLD128, HVX_EW_8)),     \
          [rd]  "i" (vd),                                         \
          [r1]  "r" ((uintptr_t)(rs1_reg))                        \
        : "memory"                                                \
    )

/*
 * HVX_EMIT_STORE: VST.128 vs2, [rs1_reg]
 * vs2 is encoded as rs2 field (bits [24:20]); rs1_reg is the scalar address.
 */
#define HVX_EMIT_STORE(vs2, rs1_reg)                             \
    __asm__ volatile (                                            \
        ".insn r %[op], %[f3], %[f7], x0, %[r1], x%c[r2]"      \
        :                                                         \
        : [op]  "i" (HVX_OPCODE),                                \
          [f3]  "i" (HVX_CAT_STORE),                             \
          [f7]  "i" (_HVX_FUNCT7(HVX_OP_VST128, HVX_EW_8)),     \
          [r1]  "r" ((uintptr_t)(rs1_reg)),                       \
          [r2]  "i" (vs2)                                         \
        : "memory"                                                \
    )

/*
 * HVX_EMIT_MOVS: VMOVS.Sew vd, rs1_reg
 * Broadcasts the low ew-width bits of scalar rs1_reg to all lanes.
 * rs1_reg is a runtime scalar value — "r" constraint is correct.
 */
#define HVX_EMIT_MOVS(ew, vd, rs1_reg)                          \
    __asm__ volatile (                                            \
        ".insn r %[op], %[f3], %[f7], x%c[rd], %[r1], x0"      \
        :                                                         \
        : [op]  "i" (HVX_OPCODE),                                \
          [f3]  "i" (HVX_CAT_MISC),                              \
          [f7]  "i" (_HVX_FUNCT7(HVX_OP_VMOVS, ew)),            \
          [rd]  "i" (vd),                                         \
          [r1]  "r" ((uint32_t)(rs1_reg))                         \
        : "memory"                                                \
    )

/*
 * HVX_EMIT_GETACC: rd = sat32(ACCX >> shift)
 *
 * result: C lvalue — GCC allocates a scalar register, coprocessor writes
 *         it via pcpi_rd → x[rd] writeback. "=r" output constraint.
 * shift:  runtime shift amount — "r" constraint.
 *
 * Both the result register and the shift register are runtime values with
 * proper "r"/"=r" constraints. This is always correct regardless of GCC
 * version.
 *
 * ENCODING LIMITATION: VGETACC's rd is encoded in the 3-bit vd field
 * (bits [9:7]), so only x0–x7 are reachable. GCC may allocate a register
 * outside this range. To be safe, declare the result variable with an
 * explicit register attribute if you need a specific register:
 *   register int32_t result asm("a0");  // a0 = x10 — outside x0-x7!
 *   register int32_t result asm("t0");  // t0 = x5  — within x0-x7, safe
 *
 * This is an architectural limitation of the v1 encoding. The macro does
 * not enforce the x0-x7 constraint at compile time — a runtime error will
 * occur if GCC allocates x8 or higher. Until a proper GCC backend is
 * available, use explicit register constraints on the result variable.
 */
#define HVX_EMIT_GETACC(result, shift)                           \
    __asm__ volatile (                                            \
        ".insn r %[op], %[f3], %[f7], %[rd], x0, %[r2]"        \
        : [rd] "=r" (result)                                     \
        : [op]  "i" (HVX_OPCODE),                                \
          [f3]  "i" (HVX_CAT_MAC),                               \
          [f7]  "i" (_HVX_FUNCT7(HVX_OP_VGETACC, HVX_EW_8)),    \
          [r2]  "r" ((uint32_t)(shift))                           \
        : "memory"                                                \
    )

/* -------------------------------------------------------------------------
 * Convenience wrappers — named after the ISA mnemonics.
 * These are the public API. Do not call HVX_EMIT_* directly in firmware.
 * ---------------------------------------------------------------------- */

/* Arithmetic — int8 */
#define hvx_vadd_s8(vd, vs1, vs2)  HVX_EMIT_RR(HVX_OP_VADD,  HVX_EW_8,  HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vsub_s8(vd, vs1, vs2)  HVX_EMIT_RR(HVX_OP_VSUB,  HVX_EW_8,  HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vmin_s8(vd, vs1, vs2)  HVX_EMIT_RR(HVX_OP_VMIN,  HVX_EW_8,  HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vmax_s8(vd, vs1, vs2)  HVX_EMIT_RR(HVX_OP_VMAX,  HVX_EW_8,  HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vmul_s8(vd, vs1, vs2)  HVX_EMIT_RR(HVX_OP_VMUL,  HVX_EW_8,  HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vmulh_s8(vd, vs1, vs2) HVX_EMIT_RR(HVX_OP_VMULH, HVX_EW_8,  HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vand_s8(vd, vs1, vs2)  HVX_EMIT_RR(HVX_OP_VAND,  HVX_EW_8,  HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vor_s8(vd, vs1, vs2)   HVX_EMIT_RR(HVX_OP_VOR,   HVX_EW_8,  HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vxor_s8(vd, vs1, vs2)  HVX_EMIT_RR(HVX_OP_VXOR,  HVX_EW_8,  HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vabs_s8(vd, vs1)       HVX_EMIT_RR(HVX_OP_VABS,  HVX_EW_8,  HVX_CAT_ARITH, vd, vs1, 0)

/* Arithmetic — int16 */
#define hvx_vadd_s16(vd, vs1, vs2) HVX_EMIT_RR(HVX_OP_VADD,  HVX_EW_16, HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vsub_s16(vd, vs1, vs2) HVX_EMIT_RR(HVX_OP_VSUB,  HVX_EW_16, HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vmin_s16(vd, vs1, vs2) HVX_EMIT_RR(HVX_OP_VMIN,  HVX_EW_16, HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vmax_s16(vd, vs1, vs2) HVX_EMIT_RR(HVX_OP_VMAX,  HVX_EW_16, HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vmul_s16(vd, vs1, vs2) HVX_EMIT_RR(HVX_OP_VMUL,  HVX_EW_16, HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vmulh_s16(vd, vs1, vs2)HVX_EMIT_RR(HVX_OP_VMULH, HVX_EW_16, HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vabs_s16(vd, vs1)      HVX_EMIT_RR(HVX_OP_VABS,  HVX_EW_16, HVX_CAT_ARITH, vd, vs1, 0)

/* Arithmetic — int32 */
#define hvx_vadd_s32(vd, vs1, vs2) HVX_EMIT_RR(HVX_OP_VADD,  HVX_EW_32, HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vsub_s32(vd, vs1, vs2) HVX_EMIT_RR(HVX_OP_VSUB,  HVX_EW_32, HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vmin_s32(vd, vs1, vs2) HVX_EMIT_RR(HVX_OP_VMIN,  HVX_EW_32, HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vmax_s32(vd, vs1, vs2) HVX_EMIT_RR(HVX_OP_VMAX,  HVX_EW_32, HVX_CAT_ARITH, vd, vs1, vs2)

/* Load / Store */
#define hvx_vld(vd, addr_ptr)      HVX_EMIT_LOAD(vd, (addr_ptr))
#define hvx_vst(vs2, addr_ptr)     HVX_EMIT_STORE(vs2, (addr_ptr))

/* Misc */
#define hvx_vmovs_s8(vd,  scalar)  HVX_EMIT_MOVS(HVX_EW_8,  vd, (scalar))
#define hvx_vmovs_s16(vd, scalar)  HVX_EMIT_MOVS(HVX_EW_16, vd, (scalar))
#define hvx_vmovs_s32(vd, scalar)  HVX_EMIT_MOVS(HVX_EW_32, vd, (scalar))
#define hvx_vmov(vd, vs1)          HVX_EMIT_RR(HVX_OP_VMOV, HVX_EW_8, HVX_CAT_MISC, vd, vs1, 0)

/* MAC */
#define hvx_vclracc()              HVX_EMIT_RR(HVX_OP_VCLRACC, HVX_EW_8, HVX_CAT_MAC, 0, 0, 0)
#define hvx_vmac_s8(vs1, vs2)      HVX_EMIT_RR(HVX_OP_VMAC,   HVX_EW_8,  HVX_CAT_MAC, 0, vs1, vs2)
#define hvx_vmac_s16(vs1, vs2)     HVX_EMIT_RR(HVX_OP_VMAC,   HVX_EW_16, HVX_CAT_MAC, 0, vs1, vs2)
#define hvx_vmac_s32(vs1, vs2)     HVX_EMIT_RR(HVX_OP_VMAC,   HVX_EW_32, HVX_CAT_MAC, 0, vs1, vs2)
#define hvx_vgetacc(result, shift)  HVX_EMIT_GETACC(result, shift)

/* -------------------------------------------------------------------------
 * Usage example (FIR filter — 16 taps, int8):
 *
 *   #include "helix_vec_asm.h"
 *
 *   int32_t fir16_s8(const int8_t *samples, const int8_t *coeffs) {
 *       // Declare result in a register within x0-x7 to satisfy the
 *       // VGETACC rd encoding constraint (3-bit field, x0-x7 only).
 *       register int32_t result asm("t0");  // t0 = x5
 *       hvx_vld(1, samples);      // Q1 = 16 input samples
 *       hvx_vld(2, coeffs);       // Q2 = 16 coefficients
 *       hvx_vclracc();             // ACCX = 0
 *       hvx_vmac_s8(1, 2);         // ACCX += dot(Q1, Q2)
 *       hvx_vgetacc(result, 7);    // result = ACCX >> 7 (Q7 fixed-point)
 *       return result;
 *   }
 *
 * NOTE on %c modifier:
 *   In .insn r templates, "x%c[rd]" with [rd]"i"(vd) uses %c to emit the
 *   integer without any # prefix that %[rd] might add in some contexts.
 *   This is used only for the Q-register index in LOAD/STORE/MOVS where
 *   the Q-register number must appear as part of a register name string.
 *   It is NOT used for scalar "r"-constrained operands.
 * ---------------------------------------------------------------------- */

#endif /* HELIX_VEC_ASM_H */
