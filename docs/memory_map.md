# Helix SoC — Memory Map

---

## Address Space (Scalar / CPU view)

This is the standard PicoSoC memory map. The CPU's scalar memory bus
sees the following regions:

| Base address | End address | Size | Region | Notes |
|---|---|---|---|---|
| `0x0000_0000` | `0x0000_03FF` | 1 KB | Internal SRAM | Default 256-word config |
| `0x0010_0000` | `0x00FF_FFFF` | ~16 MB | SPI Flash XIP | Read-only, execute-in-place |
| `0x0200_0000` | `0x0200_0000` | 4 bytes | SPI Flash config | spimemio control register |
| `0x0200_0004` | `0x0200_0004` | 4 bytes | UART divisor | Baud rate setting |
| `0x0200_0008` | `0x0200_0008` | 4 bytes | UART data | TX write / RX read |
| `0x0200_0010` | `0x02FF_FFFF` | — | I/O (iomem) | External peripheral space |

**Reset vector:** `0x0010_0000` (first word of SPI Flash XIP).

**IRQ handler:** `0x0000_0000` (first word of SRAM).
Place the IRQ handler at SRAM base or redirect with a jump instruction.

**Stack:** grows downward from `0x0000_0400` (top of SRAM) by default.
`STACKADDR = 4 × MEM_WORDS`. With the default `MEM_WORDS=256`, the stack
starts at `0x400`.

### SRAM size

The default configuration uses `MEM_WORDS=256` (256 × 32-bit words = 1 KB).
This can be increased by changing the `MEM_WORDS` parameter in
`helix_picosoc.v`. The scalar and vector address decode both derive their
bounds from this parameter via `4*MEM_WORDS`.

---

## Vector Memory Port

The HVX coprocessor has a **separate 128-bit wide memory port** that connects
directly to the internal SRAM. This port is distinct from the CPU's scalar
32-bit port. The two ports operate independently — the CPU uses its port for
scalar loads and stores; the coprocessor uses its port for VLD.128 and VST.128.

### No-arbitration guarantee

PicoRV32 asserts `pcpi_wait=1` for the entire duration of any vector memory
instruction. While `pcpi_wait` is high, the CPU does not issue any new scalar
memory transactions (`mem_valid=0`). Therefore the scalar and vector ports
never conflict on the same clock cycle — **no arbiter is required**.

### Vector memory window

The vector port only routes to the internal SRAM. It has **no peripheral
decode, no flash routing, and no I/O mapping**.

| Base address | End address | Accessible? |
|---|---|---|
| `0x0000_0000` | `0x0000_03FF` | ✓ SRAM (16-byte aligned blocks) |
| Any other address | — | ✗ Suppressed — access blocked |

Out-of-range vector accesses are **suppressed** in `helix_picosoc.v`:
`vec_mem_en` is gated by `vec_addr_in_range = (vec_mem_addr < 4*MEM_WORDS)`.
A suppressed store is silently dropped. A suppressed load returns stale data
(last SRAM read value). A `$display` warning fires in simulation.

**There is no hardware exception for out-of-range vector accesses.** Firmware
is responsible for ensuring VLD/VST addresses are within the SRAM window.
Using a pointer to flash, peripheral registers, or I/O space as a VLD address
will produce wrong data with no indication.

### Vector address alignment

The LSU masks the lower 4 address bits before presenting to the SRAM:

```
vec_mem_addr_aligned = {vec_mem_addr[31:4], 4'b0000}
```

An unaligned VLD or VST silently accesses the 16-byte block that contains
the given address. A simulation warning is printed but no hardware exception
occurs. Always pass 16-byte aligned addresses.

---

## Dual-Port SRAM Architecture

The `helix_picosoc_mem` module implements a simple dual-port SRAM using a
single Verilog `reg` array with two independent access ports:

```
              ┌─────────────────────────────┐
              │      helix_picosoc_mem      │
              │                             │
CPU scalar ──►│  32-bit port  (byte-enable) │
  bus         │  word-addressed             │
              │                             │
HVX vector ──►│  128-bit port (4-word block)│
  port        │  16-byte aligned            │
              └─────────────────────────────┘
```

**Scalar port:** 32-bit wide, byte-enable write (`wen[3:0]`), word-addressed
(`addr[21:0]` → lower `$clog2(WORDS)` bits used). Reads and writes are
registered (synchronous).

**Vector port:** 128-bit wide, accesses four consecutive 32-bit words per
transaction. The `vec_addr` field indexes 16-byte groups:

```
vec_addr = vec_mem_addr[$clog2(MEM_WORDS)+1 : 4]
```

Four consecutive words are read/written:

```
word[vec_addr×4 + 0]  →  vec_data[31:0]
word[vec_addr×4 + 1]  →  vec_data[63:32]
word[vec_addr×4 + 2]  →  vec_data[95:64]
word[vec_addr×4 + 3]  →  vec_data[127:96]
```

### Simultaneous access behaviour

A scalar write and a vector read to the same address range in the same clock
cycle is a **race condition** on the `mem[]` array. Both accesses are in
`always @(posedge clk)` blocks — the result depends on the simulator's event
scheduling. In synthesis, a true dual-port BRAM with separate read and write
ports on the same clock avoids this; single-port BRAM inference may serialize
the accesses.

**The no-arbitration guarantee prevents this in normal operation:** the CPU
never issues a scalar memory transaction while a vector instruction is in
progress. However, if scalar code executes a store immediately before a vector
load to the same address (in consecutive instructions), the store completes
in one clock and the vector load begins the next — no overlap. This is safe.

---

## Peripheral Register Map

| Address | Register | Access | Description |
|---|---|---|---|
| `0x0200_0000` | SPI flash config | R/W | spimemio control; see spimemio.v |
| `0x0200_0004` | UART divisor | R/W | Baud rate: `divisor = clk_hz / baud_rate` |
| `0x0200_0008` | UART data | R/W | Write: TX byte. Read: RX byte (−1 if empty) |

UART example for 9600 baud at 12 MHz:
```c
*(volatile uint32_t*)0x02000004 = 12000000 / 9600;  // divisor = 1250
*(volatile uint32_t*)0x02000008 = 'H';               // transmit 'H'
```

---

## Flash XIP Layout (suggested)

The reset vector is `0x0010_0000`. A typical firmware layout:

```
0x0010_0000   _start (reset handler, sets up stack, calls main)
0x0010_0010   main() and application code
...
              read-only data (.rodata)
              HVX coefficient tables (16-byte aligned)
```

HVX coefficient tables stored in flash must be copied to SRAM before use —
the vector port cannot load directly from flash. A typical startup sequence:

```c
// Copy coefficient table from flash to SRAM buffer
extern const int8_t coeffs_flash[16];           // in .rodata (flash)
int8_t coeffs_sram[16] __attribute__((aligned(16)));  // in .data or .bss (SRAM)

memcpy(coeffs_sram, coeffs_flash, 16);          // scalar copy
hvx_vld(0, coeffs_sram);                        // now safe to VLD
```

---

## Address Decode Summary

```
CPU scalar bus view:
  0x0000_0000 – 0x0000_03FF   SRAM     (ram_ready path)
  0x0010_0000 – 0x01FF_FFFF   Flash XIP (spimem_ready path)
  0x0200_0000                 SPI config
  0x0200_0004                 UART divisor
  0x0200_0008                 UART data
  0x0200_0010 – 0x02FF_FFFF   iomem (external)

HVX vector port view:
  0x0000_0000 – 0x0000_03FF   SRAM only (16-byte aligned)
  all other addresses          SUPPRESSED (vec_mem_en gated)
```
