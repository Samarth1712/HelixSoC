// =============================================================================
// helix_vec_alu.sv — Helix SIMD ALU
// =============================================================================
// Combinational parallel-lane ALU. VLEN=128 with:
//   int8  → 16 lanes,  int16 → 8 lanes,  int32 → 4 lanes.
//
// All arithmetic is saturating signed (VADD, VSUB, VABS).
// VMUL returns the lower half of the product (wrapping); VMULH returns upper.
// mac_partial is the signed 64-bit dot-product partial sum for VMAC.
//
// funct3 is passed in from vcop so the ALU can disambiguate op_id=0
// between VADD (CAT_ARITH), VMAC (CAT_MAC), VMOVS (CAT_MISC), and
// VLD (CAT_LOAD) — all share op_id=0 but are different operations.
// Without funct3, the case statement would be ambiguous when lat_opid=0.
//
// BUG FIXES vs v1:
//  - VMULH: proper N×N→2N multiply with correct upper-half extraction.
//  - mac_partial: module-level temporaries, no 'automatic' in always_comb.
//  - sat_sub: was sat_add(a, ~b+1). When b=INT_MIN, ~b+1 = INT_MIN (negation
//    overflows), giving wrong result for all inputs. Fixed: widen both
//    operands to N+1 bits, subtract directly, then saturate the N+1-bit
//    result. This is always correct regardless of input values.
//  - int32 MAC: explicit 64-bit sign-extension before multiply to prevent
//    tool-dependent behaviour when mixing $signed and part-selects.
//  - funct3 input added: op_id=0 aliasing between VADD/VMAC/VMOVS/VLD
//    resolved by gating each case on funct3 category.
// =============================================================================

