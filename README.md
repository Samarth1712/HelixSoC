# Helix SoC

A 128-bit SIMD vector coprocessor extension for PicoRV32, targeting 
embedded DSP workloads (FIR filters, dot products, int8/int16 inference).

## What This Is

Helix adds the HVX (Helix Vector Extension) to PicoRV32 via the PCPI 
coprocessor interface. No modifications to the PicoRV32 core are required.

- 16× int8 / 8× int16 / 4× int32 SIMD lanes per instruction
- Saturating signed arithmetic
- 64-bit ACCX accumulator for overflow-safe dot products  
- Fixed 3-cycle latency (arithmetic), 5-cycle (load/store)
- Custom-1 opcode space (0x2B), no conflict with PicoRV32 IRQ instructions

## Quick Start



## Repository Layout
```txt
helix-soc/
│
├── README.md                  ← Project overview, what Helix is
├── LICENSE                    ← MIT
├── CHANGELOG.md               ← Version history
│
├── docs/
│   ├── helix_vec_isa_spec.md  ← ISA spec 
│   ├── abi.md                 ← Calling conventions, caller-saved rules
│   ├── memory_map.md          ← Address space, vector vs scalar port
│   └── timing.md              ← Cycle counts, PCPI handshake diagram
│
├── rtl/
│   ├── helix_vec_defs.svh
│   ├── helix_vec_regfile.sv
│   ├── helix_vec_alu.sv
│   ├── helix_vec_lsu.sv
│   ├── helix_vcop.sv
│   └── helix_picosoc.v        ← top-level SoC
│
├── third_party/
│   └── picorv32/
│       ├── picorv32.v         ← Vendored verbatim
│       ├── simpleuart.v
│       ├── spimemio.v
│       └── COMMIT             ← Plain text file with the upstream commit hash
│
├── sw/
│   ├── include/
│   │   └── helix_vec_asm.h    ← assembler header
│   ├── examples/
│   │   └── fir16/             ← FIR example from the spec
│   └── linker/
│       └── helix.ld           ← Linker script
│
├── sim/
│   ├── tb_helix_vcop.sv       ← coprocessor testbench 
│   ├── tb_helix_vec_alu.sv    ← ALU unit testbench
│   └── Makefile
│
└── syn/
    └── constraints.xdc        ← for targeting a specific FPGA (not decided yet)
```

## Documentation

- [ISA Specification](docs/helix_vec_isa_spec.md)
- [ABI and Calling Conventions](docs/abi.md)  
- [Memory Map](docs/memory_map.md)
- [Cycle Timing](docs/timing.md)

## Known Limitations (v1)

1. **No masking** — unlike RVV, individual lanes cannot be disabled. Tail handling requires scalar code or padding.
2. **No gather/scatter** — only contiguous 16-byte aligned accesses. Strided or indexed memory access is scalar.
3. **No unsigned arithmetic** — all operations are signed. Unsigned types require bias adjustment in software.
4. **No float support** — int8/int16/int32 only. Use PicoRV32's scalar FPU (if enabled) for float.
5. **ACCX overflow with int32 VMAC** — only ~2 VMAC calls safe before overflow. Use `VGETACC` frequently or restructure as int16.
6. **No interrupt context save for Q-registers** — must be handled in software if ISR uses HVX.

## Hardware Requirements

- PicoRV32 configuration: ENABLE_PCPI=1, CATCH_ILLINSN=1, 
  ENABLE_REGS_DUALPORT=1 (enforced by generate assertions in RTL)
- 128-bit wide vector SRAM port required
- 16-byte aligned vector memory accesses only

## Third-Party Dependencies

PicoRV32 (YosysHQ/picorv32) is vendored in third_party/picorv32/.  
Commit: [hash]. Licensed ISC. No modifications made.

## License

Helix SoC RTL, ISA specification, assembler headers, and documentation 
are licensed under the MIT License. See LICENSE.

Third-party components:
- PicoRV32 (rtl/third_party/picorv32/) — ISC License, 
  copyright Claire Xenia Wolf. See third_party/picorv32/LICENSE.
  No modifications made to upstream source.

## Status

v1.0-draft. RTL functional, not yet silicon-validated.
Open issues: 
