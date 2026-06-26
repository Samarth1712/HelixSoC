# Helix SoC

A 128-bit SIMD vector coprocessor extension for PicoRV32, targeting
embedded DSP workloads (FIR filters, dot products, int8/int16 inference).

## What This Is

Helix adds the HVX (Helix Vector Extension) to PicoRV32 via the PCPI
coprocessor interface. No modifications to the PicoRV32 core are required.

- 16× int8 / 8× int16 / 4× int32 SIMD lanes per instruction
- Saturating signed arithmetic
- 64-bit ACCX accumulator for overflow-safe dot products
- Fixed 3-cycle latency (arithmetic), 7-cycle (load/store)
- Custom-1 opcode space (0x2B), no conflict with PicoRV32 IRQ instructions

## Quick Start

16-tap FIR filter in 5 instructions, ~21 CPU cycles:

```c
#include "helix_vec_asm.h"

// samples: 16-byte aligned, 16 int8 samples
// coeffs:  16-byte aligned, 16 int8 Q7 coefficients
int32_t fir16_s8(const int8_t *samples, const int8_t *coeffs) {
    // register constraint required: VGETACC rd is limited to x0–x7
    register int32_t result asm("t0");
    hvx_vld(1, samples);       // Q1 = 16 input samples
    hvx_vld(2, coeffs);        // Q2 = 16 Q7 coefficients
    hvx_vclracc();              // ACCX = 0
    hvx_vmac_s8(1, 2);          // ACCX = dot(Q1, Q2)
    hvx_vgetacc(result, 7);     // result = ACCX >> 7
    return result;
}
```

~7× faster than equivalent scalar code (~160 cycles).

## Repository Layout

```
helix-soc/
│
├── README.md
├── LICENSE                    ← MIT
├── CHANGELOG.md
│
├── docs/
│   ├── helix_vec_isa_spec.md  ← ISA specification (encoding, timing, ABI)
│   ├── abi.md                 ← Calling conventions, caller-saved rules
│   ├── memory_map.md          ← Address space, vector vs scalar port
│   └── timing.md              ← Cycle counts, PCPI handshake diagram
│
├── rtl/
│   ├── helix_vec_defs.svh     ← AUTO-GENERATED — run tools/gen_defs.py
│   ├── helix_vec_regfile.sv
│   ├── helix_vec_alu.sv
│   ├── helix_vec_lsu.sv
│   ├── helix_vcop.sv
│   └── helix_picosoc.v        ← top-level SoC
│
├── third_party/
│   └── picorv32/
│       ├── picorv32.v         ← Vendored verbatim, do not modify
│       ├── simpleuart.v
│       ├── spimemio.v
│       ├── spiflash.v
│       └── UPSTREAM.md             ← Upstream commit hash
│
├── tools/
│   └── gen_defs.py            ← Single source of truth for all encoding
│                                 constants; generates helix_vec_defs.svh
│                                 and sw/include/helix_vec_defs.h
│
├── sw/
│   ├── include/
│   │   ├── helix_vec_asm.h    ← Assembler macros (firmware API)
│   │   └── helix_vec_defs.h   ← AUTO-GENERATED — run tools/gen_defs.py
│   ├── examples/
│   │   └── fir16/             ← FIR filter example
│   └── linker/
│       └── helix.ld           ← Linker script
│
├── sim/
│   ├── tb_helix_vcop.sv       ← Coprocessor integration testbench (PCPI BFM)
│   ├── tb_helix_vec_alu.sv    ← ALU unit testbench (combinational, fast)
│   └── Makefile
│
└── syn/
    └── constraints.xdc        ← FPGA constraints (target TBD)
```

## Documentation

- [ISA Specification](docs/helix_vec_isa_spec.md) — encoding, timing, ABI, overflow analysis
- [ABI and Calling Conventions](docs/abi.md) — Q-register save/restore, VGETACC register constraint, ISR patterns
- [Memory Map](docs/memory_map.md) — scalar vs vector port, address decode, peripheral map
- [Cycle Timing](docs/timing.md) — PCPI handshake waveform, per-instruction breakdown

## Constant Generation

`rtl/helix_vec_defs.svh` and `sw/include/helix_vec_defs.h` are both
generated from a single source of truth:

```
python tools/gen_defs.py
```

Never edit the generated files directly. All encoding constant changes go
in `tools/gen_defs.py`. The generator validates constants for overflow and
conflicts before writing either file.

## Known Limitations (v1)

1. **No masking** — unlike RVV, individual lanes cannot be disabled. Tail
   handling requires scalar code or padding input to a 16-byte boundary.
2. **No gather/scatter** — only contiguous 16-byte aligned accesses.
   Strided or indexed memory access is scalar.
3. **No unsigned arithmetic** — all operations are signed. Unsigned types
   require bias adjustment in software.
4. **No float support** — int8/int16/int32 only. Use PicoRV32's scalar FPU
   (if enabled) for float.
5. **ACCX overflow with int32 VMAC** — a single worst-case VMAC.S32 call
   (4 lanes at INT32_MAX × INT32_MAX) contributes ~1.84×10¹⁹, which exceeds
   ACCX capacity (~9.22×10¹⁸). Call `VGETACC` every iteration when using
   int32 VMAC, or restructure as int16.
6. **No interrupt context save for Q-registers** — must be handled in
   software if an ISR uses HVX. See [abi.md](docs/abi.md).
7. **`VGETACC` rd limited to x0–x7** — the 3-bit `vd` field restricts
   the scalar destination register. Always declare the result variable
   with an explicit register attribute: `register int32_t r asm("t0")`.
8. **`VMULH` truncates toward −∞** — no rounding variant in v1, adds DC
   bias in fixed-point applications. A rounding variant is planned for v2.
9. **No shift instructions** — `funct3=001` is reserved for v2. Use scalar
   shifts for vector data requiring shift operations.
10. **VLD/VST limited to SRAM window** — the vector port has no peripheral
    or flash routing. Out-of-range accesses are suppressed (not trapped).

## Hardware Requirements

| PicoRV32 parameter | Required value | Reason |
|---|---|---|
| `ENABLE_PCPI` | 1 | Gates `pcpi_valid` — without it the coprocessor never sees an instruction |
| `ENABLE_REGS_DUALPORT` | 1 | `pcpi_rs1` and `pcpi_rs2` must be valid in the same cycle |

Both are enforced by assertions in `helix_picosoc.v`. `CATCH_ILLINSN` is
**not** required — `WITH_PCPI=1` already because `ENABLE_MUL=1` and
`ENABLE_DIV=1`, so HVX instructions route to the PCPI handler regardless.

Additional requirements:
- 128-bit wide vector SRAM port (provided by `helix_picosoc_mem`)
- 16-byte aligned vector memory accesses
- VLD/VST save buffers must carry `__attribute__((aligned(16)))`

## Third-Party Dependencies

PicoRV32 (YosysHQ/picorv32) is vendored in `third_party/picorv32/`.
Commit: 87c89a. Licensed ISC. No modifications made to upstream source.

## License

Helix SoC RTL, ISA specification, assembler headers, and documentation
are licensed under the MIT License. See [LICENSE](LICENSE).

Third-party components:
- PicoRV32 (`third_party/picorv32/`) — ISC License,
  copyright Claire Xenia Wolf. See `third_party/picorv32/LICENSE`.
  No modifications made to upstream source.

## Status

RTL complete, known bugs fixed, testbench written.
FPGA-validated.
