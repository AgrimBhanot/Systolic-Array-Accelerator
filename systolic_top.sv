// =============================================================================
// FILE        : systolic_top.sv
// PROJECT     : N×N Weight-Stationary Systolic Array Accelerator
// DESCRIPTION : Top-level integration wrapper that connects:
//                 1. systolic_ctrl  — the FSM Control Unit
//                 2. input_skew     — the activation diagonal-skew network
//                 3. systolic_array_grid — the N×N PE fabric
//
// INTEGRATION DIAGRAM:
//
//  External                     ┌───────────────────┐
//  Stimulus ──── start_i ─────► │                   │
//                               │   systolic_ctrl   │── weight_valid_o ─► (user logic)
//  weight_cols_i[N][N] ────────►│       (FSM)       │── load_weight_o ──► to tell the weights are right next to their PEs, so load them
//                               │                   │── act_valid_o ────► skew
//                               │                   │── acc_clear_o ────► (gated rst)
//                               │                   │── result_valid_o ─► (user logic)
//                               └───────────────────┘
//
//  act_flat_i[N][DW] ───────────►┌───────────────────┐
//                                │    input_skew     │── act_skewed[N][DW] ─► ┐
//  (act_valid_o from ctrl) ─────►│  (delay chains)   │                        │
//                                └───────────────────┘                        │
//                                                                             ▼
//                               ┌──────────────────────────────────────────────┐
//                               │            systolic_array_grid               │
//                               │               N×N PE fabric                  │
//                               │  act_west_in ◄── skewed activations          │
//                               │  load_weight_grid ◄── ctrl load_weight_o     │
//                               │  sum_north_in ◄── tied to '0                 │
//                               └──────────────────────────────────────────────┘
//                                         │
//                               sum_south_out[N][ACC_WIDTH] ─────────────────►  result_o
//
// ACCUMULATOR CLEAR STRATEGY:
//   Because the processing_element has no dedicated acc_clear pin, a clean
//   start for each tile is achieved by momentarily driving the grid's rst_n
//   low for one cycle at the start of COMPUTE:
//       pe_rst_n = rst_n & ~acc_clear_o
//   This is safe because acc_clear_o is asserted for exactly one cycle by the
//   CU before any valid activation enters the pipeline.
//
// SYNTHESIS  : Fully synthesizable.
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

import systolic_pkg::*;

