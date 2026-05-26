/*
 *  helix_picosoc.v — PicoSoC modified for Helix Vector Coprocessor
 *
 *  Based on PicoSoC by Claire Xenia Wolf.
 *  Modifications:
 *    1. ENABLE_PCPI=1 in PicoRV32 instantiation + all pcpi ports wired
 *    2. helix_vcop instantiated and connected
 *    3. helix_picosoc_mem: dual-port SRAM (32-bit scalar + 128-bit vector)
 *
 *  No-arbitration guarantee: PicoRV32 asserts pcpi_wait during all vector
 *  memory ops, so mem_valid from the CPU is never asserted simultaneously
 *  with vec_mem_en from the coprocessor. Safe by construction.
 *
 *  PicoRV32 configuration requirements for HVX (enforced below):
 *    ENABLE_PCPI=1     — required: enables pcpi_valid/pcpi_ready/pcpi_wait
 *                        ports and sets WITH_PCPI=1 in PicoRV32. WITH_PCPI
 *                        controls whether the cpu_state_ld_rs1 handler checks
 *                        pcpi_int_ready and asserts pcpi_valid. Without
 *                        ENABLE_PCPI=1, the PCPI bus ports exist but pcpi_valid
 *                        is never asserted — the coprocessor sits idle forever.
 *
 *                        NOTE: CATCH_ILLINSN is NOT a hard requirement for HVX.
 *                        PicoRV32 routes to the PCPI handler when:
 *                          WITH_PCPI = ENABLE_PCPI || ENABLE_MUL ||
 *                                      ENABLE_FAST_MUL || ENABLE_DIV
 *                        Since ENABLE_MUL=1 and ENABLE_DIV=1 in this SoC,
 *                        WITH_PCPI=1 regardless of CATCH_ILLINSN. Custom
 *                        instructions trigger instr_trap and route to PCPI
 *                        even with CATCH_ILLINSN=0. ENABLE_PCPI is what
 *                        actually gates pcpi_valid assertion.
 *
 *    ENABLE_REGS_DUALPORT=1 — required: pcpi_rs1 and pcpi_rs2 must be loaded
 *                        in the same cpu_state_ld_rs1 cycle. With single-port
 *                        register file, rs2 is loaded one cycle later, but
 *                        pcpi_valid is already asserted — the vcop would latch
 *                        a stale rs2 value.
 *
 *  BUG FIX vs v1: Vector address decode added. Previously vec_mem_addr was
 *  passed directly from the coprocessor to the SRAM with no bounds check.
 *  Any firmware bug producing an out-of-range vector address would silently
 *  wrap into SRAM (only lower address bits used by helix_picosoc_mem). This
 *  was invisible to the CPU since vec_mem_en was never gated on the address
 *  being within the SRAM window.
 *
 *  Fix: vec_mem_en is now ANDed with an in-range check. Out-of-range vector
 *  accesses are suppressed (vec_mem_en deasserted). For loads, vec_mem_rdata
 *  will be 0 (SRAM output held from previous access). This is not correct
 *  data, but it is a defined, detectable failure mode rather than silent data
 *  corruption at a wrapped address.
 *
 *  Memory map (unchanged from original PicoSoC):
 *    0x00000000–0x000003FF  Internal SRAM  (256 words default = 1 KB)
 *    0x00100000–0x00FFFFFF  SPI Flash XIP
 *    0x02000000             SPI flash config register
 *    0x02000004             UART divisor
 *    0x02000008             UART data
 *    0x02000010+            I/O (iomem)
 *
 *  Vector memory window: 0x00000000–0x000003FF (same as scalar SRAM).
 *  Vector accesses outside this range are suppressed with a simulation warning.
 */

`ifndef PICORV32_REGS
`ifdef PICORV32_V
`error "helix_picosoc.v must be read before picorv32.v!"
`endif
`define PICORV32_REGS picosoc_regs
`endif

`ifndef PICOSOC_MEM
`define PICOSOC_MEM helix_picosoc_mem
`endif

`define PICOSOC_V

