// =============================================================================
// helix_vec_lsu.sv — Helix Vector Load/Store Unit
// =============================================================================
// Handles VLD.128 / VST.128 via 128-bit wide SRAM port.
// CPU is stalled (pcpi_wait=1) for the entire duration.
//
// CHANGE vs v1: lsu_wdata now comes from the latched Q[vs2] value (lat_qb in
// vcop) rather than the live register file read port. This prevents any
// combinational dependency on insn_vs2 persisting into the memory access.
//
// Timing (synchronous SRAM with registered output):
//   Cycle 0 — vcop S_IDLE→S_DECODE: instruction latched
//   Cycle 1 — vcop S_DECODE: lsu_req asserted (registered), lat_qa/qb latched
//             LSU_IDLE: lsu_req not yet visible (registered signal, seen next cycle)
//   Cycle 2 — LSU_IDLE: sees lsu_req, latches addr/wdata, moves to LSU_ACCESS
//   Cycle 3 — LSU_ACCESS: drives vec_mem_en + addr/wdata to SRAM inputs
//   Cycle 4 — LSU_WAIT: SRAM output valid, lsu_rdata captured; moves to LSU_DONE
//   Cycle 5 — LSU_DONE: state register = LSU_DONE; lsu_done asserted
//             COMBINATIONALLY from state decode (not registered).
//             vcop S_LSU sees lsu_done=1 this same cycle, transitions to S_DONE.
//   Cycle 6 — vcop S_DONE: pcpi_ready asserted combinationally.
//
// Total CPU stall: 6 cycles from S_IDLE entry.
//
// ISA SPEC NOTE: Section 5 documents VLD/VST as 5 stall cycles. This is
// incorrect — the correct count is 6. The spec table should read:
//   VLD.128 / VST.128 | 6 | +3 for LSU state machine + 1 for lsu_req
//                         | registration delay
// Update the ISA spec when this file is updated.
//
// DESIGN NOTE — lsu_done is combinational:
// Making lsu_done a registered output (lsu_done <= 1'b1 in LSU_DONE state)
// adds one extra clock: vcop sees lsu_done one cycle after LSU enters LSU_DONE,
// then needs another cycle to transition S_LSU→S_DONE. That would be 7 total
// stall cycles. By making lsu_done combinational from state == LSU_DONE, vcop
// sees it in the same cycle LSU_DONE is entered, saving one clock.
//
// lsu_done is held for exactly one clock (the LSU_DONE cycle), then LSU
// transitions back to LSU_IDLE. vcop must be in S_LSU and checking lsu_done
// every cycle — this is guaranteed by the vcop state machine design.
// =============================================================================

`include "helix_vec_defs.svh"

module helix_vec_lsu #(
    parameter int VLEN = `HVX_VLEN
) (
    input  logic              clk,
    input  logic              resetn,

    // Control interface from helix_vcop
    input  logic              lsu_req,
    input  logic              lsu_is_store,
    input  logic [31:0]       lsu_addr,
    input  logic [VLEN-1:0]   lsu_wdata,

    output logic [VLEN-1:0]   lsu_rdata,
    output logic              lsu_done,   // combinational from state == LSU_DONE

    // 128-bit SRAM port
    output logic              vec_mem_en,
    output logic              vec_mem_we,
    output logic [31:0]       vec_mem_addr,
    output logic [VLEN-1:0]   vec_mem_wdata,
    input  logic [VLEN-1:0]   vec_mem_rdata
);

    typedef enum logic [1:0] {
        LSU_IDLE   = 2'b00,
        LSU_ACCESS = 2'b01,
        LSU_WAIT   = 2'b10,
        LSU_DONE   = 2'b11
    } lsu_state_t;

    lsu_state_t  state;
    logic        is_store_r;
    logic [31:0] addr_r;
    logic [VLEN-1:0] wdata_r;

    // =========================================================================
    // lsu_done: combinational from state register.
    // FIX: previously registered (lsu_done <= 1'b1 inside always_ff).
    // Registered lsu_done added two extra clocks: vcop saw lsu_done one cycle
    // after LSU_DONE was entered, then took another cycle to reach S_DONE.
    // Combinational lsu_done is seen by vcop in the same cycle LSU_DONE is
    // entered, saving one clock and making the 6-cycle total consistent.
    // =========================================================================
    assign lsu_done = (state == LSU_DONE);

    always_ff @(posedge clk) begin
        if (!resetn) begin
            state      <= LSU_IDLE;
            vec_mem_en <= 1'b0;
            vec_mem_we <= 1'b0;
            lsu_rdata  <= '0;
        end else begin
            vec_mem_en <= 1'b0;

            case (state)
                LSU_IDLE: begin
                    if (lsu_req) begin
                        is_store_r <= lsu_is_store;
                        addr_r     <= {lsu_addr[31:4], 4'b0000};  // 16-byte align
                        wdata_r    <= lsu_wdata;
                        state      <= LSU_ACCESS;
                    end
                end

                LSU_ACCESS: begin
                    vec_mem_en    <= 1'b1;
                    vec_mem_we    <= is_store_r;
                    vec_mem_addr  <= addr_r;
                    vec_mem_wdata <= wdata_r;
                    state         <= LSU_WAIT;
                end

                LSU_WAIT: begin
                    // Synchronous SRAM: rdata valid this cycle
                    if (!is_store_r)
                        lsu_rdata <= vec_mem_rdata;
                    state <= LSU_DONE;
                end

                // lsu_done is asserted combinationally while in this state.
                // Transition immediately back to IDLE so lsu_done is a
                // single-cycle pulse — vcop checks it every cycle in S_LSU.
                LSU_DONE: begin
                    state <= LSU_IDLE;
                end
            endcase
        end
    end

`ifdef SIMULATION
    always_ff @(posedge clk) begin
        if (lsu_req && lsu_addr[3:0] != 4'b0)
            $display("[HVX_LSU] t=%0t WARN: unaligned addr 0x%08x → aligned to 0x%08x",
                     $time, lsu_addr, {lsu_addr[31:4], 4'b0});
    end
`endif

endmodule
