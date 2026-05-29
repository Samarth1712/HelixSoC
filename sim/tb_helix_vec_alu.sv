// =============================================================================
// tb_helix_vec_alu.sv — Unit Testbench for Helix SIMD ALU
// =============================================================================
// Tests helix_vec_alu in isolation — purely combinational module, no clock
// needed for most tests. A clock is present only for the SIMULATION initial
// assertions inside the ALU itself.
//
// Coverage:
//   All arithmetic operations across all three element widths (int8/16/32)
//   Saturation boundaries (INT_MAX + 1, INT_MIN - 1)
//   VSUB INT_MIN edge case (the old sat_add(a,~b+1) bug)
//   VMULH upper-half correctness
//   VABS INT_MIN saturation
//   MAC partial sum (mac_partial output) across all widths
//   funct3 gating — VMAC (op_id=0, funct3=MAC) must not produce vd output;
//                   VADD (op_id=0, funct3=ARITH) must not produce mac_partial
//   VMOVS broadcast for all element widths
//   VMOV register copy
//   Bitwise AND/OR/XOR
//
// Run with: vcs -sverilog -full64 tb_helix_vec_alu.sv helix_vec_alu.sv
//           +define+SIMULATION +incdir+../rtl
// =============================================================================

`timescale 1ns/1ps
`include "helix_vec_defs.svh"