`include "helix_vec_defs.svh"

module helix_vec_alu #(
    parameter int VLEN = `HVX_VLEN
) (
    input  logic [VLEN-1:0]  vs1,
    input  logic [VLEN-1:0]  vs2,
    input  logic [4:0]       op_id,
    input  logic [1:0]       elem_width,
    input  logic [2:0]       funct3,        // NEW: passed from vcop for disambiguation
    input  logic [31:0]      scalar_rs1,    // for VMOVS broadcast

    output logic [VLEN-1:0]  vd,
    output logic signed [63:0] mac_partial  // signed dot-product sum for VMAC
);

    localparam LANES8  = VLEN / 8;
    localparam LANES16 = VLEN / 16;
    localparam LANES32 = VLEN / 32;

    // =========================================================================
    // Saturating helpers
    // =========================================================================

    // --- int8 ---
    // FIX: sat_sub widened to 9 bits to handle b=INT_MIN correctly.
    // Old: sat_add(a, ~b+1) — fails when b=0x80 because ~0x80+1=0x80 (overflow).
    // New: sign-extend both to 9 bits, subtract, saturate.
    //
    // FIX: positive saturation condition changed from s[8] to s[7] (and
    // analogously s[16]→s[15], s[32]→s[31] for wider widths).
    //
    // s is the (N+1)-bit sign-extended sum. For positive inputs (a[N-1]=b[N-1]=0),
    // sign extension gives 0_xxxxxxx, so the max sum is 2*(2^(N-1)-1) = 2^N - 2,
    // which fits in N bits — s[N] (carry out) is ALWAYS 0 for positive inputs.
    // Positive saturation using s[N] therefore NEVER fires.
    //
    // The correct check is s[N-1]: the MSB of the N-bit result. When both
    // inputs are positive but the N-bit result has MSB=1 (appears negative),
    // signed overflow occurred and we must saturate to INT_MAX.
    function automatic logic [7:0] sat_add_s8(input logic [7:0] a, b);
        logic [8:0] s;
        s = {a[7], a} + {b[7], b};
        if      (!a[7] && !b[7] &&  s[7]) return 8'h7F;   // was s[8] — always 0 for +inputs
        else if ( a[7] &&  b[7] && !s[7]) return 8'h80;
        else                               return s[7:0];
    endfunction

    function automatic logic [7:0] sat_sub_s8(input logic [7:0] a, b);
        logic signed [8:0] s;
        s = $signed({a[7], a}) - $signed({b[7], b});
        if      (s > 9'sh7F) return 8'h7F;
        else if (s < -9'sh80) return 8'h80;
        else                  return s[7:0];
    endfunction

    function automatic logic [7:0] sat_abs_s8(input logic [7:0] a);
        if (a == 8'h80) return 8'h7F;
        else            return a[7] ? (~a + 8'd1) : a;
    endfunction

    // --- int16 ---
    function automatic logic [15:0] sat_add_s16(input logic [15:0] a, b);
        logic [16:0] s;
        s = {a[15], a} + {b[15], b};
        if      (!a[15] && !b[15] &&  s[15]) return 16'h7FFF;  // was s[16]
        else if ( a[15] &&  b[15] && !s[15]) return 16'h8000;
        else                                  return s[15:0];
    endfunction

    function automatic logic [15:0] sat_sub_s16(input logic [15:0] a, b);
        logic signed [16:0] s;
        s = $signed({a[15], a}) - $signed({b[15], b});
        if      (s > 17'sh7FFF)  return 16'h7FFF;
        else if (s < -17'sh8000) return 16'h8000;
        else                     return s[15:0];
    endfunction

    function automatic logic [15:0] sat_abs_s16(input logic [15:0] a);
        if (a == 16'h8000) return 16'h7FFF;
        else               return a[15] ? (~a + 16'd1) : a;
    endfunction

    // --- int32 ---
    function automatic logic [31:0] sat_add_s32(input logic [31:0] a, b);
        logic [32:0] s;
        s = {a[31], a} + {b[31], b};
        if      (!a[31] && !b[31] &&  s[31]) return 32'h7FFF_FFFF;  // was s[32]
        else if ( a[31] &&  b[31] && !s[31]) return 32'h8000_0000;
        else                                  return s[31:0];
    endfunction

    function automatic logic [31:0] sat_sub_s32(input logic [31:0] a, b);
        logic signed [32:0] s;
        s = $signed({a[31], a}) - $signed({b[31], b});
        if      (s > 33'sh7FFF_FFFF)  return 32'h7FFF_FFFF;
        else if (s < -33'sh8000_0000) return 32'h8000_0000;
        else                          return s[31:0];
    endfunction

    function automatic logic [31:0] sat_abs_s32(input logic [31:0] a);
        if (a == 32'h8000_0000) return 32'h7FFF_FFFF;
        else                    return a[31] ? (~a + 32'd1) : a;
    endfunction

    // =========================================================================
    // Convenience: is this a MISC instruction (VMOVS / VMOV)?
    // Used to gate the scalar broadcast / copy cases so op_id=0 (VMOVS)
    // doesn't collide with op_id=0 (VADD) or op_id=0 (VMAC).
    // =========================================================================
    wire is_arith = (funct3 == `HVX_CAT_ARITH);
    wire is_misc  = (funct3 == `HVX_CAT_MISC);
    wire is_mac   = (funct3 == `HVX_CAT_MAC);

    // =========================================================================
    // Per-lane results
    // =========================================================================
    logic [VLEN-1:0] res8, res16, res32;

    genvar i;
    generate
        // --- int8 lanes (16 lanes) ---
        for (i = 0; i < LANES8; i++) begin : g8
            logic [7:0]  a, b;
            logic [15:0] prod_full;
            logic [7:0]  r;

            assign a = vs1[8*i +: 8];
            assign b = vs2[8*i +: 8];
            assign prod_full = $signed(a) * $signed(b);

            always_comb begin
                r = '0;
                // MISC: broadcast / copy — checked before ARITH to prevent
                // op_id=0 (VMOVS) matching VADD case when funct3=MISC.
                if (is_misc) begin
                    case (op_id)
                        `HVX_OP_VMOVS: r = scalar_rs1[7:0];
                        `HVX_OP_VMOV:  r = a;
                        default:       r = '0;
                    endcase
                end else if (is_arith) begin
                    case (op_id)
                        `HVX_OP_VADD:  r = sat_add_s8(a, b);
                        `HVX_OP_VSUB:  r = sat_sub_s8(a, b);
                        `HVX_OP_VMIN:  r = ($signed(a) < $signed(b)) ? a : b;
                        `HVX_OP_VMAX:  r = ($signed(a) > $signed(b)) ? a : b;
                        `HVX_OP_VMUL:  r = prod_full[7:0];
                        `HVX_OP_VMULH: r = prod_full[15:8];
                        `HVX_OP_VAND:  r = a & b;
                        `HVX_OP_VOR:   r = a | b;
                        `HVX_OP_VXOR:  r = a ^ b;
                        `HVX_OP_VABS:  r = sat_abs_s8(a);
                        default:       r = '0;
                    endcase
                end
                // MAC / LOAD / STORE: no lane result written to vd
            end
            assign res8[8*i +: 8] = r;
        end

        // --- int16 lanes (8 lanes) ---
        for (i = 0; i < LANES16; i++) begin : g16
            logic [15:0] a, b;
            logic [31:0] prod_full;
            logic [15:0] r;

            assign a = vs1[16*i +: 16];
            assign b = vs2[16*i +: 16];
            assign prod_full = $signed(a) * $signed(b);

            always_comb begin
                r = '0;
                if (is_misc) begin
                    case (op_id)
                        `HVX_OP_VMOVS: r = scalar_rs1[15:0];
                        `HVX_OP_VMOV:  r = a;
                        default:       r = '0;
                    endcase
                end else if (is_arith) begin
                    case (op_id)
                        `HVX_OP_VADD:  r = sat_add_s16(a, b);
                        `HVX_OP_VSUB:  r = sat_sub_s16(a, b);
                        `HVX_OP_VMIN:  r = ($signed(a) < $signed(b)) ? a : b;
                        `HVX_OP_VMAX:  r = ($signed(a) > $signed(b)) ? a : b;
                        `HVX_OP_VMUL:  r = prod_full[15:0];
                        `HVX_OP_VMULH: r = prod_full[31:16];
                        `HVX_OP_VAND:  r = a & b;
                        `HVX_OP_VOR:   r = a | b;
                        `HVX_OP_VXOR:  r = a ^ b;
                        `HVX_OP_VABS:  r = sat_abs_s16(a);
                        default:       r = '0;
                    endcase
                end
            end
            assign res16[16*i +: 16] = r;
        end

        // --- int32 lanes (4 lanes) ---
        for (i = 0; i < LANES32; i++) begin : g32
            logic [31:0] a, b;
            logic [63:0] prod_full;
            logic [31:0] r;

            assign a = vs1[32*i +: 32];
            assign b = vs2[32*i +: 32];
            // FIX: explicit 64-bit sign-extension before multiply.
            // $signed(part-select) can be treated as unsigned by some tools
            // before the cast is applied. Casting to 64-bit signed first is
            // unambiguous across all compliant SystemVerilog simulators and
            // synthesis tools.
            assign prod_full = 64'(signed'(a)) * 64'(signed'(b));

            always_comb begin
                r = '0;
                if (is_misc) begin
                    case (op_id)
                        `HVX_OP_VMOVS: r = scalar_rs1;
                        `HVX_OP_VMOV:  r = a;
                        default:       r = '0;
                    endcase
                end else if (is_arith) begin
                    case (op_id)
                        `HVX_OP_VADD:  r = sat_add_s32(a, b);
                        `HVX_OP_VSUB:  r = sat_sub_s32(a, b);
                        `HVX_OP_VMIN:  r = ($signed(a) < $signed(b)) ? a : b;
                        `HVX_OP_VMAX:  r = ($signed(a) > $signed(b)) ? a : b;
                        `HVX_OP_VMUL:  r = prod_full[31:0];
                        `HVX_OP_VMULH: r = prod_full[63:32];
                        `HVX_OP_VAND:  r = a & b;
                        `HVX_OP_VOR:   r = a | b;
                        `HVX_OP_VXOR:  r = a ^ b;
                        `HVX_OP_VABS:  r = sat_abs_s32(a);
                        default:       r = '0;
                    endcase
                end
            end
            assign res32[32*i +: 32] = r;
        end
    endgenerate

    // Output mux
    always_comb begin
        case (elem_width)
            `HVX_EW_8:   vd = res8;
            `HVX_EW_16:  vd = res16;
            `HVX_EW_32:  vd = res32;
            default:     vd = '0;
        endcase
    end

    // =========================================================================
    // MAC partial sum
    // Module-level temporaries — no 'automatic' needed in always_comb.
    // FIX (int32 path): explicit 64-bit sign-cast on both operands before
    // multiply. mp32 declared as signed [63:0] to hold the full product.
    // =========================================================================
    logic signed [15:0] mp8;
    logic signed [31:0] mp16;
    logic signed [63:0] mp32;
    integer k;

    always_comb begin
        mac_partial = '0;
        // Guard on funct3=MAC so VMAC op_id=0 doesn't fire during VADD
        if (is_mac && (op_id == `HVX_OP_VMAC)) begin
            case (elem_width)
                `HVX_EW_8: begin
                    for (k = 0; k < LANES8; k++) begin
                        mp8 = $signed(vs1[8*k +: 8]) * $signed(vs2[8*k +: 8]);
                        mac_partial = mac_partial + 64'(signed'(mp8));
                    end
                end
                `HVX_EW_16: begin
                    for (k = 0; k < LANES16; k++) begin
                        mp16 = $signed(vs1[16*k +: 16]) * $signed(vs2[16*k +: 16]);
                        mac_partial = mac_partial + 64'(signed'(mp16));
                    end
                end
                `HVX_EW_32: begin
                    for (k = 0; k < LANES32; k++) begin
                        // FIX: cast to signed 64-bit before multiply so the
                        // full product is sign-correct regardless of tool.
                        mp32 = 64'(signed'(vs1[32*k +: 32])) *
                               64'(signed'(vs2[32*k +: 32]));
                        mac_partial = mac_partial + mp32;
                    end
                end
                default: mac_partial = '0;
            endcase
        end
    end

`ifdef SIMULATION
    // Verify sat_sub and sat_add edge cases at elaboration time.
    initial begin
        // sat_sub INT_MIN cases (previously broken with ~b+1 negation)
        assert (sat_sub_s8(8'h00, 8'h80) === 8'h7F)
            else $fatal(1, "[HVX_ALU] sat_sub_s8(0, INT_MIN) != 127 — fix broken");
        assert (sat_sub_s16(16'h0000, 16'h8000) === 16'h7FFF)
            else $fatal(1, "[HVX_ALU] sat_sub_s16(0, INT_MIN) != 0x7FFF — fix broken");
        assert (sat_sub_s32(32'h0000_0000, 32'h8000_0000) === 32'h7FFF_FFFF)
            else $fatal(1, "[HVX_ALU] sat_sub_s32(0, INT_MIN) != 0x7FFFFFFF — fix broken");
        // sat_add positive saturation cases (previously broken with s[N] check)
        assert (sat_add_s8(8'h64, 8'h32) === 8'h7F)
            else $fatal(1, "[HVX_ALU] sat_add_s8(100, 50) != 127 — fix broken (s[7] vs s[8])");
        assert (sat_add_s8(8'h7F, 8'h01) === 8'h7F)
            else $fatal(1, "[HVX_ALU] sat_add_s8(127, 1) != 127 — fix broken");
        assert (sat_add_s16(16'h7FFF, 16'h0001) === 16'h7FFF)
            else $fatal(1, "[HVX_ALU] sat_add_s16(INT16_MAX, 1) != 0x7FFF — fix broken");
        assert (sat_add_s32(32'h7FFF_FFFF, 32'h0000_0001) === 32'h7FFF_FFFF)
            else $fatal(1, "[HVX_ALU] sat_add_s32(INT32_MAX, 1) != 0x7FFFFFFF — fix broken");
        // Verify no-saturation cases still correct
        assert (sat_add_s8(8'h0A, 8'h14) === 8'h1E)
            else $fatal(1, "[HVX_ALU] sat_add_s8(10, 20) != 30 — regression");
        assert (sat_add_s8(8'h3F, 8'h40) === 8'h7F)
            else $fatal(1, "[HVX_ALU] sat_add_s8(63, 64) != 127 — regression");
    end
`endif

endmodule
