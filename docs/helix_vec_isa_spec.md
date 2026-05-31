# Helix SoC — Vector ISA Specification
**Version:** 1.1-draft
**Date:** 2025
**Opcode space:** RISC-V custom-1 (`7'b0101011` = `0x2B`)

**Changelog from 1.0-draft:**
- Section 5: VLD/VST stall cycles corrected from 5 to 6 (RTL trace confirmed)
- Section 2: `VGETACC` scalar `rd` encoding limitation documented (x0–x7 only)
- Section 4.2: `VSUB` INT_MIN edge case documented
- Section 4.2: `VMULH` rounding behaviour clarified (truncation toward −∞)
- Section 6: Canonical `ew` encoding for don't-care fields specified
- Section 7: `CATCH_ILLINSN` requirement clarified (not required; `ENABLE_PCPI` is)

---

## 1. Overview

The Helix Vector Extension (HVX) adds 128-bit SIMD acceleration to the PicoRV32
core via the PCPI (Pico Co-Processor Interface). It is modelled architecturally
after the ESP32-S3's PIE extension — fixed-width 128-bit Q-registers, signed
saturating arithmetic, and a dedicated multiply-accumulate path.

### 1.1 Design Goals

- 16× int8 / 8× int16 / 4× int32 parallel lanes per instruction
- Saturating signed arithmetic (no silent wraparound in DSP code)
- Dedicated 64-bit ACCX accumulator for overflow-safe dot products
- Zero modifications to the PicoRV32 core — pure PCPI attachment
- Custom-1 opcode space — no conflict with PicoRV32 IRQ instructions (custom-0)

### 1.2 Programmer's Model

| Resource | Count | Width | Notes |
|---|---|---|---|
| Q-registers | 8 | 128-bit | Q0–Q7, caller-saved |
| ACCX | 1 | 64-bit signed | Dedicated MAC accumulator |
| Scalar regs | 32 | 32-bit | Shared with PicoRV32 (x0–x31) |

Q-registers are **not visible** to the PicoRV32 register file. The only scalar
writeback is from `VGETACC`, which deposits the saturated accumulator result into
a standard `xN` register via `pcpi_rd`.

---

## 2. Instruction Encoding

All HVX instructions are 32-bit, using the RISC-V custom-1 opcode.

```
 31      27 26  25 24 23 22    20 19 18 17    15 14  12 11 10 9     7 6       0
 ┌─────────┬──────┬─────┬────────┬─────┬────────┬───────┬─────┬───────┬──────────┐
 │  op_id  │  ew  │  0  │  vs2   │  0  │  vs1   │funct3 │  0  │  vd   │ 0101011  │
 │  [4:0]  │ [1:0]│[1:0]│ [2:0]  │[1:0]│ [2:0]  │ [2:0] │[1:0]│ [2:0] │ custom-1 │
 └─────────┴──────┴─────┴────────┴─────┴────────┴───────┴─────┴───────┴──────────┘
```

**Field definitions:**

| Field | Bits | Description |
|---|---|---|
| `op_id` | [31:27] | Operation identifier within category |
| `ew` | [26:25] | Element width: `00`=int8, `01`=int16, `10`=int32 |
| `vs2` | [22:20] | Source Q-register 2 (index 0–7) |
| `vs1` | [17:15] | Source Q-register 1 (index 0–7) |
| `funct3` | [14:12] | Operation category |
| `vd` | [9:7] | Destination Q-register (index 0–7) |
| opcode | [6:0] | `0101011` (custom-1) |

Bits [24:23], [19:18], [11:10] are reserved and **must be zero**.

**Don't-care `ew` fields:** Instructions that ignore `ew` (VLD, VST, VCLRACC,
VMOV, VGETACC) must encode `ew = 2'b00` for canonical form. Assemblers must
emit `00`; decoders must not rely on this field for these instructions.

**Don't-care `vs2` / `vs1` fields:** Instructions that do not read a source
register (e.g. VABS reads only vs1; VMOVS reads only rs1) must encode unused
source fields as `3'b000`. Decoders ignore them; the canonical encoding ensures
binary compatibility across assembler versions.