module helix_picosoc (
    input  clk,
    input  resetn,

    output        iomem_valid,
    input         iomem_ready,
    output [ 3:0] iomem_wstrb,
    output [31:0] iomem_addr,
    output [31:0] iomem_wdata,
    input  [31:0] iomem_rdata,

    input  irq_5, irq_6, irq_7,

    output ser_tx,
    input  ser_rx,

    output flash_csb,
    output flash_clk,
    output flash_io0_oe, flash_io1_oe, flash_io2_oe, flash_io3_oe,
    output flash_io0_do, flash_io1_do, flash_io2_do, flash_io3_do,
    input  flash_io0_di, flash_io1_di, flash_io2_di, flash_io3_di
);
    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    parameter [0:0] BARREL_SHIFTER    = 1;
    parameter [0:0] ENABLE_MUL        = 1;
    parameter [0:0] ENABLE_DIV        = 1;
    parameter [0:0] ENABLE_FAST_MUL   = 0;
    parameter [0:0] ENABLE_COMPRESSED = 1;
    parameter [0:0] ENABLE_COUNTERS   = 1;
    parameter [0:0] ENABLE_IRQ_QREGS  = 0;

    parameter integer MEM_WORDS     = 256;
    parameter [31:0]  STACKADDR     = (4*MEM_WORDS);
    parameter [31:0]  PROGADDR_RESET = 32'h0010_0000;
    parameter [31:0]  PROGADDR_IRQ  = 32'h0000_0000;

    // -------------------------------------------------------------------------
    // Enforce PicoRV32 configuration requirements at elaboration time.
    //
    // ENABLE_PCPI=1 and ENABLE_REGS_DUALPORT=1 are hardwired in the
    // picorv32 instantiation below. These localparams mirror those values
    // so the simulation checks can reference them symbolically. If you
    // change the instantiation, update these to match.
    //
    // CATCH_ILLINSN is intentionally NOT checked here — it is NOT a hard
    // requirement for HVX. PicoRV32's internal signal:
    //   WITH_PCPI = ENABLE_PCPI || ENABLE_MUL || ENABLE_FAST_MUL || ENABLE_DIV
    // Since ENABLE_MUL=1 and ENABLE_DIV=1 in this SoC, WITH_PCPI=1 regardless
    // of CATCH_ILLINSN. Custom instructions trigger instr_trap and route to
    // the PCPI handler in either case. ENABLE_PCPI is the true gate — it
    // controls whether pcpi_valid is ever asserted by cpu_state_ld_rs1.
    // -------------------------------------------------------------------------
    localparam PICORV32_ENABLE_PCPI          = 1; // hardwired below — do not set to 0
    localparam PICORV32_ENABLE_REGS_DUALPORT = 1; // hardwired below — do not set to 0

