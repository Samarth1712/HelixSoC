// =============================================================================
// tb_helix_vcop.sv — Testbench for Helix Vector Coprocessor
// =============================================================================
// Directed unit tests for every instruction in the Helix vector ISA v1.
// Does NOT instantiate PicoRV32 — drives PCPI signals directly as a BFM
// (Bus Functional Model) to isolate the coprocessor.
//
// Test structure:
//   Each test task:
//     1. Builds the 32-bit instruction word
//     2. Drives pcpi_valid + pcpi_insn + pcpi_rs1 + pcpi_rs2
//     3. Pre-loads Q-registers via VLD (memory model)
//     4. Waits for pcpi_ready
//     5. Checks outputs (Q-register contents via VST read-back, or pcpi_rd)
//
// Run with: vcs -sverilog -full64 tb_helix_vcop.sv helix_vcop.sv
//           helix_vec_alu.sv helix_vec_regfile.sv helix_vec_lsu.sv
//           +define+SIMULATION +incdir+../rtl
//
// Tests added vs original:
//   T18 — VSUB.S8  INT_MIN edge case: sat_sub(0, INT_MIN) must = +127
//   T19 — VSUB.S16 INT_MIN edge case: sat_sub(0, INT_MIN16) must = +32767
//   T20 — VSUB.S32 INT_MIN edge case: sat_sub(0, INT_MIN32) must = +0x7FFFFFFF
//   T21 — funct3 disambiguation: VMAC (op_id=0,funct3=MAC) must not fire
//          vd writeback; VADD (op_id=0,funct3=ARITH) must fire vd writeback.
//          Without the funct3 fix these two are indistinguishable in the ALU.
// =============================================================================

`timescale 1ns/1ps
`include "helix_vec_defs.svh"