**`VGETACC` scalar `rd` limitation:** The `vd` field is 3 bits (indices 0–7),
so the scalar destination register for `VGETACC` is limited to x0–x7. This is
an architectural constraint of the v1 encoding. Firmware must ensure the result
register is in this range. A future encoding revision may expand this.

For `VLD`/`VMOVS`: scalar `x[rs1]` carries the base address or broadcast value,
passed by PicoRV32 via `pcpi_rs1`.
For `VGETACC`: scalar `x[rs2]` carries the right-shift amount, passed via
`pcpi_rs2`. Limited to x0–x7 by the 3-bit `vs2` field.

---

## 3. Operation Categories (funct3)

| funct3 | Name | Description |
|---|---|---|
| `000` | ARITH | Saturating arithmetic, logical, compare |
| `001` | SHIFT | Reserved (v2) |
| `010` | LOAD | 128-bit aligned vector load |
| `011` | STORE | 128-bit aligned vector store |
| `100` | MAC | Multiply-accumulate, accumulator control |
| `101` | MISC | Scalar broadcast, register copy |

---

## 4. Instruction Reference

### 4.1 Load / Store

#### `VLD.128  vd, [rs1]`
- **funct3:** `010`  **op_id:** `00000`  **ew:** `00` (canonical)
- **Operation:** `Q[vd] = mem128[rs1 & ~0xF]`
- **Notes:** Address forced 16-byte aligned (lower 4 bits masked). `pcpi_rs1`
  carries the address. Stalls CPU for **6 cycles** (see Section 5).

#### `VST.128  vs2, [rs1]`
- **funct3:** `011`  **op_id:** `00000`  **ew:** `00` (canonical)
- **Operation:** `mem128[rs1 & ~0xF] = Q[vs2]`
- **Notes:** Same alignment constraint. `pcpi_rs1` = address. No Q-register
  writeback. Stalls CPU for **6 cycles** (see Section 5).

---

### 4.2 Arithmetic (funct3 = `000`)

All arithmetic operations execute in **3 CPU cycles** (IDLE→DECODE→EXECUTE→DONE).
Signed saturation clamps results to the element type's min/max rather than
wrapping.

| Mnemonic | op_id | Operation | Saturation |
|---|---|---|---|
| `VADD.Sew  vd, vs1, vs2` | `00000` | `vd[i] = sat(vs1[i] + vs2[i])` | Yes |
| `VSUB.Sew  vd, vs1, vs2` | `00001` | `vd[i] = sat(vs1[i] - vs2[i])` | Yes |
| `VMIN.Sew  vd, vs1, vs2` | `00010` | `vd[i] = min(vs1[i], vs2[i])` | — |
| `VMAX.Sew  vd, vs1, vs2` | `00011` | `vd[i] = max(vs1[i], vs2[i])` | — |
| `VMUL.Sew  vd, vs1, vs2` | `00100` | `vd[i] = (vs1[i]*vs2[i])[low]` | No (wraps) |
| `VMULH.Sew vd, vs1, vs2` | `00101` | `vd[i] = (vs1[i]*vs2[i])[high]` | No |
| `VAND.Sew  vd, vs1, vs2` | `00110` | `vd[i] = vs1[i] & vs2[i]` | — |
| `VOR.Sew   vd, vs1, vs2` | `00111` | `vd[i] = vs1[i] \| vs2[i]` | — |
| `VXOR.Sew  vd, vs1, vs2` | `01000` | `vd[i] = vs1[i] ^ vs2[i]` | — |
| `VABS.Sew  vd, vs1`      | `01001` | `vd[i] = sat(abs(vs1[i]))` | Yes |

**Saturation ranges:**

| Element width | Signed min | Signed max |
|---|---|---|
| int8 | −128 (`0x80`) | +127 (`0x7F`) |
| int16 | −32768 (`0x8000`) | +32767 (`0x7FFF`) |
| int32 | −2147483648 (`0x80000000`) | +2147483647 (`0x7FFFFFFF`) |

**`VABS` saturation edge case:** `abs(INT_MIN)` saturates to `INT_MAX`
(e.g. `abs(-128) = 127`, not `-128`).

**`VSUB` INT_MIN edge case:** `sat_sub(x, INT_MIN)` saturates to `INT_MAX` for
any `x ≥ 0`. The implementation subtracts using N+1-bit signed arithmetic to
avoid the overflow that would occur if INT_MIN were negated first (since
`-INT_MIN` is not representable in N bits). Examples:

| Expression | int8 result | int16 result | int32 result |
|---|---|---|---|
| `sat_sub(0, INT_MIN)` | +127 | +32767 | +2147483647 |
| `sat_sub(INT_MIN, INT_MIN)` | 0 | 0 | 0 |
| `sat_sub(127, INT_MIN)` | +127 (sat) | +32767 (sat) | +2147483647 (sat) |

**`VMUL` vs `VMULH`:** `VMUL` returns the lower N bits of the 2N-bit product
(modular). `VMULH` returns the upper N bits, which is equivalent to
`floor((a×b) / 2^N)` — truncation toward negative infinity. This introduces a
−½ LSB DC bias for negative products in fixed-point code. A rounding variant
(`VMULHR`) is planned for v2. For bias-sensitive applications, add a rounding
correction in scalar code after accumulation.

---

### 4.3 MAC Operations (funct3 = `100`)

#### `VCLRACC`
- **op_id:** `00001`  **ew:** `00` (canonical)
- **Operation:** `ACCX = 0`
- **Notes:** Must precede a new dot-product sequence. 3 cycle latency.

#### `VMAC.Sew  vs1, vs2`
- **op_id:** `00000`
- **Operation:** `ACCX += Σᵢ (Q[vs1][i] × Q[vs2][i])` (signed)
- **Notes:** All lane products are sign-extended to 64 bits before accumulation.
  No `vd` output — result only in ACCX. Safe to call repeatedly before
  `VGETACC`. 3 cycle latency.

**Maximum safe VMAC calls before ACCX overflow:**

| Element width | Single VMAC max contribution | ACCX capacity |
|---|---|---|
| int8  | 16 × 127 × 127 = 258,064 | 2⁶³ − 1 ≈ safe for ~35 trillion calls |
| int16 | 8 × 32767² ≈ 8.59×10⁹ | Safe for ~1 billion calls |
| int32 | 4 × (2³¹−1)² ≈ 1.84×10¹⁹ | **As few as 1 call can overflow** — 1.84×10¹⁹ > 2⁶³−1 ≈ 9.22×10¹⁸; call `VGETACC` every iteration |

#### `VGETACC  rd, rs2`
- **op_id:** `00010`  **ew:** `00` (canonical)
- **Operation:** `x[rd] = sat32(ACCX >> rs2[5:0])`
- **Notes:** Arithmetic (signed) right shift. Result saturated to int32. Writes
  scalar `x[rd]` via `pcpi_wr` / `pcpi_rd`. **Does not clear ACCX** — call
  `VCLRACC` if starting a new accumulation. 3 cycle latency.
  **Encoding limitation:** `rd` is encoded in the 3-bit `vd` field, restricting
  the destination to x0–x7. Firmware must target one of these registers.

**Typical fixed-point usage:**
```
# Q7.0 inputs → scale back with VGETACC shift=7
# Q15 (int16 inputs) → shift=15
# Shift range: 0–63 (rs2[5:0])
```

---

### 4.4 Misc (funct3 = `101`)

#### `VMOVS.Sew  vd, rs1`
- **op_id:** `00000`
- **Operation:** `Q[vd][i] = rs1[ew_width-1:0]` for all lanes i
- **Notes:** Broadcasts the low bits of scalar `x[rs1]` (via `pcpi_rs1`) to
  every lane. `ew` selects element width: `int8` takes `rs1[7:0]`, `int16`
  takes `rs1[15:0]`, `int32` takes `rs1[31:0]`.

#### `VMOV  vd, vs1`
- **op_id:** `00001`  **ew:** `00` (canonical)
- **Operation:** `Q[vd] = Q[vs1]`
- **Notes:** Simple Q-register copy. 3 cycles.

---

## 5. Execution Timing

| Instruction category | CPU stall cycles | Notes |
|---|---|---|
| ARITH / MISC | 3 | IDLE→DECODE→EXEC→DONE |
| MAC (VMAC, VCLRACC, VGETACC) | 3 | Same pipeline |
| VLD.128 / VST.128 | **6** | See detailed breakdown below |

**VLD/VST cycle breakdown (6 cycles total):**