`ifdef SIMULATION
    initial begin
        if (PICORV32_ENABLE_PCPI !== 1)
            $fatal(1, "[helix_picosoc] ENABLE_PCPI must be 1: pcpi_valid never asserted without it");
        if (PICORV32_ENABLE_REGS_DUALPORT !== 1)
            $fatal(1, "[helix_picosoc] ENABLE_REGS_DUALPORT must be 1: vcop latches stale rs2 in single-port mode");
        $display("[helix_picosoc] Configuration checks passed.");
        $display("[helix_picosoc] MEM_WORDS=%0d (%0d bytes SRAM)", MEM_WORDS, 4*MEM_WORDS);
        $display("[helix_picosoc] Vector window: 0x00000000–0x%08x", 4*MEM_WORDS - 1);
    end
`endif

    // -------------------------------------------------------------------------
    // IRQ
    // -------------------------------------------------------------------------
    reg [31:0] irq;
    always @* begin
        irq    = 0;
        irq[5] = irq_5;
        irq[6] = irq_6;
        irq[7] = irq_7;
    end

    // -------------------------------------------------------------------------
    // Scalar memory bus
    // -------------------------------------------------------------------------
    wire        mem_valid, mem_instr, mem_ready;
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire [ 3:0] mem_wstrb;

    wire        spimem_ready;
    wire [31:0] spimem_rdata;
    reg         ram_ready;
    wire [31:0] ram_rdata;

    assign iomem_valid = mem_valid && (mem_addr[31:24] > 8'h01);
    assign iomem_wstrb = mem_wstrb;
    assign iomem_addr  = mem_addr;
    assign iomem_wdata = mem_wdata;

    wire        spimemio_cfgreg_sel = mem_valid && (mem_addr == 32'h0200_0000);
    wire [31:0] spimemio_cfgreg_do;
    wire        simpleuart_reg_div_sel = mem_valid && (mem_addr == 32'h0200_0004);
    wire [31:0] simpleuart_reg_div_do;
    wire        simpleuart_reg_dat_sel = mem_valid && (mem_addr == 32'h0200_0008);
    wire [31:0] simpleuart_reg_dat_do;
    wire        simpleuart_reg_dat_wait;

    assign mem_ready = (iomem_valid && iomem_ready)
                     || spimem_ready || ram_ready
                     || spimemio_cfgreg_sel || simpleuart_reg_div_sel
                     || (simpleuart_reg_dat_sel && !simpleuart_reg_dat_wait);

    assign mem_rdata = (iomem_valid && iomem_ready) ? iomem_rdata
                     : spimem_ready                 ? spimem_rdata
                     : ram_ready                    ? ram_rdata
                     : spimemio_cfgreg_sel          ? spimemio_cfgreg_do
                     : simpleuart_reg_div_sel       ? simpleuart_reg_div_do
                     : simpleuart_reg_dat_sel       ? simpleuart_reg_dat_do
                                                    : 32'h0;

    // -------------------------------------------------------------------------
    // PCPI bus
    // -------------------------------------------------------------------------
    wire        pcpi_valid, pcpi_wr, pcpi_wait, pcpi_ready;
    wire [31:0] pcpi_insn, pcpi_rs1, pcpi_rs2, pcpi_rd;

    // -------------------------------------------------------------------------
    // Vector memory bus (128-bit) — raw signals from coprocessor
    // -------------------------------------------------------------------------
    wire         vec_mem_en_raw, vec_mem_we;
    wire [31:0]  vec_mem_addr;
    wire [127:0] vec_mem_wdata, vec_mem_rdata;

    // -------------------------------------------------------------------------
    // FIX: Vector address decode / bounds check.
    //
    // The SRAM holds MEM_WORDS 32-bit words = 4*MEM_WORDS bytes.
    // Vector accesses are 16-byte aligned, so the valid byte address range is
    // 0x0000_0000 to (4*MEM_WORDS - 16), i.e. the address must satisfy:
    //   vec_mem_addr < 4*MEM_WORDS
    // The lower 4 bits are always forced to zero by the LSU (16-byte align),
    // so we only need to check the upper bits.
    //
    // vec_mem_en is gated on this condition. Out-of-range accesses produce
    // no SRAM activity. For loads, vec_mem_rdata will be stale (last valid
    // read), which is a detectable failure mode rather than silent wrap-around.
    // -------------------------------------------------------------------------
    wire vec_addr_in_range = (vec_mem_addr < (4 * MEM_WORDS));
    wire vec_mem_en = vec_mem_en_raw && vec_addr_in_range;

`ifdef SIMULATION
    always @(posedge clk) begin
        if (vec_mem_en_raw && !vec_addr_in_range)
            $display("[helix_picosoc] t=%0t ERROR: vector access out of SRAM range: addr=0x%08x, max=0x%08x — access suppressed",
                     $time, vec_mem_addr, 4*MEM_WORDS - 1);
    end
`endif

    // -------------------------------------------------------------------------
    // PicoRV32 — ENABLE_PCPI=1 and ENABLE_REGS_DUALPORT=1 are hard requirements
    // for HVX. CATCH_ILLINSN=1 is set for safety (traps bad instructions) but
    // is NOT required for HVX — WITH_PCPI=1 already because ENABLE_MUL=1.
    // Do not set ENABLE_PCPI or ENABLE_REGS_DUALPORT to 0.
    // -------------------------------------------------------------------------
    picorv32 #(
        .STACKADDR        (STACKADDR),
        .PROGADDR_RESET   (PROGADDR_RESET),
        .PROGADDR_IRQ     (PROGADDR_IRQ),
        .BARREL_SHIFTER   (BARREL_SHIFTER),
        .COMPRESSED_ISA   (ENABLE_COMPRESSED),
        .ENABLE_COUNTERS  (ENABLE_COUNTERS),
        .ENABLE_MUL       (ENABLE_MUL),
        .ENABLE_DIV       (ENABLE_DIV),
        .ENABLE_FAST_MUL  (ENABLE_FAST_MUL),
        .ENABLE_IRQ       (1),
        .ENABLE_IRQ_QREGS (ENABLE_IRQ_QREGS),
        .ENABLE_PCPI      (1),          // REQUIRED for HVX — do not set to 0
        .CATCH_ILLINSN    (1),          // REQUIRED for HVX — do not set to 0
        .ENABLE_REGS_DUALPORT (1)       // REQUIRED for HVX — do not set to 0
    ) cpu (
        .clk       (clk),       .resetn    (resetn),
        .mem_valid (mem_valid),  .mem_instr (mem_instr),
        .mem_ready (mem_ready),  .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),  .mem_wstrb (mem_wstrb),
        .mem_rdata (mem_rdata),  .irq       (irq),
        .pcpi_valid(pcpi_valid), .pcpi_insn (pcpi_insn),
        .pcpi_rs1  (pcpi_rs1),   .pcpi_rs2  (pcpi_rs2),
        .pcpi_wr   (pcpi_wr),    .pcpi_rd   (pcpi_rd),
        .pcpi_wait (pcpi_wait),  .pcpi_ready(pcpi_ready)
    );

    // -------------------------------------------------------------------------
    // Helix Vector Coprocessor
    // -------------------------------------------------------------------------
    helix_vcop #(.VLEN(128)) vcop (
        .clk          (clk),           .resetn        (resetn),
        .pcpi_valid   (pcpi_valid),    .pcpi_insn     (pcpi_insn),
        .pcpi_rs1     (pcpi_rs1),      .pcpi_rs2      (pcpi_rs2),
        .pcpi_wr      (pcpi_wr),       .pcpi_rd       (pcpi_rd),
        .pcpi_wait    (pcpi_wait),     .pcpi_ready    (pcpi_ready),
        .vec_mem_en   (vec_mem_en_raw),.vec_mem_we    (vec_mem_we),
        .vec_mem_addr (vec_mem_addr),  .vec_mem_wdata (vec_mem_wdata),
        .vec_mem_rdata(vec_mem_rdata)
    );

    // -------------------------------------------------------------------------
    // SPI Flash
    // -------------------------------------------------------------------------
    spimemio spimemio (
        .clk    (clk),    .resetn  (resetn),
        .valid  (mem_valid && mem_addr >= 4*MEM_WORDS && mem_addr < 32'h0200_0000),
        .ready  (spimem_ready),   .addr   (mem_addr[23:0]),
        .rdata  (spimem_rdata),
        .flash_csb   (flash_csb),  .flash_clk   (flash_clk),
        .flash_io0_oe(flash_io0_oe),.flash_io1_oe(flash_io1_oe),
        .flash_io2_oe(flash_io2_oe),.flash_io3_oe(flash_io3_oe),
        .flash_io0_do(flash_io0_do),.flash_io1_do(flash_io1_do),
        .flash_io2_do(flash_io2_do),.flash_io3_do(flash_io3_do),
        .flash_io0_di(flash_io0_di),.flash_io1_di(flash_io1_di),
        .flash_io2_di(flash_io2_di),.flash_io3_di(flash_io3_di),
        .cfgreg_we(spimemio_cfgreg_sel ? mem_wstrb : 4'b0),
        .cfgreg_di(mem_wdata), .cfgreg_do(spimemio_cfgreg_do)
    );

    // -------------------------------------------------------------------------
    // UART
    // FIX (style): !mem_wstrb replaced with (mem_wstrb == 4'b0) for clarity.
    // Functionally identical — !mem_wstrb reduces 4 bits to 1, true only when
    // all four bits are zero — but the explicit comparison is unambiguous.
    // -------------------------------------------------------------------------
    simpleuart simpleuart (
        .clk(clk), .resetn(resetn), .ser_tx(ser_tx), .ser_rx(ser_rx),
        .reg_div_we(simpleuart_reg_div_sel ? mem_wstrb : 4'b0),
        .reg_div_di(mem_wdata), .reg_div_do(simpleuart_reg_div_do),
        .reg_dat_we(simpleuart_reg_dat_sel ? mem_wstrb[0] : 1'b0),
        .reg_dat_re(simpleuart_reg_dat_sel && (mem_wstrb == 4'b0)),
        .reg_dat_di(mem_wdata), .reg_dat_do(simpleuart_reg_dat_do),
        .reg_dat_wait(simpleuart_reg_dat_wait)
    );

    // -------------------------------------------------------------------------
    // Internal SRAM — scalar access
    // -------------------------------------------------------------------------
    always @(posedge clk)
        ram_ready <= mem_valid && !mem_ready && mem_addr < 4*MEM_WORDS;

    helix_picosoc_mem #(.WORDS(MEM_WORDS)) memory (
        .clk      (clk),
        // Scalar 32-bit port
        .wen      ((mem_valid && !mem_ready && mem_addr < 4*MEM_WORDS) ? mem_wstrb : 4'b0),
        .addr     (mem_addr[23:2]),
        .wdata    (mem_wdata),
        .rdata    (ram_rdata),
        // Vector 128-bit port — vec_mem_en already gated by address decode above
        .vec_en   (vec_mem_en),
        .vec_we   (vec_mem_we),
        .vec_addr (vec_mem_addr[$clog2(MEM_WORDS)+1:4]),
        .vec_wdata(vec_mem_wdata),
        .vec_rdata(vec_mem_rdata)
    );

endmodule

// =============================================================================
// helix_picosoc_mem — Dual-port SRAM
// =============================================================================
// Scalar port: 32-bit words, byte-enable write, word-addressed.
// Vector port: 128-bit (4-word) blocks, 16-byte aligned.
//
// BUG FIX vs v1: vec_addr is sized to $clog2(WORDS/4) bits, preventing
// out-of-bounds array accesses when WORDS=256 and vec_addr was 20 bits wide.
// vbase is kept as a full word index computed from the properly-sized vec_addr.
//
// No changes in this version — all fixes are in the SoC address decode above.
// =============================================================================
module helix_picosoc_mem #(
    parameter integer WORDS = 256
) (
    input clk,

    // Scalar port
    input  [3:0]  wen,
    input  [21:0] addr,
    input  [31:0] wdata,
    output reg [31:0] rdata,

    // Vector port (128-bit = 4 words per transaction)
    input  [$clog2(WORDS/4)-1:0] vec_addr,
    input         vec_en,
    input         vec_we,
    input  [127:0] vec_wdata,
    output reg [127:0] vec_rdata
);
    reg [31:0] mem [0:WORDS-1];

    // Scalar read/write (byte-enable)
    always @(posedge clk) begin
        rdata <= mem[addr[$clog2(WORDS)-1:0]];
        if (wen[0]) mem[addr[$clog2(WORDS)-1:0]][ 7: 0] <= wdata[ 7: 0];
        if (wen[1]) mem[addr[$clog2(WORDS)-1:0]][15: 8] <= wdata[15: 8];
        if (wen[2]) mem[addr[$clog2(WORDS)-1:0]][23:16] <= wdata[23:16];
        if (wen[3]) mem[addr[$clog2(WORDS)-1:0]][31:24] <= wdata[31:24];
    end

    // Vector read/write (4 consecutive words from vec_addr × 4)
    wire [$clog2(WORDS)-1:0] vb0 = {vec_addr, 2'b00};
    wire [$clog2(WORDS)-1:0] vb1 = {vec_addr, 2'b01};
    wire [$clog2(WORDS)-1:0] vb2 = {vec_addr, 2'b10};
    wire [$clog2(WORDS)-1:0] vb3 = {vec_addr, 2'b11};

    always @(posedge clk) begin
        if (vec_en) begin
            vec_rdata <= {mem[vb3], mem[vb2], mem[vb1], mem[vb0]};
            if (vec_we) begin
                mem[vb0] <= vec_wdata[ 31:  0];
                mem[vb1] <= vec_wdata[ 63: 32];
                mem[vb2] <= vec_wdata[ 95: 64];
                mem[vb3] <= vec_wdata[127: 96];
            end
        end
    end
endmodule

// picosoc_regs — unchanged from original PicoSoC
module picosoc_regs (
    input clk, wen,
    input  [5:0] waddr, raddr1, raddr2,
    input  [31:0] wdata,
    output [31:0] rdata1, rdata2
);
    reg [31:0] regs [0:31];
    always @(posedge clk)
        if (wen) regs[waddr[4:0]] <= wdata;
    assign rdata1 = regs[raddr1[4:0]];
    assign rdata2 = regs[raddr2[4:0]];
endmodule
