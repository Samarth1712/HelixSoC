// =============================================================================
// helix_vcop.sv — Helix Vector Coprocessor (PCPI top-level)
// =============================================================================
// Connects to PicoRV32 via PCPI (Pico Co-Processor Interface).
// Recognises custom-1 opcode (7'b0101011). Silently ignores others.
//
// BUG FIXES vs v1:
//  1. MULTI-DRIVER eliminated: qrf_wen, acc_clr, acc_wen, acc_addend, lsu_req,
//     lsu_is_store were driven from BOTH always_comb defaults AND always_ff.
//     Now driven exclusively from always_ff with default-zero at block top.
//  2. pcpi_wait: combinational as (pcpi_valid && is_hvx && !pcpi_ready) so
//     PicoRV32's timeout counter resets on the very first cycle.
//  3. VGETACC: removed 'automatic' variable in always_ff. Result latched in
//     vgetacc_result register during S_GETACC.
//  4. lsu_is_store: properly latched in S_DECODE before lsu_req is asserted.
//
// BUG FIXES vs v2:
//  5. funct3 now passed to helix_vec_alu so it can disambiguate op_id=0
//     between VADD (CAT_ARITH), VMAC (CAT_MAC), VMOVS (CAT_MISC), and
//     VLD/VST (CAT_LOAD/CAT_STORE). Without this, the ALU case statement
//     had no way to distinguish those categories.
//  6. pcpi_rd driven to 32'h0 when pcpi_wr=0. Previously it held the stale
//     vgetacc_result from the last VGETACC through all subsequent instructions,
//     confusing waveform readers and masking any writeback logic bugs.
//
// Pipeline timing (CPU stall cycles):
//   ARITH/MISC/MAC: 3 cycles  (IDLE→DECODE→EXEC→DONE)
//   VLD/VST:        5 cycles  (IDLE→DECODE→LSU_REQ→LSU_WAIT→LSU_DONE→DONE)
//   VGETACC:        3 cycles  (IDLE→DECODE→GETACC→DONE)
//
// PicoRV32 configuration requirements (enforced in helix_picosoc.v):
//   ENABLE_PCPI=1, CATCH_ILLINSN=1, ENABLE_REGS_DUALPORT=1
// =============================================================================