```
Cycle 0  vcop S_IDLE → S_DECODE   instruction and rs1/rs2 latched
Cycle 1  vcop S_DECODE             lsu_req asserted (registered);
                                   Q-register values latched
         LSU  LSU_IDLE             lsu_req not yet visible (registered)
Cycle 2  LSU  LSU_IDLE → LSU_ACCESS addr/wdata latched, req seen
Cycle 3  LSU  LSU_ACCESS            vec_mem_en driven; SRAM sampling inputs
Cycle 4  LSU  LSU_WAIT              SRAM output valid; lsu_rdata captured
         LSU  → LSU_DONE
Cycle 5  LSU  LSU_DONE              lsu_done asserted combinationally;
         vcop S_LSU sees lsu_done=1 same cycle → S_DONE
Cycle 6  vcop S_DONE                pcpi_ready asserted combinationally
```

The `lsu_done` signal is combinational from the LSU state register
(`assign lsu_done = (state == LSU_DONE)`). This avoids a registered version
that would add one extra clock (7 cycles total).

The core is stalled (no IPC loss for other instructions) for exactly the listed
cycles. `pcpi_wait` is asserted from cycle 1 through cycle N−1; `pcpi_ready`
is pulsed for exactly one cycle at completion.

---

## 6. Instruction Encoding Table (complete)

| Mnemonic | op_id | ew | funct3 | vd | vs1 | vs2 | rs1 used | rs2 used |
|---|---|---|---|---|---|---|---|---|
| VLD.128 | 0 | 00 | 010 | ✓ | — | — | addr | — |
| VST.128 | 0 | 00 | 011 | — | — | ✓ | addr | — |
| VADD.Sew | 0 | ew | 000 | ✓ | ✓ | ✓ | — | — |
| VSUB.Sew | 1 | ew | 000 | ✓ | ✓ | ✓ | — | — |
| VMIN.Sew | 2 | ew | 000 | ✓ | ✓ | ✓ | — | — |
| VMAX.Sew | 3 | ew | 000 | ✓ | ✓ | ✓ | — | — |
| VMUL.Sew | 4 | ew | 000 | ✓ | ✓ | ✓ | — | — |
| VMULH.Sew| 5 | ew | 000 | ✓ | ✓ | ✓ | — | — |
| VAND.Sew | 6 | ew | 000 | ✓ | ✓ | ✓ | — | — |
| VOR.Sew  | 7 | ew | 000 | ✓ | ✓ | ✓ | — | — |
| VXOR.Sew | 8 | ew | 000 | ✓ | ✓ | ✓ | — | — |
| VABS.Sew | 9 | ew | 000 | ✓ | ✓ | — | — | — |
| VCLRACC  | 1 | 00 | 100 | — | — | — | — | — |
| VMAC.Sew | 0 | ew | 100 | — | ✓ | ✓ | — | — |
| VGETACC  | 2 | 00 | 100 | ✓* | — | — | — | shift† |
| VMOVS.Sew| 0 | ew | 101 | ✓ | — | — | scalar | — |
| VMOV     | 1 | 00 | 101 | ✓ | ✓ | — | — | — |

*`vd` field carries `rd` index for VGETACC; limited to x0–x7 (3-bit field).
†`vs2` field carries shift register index for VGETACC; limited to x0–x7.

**Unused fields:** Fields marked — must be encoded as zero. This is the
canonical form required for binary compatibility. Decoders ignore these fields
but encoders must zero them.

---

## 7. Worked Binary Encoding Examples

Full 32-bit encodings showing all fields including reserved zeros. These are
the reference for assembler writers and simulator implementors.

