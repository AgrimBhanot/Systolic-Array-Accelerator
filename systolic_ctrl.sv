// =============================================================================
// FILE        : systolic_ctrl.sv
// PROJECT     : N×N Weight-Stationary Systolic Array Accelerator
// DESCRIPTION : Control Unit for the weight-stationary systolic array.
//
// FSM STATE MACHINE:
//
//   ┌─────────┐  start_i   ┌─────────────┐  load_done   ┌─────────┐
//   │  IDLE   │──────────► │ LOAD_WEIGHT │────────────► │ COMPUTE │
//   └─────────┘            └─────────────┘              └────┬────┘
//        ▲                                                   │ compute_done
//        │                  ┌────────────┐                   │
//        └──────────────────│ WRITE_BACK │ ◄─────────────────┘
//            wb_done        └────────────┘
//
// HANDSHAKING PROTOCOL:
//   • IDLE        : Assert start_i to begin a new tile computation.
//   • LOAD_WEIGHT : CU drives weight_valid_o for N cycles.  During this phase
//                   the external agent (or testbench) must present weight data
//                   on act_west_in (the weights are streamed through the
//                   activation horizontal lanes, as per the architecture).
//                   The CU pulses load_weight_o to tell every PE to latch its
//                   weight on the final cycle of the loading phase.
//   • COMPUTE     : CU asserts act_valid_o for 2N cycles.  During this phase
//                   the input_skew module presents staggered activations on
//                   the West edge of the grid.  acc_clear_o is asserted only
//                   on cycle 0 of COMPUTE (one-cycle reset pulse); because the
//                   existing PE has no dedicated clear pin the CU holds rst_n
//                   low for one cycle to flush accumulators — see note below.
//   • WRITE_BACK  : Asserts result_valid_o for WB_CYCLES cycles, signalling
//                   that sum_south_out holds stable results.
//
// ACCUMULATOR RESET NOTE:
//   The existing processing_element does not expose a dedicated acc_clear port.
//   To clear accumulators between tile computations the CU momentarily drives
//   acc_clear_o high.  The top-level integrator must AND this signal with rst_n
//   before routing it to the PE grid.  The signal is pulsed for exactly one
//   cycle at the beginning of COMPUTE, then de-asserted for the rest of the
//   computation.  On the very first computation after power-on reset this
//   pulse is not strictly necessary (reset zeroed everything), but it is
//   issued anyway for uniformity.
//
// TIMING SUMMARY (all counts are full clock cycles):
//   LOAD_WEIGHT  : N      cycles  (= LOAD_CYCLES   from systolic_pkg)
//   COMPUTE      : 2N     cycles  (= COMPUTE_CYCLES from systolic_pkg)
//   WRITE_BACK   : 1      cycle   (= WB_CYCLES      from systolic_pkg)
//   Total / tile : 3N + 1 cycles  (excluding IDLE stall time)
//
// DESIGN CONSTRAINTS:
//   • All sequential logic uses always_ff @(posedge clk or negedge rst_n).
//   • All combinational logic uses always_comb.
//   • No behavioral delays (#), no initial blocks, no un-sized integers.
//   • Zero inferred latches — every branch of every always_comb has a default.
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

import systolic_pkg::*;

