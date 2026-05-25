# Helix SoC — Vector ISA Specification
**Version:** 1.0-draft  
**Date:** 2025  
**Opcode space:** RISC-V custom-1 (`7'b0101011` = `0x2B`)

---

## 1. Overview

The Helix Vector Extension (HVX) adds 128-bit SIMD acceleration to the PicoRV32 core via the PCPI (Pico Co-Processor Interface). It is modelled architecturally after the ESP32-S3's PIE extension — fixed-width 128-bit Q-registers, signed saturating arithmetic, and a dedicated multiply-accumulate path.

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

Q-registers are **not visible** to the PicoRV32 register file. The only scalar writeback is from `VGETACC`, which deposits the saturated accumulator result into a standard `xN` register via `pcpi_rd`.

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

Bits [24:23], [19:18], [11:10] are reserved and must be zero.

For `VLD`/`VMOVS`: scalar `x[rs1]` carries the base address or broadcast value — passed by PicoRV32 via `pcpi_rs1`.  
For `VGETACC`: scalar `x[rs2]` carries the right-shift amount — passed via `pcpi_rs2`.

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
- **funct3:** `010`  **op_id:** `00000`  **ew:** any (ignored)
- **Operation:** `Q[vd] = mem128[rs1 & ~0xF]`
- **Notes:** Address is forced 16-byte aligned (lower 4 bits masked). `pcpi_rs1` carries the address. Stalls CPU for ~5 cycles.

#### `VST.128  vs2, [rs1]`
- **funct3:** `011`  **op_id:** `00000`  **ew:** any (ignored)
- **Operation:** `mem128[rs1 & ~0xF] = Q[vs2]`
- **Notes:** Same alignment constraint. `pcpi_rs1` = address. No Q-register writeback.

---

### 4.2 Arithmetic (funct3 = `000`)

All arithmetic operations execute in **3 CPU cycles** (IDLE→DECODE→EXECUTE→DONE).  
Signed saturation clamps results to the element type's min/max rather than wrapping.

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

**`VABS` saturation edge case:** `abs(INT_MIN)` saturates to `INT_MAX` (e.g. `abs(-128) = 127`, not `-128`).

**`VMUL` vs `VMULH`:** `VMUL` returns the lower N bits of the 2N-bit product (modular). `VMULH` returns the upper N bits (effectively `floor((a×b) / 2^N)`). Useful for fixed-point scaling without a dedicated right-shift instruction.

---

### 4.3 MAC Operations (funct3 = `100`)

#### `VCLRACC`
- **op_id:** `00001`
- **Operation:** `ACCX = 0`
- **Notes:** Must precede a new dot-product sequence. 3 cycle latency.

#### `VMAC.Sew  vs1, vs2`
- **op_id:** `00000`
- **Operation:** `ACCX += Σᵢ (Q[vs1][i] × Q[vs2][i])` (signed)
- **Notes:** All lane products are sign-extended to 64 bits before accumulation. No vd output — result only in ACCX. Safe to call repeatedly before `VGETACC`. 3 cycle latency.

**Maximum safe VMAC calls before ACCX overflow:**

| Element width | Single VMAC max contribution | ACCX capacity |
|---|---|---|
| int8  | 16 × 127 × 127 = 258,064 | 2⁶³ − 1 ≈ safe for ~35 trillion calls |
| int16 | 8 × 32767² ≈ 8.6×10⁹ | Safe for ~1 billion calls |
| int32 | 4 × 2^62 | ~2 calls before risk; use `VGETACC` periodically |

#### `VGETACC  rd, rs2`
- **op_id:** `00010`
- **Operation:** `x[rd] = sat32(ACCX >> rs2[5:0])`
- **Notes:** Arithmetic (signed) right shift. Result saturated to int32. Writes scalar `x[rd]` via `pcpi_wr` / `pcpi_rd`. **Does not clear ACCX** — call `VCLRACC` if starting a new accumulation. 3 cycle latency.

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
- **Notes:** Broadcasts the low bits of scalar `x[rs1]` (via `pcpi_rs1`) to every lane. `ew` selects element width: `int8` takes `rs1[7:0]`, `int16` takes `rs1[15:0]`, `int32` takes `rs1[31:0]`.

#### `VMOV  vd, vs1`
- **op_id:** `00001`
- **Operation:** `Q[vd] = Q[vs1]`
- **Notes:** Simple Q-register copy. 3 cycles.

---