```
Format: [31:27]op_id [26:25]ew [24:23]00 [22:20]vs2 [19:18]00
        [17:15]vs1 [14:12]f3 [11:10]00 [9:7]vd [6:0]=0x2B

VLD.128  Q0, [a0]
  op_id=00000 ew=00 vs2=000 vs1=000 f3=010 vd=000
  → 0000_0_00_00_000_00_000_010_00_000_0101011
  → 0x0000_202B  (f3=010=LOAD contributes bits[14:12]=0x2000)

VST.128  [a0], Q1
  op_id=00000 ew=00 vs2=001 vs1=000 f3=011 vd=000
  → 0000_0_00_00_001_00_000_011_00_000_0101011
  → 0x0010_302B  (vs2=001 at bits[22:20], f3=011=STORE)

VADD.S8  Q2, Q0, Q1
  op_id=00000 ew=00 vs2=001 vs1=000 f3=000 vd=010
  → 0000_0_00_00_001_00_000_000_00_010_0101011
  → 0x0010_012B  (vs2=001, f3=000=ARITH, vd=010)

VMAC.S8  Q0, Q1
  op_id=00000 ew=00 vs2=001 vs1=000 f3=100 vd=000
  → 0000_0_00_00_001_00_000_100_00_000_0101011
  → 0x0010_402B  (f3=100=MAC contributes bits[14:12]=0x4000)

VCLRACC
  op_id=00001 ew=00 vs2=000 vs1=000 f3=100 vd=000
  → 0000_1_00_00_000_00_000_100_00_000_0101011
  → 0x0800_402B  (op_id bit[27]=1, f3=100=MAC)

VGETACC  x0, x2  (rd=x0, shift_reg=x2)
  op_id=00010 ew=00 vs2=010 vs1=000 f3=100 vd=000
  → 0001_0_00_00_010_00_000_100_00_000_0101011
  → 0x1020_402B  (op_id[29]=1, vs2=010, f3=100=MAC)

VMOVS.S8 Q5, a0  (broadcast a0[7:0] to all lanes)
  op_id=00000 ew=00 vs2=000 vs1=000 f3=101 vd=101
  → 0000_0_00_00_000_00_000_101_00_101_0101011
  → 0x0000_52AB  (f3=101=MISC contributes 0x5000, vd=101 contributes 0xA80)
```

---

## 8. ABI and Calling Conventions

- **Q0–Q7 are all caller-saved.** If a function uses any Q-register, it must
  save/restore them around calls it makes. There is no callee-saved convention
  for Q-registers in v1.
- **ACCX is caller-saved.** Always `VCLRACC` before beginning a new
  accumulation; never assume ACCX is zero on function entry.
- **ACCX is not automatically saved/restored on interrupts** by PicoRV32.
  If an ISR uses vector instructions, save ACCX manually by issuing `VGETACC`
  with shift=0 into a scratch register before the ISR body, and reconstruct
  with `VMAC` on return.

**Prologue/epilogue pattern for a function using Q-registers across a call:**

```c
// Caller must save any Q-registers it needs preserved across calls.
// There is no callee-save convention — the callee owns all Q-registers.

void outer(void) {
    // MUST be 16-byte aligned — VLD/VST mask lower 4 address bits,
    // so a 4-byte-aligned buffer would silently access the wrong location.
    int32_t saved_q0[4] __attribute__((aligned(16)));
    int32_t saved_q1[4] __attribute__((aligned(16)));

    // Save Q0, Q1 before calling inner()
    hvx_vst(0, saved_q0);   // VST Q0 → saved_q0
    hvx_vst(1, saved_q1);   // VST Q1 → saved_q1

    inner();                 // may clobber Q0–Q7 and ACCX

    // Restore Q0, Q1
    hvx_vld(0, saved_q0);
    hvx_vld(1, saved_q1);
    // ACCX was also clobbered — caller must VCLRACC if needed
}
```

**PicoRV32 configuration requirements:**

The following PicoRV32 parameters are hard requirements for HVX functionality.
They are enforced by assertions in `helix_picosoc.v`.

| Parameter | Required value | Reason |
|---|---|---|
| `ENABLE_PCPI` | 1 | Gates `pcpi_valid` assertion in `cpu_state_ld_rs1`; without it the coprocessor never sees a valid instruction |
| `ENABLE_REGS_DUALPORT` | 1 | `pcpi_rs1` and `pcpi_rs2` must be valid in the same cycle `pcpi_valid` rises; single-port mode loads rs2 one cycle late |

`CATCH_ILLINSN` is **not** a hard requirement. Because `ENABLE_MUL=1` and
`ENABLE_DIV=1` in the Helix SoC, PicoRV32's internal `WITH_PCPI=1` regardless
of `CATCH_ILLINSN`, so custom instructions trigger `instr_trap` and route to
the PCPI handler in either case.

