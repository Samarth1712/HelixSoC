# Helix HVX — ABI and Calling Conventions

This document covers the HVX-specific ABI layered on top of the standard
RISC-V ILP32 calling convention. Scalar registers (x0–x31) follow the
standard RISC-V psABI. Only HVX-specific rules are described here.

---

## Register File Summary

| Resource | Count | Width | Convention |
|---|---|---|---|
| Q0–Q7 | 8 | 128-bit | All **caller-saved** |
| ACCX | 1 | 64-bit signed | **Caller-saved** |
| x0–x31 | 32 | 32-bit | Standard RISC-V psABI |

---

## Q-Register Convention

**All Q-registers are caller-saved.** There is no callee-saved Q-register
in HVX v1. This means:

- A function that uses any Q-register may clobber it without saving it.
- A caller that needs a Q-register value preserved across a function call
  must save and restore it itself.
- There is no expectation that a called function preserves any Q-register.

This matches the ESP32-S3 PIE extension convention and keeps the coprocessor
state machine simple — there is no need to detect which Q-registers a function
uses in order to generate a callee prologue.

### Saving Q-registers across a call

```c
#include "helix_vec_asm.h"

// 16-byte aligned scratch buffers for Q-register save/restore
// Must be 16-byte aligned: use __attribute__((aligned(16)))
static int8_t q0_save[16] __attribute__((aligned(16)));
static int8_t q1_save[16] __attribute__((aligned(16)));

void outer(const int8_t *data) {
    // Save Q0, Q1 before calling a function that may clobber them
    hvx_vst(0, q0_save);
    hvx_vst(1, q1_save);

    some_function_that_uses_hvx(data);   // may clobber Q0-Q7 and ACCX

    // Restore Q0, Q1
    hvx_vld(0, q0_save);
    hvx_vld(1, q1_save);

    // ACCX was also clobbered — re-initialize before using it
    hvx_vclracc();
}
```

For stack-allocated save buffers, ensure 16-byte alignment:

```c
void outer_stack_save(void) {
    // GCC aligned stack allocation
    int8_t q0_save[16] __attribute__((aligned(16)));

    hvx_vst(0, q0_save);
    some_hvx_function();
    hvx_vld(0, q0_save);
}
```

---

## ACCX Convention

**ACCX is caller-saved.** Never assume ACCX is zero on function entry.
Always call `hvx_vclracc()` before beginning a new dot-product sequence.

```c
// WRONG — assumes ACCX is zero on entry
void dot_product_wrong(const int8_t *a, const int8_t *b, int32_t *out) {
    hvx_vld(0, a);
    hvx_vld(1, b);
    hvx_vmac_s8(0, 1);          // BUG: ACCX may hold stale value from caller
    hvx_vgetacc(*out, 0);
}

// CORRECT — explicitly clears ACCX first
void dot_product_correct(const int8_t *a, const int8_t *b, int32_t *out) {
    hvx_vld(0, a);
    hvx_vld(1, b);
    hvx_vclracc();              // ACCX = 0
    hvx_vmac_s8(0, 1);
    hvx_vgetacc(*out, 0);
}
```

### VGETACC does not clear ACCX

`VGETACC` reads and shifts ACCX but does **not** reset it to zero. If you
are chaining multiple dot products where each result is read before starting
the next, you must `VCLRACC` between them:

```c
int32_t result_a, result_b;

hvx_vclracc();
hvx_vmac_s8(0, 1);
hvx_vgetacc(result_a, 7);    // reads ACCX >> 7; ACCX still holds the value

hvx_vclracc();               // REQUIRED before next accumulation
hvx_vmac_s8(2, 3);
hvx_vgetacc(result_b, 7);
```

---

## VGETACC Register Constraint

`VGETACC` writes its result to a scalar register via the PCPI `pcpi_rd`
writeback. The destination register is encoded in the 3-bit `vd` field of
the instruction, which limits it to **x0–x7** (registers 0 through 7).

In the standard RISC-V ABI, the x0–x7 registers are:

| Register | ABI name | Role |
|---|---|---|
| x0 | zero | Always zero (writes ignored) |
| x1 | ra | Return address |
| x2 | sp | Stack pointer |
| x3 | gp | Global pointer |
| x4 | tp | Thread pointer |
| x5 | t0 | Temporary |
| x6 | t1 | Temporary |
| x7 | t2 | Temporary |

**Usable destinations for VGETACC:** x5 (t0), x6 (t1), x7 (t2).

x0 discards the result. x1, x2, x3, x4 are architectural registers that
should not be used as general temporaries in most code.

**Use an explicit register attribute to constrain GCC's allocation:**

```c
// Safe — t0 is x5, within the x0-x7 range
register int32_t result asm("t0");
hvx_vgetacc(result, 7);

// Safe — t1 is x6
register int32_t result asm("t1");
hvx_vgetacc(result, 7);

// DANGEROUS — a0 is x10, outside x0-x7; hardware will write to wrong register
register int32_t result asm("a0");
hvx_vgetacc(result, 7);   // BUG: instruction encodes rd=2 (x2=sp), not x10
```

