/*
 * helix_vec_asm.h — Helix Vector ISA Assembler Macros
 * =====================================================
 * Usage: include this header in firmware C files.
 * Requires GCC cross-compiler for RISC-V: riscv32-unknown-elf-gcc
 *
 * Custom-1 opcode encoding (7'b0101011 = 0x2B):
 *   [31:27] op_id   [26:25] ewidth  [24:23] 0
 *   [22:20] vs2     [19:18] 0       [17:15] vs1
 *   [14:12] funct3  [11:10] 0       [9:7]   vd
 *   [6:0]   0x2B
 *
 * The GCC .insn directive is used to emit custom instructions without
 * patching binutils. Syntax: .insn r OPCODE, FUNCT3, FUNCT7, RD, RS1, RS2
 * We repurpose the funct7 field for {op_id[4:0], ewidth[1:0]}.
 *
 * NOTE: scalar register arguments (rs1, rs2) carry addresses/immediates.
 *       Q-register numbers (0-7) are encoded directly as small integers.
 *       They map to the lower 3 bits of the rd/rs1/rs2 fields respectively.
 *
 * To assemble a file using these macros:
 *   riscv32-unknown-elf-gcc -march=rv32imc -O2 -I. your_file.c
 *       -o your_file.elf
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
 * Instruction word assembly macro
 * Build the 32-bit encoding at preprocessor time (compile-time constant).
 *
 *  bits [31:27] = opid  (5 bits)
 *  bits [26:25] = ew    (2 bits)
 *  bits [24:23] = 0
 *  bits [22:20] = vs2   (3 bits)
 *  bits [19:18] = 0
 *  bits [17:15] = vs1   (3 bits)
 *  bits [14:12] = funct3(3 bits)
 *  bits [11:10] = 0
 *  bits  [9: 7] = vd    (3 bits)
 *  bits  [6: 0] = 0x2B
 * ---------------------------------------------------------------------- */
#define HVX_INSN(opid, ew, vs2, vs1, funct3, vd)  \
    ( ((uint32_t)(opid)   << 27) | \
      ((uint32_t)(ew)     << 25) | \
      ((uint32_t)(vs2)    << 20) | \
      ((uint32_t)(vs1)    << 15) | \
      ((uint32_t)(funct3) << 12) | \
      ((uint32_t)(vd)     <<  7) | \
      HVX_OPCODE )

/* -------------------------------------------------------------------------
 * .insn emission helper
 * GCC inline asm with .insn r  opcode, funct3, funct7, rd, rs1, rs2
 * We encode:  rd=vd, rs1=vs1, rs2=vs2  (all as register numbers 0-7)
 *             funct7 repurposed as {opid[4:0], ew[1:0]}  (7 bits total)
 * ---------------------------------------------------------------------- */
#define _HVX_FUNCT7(opid, ew)   (((opid) << 2) | (ew))

/*
 * HVX_EMIT_RR: emit a Q×Q→Q arithmetic/MAC instruction
 * vd, vs1, vs2: Q-register indices (0-7)
 * No scalar register input or output.
 */
#define HVX_EMIT_RR(opid, ew, funct3, vd, vs1, vs2)          \
    __asm__ volatile (                                         \
        ".insn r %[op], %[f3], %[f7], x%[rd], x%[r1], x%[r2]" \
        :                                                      \
        : [op] "i" (HVX_OPCODE),                              \
          [f3] "i" (funct3),                                   \
          [f7] "i" (_HVX_FUNCT7(opid, ew)),                   \
          [rd] "i" (vd),                                       \
          [r1] "i" (vs1),                                      \
          [r2] "i" (vs2)                                       \
        : "memory"                                             \
    )

/*
 * HVX_EMIT_LOAD: VLD.128  vd, [rs1_reg]
 * rs1_reg: C variable holding the base address (any scalar register)
 */
#define HVX_EMIT_LOAD(vd, rs1_reg)                            \
    __asm__ volatile (                                         \
        ".insn r %[op], %[f3], %[f7], x%[rd], %[r1], x0"    \
        :                                                      \
        : [op] "i" (HVX_OPCODE),                              \
          [f3] "i" (HVX_CAT_LOAD),                            \
          [f7] "i" (_HVX_FUNCT7(HVX_OP_VLD128, HVX_EW_8)),   \
          [rd] "i" (vd),                                       \
          [r1] "r" (rs1_reg)                                   \
        : "memory"                                             \
    )

/*
 * HVX_EMIT_STORE: VST.128  vs2, [rs1_reg]
 */