module tb_helix_vec_alu;

    // =========================================================================
    // DUT signals
    // =========================================================================
    localparam VLEN = 128;

    logic [VLEN-1:0]        vs1, vs2;
    logic [4:0]             op_id;
    logic [1:0]             elem_width;
    logic [2:0]             funct3;
    logic [31:0]            scalar_rs1;

    logic [VLEN-1:0]        vd;
    logic signed [63:0]     mac_partial;

    helix_vec_alu #(.VLEN(VLEN)) dut (
        .vs1        (vs1),
        .vs2        (vs2),
        .op_id      (op_id),
        .elem_width (elem_width),
        .funct3     (funct3),
        .scalar_rs1 (scalar_rs1),
        .vd         (vd),
        .mac_partial(mac_partial)
    );

    // Clock — only needed to let ALU's SIMULATION initial block fire
    logic clk = 0;
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
            $display("  [FAIL] %s  (got vd[31:0]=%0h mac=%0d)", name, vd[31:0], mac_partial);
        end
    endtask

    // =========================================================================
    // Helpers — build packed lane vectors
    // =========================================================================

    // Fill all int8 lanes with the same value
    function automatic logic [127:0] fill8(input logic [7:0] val);
        fill8 = {16{val}};
    endfunction

    // Fill all int16 lanes with the same value
    function automatic logic [127:0] fill16(input logic [15:0] val);
        fill16 = {8{val}};
    endfunction

    // Fill all int32 lanes with the same value
    function automatic logic [127:0] fill32(input logic [31:0] val);
        fill32 = {4{val}};
    endfunction

    // Set one int8 lane, rest zero
    function automatic logic [127:0] lane8(input int lane, input logic [7:0] val);
        logic [127:0] r;
        r = 128'h0;
        r[8*lane +: 8] = val;
        return r;
    endfunction

    // Set one int16 lane, rest zero
    function automatic logic [127:0] lane16(input int lane, input logic [15:0] val);
        logic [127:0] r;
        r = 128'h0;
        r[16*lane +: 16] = val;
        return r;
    endfunction

    // Set one int32 lane, rest zero
    function automatic logic [127:0] lane32(input int lane, input logic [31:0] val);
        logic [127:0] r;
        r = 128'h0;
        r[32*lane +: 32] = val;
        return r;
    endfunction

    // Apply inputs and wait for combinational propagation
    task automatic apply(
        input logic [4:0]    _opid,
        input logic [1:0]    _ew,
        input logic [2:0]    _f3,
        input logic [127:0]  _vs1,
        input logic [127:0]  _vs2,
        input logic [31:0]   _rs1
    );
        op_id       = _opid;
        elem_width  = _ew;
        funct3      = _f3;
        vs1         = _vs1;
        vs2         = _vs2;
        scalar_rs1  = _rs1;
        #1;   // combinational settle
    endtask

    // =========================================================================
    // TEST SUITE
    // =========================================================================
    initial begin : test_main
        $display("\n=== Helix ALU Unit Testbench ===\n");

        // Default inputs
        vs1 = 0; vs2 = 0; op_id = 0; elem_width = 0;
        funct3 = `HVX_CAT_ARITH; scalar_rs1 = 0;
        #2;

        // ==================================================================
        // INT8 ARITHMETIC
        // ==================================================================
        $display("--- VADD.S8 ---");

        // Normal: 10 + 20 = 30
        apply(`HVX_OP_VADD, `HVX_EW_8, `HVX_CAT_ARITH,
              fill8(8'h0A), fill8(8'h14), 0);
        check("VADD.S8 10+20=30 all lanes", vd === fill8(8'h1E));

        // Positive saturation: 100 + 50 → +127
        apply(`HVX_OP_VADD, `HVX_EW_8, `HVX_CAT_ARITH,
              lane8(0, 8'h64), lane8(0, 8'h32), 0);
        check("VADD.S8 100+50 sat=127", vd[7:0] === 8'h7F);

        // Negative saturation: -100 + (-50) → -128
        apply(`HVX_OP_VADD, `HVX_EW_8, `HVX_CAT_ARITH,
              lane8(0, 8'h9C), lane8(0, 8'hCE), 0);
        check("VADD.S8 -100+(-50) sat=-128", $signed(vd[7:0]) === -128);

        $display("--- VSUB.S8 ---");

        // Normal: 30 - 10 = 20
        apply(`HVX_OP_VSUB, `HVX_EW_8, `HVX_CAT_ARITH,
              fill8(8'h1E), fill8(8'h0A), 0);
        check("VSUB.S8 30-10=20 all lanes", vd === fill8(8'h14));

        // Positive saturation: 127 - (-1) → +127
        apply(`HVX_OP_VSUB, `HVX_EW_8, `HVX_CAT_ARITH,
              lane8(0, 8'h7F), lane8(0, 8'hFF), 0);
        check("VSUB.S8 127-(-1) sat=127", vd[7:0] === 8'h7F);

        // Negative saturation: -128 - 1 → -128
        apply(`HVX_OP_VSUB, `HVX_EW_8, `HVX_CAT_ARITH,
              lane8(0, 8'h80), lane8(0, 8'h01), 0);
        check("VSUB.S8 -128-1 sat=-128", vd[7:0] === 8'h80);

        // --- INT_MIN EDGE CASE (the old sat_add(a,~b+1) bug) ---
        // sat_sub(0, INT_MIN): old code computed sat_add(0, ~0x80+1) = sat_add(0, 0x80)
        // = sat_add(0, -128) = -128. Correct result = +127 (saturated).
        apply(`HVX_OP_VSUB, `HVX_EW_8, `HVX_CAT_ARITH,
              lane8(0, 8'h00), lane8(0, 8'h80), 0);
        check("VSUB.S8 0-INT_MIN = +127 sat [INT_MIN bug]", vd[7:0] === 8'h7F);

        // sat_sub(INT_MIN, INT_MIN) = 0 (exact, no saturation)
        apply(`HVX_OP_VSUB, `HVX_EW_8, `HVX_CAT_ARITH,
              lane8(0, 8'h80), lane8(0, 8'h80), 0);
        check("VSUB.S8 INT_MIN-INT_MIN = 0", vd[7:0] === 8'h00);

        // sat_sub(127, INT_MIN) = 255 → saturates to +127
        apply(`HVX_OP_VSUB, `HVX_EW_8, `HVX_CAT_ARITH,
              lane8(0, 8'h7F), lane8(0, 8'h80), 0);
        check("VSUB.S8 127-INT_MIN = +127 sat", vd[7:0] === 8'h7F);

        $display("--- VMIN/VMAX.S8 ---");

        apply(`HVX_OP_VMIN, `HVX_EW_8, `HVX_CAT_ARITH,
              lane8(0, 8'h10), lane8(0, 8'hF0), 0);
        check("VMIN.S8 min(16,-16)=-16", $signed(vd[7:0]) === -16);

        apply(`HVX_OP_VMAX, `HVX_EW_8, `HVX_CAT_ARITH,
              lane8(0, 8'h10), lane8(0, 8'hF0), 0);
        check("VMAX.S8 max(16,-16)=16", vd[7:0] === 8'h10);

        $display("--- VMUL.S8 ---");

        apply(`HVX_OP_VMUL, `HVX_EW_8, `HVX_CAT_ARITH,
              lane8(0, 8'h03), lane8(0, 8'h04), 0);
        check("VMUL.S8 3×4=12", vd[7:0] === 8'h0C);

        // 16×16 = 256; lower 8 bits = 0 (wraps)
        apply(`HVX_OP_VMUL, `HVX_EW_8, `HVX_CAT_ARITH,
              lane8(0, 8'h10), lane8(0, 8'h10), 0);
        check("VMUL.S8 16×16 wrap=0", vd[7:0] === 8'h00);

        $display("--- VMULH.S8 ---");

        // 100×100 = 10000 = 0x2710; upper byte = 0x27 = 39
        apply(`HVX_OP_VMULH, `HVX_EW_8, `HVX_CAT_ARITH,
              lane8(0, 8'h64), lane8(0, 8'h64), 0);
        check("VMULH.S8 100×100 upper=39", vd[7:0] === 8'h27);

        // -64×2 = -128 = 0xFF80; upper byte = 0xFF = -1 as signed
        apply(`HVX_OP_VMULH, `HVX_EW_8, `HVX_CAT_ARITH,
              lane8(0, 8'hC0), lane8(0, 8'h02), 0);
        check("VMULH.S8 -64×2 upper=-1", $signed(vd[7:0]) === -1);

        // 64×(-1) = -64 = 0xFFC0; upper byte = 0xFF = -1 as signed
        apply(`HVX_OP_VMULH, `HVX_EW_8, `HVX_CAT_ARITH,
              lane8(0, 8'h40), lane8(0, 8'hFF), 0);
        check("VMULH.S8 64×(-1) upper=-1", $signed(vd[7:0]) === -1);

        $display("--- VABS.S8 ---");

        apply(`HVX_OP_VABS, `HVX_EW_8, `HVX_CAT_ARITH,
              lane8(0, 8'hFF), '0, 0);
        check("VABS.S8 abs(-1)=1", vd[7:0] === 8'h01);

        apply(`HVX_OP_VABS, `HVX_EW_8, `HVX_CAT_ARITH,
              lane8(0, 8'h80), '0, 0);
        check("VABS.S8 abs(INT_MIN)=127 sat", vd[7:0] === 8'h7F);

        apply(`HVX_OP_VABS, `HVX_EW_8, `HVX_CAT_ARITH,
              lane8(0, 8'h7F), '0, 0);
        check("VABS.S8 abs(127)=127", vd[7:0] === 8'h7F);

        $display("--- VAND/VOR/VXOR.S8 ---");

        apply(`HVX_OP_VAND, `HVX_EW_8, `HVX_CAT_ARITH,
              fill8(8'hAA), fill8(8'h55), 0);
        check("VAND 0xAA & 0x55 = 0x00", vd === 128'h0);

        apply(`HVX_OP_VOR, `HVX_EW_8, `HVX_CAT_ARITH,
              fill8(8'hAA), fill8(8'h55), 0);
        check("VOR  0xAA | 0x55 = 0xFF", vd === fill8(8'hFF));

        apply(`HVX_OP_VXOR, `HVX_EW_8, `HVX_CAT_ARITH,
              fill8(8'hAA), fill8(8'h55), 0);
        check("VXOR 0xAA ^ 0x55 = 0xFF", vd === fill8(8'hFF));

        apply(`HVX_OP_VXOR, `HVX_EW_8, `HVX_CAT_ARITH,
              fill8(8'hFF), fill8(8'hFF), 0);
        check("VXOR 0xFF ^ 0xFF = 0x00", vd === 128'h0);

        // ==================================================================
        // INT16 ARITHMETIC
        // ==================================================================
        $display("--- VADD.S16 ---");

        apply(`HVX_OP_VADD, `HVX_EW_16, `HVX_CAT_ARITH,
              fill16(16'h0064), fill16(16'h00C8), 0);
        check("VADD.S16 100+200=300 all lanes", vd === fill16(16'h012C));

        // Positive saturation
        apply(`HVX_OP_VADD, `HVX_EW_16, `HVX_CAT_ARITH,
              lane16(0, 16'h7FFF), lane16(0, 16'h0001), 0);
        check("VADD.S16 0x7FFF+1 sat=0x7FFF", vd[15:0] === 16'h7FFF);

        // Negative saturation
        apply(`HVX_OP_VADD, `HVX_EW_16, `HVX_CAT_ARITH,
              lane16(0, 16'h8000), lane16(0, 16'hFFFF), 0);
        check("VADD.S16 INT_MIN+(-1) sat=INT_MIN", vd[15:0] === 16'h8000);

        $display("--- VSUB.S16 INT_MIN edge case ---");

        apply(`HVX_OP_VSUB, `HVX_EW_16, `HVX_CAT_ARITH,
              lane16(0, 16'h0000), lane16(0, 16'h8000), 0);
        check("VSUB.S16 0-INT_MIN16 = +32767 sat", vd[15:0] === 16'h7FFF);

        apply(`HVX_OP_VSUB, `HVX_EW_16, `HVX_CAT_ARITH,
              lane16(0, 16'h8000), lane16(0, 16'h8000), 0);
        check("VSUB.S16 INT_MIN16-INT_MIN16 = 0", vd[15:0] === 16'h0000);

        $display("--- VABS.S16 ---");

        apply(`HVX_OP_VABS, `HVX_EW_16, `HVX_CAT_ARITH,
              lane16(0, 16'h8000), '0, 0);
        check("VABS.S16 abs(INT_MIN16)=32767 sat", vd[15:0] === 16'h7FFF);

        // ==================================================================
        // INT32 ARITHMETIC
        // ==================================================================
        $display("--- VADD.S32 ---");

        apply(`HVX_OP_VADD, `HVX_EW_32, `HVX_CAT_ARITH,
              fill32(32'h0000_000A), fill32(32'h0000_0005), 0);
        check("VADD.S32 10+5=15 all lanes", vd === fill32(32'h0000_000F));

        // Positive saturation
        apply(`HVX_OP_VADD, `HVX_EW_32, `HVX_CAT_ARITH,
              lane32(0, 32'h7FFF_FFFF), lane32(0, 32'h0000_0001), 0);
        check("VADD.S32 INT_MAX+1 sat=INT_MAX", vd[31:0] === 32'h7FFF_FFFF);

        $display("--- VSUB.S32 INT_MIN edge case ---");

        apply(`HVX_OP_VSUB, `HVX_EW_32, `HVX_CAT_ARITH,
              lane32(0, 32'h0000_0000), lane32(0, 32'h8000_0000), 0);
        check("VSUB.S32 0-INT_MIN32 = 0x7FFFFFFF sat", vd[31:0] === 32'h7FFF_FFFF);

        apply(`HVX_OP_VSUB, `HVX_EW_32, `HVX_CAT_ARITH,
              lane32(0, 32'h8000_0000), lane32(0, 32'h8000_0000), 0);
        check("VSUB.S32 INT_MIN32-INT_MIN32 = 0", vd[31:0] === 32'h0000_0000);

        $display("--- VABS.S32 ---");

        apply(`HVX_OP_VABS, `HVX_EW_32, `HVX_CAT_ARITH,
              lane32(0, 32'h8000_0000), '0, 0);
        check("VABS.S32 abs(INT_MIN32)=0x7FFFFFFF sat", vd[31:0] === 32'h7FFF_FFFF);

        // ==================================================================
        // MISC — VMOVS and VMOV
        // ==================================================================
        $display("--- VMOVS ---");

        // Broadcast 0x42 to all int8 lanes
        apply(`HVX_OP_VMOVS, `HVX_EW_8, `HVX_CAT_MISC,
              '0, '0, 32'h0000_0042);
        check("VMOVS.S8 broadcast 0x42", vd === fill8(8'h42));

        // Broadcast 0x1234 to all int16 lanes (low 16 bits used)
        apply(`HVX_OP_VMOVS, `HVX_EW_16, `HVX_CAT_MISC,
              '0, '0, 32'h0000_1234);
        check("VMOVS.S16 broadcast 0x1234", vd === fill16(16'h1234));

        // Broadcast 0xDEAD_BEEF to all int32 lanes
        apply(`HVX_OP_VMOVS, `HVX_EW_32, `HVX_CAT_MISC,
              '0, '0, 32'hDEAD_BEEF);
        check("VMOVS.S32 broadcast 0xDEADBEEF", vd === fill32(32'hDEAD_BEEF));

        $display("--- VMOV ---");

        apply(`HVX_OP_VMOV, `HVX_EW_8, `HVX_CAT_MISC,
              128'hAABB_CCDD_EEFF_0011_2233_4455_6677_8899, '0, 0);
        check("VMOV copies vs1 to vd", vd === 128'hAABB_CCDD_EEFF_0011_2233_4455_6677_8899);

        // ==================================================================
        // MAC partial sum — mac_partial output
        // ==================================================================
        $display("--- mac_partial: VMAC.S8 ---");

        // All lanes = 1 × 1 = 1, sum over 16 lanes = 16
        apply(`HVX_OP_VMAC, `HVX_EW_8, `HVX_CAT_MAC,
              fill8(8'h01), fill8(8'h01), 0);
        check("VMAC.S8 16×(1×1)=16", mac_partial === 64'sd16);

        // All lanes = 2 × 3 = 6, sum over 16 = 96
        apply(`HVX_OP_VMAC, `HVX_EW_8, `HVX_CAT_MAC,
              fill8(8'h02), fill8(8'h03), 0);
        check("VMAC.S8 16×(2×3)=96", mac_partial === 64'sd96);

        // Negative: all lanes = -1 × 1 = -1, sum = -16
        apply(`HVX_OP_VMAC, `HVX_EW_8, `HVX_CAT_MAC,
              fill8(8'hFF), fill8(8'h01), 0);
        check("VMAC.S8 16×(-1×1)=-16", mac_partial === -64'sd16);

        // Mixed: vs1[0]=-128, vs2[0]=1 → product=-128; rest zero
        apply(`HVX_OP_VMAC, `HVX_EW_8, `HVX_CAT_MAC,
              lane8(0, 8'h80), lane8(0, 8'h01), 0);
        check("VMAC.S8 INT_MIN×1=-128 partial", mac_partial === -64'sd128);

        $display("--- mac_partial: VMAC.S16 ---");

        // All lanes = 10 × 3 = 30, sum over 8 = 240
        apply(`HVX_OP_VMAC, `HVX_EW_16, `HVX_CAT_MAC,
              fill16(16'h000A), fill16(16'h0003), 0);
        check("VMAC.S16 8×(10×3)=240", mac_partial === 64'sd240);

        // Large values: all lanes = 0x7FFF × 0x7FFF
        // 32767 × 32767 = 1,073,676,289 per lane × 8 lanes = 8,589,410,312
        apply(`HVX_OP_VMAC, `HVX_EW_16, `HVX_CAT_MAC,
              fill16(16'h7FFF), fill16(16'h7FFF), 0);
        check("VMAC.S16 8×(32767²) no overflow",
              mac_partial === 64'sd8_589_410_312);

        $display("--- mac_partial: VMAC.S32 ---");

        // Simple: 4 lanes = 10 × 5 = 50, sum = 200
        apply(`HVX_OP_VMAC, `HVX_EW_32, `HVX_CAT_MAC,
              fill32(32'h0000_000A), fill32(32'h0000_0005), 0);
        check("VMAC.S32 4×(10×5)=200", mac_partial === 64'sd200);

        // ==================================================================
        // FUNCT3 DISAMBIGUATION
        // The key correctness property: op_id=0 behaves differently
        // depending on funct3. Without funct3 gating these would be
        // identical to the ALU and the wrong operation would fire.
        // ==================================================================
        $display("--- funct3 gating: op_id=0 disambiguation ---");

        // VADD (op_id=0, funct3=ARITH): should produce vd output, mac_partial=0
        apply(`HVX_OP_VADD, `HVX_EW_8, `HVX_CAT_ARITH,
              fill8(8'h01), fill8(8'h01), 0);
        check("VADD (f3=ARITH, op=0): vd=2 all lanes", vd === fill8(8'h02));
        check("VADD (f3=ARITH, op=0): mac_partial=0",  mac_partial === 64'sd0);

        // VMAC (op_id=0, funct3=MAC): should produce mac_partial, vd=don't care
        // The important check is mac_partial is correct and is NOT zero.
        apply(`HVX_OP_VMAC, `HVX_EW_8, `HVX_CAT_MAC,
              fill8(8'h01), fill8(8'h01), 0);
        check("VMAC (f3=MAC,  op=0): mac_partial=16", mac_partial === 64'sd16);
        check("VMAC (f3=MAC,  op=0): vd=0 (no lane write)", vd === 128'h0);

        // VMOVS (op_id=0, funct3=MISC): should broadcast scalar, mac_partial=0
        apply(`HVX_OP_VMOVS, `HVX_EW_8, `HVX_CAT_MISC,
              fill8(8'hFF), fill8(8'hFF), 32'h0000_0055);
        check("VMOVS (f3=MISC, op=0): broadcasts 0x55", vd === fill8(8'h55));
        check("VMOVS (f3=MISC, op=0): mac_partial=0",   mac_partial === 64'sd0);

        // VCLRACC and VGETACC (funct3=MAC) should produce vd=0 and mac_partial=0
        // (they don't write vd and don't compute a partial sum)
        apply(`HVX_OP_VCLRACC, `HVX_EW_8, `HVX_CAT_MAC,
              fill8(8'hFF), fill8(8'hFF), 0);
        check("VCLRACC (f3=MAC): vd=0",        vd === 128'h0);
        check("VCLRACC (f3=MAC): mac_partial=0", mac_partial === 64'sd0);

        // ARITH with op_id=1 (VSUB) should not produce mac_partial
        apply(`HVX_OP_VSUB, `HVX_EW_8, `HVX_CAT_ARITH,
              fill8(8'h05), fill8(8'h03), 0);
        check("VSUB (f3=ARITH, op=1): mac_partial=0", mac_partial === 64'sd0);
        check("VSUB (f3=ARITH, op=1): vd=2 all lanes", vd === fill8(8'h02));

        // ==================================================================
        // Default/unknown op_id handling
        // ==================================================================
        $display("--- Unknown op_id ---");

        apply(5'd31, `HVX_EW_8, `HVX_CAT_ARITH, fill8(8'hFF), fill8(8'hFF), 0);
        check("Unknown op_id=31: vd=0 (default)", vd === 128'h0);

        // ==================================================================
        // Summary
        // ==================================================================
        @(posedge clk);
        $display("\n=== ALU Results: %0d/%0d passed, %0d failed ===\n",
                 tests_pass, tests_run, tests_fail);
        if (tests_fail == 0)
            $display("ALL ALU TESTS PASSED");
        else
            $display("SOME ALU TESTS FAILED — check above");

        $finish;
    end

    // Timeout
    initial begin
        #100000;
        $display("[TIMEOUT] ALU testbench exceeded 100us");
        $finish;
    end

endmodule