module systolic_top #(
    parameter int unsigned ARRAY_N   = N,
    parameter int unsigned DW        = DATA_WIDTH,
    parameter int unsigned AW        = ACC_WIDTH
) (
    // ── Clock & Reset ─────────────────────────────────────────────────────────
    input  logic                                      clk,
    input  logic                                      rst_n,       // Async active-low

    // ── Tile Start Handshake ──────────────────────────────────────────────────
    input  logic                                      start_i,     // Pulse to begin a tile

    // ── Weight Input Bus ─────────────────────────────────────────────────────
    // External agent streams N weight columns over N consecutive cycles.
    // Column order: column (N-1) first, column 0 last (rightmost-first).
    // This matches the existing testbench streaming convention.
    input  logic [ARRAY_N-1:0][DW-1:0]               weight_cols_i,

    // ── Activation Input Bus ─────────────────────────────────────────────────
    // External agent presents all N row activations simultaneously.
    // The skew module staggers them before feeding the grid.
    input  logic [ARRAY_N-1:0][DW-1:0]               act_flat_i,

    // ── Result Output ─────────────────────────────────────────────────────────
    output logic [ARRAY_N-1:0][AW-1:0]               result_o,    // Column dot-products
    output logic                                      result_valid_o,  // Stable result flag

    // ── Status ─────────────────────────────────────────────────────────────────
    output logic                                      weight_valid_o, // Loading phase active
    output fsm_state_t                                state_o         // FSM state (debug)
);

  // ---------------------------------------------------------------------------
  // Internal wires
  // ---------------------------------------------------------------------------

  // Control unit outputs
  logic [ARRAY_N-1:0][ARRAY_N-1:0] load_weight_w;  // Load-weight enable grid
  logic [ARRAY_N-1:0]              act_valid_w;     // Per-row compute valid
  logic                            acc_clear_w;     // Accumulator flush pulse

  // Skew module outputs
  logic [ARRAY_N-1:0][DW-1:0]     act_skewed_w;        // Diagonally staggered data
  logic [ARRAY_N-1:0]             act_skewed_valid_w;   // Staggered valid (unused by grid as of now)

  // Gated reset: drop rst_n for one cycle to flush accumulators
  logic                            pe_rst_n_w;

  // Grid act_west_in mux: weight data during LOAD_WEIGHT, activation data during COMPUTE
  logic [ARRAY_N-1:0][DW-1:0]     act_west_mux_w;

  // Grid sum_north_in: always zero for standard matrix multiply
  logic [ARRAY_N-1:0][AW-1:0]     sum_north_zeros_w;

  // Grid passthrough outputs
  logic [ARRAY_N-1:0][DW-1:0]     act_east_w;       // Not used externally here

  // ---------------------------------------------------------------------------
  // Ground the North partial-sum injection bus (standard matrix-multiply mode).
  assign sum_north_zeros_w = '0;

  // ---------------------------------------------------------------------------
  // Sub-module 1: Control Unit FSM
  // ---------------------------------------------------------------------------
  systolic_ctrl #(
      .ARRAY_N  (ARRAY_N),
      .LOAD_CYC (LOAD_CYCLES),
      .COMP_CYC (COMPUTE_CYCLES),
      .WB_CYC   (WB_CYCLES)
  ) u_ctrl (
      .clk            (clk            ),
      .rst_n          (rst_n          ),
      .start_i        (start_i        ),
      .weight_valid_o (weight_valid_o ),
      .load_weight_o  (load_weight_w  ),
      .act_valid_o    (act_valid_w    ),
      .acc_clear_o    (acc_clear_w    ),
      .result_valid_o (result_valid_o ),
      .state_o        (state_o        )
  );

  // ---------------------------------------------------------------------------
  // Sub-module 2: Input Skewing Module
  // ---------------------------------------------------------------------------
  input_skew #(
      .ROWS      (ARRAY_N),
      .DW        (DW),
      .MAX_DELAY (ARRAY_N - 1)
  ) u_skew (
      .clk               (clk            ),
      .rst_n             (rst_n          ),
      .act_in            (act_flat_i     ),
      .act_valid         (act_valid_w    ),
      .act_skewed        (act_skewed_w        ),
      .act_skewed_valid  (act_skewed_valid_w  )
  );

  // ---------------------------------------------------------------------------
  // Accumulator clear: gate rst_n low for exactly one cycle when acc_clear_w
  // is pulsed.  PE fabric resets on negedge of pe_rst_n_w.
  // ---------------------------------------------------------------------------
  always_comb begin : comb_pe_rst_gate
    pe_rst_n_w = rst_n & (~acc_clear_w);
  end

  // ---------------------------------------------------------------------------
  // act_west_in MUX: during weight loading the weight column data must flow
  // through the horizontal lanes so PEs can latch their weights.  During the
  // compute phase the staggered activations are injected instead.
  // ---------------------------------------------------------------------------
  always_comb begin : comb_act_west_mux
    if (weight_valid_o) begin
      act_west_mux_w = weight_cols_i;   // Weight streaming mode
    end else begin
      act_west_mux_w = act_skewed_w;    // Activation compute mode
    end
  end

  // ---------------------------------------------------------------------------
  // Sub-module 3: Systolic Array PE Grid
  // ---------------------------------------------------------------------------
  systolic_array_grid #(
      .ARRAY_SIZE        (ARRAY_N),
      .ACTIVATION_WIDTH  (DW),
      .WEIGHT_WIDTH      (DW),
      .ACCUMULATOR_WIDTH (AW)
  ) u_grid (
      .clk              (clk              ),
      .rst_n            (pe_rst_n_w       ),   // Gated reset (also clears accumulators)
      .load_weight_grid (load_weight_w    ),
      .act_west_in      (act_west_mux_w   ),
      .sum_north_in     (sum_north_zeros_w),
      .act_east_out     (act_east_w       ),
      .sum_south_out    (result_o         )
  );

endmodule : systolic_top

`default_nettype wire
