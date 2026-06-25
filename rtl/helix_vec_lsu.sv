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
//   Cycle 3 — LSU_ACCESS: asserts vec_mem_en; SRAM latches addr on this edge
//   Cycle 4 — LSU_WAIT: SRAM updates vec_mem_rdata via NBA at this edge.
//             lsu_rdata NOT captured here — doing so would read the pre-update
//             value because both the SRAM and LSU fire at the same posedge.
//   Cycle 5 — LSU_LATCH: vec_mem_rdata is now stable (updated at cycle 4 NBA).
//             lsu_rdata captured here — reads the post-cycle-4-NBA value.
//             Transitions to LSU_DONE.
//   Cycle 5 — LSU_DONE: lsu_done asserted COMBINATIONALLY from state decode.
//             vcop S_LSU sees lsu_done=1 same cycle, transitions to S_DONE.
//   Cycle 6 — vcop S_DONE: pcpi_ready asserted combinationally.
//             Q register written with lsu_rdata.
//
// Total CPU stall: 7 cycles from S_IDLE entry.
//
// WHY LSU_LATCH IS NEEDED:
// Both helix_picosoc_mem and the simulation testbench use registered (synchronous)
// vector reads: vec_rdata <= mem[addr] at posedge clk when vec_en=1.
// When the LSU is in LSU_WAIT, vec_mem_en=1 is already asserted (set at
// LSU_ACCESS). At the LSU_WAIT posedge, two things fire simultaneously:
//   - SRAM:  vec_mem_rdata <= mem[addr]  (NBA, updates AFTER this posedge)
//   - LSU:   lsu_rdata <= vec_mem_rdata  (NBA, reads PRE-posedge value)
// Due to NBA semantics the LSU reads the stale pre-update value.
// LSU_LATCH adds one cycle so lsu_rdata is captured AFTER the SRAM NBA settles.
//
// ISA SPEC: VLD/VST stall cycles = 7 (updated from earlier incorrect 6/5).
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

    // 5-state machine requires 3-bit encoding.
    typedef enum logic [2:0] {
        LSU_IDLE   = 3'b000,
        LSU_ACCESS = 3'b001,
        LSU_WAIT   = 3'b010,
        LSU_LATCH  = 3'b011,   // NEW: capture lsu_rdata after SRAM NBA settles
        LSU_DONE   = 3'b100
    } lsu_state_t;

    lsu_state_t  state;
    logic        is_store_r;
    logic [31:0] addr_r;
    logic [VLEN-1:0] wdata_r;

    // =========================================================================
    // lsu_done: combinational from state register.
    // vcop sees it in the same cycle LSU enters LSU_DONE — no extra registered
    // cycle needed.
    // =========================================================================
    assign lsu_done = (state == LSU_DONE);

    always_ff @(posedge clk) begin
        if (!resetn) begin
            state      <= LSU_IDLE;
            vec_mem_en <= 1'b0;
            vec_mem_we <= 1'b0;
            lsu_rdata  <= '0;
        end else begin
            vec_mem_en <= 1'b0;   // default: deassert each cycle

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
                    // Assert vec_mem_en. SRAM latches addr+en at this posedge
                    // (via NBA). At the NEXT posedge (LSU_WAIT), the SRAM will
                    // update vec_mem_rdata.
                    vec_mem_en    <= 1'b1;
                    vec_mem_we    <= is_store_r;
                    vec_mem_addr  <= addr_r;
                    vec_mem_wdata <= wdata_r;
                    state         <= LSU_WAIT;
                end

                LSU_WAIT: begin
                    // At this posedge: SRAM fires (sees vec_mem_en=1) and
                    // updates vec_mem_rdata via NBA. We do NOT capture here
                    // because the LSU and SRAM both use NBA — reading now would
                    // see the pre-update value. Transition to LSU_LATCH instead.
                    state <= LSU_LATCH;
                end

                LSU_LATCH: begin
                    // vec_mem_rdata is now stable: it was updated by the SRAM's
                    // NBA at the previous (LSU_WAIT) posedge. Safe to capture.
                    if (!is_store_r)
                        lsu_rdata <= vec_mem_rdata;
                    state <= LSU_DONE;
                end

                // lsu_done asserted combinationally this cycle.
                // vcop S_LSU sees it, writes Q register, moves to S_DONE.
                // Transition back to LSU_IDLE immediately.
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