#define HVX_EMIT_STORE(vs2, rs1_reg)                          \
    __asm__ volatile (                                         \
        ".insn r %[op], %[f3], %[f7], x0, %[r1], x%[r2]"    \
        :                                                      \
        : [op] "i" (HVX_OPCODE),                              \
          [f3] "i" (HVX_CAT_STORE),                           \
          [f7] "i" (_HVX_FUNCT7(HVX_OP_VST128, HVX_EW_8)),   \
          [r1] "r" (rs1_reg),                                  \
          [r2] "i" (vs2)                                       \
        : "memory"                                             \
    )

/*
 * HVX_EMIT_MOVS: broadcast scalar to all lanes of vd
 * ew: element width selector  rs1_reg: scalar value to broadcast
 */
#define HVX_EMIT_MOVS(ew, vd, rs1_reg)                        \
    __asm__ volatile (                                         \
        ".insn r %[op], %[f3], %[f7], x%[rd], %[r1], x0"    \
        :                                                      \
        : [op] "i" (HVX_OPCODE),                              \
          [f3] "i" (HVX_CAT_MISC),                            \
          [f7] "i" (_HVX_FUNCT7(HVX_OP_VMOVS, ew)),          \
          [rd] "i" (vd),                                       \
          [r1] "r" (rs1_reg)                                   \
        : "memory"                                             \
    )

/*
 * HVX_EMIT_GETACC: result = sat32(ACCX >> shift)
 * shift: C variable (any scalar register)
 * result: C lvalue receiving pcpi_rd writeback via rd register
 * NOTE: GCC will allocate a general-purpose register for result;
 *       the coprocessor writes it via pcpi_rd → x[rd] writeback.
 */
#define HVX_EMIT_GETACC(result, shift)                        \
    __asm__ volatile (                                         \
        ".insn r %[op], %[f3], %[f7], %[rd], x0, %[r2]"     \
        : [rd] "=r" (result)                                  \
        : [op] "i" (HVX_OPCODE),                              \
          [f3] "i" (HVX_CAT_MAC),                             \
          [f7] "i" (_HVX_FUNCT7(HVX_OP_VGETACC, HVX_EW_8)), \
          [r2] "r" (shift)                                     \
        : "memory"                                             \
    )

/* -------------------------------------------------------------------------
 * Convenience wrappers — named after the ISA mnemonics
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
#define hvx_vmulh_s16(vd,vs1, vs2) HVX_EMIT_RR(HVX_OP_VMULH, HVX_EW_16, HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vabs_s16(vd, vs1)      HVX_EMIT_RR(HVX_OP_VABS,  HVX_EW_16, HVX_CAT_ARITH, vd, vs1, 0)

/* Arithmetic — int32 */
#define hvx_vadd_s32(vd, vs1, vs2) HVX_EMIT_RR(HVX_OP_VADD,  HVX_EW_32, HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vsub_s32(vd, vs1, vs2) HVX_EMIT_RR(HVX_OP_VSUB,  HVX_EW_32, HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vmin_s32(vd, vs1, vs2) HVX_EMIT_RR(HVX_OP_VMIN,  HVX_EW_32, HVX_CAT_ARITH, vd, vs1, vs2)
#define hvx_vmax_s32(vd, vs1, vs2) HVX_EMIT_RR(HVX_OP_VMAX,  HVX_EW_32, HVX_CAT_ARITH, vd, vs1, vs2)

/* Load / Store */
#define hvx_vld(vd, addr_ptr)      HVX_EMIT_LOAD(vd, (uint32_t)(addr_ptr))
#define hvx_vst(vs2, addr_ptr)     HVX_EMIT_STORE(vs2, (uint32_t)(addr_ptr))

/* Misc */
#define hvx_vmovs_s8(vd,  scalar)  HVX_EMIT_MOVS(HVX_EW_8,  vd, (uint32_t)(scalar))
#define hvx_vmovs_s16(vd, scalar)  HVX_EMIT_MOVS(HVX_EW_16, vd, (uint32_t)(scalar))
#define hvx_vmovs_s32(vd, scalar)  HVX_EMIT_MOVS(HVX_EW_32, vd, (uint32_t)(scalar))
#define hvx_vmov(vd, vs1)          HVX_EMIT_RR(HVX_OP_VMOV,   HVX_EW_8, HVX_CAT_MISC, vd, vs1, 0)

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
 *       int32_t result;
 *       hvx_vld(1, samples);      // Q1 = 16 input samples
 *       hvx_vld(2, coeffs);       // Q2 = 16 coefficients
 *       hvx_vclracc();             // ACCX = 0
 *       hvx_vmac_s8(1, 2);         // ACCX += dot(Q1, Q2)
 *       hvx_vgetacc(result, 7);    // result = ACCX >> 7 (Q7 fixed-point scale)
 *       return result;
 *   }
 * ---------------------------------------------------------------------- */

#endif /* HELIX_VEC_ASM_H */