---

## 9. Known Limitations (v1)

1. **No masking** — unlike RVV, individual lanes cannot be disabled. Tail
   handling requires scalar code or padding input to a 16-byte boundary.
2. **No gather/scatter** — only contiguous 16-byte aligned accesses. Strided
   or indexed memory access is scalar.
3. **No unsigned arithmetic** — all operations are signed. Unsigned types
   require bias adjustment in software.
4. **No float support** — int8/int16/int32 only. Use PicoRV32's scalar FPU
   (if enabled) for float.
5. **ACCX overflow with int32 VMAC** — a single worst-case VMAC.S32 call
   (all 4 lanes at INT32_MAX × INT32_MAX) contributes ~1.84×10¹⁹, which
   exceeds ACCX capacity (2⁶³−1 ≈ 9.22×10¹⁸). Call `VGETACC` every
   iteration when using int32 VMAC, or restructure as int16.
6. **No interrupt context save for Q-registers** — must be handled in software
   if ISR uses HVX.
7. **`VGETACC` rd limited to x0–x7** — the 3-bit `vd` field restricts the
   scalar destination register. Future versions will extend to the full
   register file.
8. **`VMULH` truncates toward −∞** — no rounding variant in v1. Adds −½ LSB
   DC bias in fixed-point applications. A rounding variant is planned for v2.
9. **No shift instructions** — `funct3=001` is reserved for v2. Scalar shifts
   must be used for vector data requiring shift operations.
10. **VLD/VST limited to SRAM window** — the vector memory port has no address
    decode for peripherals or flash. Out-of-range accesses are suppressed
    (gated in `helix_picosoc.v`) rather than routed to other bus agents.

---

## 10. Example: 16-tap FIR Filter (int8, Q7 coefficients)

```c
#include "helix_vec_asm.h"

// samples: 16-byte aligned, 16 int8 samples
// coeffs:  16-byte aligned, 16 int8 Q7 coefficients
// returns: filtered output as int32 (Q7 scaled, shift=7 to get int8)
int32_t fir16_s8(const int8_t *samples, const int8_t *coeffs) {
    // Explicit register constraint required: VGETACC encodes rd in the
    // 3-bit vd field, limiting destination to x0-x7. t0=x5 is safe.
    // Without this, GCC may allocate a0 (x10), causing the instruction
    // to encode rd=x2 (sp) — silently corrupting the stack pointer.
    register int32_t result asm("t0");
    hvx_vld(1, samples);       // Q1 = 16 input samples
    hvx_vld(2, coeffs);        // Q2 = 16 Q7 coefficients
    hvx_vclracc();              // ACCX = 0
    hvx_vmac_s8(1, 2);          // ACCX = dot(Q1, Q2), signed 64-bit
    hvx_vgetacc(result, 7);     // result = ACCX >> 7 (scale from Q7)
    return result;
}
```

**Instruction count:** 5 instructions.

**Cycle count:** 6 + 6 + 3 + 3 + 3 = **21 CPU cycles** (two VLD at 6 each,
VCLRACC + VMAC + VGETACC at 3 each).

Scalar equivalent for 16 int8 multiply-accumulates: ~160 cycles (load, sign-extend,
multiply, accumulate × 16). **~7.6× speedup.**

---

## 11. Instruction Opcode Quick Reference

Binary field layout. For computed 32-bit hex values see Section 7.

```
Format: [31:27]op_id [26:25]ew [22:20]vs2 [17:15]vs1 [14:12]f3 [9:7]vd [6:0]=0x2B

VLD.128  Q0,[a0]   → 00000_00_000_000_010_000_0x2B  | rs1=a0
VST.128  [a0],Q1   → 00000_00_001_000_011_000_0x2B  | rs1=a0
VADD.S8  Q2,Q0,Q1  → 00000_00_001_000_000_010_0x2B
VMAC.S8  Q0,Q1     → 00000_00_001_000_100_000_0x2B
VCLRACC            → 00001_00_000_000_100_000_0x2B
VGETACC  x0,x2     → 00010_00_010_000_100_000_0x2B  | vs2=shift reg (x0–x7 only)
VMOVS.S8 Q5,a0     → 00000_00_000_000_101_101_0x2B  | rs1=a0
```
