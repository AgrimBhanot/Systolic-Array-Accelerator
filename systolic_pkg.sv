// =============================================================================
// FILE        : systolic_pkg.sv
// PROJECT     : N×N Weight-Stationary Systolic Array Accelerator
// AUTHOR      : RTL Design
// DESCRIPTION : Shared parameter package consumed by the control unit, input
//               skewing module, and any future top-level integration wrappers.
//               Import with:  import systolic_pkg::*;
// =============================================================================
// SYNTHESIS   : Fully synthesizable — no delays, no initial blocks.
// LINT        : Default-nettype none enforced at file level.
// =============================================================================

`default_nettype none

package systolic_pkg;

  // ---------------------------------------------------------------------------
  // Array geometry
  // ---------------------------------------------------------------------------
  parameter int unsigned N          = 4;   // Grid dimension: N×N Processing Elements

  // ---------------------------------------------------------------------------
  // Data widths
  // ---------------------------------------------------------------------------
  parameter int unsigned DATA_WIDTH = 8;   // Activation / weight operand width (bits)
  parameter int unsigned ACC_WIDTH  = 32;  // Partial-sum / accumulator width   (bits)

  // ---------------------------------------------------------------------------
  // Derived timing constants
  // ---------------------------------------------------------------------------
  // Total skew depth: row (N-1) sees (N-1) delay stages.
  parameter int unsigned SKEW_DEPTH = N - 1;

  // Number of clock cycles the compute phase lasts.
  // = N (pipeline fill) + N (drain) - 1  →  2N-1 cycles cover every diagonal.
  // We add 1 guard cycle → 2N cycles total.
  parameter int unsigned COMPUTE_CYCLES = 2 * N;

  // Weight-loading takes exactly N cycles to ripple weights to column N-1.
  parameter int unsigned LOAD_CYCLES = N;

  // Write-back phase: 1 cycle to register outputs (extend if downstream is slow).
  parameter int unsigned WB_CYCLES = 1;

  // ---------------------------------------------------------------------------
  // FSM state encoding  (one-hot recommended for FPGA; binary for ASIC)
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    IDLE        = 2'b00,
    LOAD_WEIGHT = 2'b01,
    COMPUTE     = 2'b10,
    WRITE_BACK  = 2'b11
  } fsm_state_t;

endpackage : systolic_pkg

`default_nettype wire