module systolic_ctrl #(
    parameter int unsigned ARRAY_N    = N,              // Grid dimension
    parameter int unsigned LOAD_CYC   = LOAD_CYCLES,   // Weight-load phase length
    parameter int unsigned COMP_CYC   = COMPUTE_CYCLES,// Compute phase length
    parameter int unsigned WB_CYC     = WB_CYCLES      // Write-back phase length
) (
    // ── Clock & Reset ─────────────────────────────────────────────────────────
    input  logic            clk,
    input  logic            rst_n,         // Async active-low system reset

    // ── Handshake Inputs ──────────────────────────────────────────────────────
    input  logic            start_i,       // Pulse high for ≥1 cycle to start tile

    // ── Control Outputs to Grid / Skew Module ─────────────────────────────────

    // weight_valid_o: HIGH during LOAD_WEIGHT phase.
    // The external data source must present one weight column per cycle on
    // act_west_in while this signal is asserted.
    output logic            weight_valid_o,

    // load_weight_o: HIGH for exactly ONE cycle — the last cycle of LOAD_WEIGHT.
    // All PEs latch their weight_reg on this rising edge.
    // Wire to load_weight_grid (all bits) on the systolic_array_grid.
    output logic [ARRAY_N-1:0][ARRAY_N-1:0] load_weight_o,

    // act_valid_o: HIGH during the COMPUTE phase.
    // Route to the act_valid port of the input_skew module so it knows when
    // to accept and forward activations.
    output logic [ARRAY_N-1:0] act_valid_o,

    // acc_clear_o: HIGH for ONE cycle at the start of COMPUTE.
    // Top-level must gate rst_n with this: pe_rst_n = rst_n & ~acc_clear_o.
    output logic            acc_clear_o,

    // result_valid_o: HIGH during WRITE_BACK phase.
    // Downstream consumer may latch sum_south_out while this is asserted.
    output logic            result_valid_o,

    // ── State Observer (optional — useful for debug / coverage) ───────────────
    output fsm_state_t      state_o
);

  // ---------------------------------------------------------------------------
  // Local counter widths — sized to hold the largest cycle count.
  // $clog2(COMP_CYC) gives the minimum bits; we add 1 for unambiguous compare.
  // ---------------------------------------------------------------------------
  localparam int unsigned CNT_W = $clog2(COMP_CYC) + 1;  // e.g. $clog2(8)+1 = 4

  // ---------------------------------------------------------------------------
  // Internal registers
  // ---------------------------------------------------------------------------
  fsm_state_t             state_r,  state_nxt;     // Current / next FSM state
  logic [CNT_W-1:0]       cnt_r,    cnt_nxt;       // Phase cycle counter

  // One-cycle combinational flags decoded from counter value
  logic                   last_load_cycle;  // Final cycle of LOAD_WEIGHT
  logic                   last_comp_cycle;  // Final cycle of COMPUTE
  logic                   last_wb_cycle;    // Final cycle of WRITE_BACK

  // ---------------------------------------------------------------------------
  // Combinational: decode phase-boundary flags
  // ---------------------------------------------------------------------------
  always_comb begin : comb_boundary_flags
    last_load_cycle = (state_r == LOAD_WEIGHT) && (cnt_r == CNT_W'(LOAD_CYC - 1));
    last_comp_cycle = (state_r == COMPUTE)     && (cnt_r == CNT_W'(COMP_CYC - 1));
    last_wb_cycle   = (state_r == WRITE_BACK)  && (cnt_r == CNT_W'(WB_CYC  - 1));
  end

  // ---------------------------------------------------------------------------
  // Combinational: next-state & next-counter logic
  // ---------------------------------------------------------------------------
  always_comb begin : comb_fsm_next

    // ── Defaults (prevent latches) ──────────────────────────────────────────
    state_nxt = state_r;
    cnt_nxt   = cnt_r + CNT_W'(1);   // Default: increment counter

    case (state_r)

      // ── IDLE ───────────────────────────────────────────────────────────────
      IDLE : begin
        cnt_nxt = '0;                         // Reset counter in IDLE
        if (start_i) begin
          state_nxt = LOAD_WEIGHT;
          cnt_nxt   = '0;
        end
      end

      // ── LOAD_WEIGHT ────────────────────────────────────────────────────────
      LOAD_WEIGHT : begin
        if (last_load_cycle) begin
          state_nxt = COMPUTE;
          cnt_nxt   = '0;
        end
      end

      // ── COMPUTE ────────────────────────────────────────────────────────────
      COMPUTE : begin
        if (last_comp_cycle) begin
          state_nxt = WRITE_BACK;
          cnt_nxt   = '0;
        end
      end

      // ── WRITE_BACK ─────────────────────────────────────────────────────────
      WRITE_BACK : begin
        if (last_wb_cycle) begin
          state_nxt = IDLE;
          cnt_nxt   = '0;
        end
      end

      // ── Default (unreachable — all 2-bit encodings covered) ────────────────
      default : begin
        state_nxt = IDLE;
        cnt_nxt   = '0;
      end

    endcase
  end

  // ---------------------------------------------------------------------------
  // Sequential: register state and counter
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin : ff_state_cnt
    if (!rst_n) begin
      state_r <= IDLE;
      cnt_r   <= '0;
    end else begin
      state_r <= state_nxt;
      cnt_r   <= cnt_nxt;
    end
  end

  // ---------------------------------------------------------------------------
  // Combinational: output decode
  // All outputs are registered upstream in the FF block or decoded purely from
  // combinational state/counter — no flip-flops on outputs themselves so that
  // the control signals are zero-cycle-latency from the state perspective.
  // ---------------------------------------------------------------------------
  always_comb begin : comb_outputs

    // ── Defaults — prevent latches ──────────────────────────────────────────
    weight_valid_o  = 1'b0;
    load_weight_o   = '0;
    act_valid_o     = '0;
    acc_clear_o     = 1'b0;
    result_valid_o  = 1'b0;

    case (state_r)

      IDLE : begin
        // All outputs remain at their default (de-asserted) values.
      end

      LOAD_WEIGHT : begin
        // Assert weight_valid for the entire loading phase.
        weight_valid_o = 1'b1;

        // On the very last loading cycle, pulse load_weight to all PEs so
        // they simultaneously latch the weight currently sitting at their input.
        if (last_load_cycle) begin
          load_weight_o = '1;   // All-ones: enable every PE [i][j]
        end
      end

      COMPUTE : begin
        // Assert act_valid to all rows for the entire compute phase.
        act_valid_o = '1;

        // Pulse acc_clear on the first compute cycle only (cnt_r == 0).
        // This flushes any accumulated state from a prior tile.
        if (cnt_r == '0) begin
          acc_clear_o = 1'b1;
        end
      end

      WRITE_BACK : begin
        // Signal to downstream consumer that results are stable.
        result_valid_o = 1'b1;
      end

      default : begin
        // Defaults already applied above.
      end

    endcase
  end

  // ---------------------------------------------------------------------------
  // State observer output
  // ---------------------------------------------------------------------------
  assign state_o = state_r;

endmodule : systolic_ctrl

`default_nettype wire