## 5. Execution Timing

| Instruction category | CPU stall cycles | Notes |
|---|---|---|
| ARITH / MISC | 3 | IDLE→DECODE→EXEC→DONE |
| MAC (VMAC, VCLRACC, VGETACC) | 3 | Same pipeline |
| VLD.128 / VST.128 | 5 | +2 for LSU state machine |

The core is stalled (no IPC loss for other instructions) for exactly the listed cycles. `pcpi_wait` is asserted from cycle 1 through cycle N−1; `pcpi_ready` is pulsed for exactly one cycle at completion.

---

## 6. Instruction Encoding Table (complete)

| Mnemonic | op_id | ew | funct3 | vd | vs1 | vs2 | rs1 used | rs2 used |
|---|---|---|---|---|---|---|---|---|
| VLD.128 | 0 | — | 010 | ✓ | — | — | addr | — |
| VST.128 | 0 | — | 011 | — | — | ✓ | addr | — |
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
| VCLRACC  | 1 | — | 100 | — | — | — | — | — |
| VMAC.Sew | 0 | ew | 100 | — | ✓ | ✓ | — | — |
| VGETACC  | 2 | — | 100 | — | — | — | — | shift |
| VMOVS.Sew| 0 | ew | 101 | ✓ | — | — | scalar | — |
| VMOV     | 1 | — | 101 | ✓ | ✓ | — | — | — |

---

## 7. ABI and Calling Conventions

- **Q0–Q7 are all caller-saved.** If a function uses any Q-register, it must save/restore them around calls it makes. There is no callee-saved convention for Q-registers in v1.
- **ACCX is caller-saved.** Always `VCLRACC` before beginning a new accumulation; never assume ACCX is zero on function entry.
- **ACCX is not automatically saved/restored on interrupts** by PicoRV32. If an ISR uses vector instructions, save ACCX manually by issuing `VGETACC` with shift=0 into a scratch register before the ISR body, and reconstruct with `VMAC` on return.

---

## 8. Known Limitations (v1)

1. **No masking** — unlike RVV, individual lanes cannot be disabled. Tail handling requires scalar code or padding.
2. **No gather/scatter** — only contiguous 16-byte aligned accesses. Strided or indexed memory access is scalar.
3. **No unsigned arithmetic** — all operations are signed. Unsigned types require bias adjustment in software.
4. **No float support** — int8/int16/int32 only. Use PicoRV32's scalar FPU (if enabled) for float.
5. **ACCX overflow with int32 VMAC** — only ~2 VMAC calls safe before overflow. Use `VGETACC` frequently or restructure as int16.
6. **No interrupt context save for Q-registers** — must be handled in software if ISR uses HVX.

---

## 9. Example: 16-tap FIR Filter (int8, Q7 coefficients)

```c
#include "helix_vec_asm.h"

// samples: 16-byte aligned, 16 int8 samples
// coeffs:  16-byte aligned, 16 int8 Q7 coefficients
// returns: filtered output as int32 (Q7 scaled, shift=7 to get int8)
int32_t fir16_s8(const int8_t *samples, const int8_t *coeffs) {
    int32_t result;
    hvx_vld(1, samples);       // Q1 = 16 input samples
    hvx_vld(2, coeffs);        // Q2 = 16 Q7 coefficients
    hvx_vclracc();              // ACCX = 0
    hvx_vmac_s8(1, 2);          // ACCX = dot(Q1, Q2), signed 64-bit
    hvx_vgetacc(result, 7);     // result = ACCX >> 7 (scale from Q7)
    return result;
}
```

**Instruction count:** 5 instructions, ~17 CPU cycles vs ~160 scalar.

---

## 10. Instruction Opcode Quick Reference

```
Format: [31:27]op_id [26:25]ew [22:20]vs2 [17:15]vs1 [14:12]f3 [9:7]vd [6:0]=0x2B

VLD.128  q0,[a0]  → 00000_00_000_000_010_00_0x2B  | rs1=a0
VST.128  [a0],q1  → 00000_00_001_000_011_00_0x2B  | rs1=a0
VADD.S8  q2,q0,q1 → 00000_00_001_000_000_010_0x2B
VMAC.S8  q0,q1    → 00000_00_001_000_100_000_0x2B
VCLRACC           → 00001_00_000_000_100_000_0x2B
VGETACC  rd,rs2   → 00010_00_000_000_100_rd_0x2B  | rs2=shift
```