`include "helix_vec_defs.svh"

module helix_vcop #(
    parameter int VLEN = `HVX_VLEN
) (
    input  logic              clk,
    input  logic              resetn,

    // PicoRV32 PCPI
    input  logic              pcpi_valid,
    input  logic [31:0]       pcpi_insn,
    input  logic [31:0]       pcpi_rs1,
    input  logic [31:0]       pcpi_rs2,
    output logic              pcpi_wr,
    output logic [31:0]       pcpi_rd,
    output logic              pcpi_wait,
    output logic              pcpi_ready,

    // 128-bit vector memory port
    output logic              vec_mem_en,
    output logic              vec_mem_we,
    output logic [31:0]       vec_mem_addr,
    output logic [VLEN-1:0]   vec_mem_wdata,
    input  logic [VLEN-1:0]   vec_mem_rdata
);

    // =========================================================================
    // Decode wires from pcpi_insn (combinational, held stable by PicoRV32)
    // =========================================================================
    wire [6:0] insn_opc    = pcpi_insn[6:0];
    wire [2:0] insn_funct3 = pcpi_insn[14:12];
    wire [1:0] insn_ew     = pcpi_insn[26:25];
    wire [4:0] insn_opid   = pcpi_insn[31:27];
    wire [2:0] insn_vd     = pcpi_insn[9:7];
    wire [2:0] insn_vs1    = pcpi_insn[17:15];
    wire [2:0] insn_vs2    = pcpi_insn[22:20];

    wire is_hvx = (insn_opc == `HVX_OPCODE);

    // =========================================================================
    // State machine
    // =========================================================================
    typedef enum logic [2:0] {
        S_IDLE    = 3'b000,
        S_DECODE  = 3'b001,
        S_EXECUTE = 3'b010,
        S_LSU     = 3'b011,
        S_GETACC  = 3'b100,
        S_DONE    = 3'b101
    } state_t;

    state_t state;

    // =========================================================================
    // Latched instruction fields (stable for duration of operation)
    // =========================================================================
    logic [4:0]  lat_opid;
    logic [1:0]  lat_ew;
    logic [2:0]  lat_vd, lat_vs1, lat_vs2;
    logic [2:0]  lat_funct3;
    logic [31:0] lat_rs1, lat_rs2;
    logic        lat_is_store;

    // Latched Q-register values (captured in S_DECODE)
    logic [VLEN-1:0] lat_qa, lat_qb;

    // VGETACC shifted + saturated result
    logic [31:0] vgetacc_result;

    // =========================================================================
    // Register file
    // =========================================================================
    logic [VLEN-1:0]    qrf_rdata_a, qrf_rdata_b;
    logic               qrf_wen;
    logic [2:0]         qrf_waddr;
    logic [VLEN-1:0]    qrf_wdata;
    logic               acc_clr;
    logic               acc_wen;
    logic signed [63:0] acc_addend;
    logic signed [63:0] acc_rdata;

    helix_vec_regfile #(.VLEN(VLEN)) u_regfile (
        .clk        (clk),
        .resetn     (resetn),
        .raddr_a    (insn_vs1),
        .rdata_a    (qrf_rdata_a),
        .raddr_b    (insn_vs2),
        .rdata_b    (qrf_rdata_b),
        .wen        (qrf_wen),
        .waddr      (qrf_waddr),
        .wdata      (qrf_wdata),
        .acc_clr    (acc_clr),
        .acc_wen    (acc_wen),
        .acc_addend (acc_addend),
        .acc_rdata  (acc_rdata)
    );

    // =========================================================================
    // ALU (combinational, reads latched Q values)
    // FIX: lat_funct3 now passed to ALU so it can disambiguate op_id=0
    // between VADD (CAT_ARITH=0), VMAC (CAT_MAC=4), VMOVS (CAT_MISC=5).
    // =========================================================================
    logic [VLEN-1:0]    alu_vd;
    logic signed [63:0] alu_mac_partial;

    helix_vec_alu #(.VLEN(VLEN)) u_alu (
        .vs1         (lat_qa),
        .vs2         (lat_qb),
        .op_id       (lat_opid),
        .elem_width  (lat_ew),
        .funct3      (lat_funct3),   // FIX: was not connected in v2
        .scalar_rs1  (lat_rs1),
        .vd          (alu_vd),
        .mac_partial (alu_mac_partial)
    );

    // =========================================================================
    // LSU
    // =========================================================================
    logic           lsu_req, lsu_is_store, lsu_done;
    logic [VLEN-1:0] lsu_rdata;

    helix_vec_lsu #(.VLEN(VLEN)) u_lsu (
        .clk           (clk),
        .resetn        (resetn),
        .lsu_req       (lsu_req),
        .lsu_is_store  (lsu_is_store),
        .lsu_addr      (lat_rs1),
        .lsu_wdata     (lat_qb),
        .lsu_rdata     (lsu_rdata),
        .lsu_done      (lsu_done),
        .vec_mem_en    (vec_mem_en),
        .vec_mem_we    (vec_mem_we),
        .vec_mem_addr  (vec_mem_addr),
        .vec_mem_wdata (vec_mem_wdata),
        .vec_mem_rdata (vec_mem_rdata)
    );

    // =========================================================================
    // pcpi_ready — combinational from state
    // =========================================================================
    assign pcpi_ready = (state == S_DONE);

    // =========================================================================
    // pcpi_wait — combinational, asserted on FIRST cycle of a Helix instruction.
    // Resets PicoRV32's pcpi_timeout_counter immediately, preventing a
    // spurious illegal-instruction trap during multi-cycle operations.
    // =========================================================================
    assign pcpi_wait = pcpi_valid && is_hvx && !pcpi_ready;

    // =========================================================================
    // pcpi_wr / pcpi_rd
    // FIX: pcpi_rd is now driven to 32'h0 when pcpi_wr=0.
    // Previously vgetacc_result was always forwarded to pcpi_rd regardless of
    // whether a writeback was actually happening, leaving stale data visible
    // on the bus after every non-VGETACC instruction. PicoRV32 gates on
    // pcpi_wr before sampling pcpi_rd, so this was not a functional bug, but
    // it obscured waveforms and made writeback logic harder to verify.
    // =========================================================================
    assign pcpi_wr = pcpi_ready &&
                     (lat_funct3 == `HVX_CAT_MAC) &&
                     (lat_opid   == `HVX_OP_VGETACC);
    assign pcpi_rd = pcpi_wr ? vgetacc_result : 32'h0;

    // =========================================================================
    // Combinational: ACCX shift+saturate for VGETACC (used in S_GETACC)
    // =========================================================================
    logic signed [63:0] acc_shifted;
    logic signed [63:0] acc_sat;

    always_comb begin
        acc_shifted = acc_rdata >>> lat_rs2[5:0];
        if      (acc_shifted > 64'sh7FFF_FFFF)  acc_sat = 64'sh0000_0000_7FFF_FFFF;
        else if (acc_shifted < -64'sh8000_0000)  acc_sat = 64'shFFFF_FFFF_8000_0000;
        else                                      acc_sat = acc_shifted;
    end

    // =========================================================================
    // Main state machine — all control signals driven EXCLUSIVELY from here
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!resetn) begin
            state          <= S_IDLE;
            lat_opid       <= '0;
            lat_ew         <= '0;
            lat_vd         <= '0;
            lat_vs1        <= '0;
            lat_vs2        <= '0;
            lat_funct3     <= '0;
            lat_rs1        <= '0;
            lat_rs2        <= '0;
            lat_is_store   <= 1'b0;
            lat_qa         <= '0;
            lat_qb         <= '0;
            vgetacc_result <= '0;
            // Control signals
            qrf_wen        <= 1'b0;
            qrf_waddr      <= '0;
            qrf_wdata      <= '0;
            acc_clr        <= 1'b0;
            acc_wen        <= 1'b0;
            acc_addend     <= '0;
            lsu_req        <= 1'b0;
            lsu_is_store   <= 1'b0;
        end else begin
            // Default: deassert all one-cycle control signals
            qrf_wen      <= 1'b0;
            acc_clr      <= 1'b0;
            acc_wen      <= 1'b0;
            lsu_req      <= 1'b0;
            lsu_is_store <= 1'b0;

            case (state)
                // ------------------------------------------------------------
                S_IDLE: begin
                    if (pcpi_valid && is_hvx) begin
                        lat_opid     <= insn_opid;
                        lat_ew       <= insn_ew;
                        lat_vd       <= insn_vd;
                        lat_vs1      <= insn_vs1;
                        lat_vs2      <= insn_vs2;
                        lat_funct3   <= insn_funct3;
                        lat_rs1      <= pcpi_rs1;
                        lat_rs2      <= pcpi_rs2;
                        lat_is_store <= (insn_funct3 == `HVX_CAT_STORE);
                        state        <= S_DECODE;
                    end
                end

                // ------------------------------------------------------------
                // Latch Q-register values (async read is already valid here).
                // lat_funct3 is stable from S_IDLE latch — dispatch on it.
                // ------------------------------------------------------------
                S_DECODE: begin
                    lat_qa <= qrf_rdata_a;   // Q[vs1]
                    lat_qb <= qrf_rdata_b;   // Q[vs2]

                    case (lat_funct3)
                        `HVX_CAT_ARITH,
                        `HVX_CAT_MISC:   state <= S_EXECUTE;

                        `HVX_CAT_LOAD,
                        `HVX_CAT_STORE: begin
                            lsu_req      <= 1'b1;
                            lsu_is_store <= lat_is_store;
                            state        <= S_LSU;
                        end

                        `HVX_CAT_MAC: begin
                            case (lat_opid)
                                `HVX_OP_VMAC,
                                `HVX_OP_VCLRACC: state <= S_EXECUTE;
                                `HVX_OP_VGETACC: state <= S_GETACC;
                                default:         state <= S_DONE;
                            endcase
                        end

                        default: state <= S_DONE;
                    endcase
                end

                // ------------------------------------------------------------
                // ALU result combinationally valid (reads lat_qa/lat_qb).
                // lat_funct3 passed to ALU ensures correct operation selected.
                // ------------------------------------------------------------
                S_EXECUTE: begin
                    case (lat_funct3)
                        `HVX_CAT_ARITH,
                        `HVX_CAT_MISC: begin
                            qrf_wen   <= 1'b1;
                            qrf_waddr <= lat_vd;
                            qrf_wdata <= alu_vd;
                        end

                        `HVX_CAT_MAC: begin
                            if (lat_opid == `HVX_OP_VMAC) begin
                                acc_wen    <= 1'b1;
                                acc_addend <= alu_mac_partial;
                            end else if (lat_opid == `HVX_OP_VCLRACC) begin
                                acc_clr <= 1'b1;
                            end
                        end

                        default: ;
                    endcase
                    state <= S_DONE;
                end

                // ------------------------------------------------------------
                // Wait for LSU, then optionally write Q[vd] on load.
                // ------------------------------------------------------------
                S_LSU: begin
                    if (lsu_done) begin
                        if (!lat_is_store) begin
                            qrf_wen   <= 1'b1;
                            qrf_waddr <= lat_vd;
                            qrf_wdata <= lsu_rdata;
                        end
                        state <= S_DONE;
                    end
                end

                // ------------------------------------------------------------
                // Shift ACCX, saturate to int32, latch result for pcpi_rd.
                // acc_shifted/acc_sat are combinational from acc_rdata.
                // ------------------------------------------------------------
                S_GETACC: begin
                    vgetacc_result <= acc_sat[31:0];
                    state          <= S_DONE;
                end

                // ------------------------------------------------------------
                // pcpi_ready asserted combinationally this cycle.
                // pcpi_wr/pcpi_rd driven from assigns above.
                // Transition to IDLE on next edge.
                // ------------------------------------------------------------
                S_DONE: begin
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

`ifdef SIMULATION
    // Warn if funct3=SHIFT (reserved) is presented — silent completion is
    // correct behaviour but worth flagging during simulation.
    always_ff @(posedge clk) begin
        if (resetn && pcpi_valid && is_hvx &&
            pcpi_insn[14:12] == `HVX_CAT_SHIFT)
            $display("[HVX_VCOP] t=%0t WARNING: funct3=SHIFT (reserved) instruction presented — silently completed", $time);
    end
`endif

endmodule
