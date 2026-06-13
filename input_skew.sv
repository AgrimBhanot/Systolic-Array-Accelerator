// =============================================================================
// FILE        : input_skew.sv
// PROJECT     : N×N Weight-Stationary Systolic Array Accelerator
// DESCRIPTION : Input Skewing Module — transforms a flush (un-skewed) N-wide
//               activation bus into a properly staggered N-wide bus suitable
//               for feeding the West edge of the systolic array.
//
// SKEW TABLE (N = 4):
//   Row 0 → 0 cycle  delay  (combinational pass-through)
//   Row 1 → 1 cycle  delay  (1-stage  shift register)
//   Row 2 → 2 cycles delay  (2-stage  shift register)
//   Row 3 → 3 cycles delay  (3-stage  shift register)
//
// THEORY OF OPERATION:
//   In a weight-stationary systolic array the activation matrix X must arrive
//   diagonally aligned so that X[r][c] reaches PE[r][c] at the correct cycle.
//   Without skewing, all elements of row r arrive simultaneously and would
//   collide with the wrong PE column.  The delay chain ensures that element
//   X[r][c] is delayed by r cycles, causing it to meet X[0][c] as the data
//   wave propagates East through the pipeline.
//
// IMPLEMENTATION NOTES:
//   • Each pipeline stage (row × delay-depth) is a separate always_ff block
//     that only ever touches single, statically-named signals — no dynamic or
//     constant array indexing inside always blocks.
//   • Row 0 is a plain assign wire (zero pipeline registers).
//   • Row r has r pipeline stages; its output is tapped from stage (r-1).
//   • All combinational outputs use continuous assign statements.
//   • No behavioral delays (#), no initial blocks, no un-sized integer literals.
//   • Zero inferred latches — every branch is covered.
//
// SYNTHESIS   : Fully synthesizable.  Area ≈ (N*(N-1)/2)×DW data FFs +
//               (N*(N-1)/2) valid FFs.
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

import systolic_pkg::*;

module input_skew #(
    parameter int unsigned ROWS      = N,            // Number of activation rows
    parameter int unsigned DW        = DATA_WIDTH,   // Operand width in bits
    parameter int unsigned MAX_DELAY = ROWS - 1      // Max pipeline depth (= ROWS-1)
) (
    // ── Clock & Reset ─────────────────────────────────────────────────────────
    input  logic                      clk,
    input  logic                      rst_n,         // Async active-low reset

    // ── Un-skewed inputs (all rows present simultaneously) ────────────────────
    input  logic [ROWS-1:0][DW-1:0]  act_in,        // Parallel activation bus
    input  logic [ROWS-1:0]          act_valid,      // Per-row data-valid strobes

    // ── Skewed outputs to the West edge of the systolic grid ─────────────────
    output logic [ROWS-1:0][DW-1:0]  act_skewed,        // Staggered activation bus
    output logic [ROWS-1:0]          act_skewed_valid    // Staggered valid bus
);

  // ---------------------------------------------------------------------------
  // Intermediate pipeline nodes — one logic signal per (row, stage) pair.
  //
  // Naming convention:
  //   d_r<ROW>_s<STAGE>  — data   at row ROW after STAGE clock cycles
  //   v_r<ROW>_s<STAGE>  — valid  at row ROW after STAGE clock cycles
  //
  // Row 0 needs no pipeline storage (pure wire, zero stages).
  // Row 1 needs stage 0           (1 stage  → delay = 1 cycle).
  // Row 2 needs stages 0, 1       (2 stages → delay = 2 cycles).
  // Row 3 needs stages 0, 1, 2   (3 stages → delay = 3 cycles).
  // ---------------------------------------------------------------------------

  // Row 1 – 1 stage
  logic [DW-1:0] d_r1_s0; logic v_r1_s0;

  // Row 2 – 2 stages
  logic [DW-1:0] d_r2_s0; logic v_r2_s0;
  logic [DW-1:0] d_r2_s1; logic v_r2_s1;

  // Row 3 – 3 stages
  logic [DW-1:0] d_r3_s0; logic v_r3_s0;
  logic [DW-1:0] d_r3_s1; logic v_r3_s1;
  logic [DW-1:0] d_r3_s2; logic v_r3_s2;

  // ---------------------------------------------------------------------------
  // Row 0 — zero delay: direct continuous assignment
  // ---------------------------------------------------------------------------
  assign act_skewed[0]       = act_in[0];
  assign act_skewed_valid[0] = act_valid[0];

  // ---------------------------------------------------------------------------
  // Row 1 — 1 pipeline stage
  // Stage 0: capture from act_in[1]
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin : ff_r1_s0
    if (!rst_n) begin
      d_r1_s0 <= {DW{1'b0}};
      v_r1_s0 <= 1'b0;
    end else begin
      d_r1_s0 <= act_in[1];
      v_r1_s0 <= act_valid[1];
    end
  end : ff_r1_s0

  // Row 1 output: tap after 1 stage
  assign act_skewed[1]       = d_r1_s0;
  assign act_skewed_valid[1] = v_r1_s0;

  // ---------------------------------------------------------------------------
  // Row 2 — 2 pipeline stages
  // Stage 0: capture from act_in[2]
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin : ff_r2_s0
    if (!rst_n) begin
      d_r2_s0 <= {DW{1'b0}};
      v_r2_s0 <= 1'b0;
    end else begin
      d_r2_s0 <= act_in[2];
      v_r2_s0 <= act_valid[2];
    end
  end : ff_r2_s0

  // Stage 1: ripple from stage 0
  always_ff @(posedge clk or negedge rst_n) begin : ff_r2_s1
    if (!rst_n) begin
      d_r2_s1 <= {DW{1'b0}};
      v_r2_s1 <= 1'b0;
    end else begin
      d_r2_s1 <= d_r2_s0;
      v_r2_s1 <= v_r2_s0;
    end
  end : ff_r2_s1

  // Row 2 output: tap after 2 stages
  assign act_skewed[2]       = d_r2_s1;
  assign act_skewed_valid[2] = v_r2_s1;

  // ---------------------------------------------------------------------------
  // Row 3 — 3 pipeline stages
  // Stage 0: capture from act_in[3]
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin : ff_r3_s0
    if (!rst_n) begin
      d_r3_s0 <= {DW{1'b0}};
      v_r3_s0 <= 1'b0;
    end else begin
      d_r3_s0 <= act_in[3];
      v_r3_s0 <= act_valid[3];
    end
  end : ff_r3_s0

  // Stage 1: ripple from stage 0
  always_ff @(posedge clk or negedge rst_n) begin : ff_r3_s1
    if (!rst_n) begin
      d_r3_s1 <= {DW{1'b0}};
      v_r3_s1 <= 1'b0;
    end else begin
      d_r3_s1 <= d_r3_s0;
      v_r3_s1 <= v_r3_s0;
    end
  end : ff_r3_s1

  // Stage 2: ripple from stage 1
  always_ff @(posedge clk or negedge rst_n) begin : ff_r3_s2
    if (!rst_n) begin
      d_r3_s2 <= {DW{1'b0}};
      v_r3_s2 <= 1'b0;
    end else begin
      d_r3_s2 <= d_r3_s1;
      v_r3_s2 <= v_r3_s1;
    end
  end : ff_r3_s2

  // Row 3 output: tap after 3 stages
  assign act_skewed[3]       = d_r3_s2;
  assign act_skewed_valid[3] = v_r3_s2;

endmodule : input_skew

`default_nettype wire
