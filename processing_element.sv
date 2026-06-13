
`timescale 1ns / 1ps
`default_nettype none

module processing_element #(
    parameter int ACTIVATION_WIDTH  = 8,
    parameter int WEIGHT_WIDTH      = 8,
    parameter int ACCUMULATOR_WIDTH = 32
) (
    // ── Clock & Reset ──────
    input  logic                          clk,
    input  logic                          rst_n,        // Asynchronous, active-low

    // ── Control ─────────────────
    input  logic                          load_weight,  // 1 → latch act_in into weight_reg

    // ── Data Inputs ─────────────
    input  logic [ACTIVATION_WIDTH-1:0]   act_in,       // Activation arriving from the West
    input  logic [ACCUMULATOR_WIDTH-1:0]  sum_in,       // Partial sum arriving from the North

    // ── Data Outputs  (both fully registered) ────────
    output logic [ACTIVATION_WIDTH-1:0]   act_out,      // Activation forwarded to the East
    output logic [ACCUMULATOR_WIDTH-1:0]  sum_out       // MAC result forwarded to the South
);

 
    localparam int PRODUCT_WIDTH = ACTIVATION_WIDTH + WEIGHT_WIDTH;

    // ==============================
    // Internal Signals
    // ======================
    logic [WEIGHT_WIDTH-1:0]   weight_reg;    // Stationary weight — loaded once per tile
    logic [PRODUCT_WIDTH-1:0]  mac_product;   // Full-precision intermediate multiply result

    always_comb begin : proc_multiply
        mac_product = $unsigned(act_in) * $unsigned(weight_reg);
    end



    // Sequential block
    always_ff @(posedge clk or negedge rst_n) begin : proc_pe_registers

        if (!rst_n) begin
            // ── Asynchronous Reset: Clear all registers ─────────
            weight_reg <= '0;
            act_out    <= '0;
            sum_out    <= '0;

        end else begin


            if (load_weight) begin
                weight_reg <= WEIGHT_WIDTH'(act_out);
            end

            act_out <= act_in;


            sum_out <= sum_in + ACCUMULATOR_WIDTH'(mac_product);

        end
    end

endmodule : processing_element

`default_nettype wire