**Recommended pattern for functions returning a VGETACC result:**

```c
int32_t fir16_s8(const int8_t *samples, const int8_t *coeffs) {
    register int32_t result asm("t0");   // x5 — safe for VGETACC

    hvx_vld(0, samples);
    hvx_vld(1, coeffs);
    hvx_vclracc();
    hvx_vmac_s8(0, 1);
    hvx_vgetacc(result, 7);

    return result;   // GCC emits mv a0, t0 to place result in return register
}
```

This limitation is architectural (v1 encoding). It will be resolved in a
future encoding revision that uses a 5-bit rd field.

---

## Interrupt Handling

**Q-registers and ACCX are not saved by PicoRV32 on interrupt entry.** The
hardware saves only the scalar register file (x1–x31) via the IRQ Q-registers
mechanism. If an interrupt service routine (ISR) uses any HVX instruction,
it must manually save and restore the full HVX state.

### ISR that uses HVX

```c
// 16-byte aligned save areas in .bss or on an interrupt stack
static int8_t  isr_q_save[8][16] __attribute__((aligned(16)));  // Q0-Q7
static int32_t isr_accx_lo __attribute__((aligned(4)));

void __attribute__((interrupt)) hvx_isr(void) {
    // 1. Save ACCX — use VGETACC with shift=0 to read current value
    //    Store into isr_accx_lo (lower 32 bits; upper bits lost if > INT32_MAX)
    //    For full 64-bit save, use two VGETACC calls with appropriate shifts.
    register int32_t accx_saved asm("t0");
    hvx_vgetacc(accx_saved, 0);
    isr_accx_lo = accx_saved;

    // 2. Save all Q-registers that the ISR will use
    hvx_vst(0, isr_q_save[0]);
    hvx_vst(1, isr_q_save[1]);
    // ... save only the ones the ISR touches, or all 8 for safety

    // --- ISR body ---
    // ... HVX operations here ...

    // 3. Restore Q-registers
    hvx_vld(0, isr_q_save[0]);
    hvx_vld(1, isr_q_save[1]);

    // 4. Restore ACCX:
    //    Load the saved scalar value into a Q-register lane, then VMAC with 1.
    //    This is approximate — full 64-bit ACCX restore requires more work.
    //    For most ISR cases, a VCLRACC followed by re-accumulating is cleaner.
    hvx_vclracc();
    // If ACCX must be exactly restored, use a dedicated restore routine.
}
```

**Recommendation:** If your ISR uses HVX, keep it short and either:
- Avoid any HVX instructions that read ACCX (VMAC, VGETACC) in the ISR, or
- Treat ACCX as destroyed by the ISR and require the main loop to re-initialize
  it after any ISR that uses HVX.

The cleanest design is to keep ISRs HVX-free and use HVX only in non-interruptible
sections or cooperative task contexts.

---

## Memory Alignment

All HVX vector memory operations require **16-byte aligned addresses**. The
LSU hardware masks the lower 4 address bits (`addr & ~0xF`), so an unaligned
address silently accesses the aligned block containing it. This is not an error
in hardware but will produce wrong data.

**Aligning buffers in C:**

```c
// Static allocation
int8_t coeffs[16] __attribute__((aligned(16)));
int8_t samples[32] __attribute__((aligned(16)));  // 2 blocks of 16

// Dynamic allocation — use aligned_alloc or posix_memalign
int8_t *buf = aligned_alloc(16, 64);   // 64 bytes, 16-byte aligned

// Stack allocation
int8_t stack_buf[16] __attribute__((aligned(16)));
```

**Linker script note:** The provided `helix.ld` places `.data` and `.bss`
sections at 4-byte aligned boundaries by default. If your HVX buffers are
in BSS or data, add explicit alignment annotations as shown above. Global
arrays with `__attribute__((aligned(16)))` will be correctly aligned by GCC.

---

## Stack Frame Conventions

HVX does not change the scalar stack frame layout. The standard RISC-V ILP32
ABI applies for scalar registers. Q-register saves go into caller-allocated
stack space (16-byte aligned), not into the callee's frame.

**Stack alignment:** RISC-V ILP32 requires 16-byte stack alignment at all
public function entry points. Since HVX save buffers are 16 bytes each, this
alignment is naturally compatible — a stack save of one Q-register does not
break alignment.

---

## Inline Asm Ordering

GCC cannot see Q-register liveness through the `helix_vec_asm.h` macros.
The `"memory"` clobber prevents reordering across memory operations, but two
consecutive HVX arithmetic instructions with a data dependency may be reordered
relative to each other if GCC's optimizer cannot determine the dependency.

**In practice this is rarely a problem** because HVX instructions always
complete before the next RISC-V instruction is issued (the CPU is stalled via
`pcpi_wait`). The ordering concern is at the GCC IR level — if you load data
into Q-registers and then immediately use them, GCC should not reorder the loads
after the arithmetic.

To be safe for dependency-critical sequences, use a single `asm volatile`
block or ensure the sequence appears in the same basic block with no
intervening control flow.
