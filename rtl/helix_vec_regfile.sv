// =============================================================================
// helix_vec_regfile.sv — Helix Vector Register File
// =============================================================================
// 8 × VLEN-bit Q-registers (Q0-Q7), two async read ports, one sync write port.
// 1 × 64-bit signed ACCX accumulator with synchronous clear and accumulate.
//
// BUG FIX vs v1: removed erroneous {{32{acc_addend[31]}},acc_addend} which
// tried to sign-extend a 64-bit signal to 96 bits. acc_addend is already 64-bit
// and is treated as signed by the ALU before being passed here.
// =============================================================================

`include "helix_vec_defs.svh"

module helix_vec_regfile #(
    parameter int VLEN  = `HVX_VLEN,
    parameter int NREGS = `HVX_NQREGS
) (
    input  logic              clk,
    input  logic              resetn,

    // Read port A (vs1) — asynchronous
    input  logic [2:0]        raddr_a,
    output logic [VLEN-1:0]   rdata_a,

    // Read port B (vs2) — asynchronous
    input  logic [2:0]        raddr_b,
    output logic [VLEN-1:0]   rdata_b,

    // Write port (vd) — synchronous
    input  logic              wen,
    input  logic [2:0]        waddr,
    input  logic [VLEN-1:0]   wdata,

    // ACCX accumulator — clear takes priority over accumulate
    input  logic              acc_clr,       // sync clear: ACCX = 0
    input  logic              acc_wen,       // accumulate: ACCX += acc_addend
    input  logic signed [63:0] acc_addend,   // signed 64-bit addend from MAC unit
    output logic signed [63:0] acc_rdata     // current ACCX value
);

    logic [VLEN-1:0]   qregs [0:NREGS-1];
    logic signed [63:0] accx;

    // Async reads
    assign rdata_a   = qregs[raddr_a];
    assign rdata_b   = qregs[raddr_b];
    assign acc_rdata = accx;

    integer j;
    always_ff @(posedge clk) begin
        if (!resetn) begin
            for (j = 0; j < NREGS; j = j+1)
                qregs[j] <= '0;
            accx <= '0;
        end else begin
            if (wen)
                qregs[waddr] <= wdata;

            // acc_clr priority over acc_wen
            if (acc_clr)
                accx <= '0;
            else if (acc_wen)
                accx <= accx + acc_addend;   // both are signed 64-bit: no extension needed
        end
    end

`ifdef SIMULATION
    always_ff @(posedge clk) begin
        if (resetn && acc_clr && acc_wen)
            $display("[HVX_RF] t=%0t WARNING: acc_clr && acc_wen both high; clr wins", $time);
    end
`endif

endmodule