module tb_helix_vcop;

    // =========================================================================
    // DUT signals
    // =========================================================================
    logic        clk, resetn;
    logic        pcpi_valid;
    logic [31:0] pcpi_insn, pcpi_rs1, pcpi_rs2;
    logic        pcpi_wr, pcpi_wait, pcpi_ready;
    logic [31:0] pcpi_rd;

    logic        vec_mem_en, vec_mem_we;
    logic [31:0] vec_mem_addr;
    logic [127:0] vec_mem_wdata, vec_mem_rdata;

    // =========================================================================
    // Memory model (replaces helix_picosoc_mem)
    // 64 × 128-bit = 1 KB, matching the default MEM_WORDS=256 SRAM.
    // =========================================================================
    logic [127:0] mem_model [0:63];

    always_ff @(posedge clk) begin
        if (vec_mem_en) begin
            vec_mem_rdata <= mem_model[vec_mem_addr[9:4]];
            if (vec_mem_we)
                mem_model[vec_mem_addr[9:4]] <= vec_mem_wdata;
        end
    end

    // =========================================================================
    // DUT
    // =========================================================================
    helix_vcop #(.VLEN(128)) dut (
        .clk          (clk),
        .resetn       (resetn),
        .pcpi_valid   (pcpi_valid),
        .pcpi_insn    (pcpi_insn),
        .pcpi_rs1     (pcpi_rs1),
        .pcpi_rs2     (pcpi_rs2),
        .pcpi_wr      (pcpi_wr),
        .pcpi_rd      (pcpi_rd),
        .pcpi_wait    (pcpi_wait),
        .pcpi_ready   (pcpi_ready),
        .vec_mem_en   (vec_mem_en),
        .vec_mem_we   (vec_mem_we),
        .vec_mem_addr (vec_mem_addr),
        .vec_mem_wdata(vec_mem_wdata),
        .vec_mem_rdata(vec_mem_rdata)
    );

    // =========================================================================
    // Clock — 100 MHz
    // =========================================================================
    initial clk = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // Test tracking
    // =========================================================================
    int tests_run  = 0;
    int tests_pass = 0;
    int tests_fail = 0;

    task automatic check(input string name, input logic pass);
        tests_run++;
        if (pass) begin
            tests_pass++;
            $display("  [PASS] %s", name);
        end else begin
            tests_fail++;
            $display("  [FAIL] %s", name);
        end
    endtask

    // =========================================================================
    // Instruction word builder
    // =========================================================================
    function automatic logic [31:0] hvx_insn(
        input logic [4:0] opid,
        input logic [1:0] ew,
        input logic [2:0] vs2, vs1, vd,
        input logic [2:0] funct3
    );
        return {opid, ew, 2'b00, vs2, 2'b00, vs1, funct3, 2'b00, vd, `HVX_OPCODE};
    endfunction

    // =========================================================================
    // BFM: issue one instruction, wait for completion, deassert
    // =========================================================================
    task automatic issue(input logic [31:0] insn, input logic [31:0] rs1, rs2);
        @(posedge clk);
        pcpi_valid <= 1'b1;
        pcpi_insn  <= insn;
        pcpi_rs1   <= rs1;
        pcpi_rs2   <= rs2;
        while (!pcpi_ready) @(posedge clk);
        @(posedge clk);
        pcpi_valid <= 1'b0;
        pcpi_insn  <= '0;
    endtask

    // =========================================================================
    // Helpers
    // =========================================================================
    task automatic load_q(input int qn, input logic [127:0] val, input int addr);
        mem_model[addr >> 4] = val;
        issue(hvx_insn(`HVX_OP_VLD128, `HVX_EW_8, 3'd0, 3'd0, qn[2:0], `HVX_CAT_LOAD),
              addr, 0);
    endtask

    task automatic store_q(input int qn, input int addr);
        issue(hvx_insn(`HVX_OP_VST128, `HVX_EW_8, qn[2:0], 3'd0, 3'd0, `HVX_CAT_STORE),
              addr, 0);
    endtask

    function automatic logic [127:0] read_mem(input int addr);
        return mem_model[addr >> 4];
    endfunction

    // =========================================================================
    // RESET
    // =========================================================================
    initial begin
        pcpi_valid = 0; pcpi_insn = 0; pcpi_rs1 = 0; pcpi_rs2 = 0;
        resetn = 0;
        repeat(4) @(posedge clk);
        resetn = 1;
        @(posedge clk);
    end

    // =========================================================================
    // TEST SUITE
    // =========================================================================
    initial begin : test_main
        logic [127:0] a128, b128, r128;
        logic [127:0] expect;
        logic [31:0]  rval;
        int i;

        wait(resetn);
        @(posedge clk);
        $display("\n=== Helix Vector ISA Testbench ===\n");

        // ------------------------------------------------------------------
        // T01: VLD.128
        // ------------------------------------------------------------------
        $display("--- T01: VLD.128 ---");
        a128 = 128'hDEAD_BEEF_CAFE_BABE_1234_5678_9ABC_DEF0;
        load_q(0, a128, 32'h0000_0000);
        store_q(0, 32'h0000_0100);
        r128 = read_mem(32'h0000_0100);
        check("VLD.128 round-trip", r128 === a128);

        // ------------------------------------------------------------------
        // T02: VST.128 byte ordering
        // ------------------------------------------------------------------
        $display("--- T02: VST.128 byte order ---");
        check("VST.128 lane[0]=LSB",  r128[7:0]    === 8'hF0);
        check("VST.128 lane[15]=MSB", r128[127:120] === 8'hDE);

        // ------------------------------------------------------------------
        // T03: VADD.S8 — saturating signed add
        // ------------------------------------------------------------------
        $display("--- T03: VADD.S8 ---");
        a128 = {112'h0, 8'h00, 8'h0A, 8'h9C, 8'h64};
        b128 = {112'h0, 8'h00, 8'h14, 8'hCE, 8'h32};
        load_q(1, a128, 32'h0000_0010);
        load_q(2, b128, 32'h0000_0020);
        issue(hvx_insn(`HVX_OP_VADD, `HVX_EW_8, 3'd2, 3'd1, 3'd3, `HVX_CAT_ARITH), 0, 0);
        store_q(3, 32'h0000_0030);
        r128 = read_mem(32'h0000_0030);
        check("VADD.S8 pos sat to +127",  r128[7:0]   === 8'h7F);
        check("VADD.S8 neg sat to -128",  r128[15:8]  === 8'h80);
        check("VADD.S8 normal 10+20=30",  r128[23:16] === 8'h1E);
        check("VADD.S8 zero lane",        r128[31:24] === 8'h00);

        // ------------------------------------------------------------------
        // T04: VSUB.S8 — standard cases
        // ------------------------------------------------------------------
        $display("--- T04: VSUB.S8 ---");
        a128 = {120'h0, 8'h7F, 8'h80};
        b128 = {120'h0, 8'hFF, 8'h01};
        load_q(1, a128, 32'h0000_0010);
        load_q(2, b128, 32'h0000_0020);
        issue(hvx_insn(`HVX_OP_VSUB, `HVX_EW_8, 3'd2, 3'd1, 3'd3, `HVX_CAT_ARITH), 0, 0);
        store_q(3, 32'h0000_0030);
        r128 = read_mem(32'h0000_0030);
        check("VSUB.S8 neg sat -128-1=-128",  r128[7:0]  === 8'h80);
        check("VSUB.S8 pos sat 127-(-1)=127", r128[15:8] === 8'h7F);

        // ------------------------------------------------------------------
        // T05: VMIN / VMAX
        // ------------------------------------------------------------------
        $display("--- T05: VMIN/VMAX.S8 ---");
        a128 = {120'h0, 8'h10, 8'hF0};
        b128 = {120'h0, 8'h20, 8'h05};
        load_q(1, a128, 32'h0000_0010);
        load_q(2, b128, 32'h0000_0020);
        issue(hvx_insn(`HVX_OP_VMIN, `HVX_EW_8, 3'd2, 3'd1, 3'd3, `HVX_CAT_ARITH), 0, 0);
        store_q(3, 32'h0000_0030);
        r128 = read_mem(32'h0000_0030);
        check("VMIN.S8 min(-16,5)=-16", r128[7:0]  === 8'hF0);
        check("VMIN.S8 min(16,32)=16",  r128[15:8] === 8'h10);
        issue(hvx_insn(`HVX_OP_VMAX, `HVX_EW_8, 3'd2, 3'd1, 3'd4, `HVX_CAT_ARITH), 0, 0);
        store_q(4, 32'h0000_0040);
        r128 = read_mem(32'h0000_0040);
        check("VMAX.S8 max(-16,5)=5",   r128[7:0]  === 8'h05);
        check("VMAX.S8 max(16,32)=32",  r128[15:8] === 8'h20);

        // ------------------------------------------------------------------
        // T06: VMUL.S8 — lower half
        // ------------------------------------------------------------------
        $display("--- T06: VMUL.S8 ---");
        a128 = {120'h0, 8'h10, 8'h03};
        b128 = {120'h0, 8'h10, 8'h04};
        load_q(1, a128, 32'h0000_0010);
        load_q(2, b128, 32'h0000_0020);
        issue(hvx_insn(`HVX_OP_VMUL, `HVX_EW_8, 3'd2, 3'd1, 3'd3, `HVX_CAT_ARITH), 0, 0);
        store_q(3, 32'h0000_0030);
        r128 = read_mem(32'h0000_0030);
        check("VMUL.S8 3×4=12 lower",  r128[7:0]  === 8'h0C);
        check("VMUL.S8 16×16 wrap=0",  r128[15:8] === 8'h00);

        // ------------------------------------------------------------------
        // T07: VMULH.S8 — upper half
        // ------------------------------------------------------------------
        $display("--- T07: VMULH.S8 ---");
        a128 = {120'h0, 8'hC0, 8'h64};
        b128 = {120'h0, 8'h02, 8'h64};
        load_q(1, a128, 32'h0000_0010);
        load_q(2, b128, 32'h0000_0020);
        issue(hvx_insn(`HVX_OP_VMULH, `HVX_EW_8, 3'd2, 3'd1, 3'd3, `HVX_CAT_ARITH), 0, 0);
        store_q(3, 32'h0000_0030);
        r128 = read_mem(32'h0000_0030);
        check("VMULH.S8 100×100 upper=39", r128[7:0]  === 8'h27);
        check("VMULH.S8 -64×2 upper=-1",   r128[15:8] === 8'hFF);

        // ------------------------------------------------------------------
        // T08: VABS.S8
        // ------------------------------------------------------------------
        $display("--- T08: VABS.S8 ---");
        a128 = {112'h0, 8'h05, 8'hFF, 8'h80};
        load_q(1, a128, 32'h0000_0010);
        issue(hvx_insn(`HVX_OP_VABS, `HVX_EW_8, 3'd0, 3'd1, 3'd3, `HVX_CAT_ARITH), 0, 0);
        store_q(3, 32'h0000_0030);
        r128 = read_mem(32'h0000_0030);
        check("VABS.S8 abs(-128)=127 sat", r128[7:0]   === 8'h7F);
        check("VABS.S8 abs(-1)=1",         r128[15:8]  === 8'h01);
        check("VABS.S8 abs(5)=5",          r128[23:16] === 8'h05);

        // ------------------------------------------------------------------
        // T09: VADD.S16
        // ------------------------------------------------------------------
        $display("--- T09: VADD.S16 ---");
        a128 = {96'h0, 16'h0064, 16'h7FFF};
        b128 = {96'h0, 16'h00C8, 16'h0001};
        load_q(1, a128, 32'h0000_0010);
        load_q(2, b128, 32'h0000_0020);
        issue(hvx_insn(`HVX_OP_VADD, `HVX_EW_16, 3'd2, 3'd1, 3'd3, `HVX_CAT_ARITH), 0, 0);
        store_q(3, 32'h0000_0030);
        r128 = read_mem(32'h0000_0030);
        check("VADD.S16 sat 0x7FFF+1=0x7FFF", r128[15:0]  === 16'h7FFF);
        check("VADD.S16 100+200=300",          r128[31:16] === 16'h012C);

        // ------------------------------------------------------------------
        // T10: VADD.S32
        // ------------------------------------------------------------------
        $display("--- T10: VADD.S32 ---");
        a128 = {64'h0, 32'h7FFF_FFFF, 32'h0000_000A};
        b128 = {64'h0, 32'h0000_0001, 32'h0000_0005};
        load_q(1, a128, 32'h0000_0010);
        load_q(2, b128, 32'h0000_0020);
        issue(hvx_insn(`HVX_OP_VADD, `HVX_EW_32, 3'd2, 3'd1, 3'd3, `HVX_CAT_ARITH), 0, 0);
        store_q(3, 32'h0000_0030);
        r128 = read_mem(32'h0000_0030);
        check("VADD.S32 10+5=15",              r128[31:0]  === 32'h0000_000F);
        check("VADD.S32 sat 0x7FFFFFFF+1=sat", r128[63:32] === 32'h7FFF_FFFF);

        // ------------------------------------------------------------------
        // T11: VMOVS — broadcast scalar
        // ------------------------------------------------------------------
        $display("--- T11: VMOVS ---");
        issue(hvx_insn(`HVX_OP_VMOVS, `HVX_EW_8, 3'd0, 3'd0, 3'd5, `HVX_CAT_MISC),
              32'h0000_0042, 0);
        store_q(5, 32'h0000_0050);
        r128 = read_mem(32'h0000_0050);
        check("VMOVS.S8 all lanes=0x42", r128 === {16{8'h42}});

        issue(hvx_insn(`HVX_OP_VMOVS, `HVX_EW_16, 3'd0, 3'd0, 3'd5, `HVX_CAT_MISC),
              32'h0000_1234, 0);
        store_q(5, 32'h0000_0050);
        r128 = read_mem(32'h0000_0050);
        check("VMOVS.S16 all lanes=0x1234", r128 === {8{16'h1234}});

        // ------------------------------------------------------------------
        // T12: VMOV
        // ------------------------------------------------------------------
        $display("--- T12: VMOV ---");
        a128 = 128'hAABB_CCDD_EEFF_0011_2233_4455_6677_8899;
        load_q(0, a128, 32'h0000_0000);
        issue(hvx_insn(`HVX_OP_VMOV, `HVX_EW_8, 3'd0, 3'd0, 3'd7, `HVX_CAT_MISC), 0, 0);
        store_q(7, 32'h0000_0070);
        r128 = read_mem(32'h0000_0070);
        check("VMOV Q0→Q7", r128 === a128);

        // ------------------------------------------------------------------
        // T13: VMAC / VCLRACC / VGETACC — int8
        // ------------------------------------------------------------------
        $display("--- T13: VMAC / VCLRACC / VGETACC ---");
        a128 = {16{8'h01}};
        b128 = {16{8'h02}};
        load_q(1, a128, 32'h0000_0010);
        load_q(2, b128, 32'h0000_0020);
        issue(hvx_insn(`HVX_OP_VCLRACC, `HVX_EW_8, 3'd0, 3'd0, 3'd0, `HVX_CAT_MAC), 0, 0);
        issue(hvx_insn(`HVX_OP_VMAC,    `HVX_EW_8, 3'd2, 3'd1, 3'd0, `HVX_CAT_MAC), 0, 0);
        issue(hvx_insn(`HVX_OP_VGETACC, `HVX_EW_8, 3'd0, 3'd0, 3'd0, `HVX_CAT_MAC), 0, 32'd0);
        rval = pcpi_rd;
        check("VCLRACC+VMAC+VGETACC=32", rval === 32'd32);
        check("VGETACC asserts pcpi_wr",  pcpi_wr === 1'b1);

        // Cumulative: ACCX was not cleared, second VMAC adds 32 more
        issue(hvx_insn(`HVX_OP_VMAC,    `HVX_EW_8, 3'd2, 3'd1, 3'd0, `HVX_CAT_MAC), 0, 0);
        issue(hvx_insn(`HVX_OP_VGETACC, `HVX_EW_8, 3'd0, 3'd0, 3'd0, `HVX_CAT_MAC), 0, 32'd0);
        rval = pcpi_rd;
        check("Cumulative VMAC ACCX=64", rval === 32'd64);

        // Shift: 64 >> 1 = 32
        issue(hvx_insn(`HVX_OP_VGETACC, `HVX_EW_8, 3'd0, 3'd0, 3'd0, `HVX_CAT_MAC), 0, 32'd1);
        rval = pcpi_rd;
        check("VGETACC shift=1: 64>>1=32", rval === 32'd32);

        // Non-VGETACC must not assert pcpi_wr
        issue(hvx_insn(`HVX_OP_VCLRACC, `HVX_EW_8, 3'd0, 3'd0, 3'd0, `HVX_CAT_MAC), 0, 0);
        check("VCLRACC: pcpi_wr=0",  pcpi_wr === 1'b0);
        check("VCLRACC: pcpi_rd=0",  pcpi_rd === 32'h0);

        // ------------------------------------------------------------------
        // T14: VMAC.S16
        // ------------------------------------------------------------------
        $display("--- T14: VMAC.S16 ---");
        a128 = {8{16'h000A}};
        b128 = {8{16'h0003}};
        load_q(1, a128, 32'h0000_0010);
        load_q(2, b128, 32'h0000_0020);
        issue(hvx_insn(`HVX_OP_VCLRACC, `HVX_EW_16, 3'd0, 3'd0, 3'd0, `HVX_CAT_MAC), 0, 0);
        issue(hvx_insn(`HVX_OP_VMAC,    `HVX_EW_16, 3'd2, 3'd1, 3'd0, `HVX_CAT_MAC), 0, 0);
        issue(hvx_insn(`HVX_OP_VGETACC, `HVX_EW_16, 3'd0, 3'd0, 3'd0, `HVX_CAT_MAC), 0, 32'd0);
        check("VMAC.S16 8×30=240", pcpi_rd === 32'd240);

        // ------------------------------------------------------------------
        // T15: VAND / VOR / VXOR
        // ------------------------------------------------------------------
        $display("--- T15: VAND/VOR/VXOR ---");
        a128 = {16{8'hAA}};
        b128 = {16{8'h55}};
        load_q(1, a128, 32'h0000_0010);
        load_q(2, b128, 32'h0000_0020);
        issue(hvx_insn(`HVX_OP_VAND, `HVX_EW_8, 3'd2, 3'd1, 3'd3, `HVX_CAT_ARITH), 0, 0);
        store_q(3, 32'h0000_0030);
        r128 = read_mem(32'h0000_0030);
        check("VAND 0xAA & 0x55 = 0x00", r128 === 128'h0);
        issue(hvx_insn(`HVX_OP_VOR,  `HVX_EW_8, 3'd2, 3'd1, 3'd3, `HVX_CAT_ARITH), 0, 0);
        store_q(3, 32'h0000_0030);
        r128 = read_mem(32'h0000_0030);
        check("VOR  0xAA | 0x55 = 0xFF", r128 === {16{8'hFF}});
        issue(hvx_insn(`HVX_OP_VXOR, `HVX_EW_8, 3'd2, 3'd1, 3'd3, `HVX_CAT_ARITH), 0, 0);
        store_q(3, 32'h0000_0030);
        r128 = read_mem(32'h0000_0030);
        check("VXOR 0xAA ^ 0x55 = 0xFF", r128 === {16{8'hFF}});

        // ------------------------------------------------------------------
        // T16: Non-Helix instruction — coprocessor must NOT respond
        // ------------------------------------------------------------------
        $display("--- T16: Non-Helix passthrough ---");
        @(posedge clk);
        pcpi_valid <= 1'b1;
        pcpi_insn  <= 32'h0000_0033;  // ADD x0,x0,x0 — opcode 0x33, not 0x2B
        pcpi_rs1   <= 0;
        pcpi_rs2   <= 0;
        repeat(6) @(posedge clk);
        check("Non-HVX: pcpi_wait=0",  pcpi_wait  === 1'b0);
        check("Non-HVX: pcpi_ready=0", pcpi_ready === 1'b0);
        pcpi_valid <= 1'b0;
        @(posedge clk);

        // ------------------------------------------------------------------
        // T17: Unaligned VLD — auto-aligned in LSU
        // ------------------------------------------------------------------
        $display("--- T17: Unaligned VLD (auto-align) ---");
        a128 = 128'h0102_0304_0506_0708_090A_0B0C_0D0E_0F10;
        mem_model[32'h0000_0200 >> 4] = a128;
        issue(hvx_insn(`HVX_OP_VLD128, `HVX_EW_8, 3'd0, 3'd0, 3'd6, `HVX_CAT_LOAD),
              32'h0000_0205, 0);
        store_q(6, 32'h0000_0300);
        r128 = read_mem(32'h0000_0300);
        check("Unaligned VLD loads aligned block", r128 === a128);

        // ------------------------------------------------------------------
        // T18: VSUB.S8 INT_MIN edge case
        // Bug: sat_sub(0, INT_MIN) previously returned INT_MIN (wrong) because
        // negating INT_MIN via ~b+1 overflows back to INT_MIN. Fix widened the
        // subtraction to N+1 bits so negation of the operand is not needed.
        // ------------------------------------------------------------------
        $display("--- T18: VSUB.S8 INT_MIN edge case ---");
        // Lane 0: 0 - (-128) should saturate to +127
        // Lane 1: -128 - (-128) = 0 (exact, no saturation)
        // Lane 2: 127 - (-128) should saturate to +127
        a128 = {112'h0, 8'h7F, 8'h80, 8'h00};
        b128 = {112'h0, 8'h80, 8'h80, 8'h80};
        load_q(1, a128, 32'h0000_0010);
        load_q(2, b128, 32'h0000_0020);
        issue(hvx_insn(`HVX_OP_VSUB, `HVX_EW_8, 3'd2, 3'd1, 3'd3, `HVX_CAT_ARITH), 0, 0);
        store_q(3, 32'h0000_0030);
        r128 = read_mem(32'h0000_0030);
        check("VSUB.S8 0-INT_MIN=+127 sat",      r128[7:0]   === 8'h7F);
        check("VSUB.S8 INT_MIN-INT_MIN=0",        r128[15:8]  === 8'h00);
        check("VSUB.S8 127-INT_MIN=+127 sat",     r128[23:16] === 8'h7F);

        // ------------------------------------------------------------------
        // T19: VSUB.S16 INT_MIN edge case
        // ------------------------------------------------------------------
        $display("--- T19: VSUB.S16 INT_MIN edge case ---");
        // Lane 0: 0 - INT_MIN16 should saturate to +32767
        // Lane 1: INT_MIN16 - INT_MIN16 = 0
        a128 = {96'h0, 16'h8000, 16'h0000};
        b128 = {96'h0, 16'h8000, 16'h8000};
        load_q(1, a128, 32'h0000_0010);
        load_q(2, b128, 32'h0000_0020);
        issue(hvx_insn(`HVX_OP_VSUB, `HVX_EW_16, 3'd2, 3'd1, 3'd3, `HVX_CAT_ARITH), 0, 0);
        store_q(3, 32'h0000_0030);
        r128 = read_mem(32'h0000_0030);
        check("VSUB.S16 0-INT_MIN16=+32767 sat",   r128[15:0]  === 16'h7FFF);
        check("VSUB.S16 INT_MIN16-INT_MIN16=0",     r128[31:16] === 16'h0000);

        // ------------------------------------------------------------------
        // T20: VSUB.S32 INT_MIN edge case
        // ------------------------------------------------------------------
        $display("--- T20: VSUB.S32 INT_MIN edge case ---");
        // Lane 0: 0 - INT_MIN32 should saturate to +0x7FFFFFFF
        // Lane 1: INT_MIN32 - INT_MIN32 = 0
        a128 = {64'h0, 32'h8000_0000, 32'h0000_0000};
        b128 = {64'h0, 32'h8000_0000, 32'h8000_0000};
        load_q(1, a128, 32'h0000_0010);
        load_q(2, b128, 32'h0000_0020);
        issue(hvx_insn(`HVX_OP_VSUB, `HVX_EW_32, 3'd2, 3'd1, 3'd3, `HVX_CAT_ARITH), 0, 0);
        store_q(3, 32'h0000_0030);
        r128 = read_mem(32'h0000_0030);
        check("VSUB.S32 0-INT_MIN32=0x7FFFFFFF sat", r128[31:0]  === 32'h7FFF_FFFF);
        check("VSUB.S32 INT_MIN32-INT_MIN32=0",       r128[63:32] === 32'h0000_0000);

        // ------------------------------------------------------------------
        // T21: funct3 disambiguation — VMAC vs VADD (both op_id=0)
        //
        // Before the funct3 fix, the ALU received no funct3 signal. When
        // op_id=0 arrived, the case statement matched HVX_OP_VADD regardless
        // of whether the instruction was VADD (CAT_ARITH) or VMAC (CAT_MAC).
        // This meant VMAC would incorrectly write a lane result to vd and also
        // attempt to accumulate — double action instead of accumulate-only.
        //
        // Test: Load Q1=[1,...,1], Q2=[1,...,1]. Run VMAC (should accumulate
        // 16 into ACCX, no Q3 write). Then run VADD into Q3 (should produce
        // Q3=[2,...,2]). If funct3 was broken, Q3 would be corrupted by the
        // VMAC lane result before the VADD runs.
        // ------------------------------------------------------------------
        $display("--- T21: funct3 disambiguation VMAC vs VADD ---");
        a128 = {16{8'h01}};
        load_q(1, a128, 32'h0000_0010);
        load_q(2, a128, 32'h0000_0020);

        // Zero Q3 first so we can detect any spurious VMAC write
        issue(hvx_insn(`HVX_OP_VMOVS, `HVX_EW_8, 3'd0, 3'd0, 3'd3, `HVX_CAT_MISC),
              32'h0, 0);

        // Clear accumulator and run VMAC
        issue(hvx_insn(`HVX_OP_VCLRACC, `HVX_EW_8, 3'd0, 3'd0, 3'd0, `HVX_CAT_MAC), 0, 0);
        issue(hvx_insn(`HVX_OP_VMAC,    `HVX_EW_8, 3'd2, 3'd1, 3'd3, `HVX_CAT_MAC), 0, 0);

        // Q3 must still be zero — VMAC must not have written it
        store_q(3, 32'h0000_0030);
        r128 = read_mem(32'h0000_0030);
        check("VMAC does not write vd (funct3 gate)", r128 === 128'h0);

        // Verify ACCX was actually updated (VMAC did accumulate)
        issue(hvx_insn(`HVX_OP_VGETACC, `HVX_EW_8, 3'd0, 3'd0, 3'd0, `HVX_CAT_MAC), 0, 32'd0);
        check("VMAC accumulates ACCX=16", pcpi_rd === 32'd16);

        // Now run VADD Q1+Q2→Q3, which should write Q3=[2,...,2]
        issue(hvx_insn(`HVX_OP_VADD, `HVX_EW_8, 3'd2, 3'd1, 3'd3, `HVX_CAT_ARITH), 0, 0);
        store_q(3, 32'h0000_0030);
        r128 = read_mem(32'h0000_0030);
        check("VADD writes vd correctly after VMAC", r128 === {16{8'h02}});

        // ------------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------------
        @(posedge clk);
        $display("\n=== Results: %0d/%0d passed, %0d failed ===\n",
                 tests_pass, tests_run, tests_fail);
        if (tests_fail == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED — check above");

        $finish;
    end

    // Timeout watchdog — extended to cover the new tests
    initial begin
        #700000;
        $display("[TIMEOUT] Simulation exceeded 700us");
        $finish;
    end

endmodule
