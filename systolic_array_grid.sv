

`timescale 1ns / 1ps
`default_nettype none

module systolic_array_grid #(
    parameter int ARRAY_SIZE        = 4,   // Grid dimension:  ARRAY_SIZE × ARRAY_SIZE PEs
    parameter int ACTIVATION_WIDTH  = 8,   // Must match processing_element parameter
    parameter int WEIGHT_WIDTH      = 8,   // Must match processing_element parameter
    parameter int ACCUMULATOR_WIDTH = 32   // Must match processing_element parameter
) (
    // ── Clock & Reset ─────────────────────────────────────────────────────────
    input  logic clk,
    input  logic rst_n,                    // Asynchronous, active-low


    input  logic [ARRAY_SIZE-1:0][ARRAY_SIZE-1:0]        load_weight_grid,

    input  logic [ARRAY_SIZE-1:0][ACTIVATION_WIDTH-1:0]  act_west_in,

    // sum_north_in[j] feeds the topmost PE in column j.
    // Typically driven with '0 during standard matrix-multiply operation.
    input  logic [ARRAY_SIZE-1:0][ACCUMULATOR_WIDTH-1:0] sum_north_in,

    // act_east_out[i] is PE[i][ARRAY_SIZE-1].act_out (registered).
    output logic [ARRAY_SIZE-1:0][ACTIVATION_WIDTH-1:0]  act_east_out,

    // sum_south_out[j] is PE[ARRAY_SIZE-1][j].sum_out (registered).
    // After ARRAY_SIZE pipeline cycles these hold the dot-product results.
    output logic [ARRAY_SIZE-1:0][ACCUMULATOR_WIDTH-1:0] sum_south_out
);

  
    logic [ACTIVATION_WIDTH-1:0]  act_h [ARRAY_SIZE-1:0][ARRAY_SIZE:0];
    logic [ACCUMULATOR_WIDTH-1:0] sum_v [ARRAY_SIZE:0][ARRAY_SIZE-1:0];

    
    generate
        for (genvar i = 0; i < ARRAY_SIZE; i++) begin : gen_act_boundary
            // West edge: tie the leftmost horizontal wire to the external input port.
            assign act_h[i][0] = act_west_in[i];

            // East edge: the rightmost horizontal wire exits the grid.
            // PE[i][ARRAY_SIZE-1].act_out writes act_h[i][ARRAY_SIZE].
            assign act_east_out[i] = act_h[i][ARRAY_SIZE];
        end
    endgenerate


    generate
        for (genvar j = 0; j < ARRAY_SIZE; j++) begin : gen_sum_boundary
            // North edge: tie the topmost vertical wire to the external input port.
            // This means PE[0][j].sum_in = sum_v[0][j] = sum_north_in[j].
            assign sum_v[0][j] = sum_north_in[j];

            // South edge: the bottommost vertical wire carries the final result.
            // PE[ARRAY_SIZE-1][j].sum_out writes sum_v[ARRAY_SIZE][j].
            // Expose that wire on the output port.
            assign sum_south_out[j] = sum_v[ARRAY_SIZE][j];
        end
    endgenerate

    generate
        for (genvar i = 0; i < ARRAY_SIZE; i++) begin : gen_row
            for (genvar j = 0; j < ARRAY_SIZE; j++) begin : gen_col


                processing_element #(
                    // ── Propagate all width parameters to every PE instance ───
                    .ACTIVATION_WIDTH  (ACTIVATION_WIDTH ),
                    .WEIGHT_WIDTH      (WEIGHT_WIDTH     ),
                    .ACCUMULATOR_WIDTH (ACCUMULATOR_WIDTH)
                ) u_pe (

                    .clk         (clk                    ),
                    .rst_n       (rst_n                  ),

                    .load_weight (load_weight_grid[i][j] ),


                    .act_in      (act_h[i][j]            ),

                    .sum_in      (sum_v[i][j]            ),

                    .act_out     (act_h[i][j+1]          ),

                    .sum_out     (sum_v[i+1][j]          )
                );

            end 
        end 
    endgenerate

endmodule : systolic_array_grid

`default_nettype wire
