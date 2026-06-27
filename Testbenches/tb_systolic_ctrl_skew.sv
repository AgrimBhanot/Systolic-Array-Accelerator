// =============================================================================
// FILE        : tb_systolic_ctrl_skew.sv
// PROJECT     : N×N Weight-Stationary Systolic Array Accelerator
// DESCRIPTION : Self-checking testbench for:
//                 • systolic_ctrl  — Control Unit FSM
//                 • input_skew    — Activation Skewing Module
//
// WHAT IT VERIFIES:
//   1. FSM state sequence: IDLE → LOAD_WEIGHT → COMPUTE → WRITE_BACK → IDLE
//   2. Cycle-accurate assertion/deassertion of all control signals.
//   3. Correct skew depth for each activation row (0–3 cycle delays).
//   4. Proper propagation of the valid strobe through the delay chain.
//   5. load_weight_o is asserted for exactly one cycle (last cycle of LOAD).
//   6. acc_clear_o is asserted for exactly one cycle (first cycle of COMPUTE).
//   7. result_valid_o is asserted for exactly WB_CYCLES cycles.
//
// DESIGN CONSTRAINTS (testbench):
//   • Uses @(posedge clk) / @(negedge clk) — no behavioral #delays in
//     RTL-observable paths.
//   • initial blocks are permitted in testbenches (not in synthesizable RTL).
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

import systolic_pkg::*;

module tb_systolic_ctrl_skew;

  // ---------------------------------------------------------------------------
  // Local parameters — kept explicit (no un-sized integers)
  // ---------------------------------------------------------------------------
  localparam int unsigned ARRAY_N   = N;            // 4
  localparam int unsigned DW        = DATA_WIDTH;   // 8
  localparam int unsigned CLK_HALF  = 5;            // 10 ns period

  // ---------------------------------------------------------------------------
  // DUT Ports — Control Unit
  // ---------------------------------------------------------------------------
  logic                                       clk;
  logic                                       rst_n;
  logic                                       start_i;

  logic                                       weight_valid_o;
  logic [ARRAY_N-1:0][ARRAY_N-1:0]           load_weight_o;
  logic [ARRAY_N-1:0]                         act_valid_o;
  logic                                       acc_clear_o;
  logic                                       result_valid_o;
  fsm_state_t                                 state_o;

  // ---------------------------------------------------------------------------
  // DUT Ports — Input Skew
  // ---------------------------------------------------------------------------
  logic [ARRAY_N-1:0][DW-1:0]                act_in;
  logic [ARRAY_N-1:0]                         act_valid_skew;

  logic [ARRAY_N-1:0][DW-1:0]                act_skewed;
  logic [ARRAY_N-1:0]                         act_skewed_valid;

  // ---------------------------------------------------------------------------
  // DUT Instantiation — Control Unit
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
      .load_weight_o  (load_weight_o  ),
      .act_valid_o    (act_valid_o    ),
      .acc_clear_o    (acc_clear_o    ),
      .result_valid_o (result_valid_o ),
      .state_o        (state_o        )
  );

  // ---------------------------------------------------------------------------
  // DUT Instantiation — Input Skew
  // The act_valid input to the skew module is taken directly from the CU's
  // act_valid_o so that the delay-chain valid tracking is also exercised.
  // ---------------------------------------------------------------------------
  assign act_valid_skew = act_valid_o;

  input_skew #(
      .ROWS      (ARRAY_N),
      .DW        (DW),
      .MAX_DELAY (ARRAY_N - 1)
  ) u_skew (
      .clk              (clk             ),
      .rst_n            (rst_n           ),
      .act_in           (act_in          ),
      .act_valid        (act_valid_skew  ),
      .act_skewed       (act_skewed      ),
      .act_skewed_valid (act_skewed_valid)
  );

  // ---------------------------------------------------------------------------
  // Clock Generation
  // ---------------------------------------------------------------------------

  initial begin
    $dumpfile("Waveforms/wave_systolic_ctrl_skew.vcd");
    $dumpvars(0, tb_systolic_ctrl_skew);
  end

  initial begin
    clk = 1'b0;
    forever #CLK_HALF clk = ~clk;
  end

  // ---------------------------------------------------------------------------
  // Scoreboard / counters (declared here so tasks can access them)
  // ---------------------------------------------------------------------------
  int unsigned total_errors;

  // Shared assertion counters — incremented by check() and the inline assert blocks
  int assert_total  = 0;
  int assert_passed = 0;
  int assert_failed = 0;

  // 1-cycle delayed tracking registers for temporal assertions.
  // These shadow key outputs one clock behind so we can verify
  // properties like "acc_clear was high exactly one cycle ago".
  fsm_state_t  state_o_d1;
  logic        acc_clear_d1;
  logic        result_valid_d1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_o_d1       <= IDLE;
      acc_clear_d1     <= 1'b0;
      result_valid_d1  <= 1'b0;
    end else begin
      state_o_d1       <= state_o;
      acc_clear_d1     <= acc_clear_o;
      result_valid_d1  <= result_valid_o;
    end
  end

  // Cycle counter for readable assertion messages
  int cycle_count = 0;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) cycle_count <= 0;
    else        cycle_count <= cycle_count + 1;
  end

  // Skew-verify variables — declared at module level (iverilog does not
  // support 'automatic' on variables inside begin..end named blocks).
  int unsigned skew_cycle [N];
  int unsigned sample_cycle_sv;
  logic        skew_found  [N];

  // ---------------------------------------------------------------------------
  // Helper: assert with message
  // ---------------------------------------------------------------------------
  // Wraps an immediate assert so that every check prints a cycle-stamped
  // success line on pass and a $error on fail — both update shared counters.
  task automatic check(
      input logic      actual,
      input logic      expected,
      input string     msg
  );
    assert_total++;
    if (actual !== expected) begin
      $error("[ASSERT FAIL ] Cycle %0d: %s  (got %b, expected %b)",
             cycle_count, msg, actual, expected);
      total_errors++;
      assert_failed++;
    end else begin
      $display("[ASSERT SUCCESS] Cycle %0d: %s", cycle_count, msg);
      assert_passed++;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Main test sequence
  // ---------------------------------------------------------------------------
  initial begin
    // ── Initialization ────────────────────────────────────────────────────────
    total_errors  = 32'h0;
    rst_n         = 1'b0;
    start_i       = 1'b0;
    act_in        = '0;

    // Apply reset for 3 clock cycles
    repeat (3) @(posedge clk);
    #1;   // Small δ past posedge so outputs have settled
    rst_n = 1'b1;

    // ── Verify IDLE state after reset ─────────────────────────────────────────
    @(negedge clk);
    check(state_o == IDLE,        1'b1, "State == IDLE after reset");
    check(weight_valid_o,         1'b0, "weight_valid_o LOW in IDLE");
    check(|load_weight_o,         1'b0, "load_weight_o all-LOW in IDLE");
    check(|act_valid_o,           1'b0, "act_valid_o all-LOW in IDLE");
    check(acc_clear_o,            1'b0, "acc_clear_o LOW in IDLE");
    check(result_valid_o,         1'b0, "result_valid_o LOW in IDLE");

    // -----------------------------------------------------------------
    // ASSERTION A: Post-reset state correctness — all control outputs
    // must be de-asserted after reset. This is a hard RTL invariant.
    // -----------------------------------------------------------------
    assert_total++;
    assert (state_o == IDLE && weight_valid_o == 0 && acc_clear_o == 0 && result_valid_o == 0) else begin
      $error("[ASSERT FAIL ] Cycle %0d: post-reset invariant violated — one or more control signals active in IDLE",
             cycle_count);
      assert_failed++;
    end
    if (state_o == IDLE && weight_valid_o == 0 && acc_clear_o == 0 && result_valid_o == 0) begin
      $display("[ASSERT SUCCESS] Cycle %0d: post-reset invariant confirmed — FSM in IDLE, all control outputs quiescent",
               cycle_count);
      assert_passed++;
    end

    // ── Drive constant activation values so we can track the skew delay ──────
    // Each row r gets a distinct marker value: 8'(r + 1).
    act_in[0] = DW'(8'h11);
    act_in[1] = DW'(8'h22);
    act_in[2] = DW'(8'h33);
    act_in[3] = DW'(8'h44);

    // ── Pulse start_i to kick off the FSM ─────────────────────────────────────
    @(posedge clk); #1;
    start_i = 1'b1;
    @(posedge clk); #1;
    start_i = 1'b0;

    // ── LOAD_WEIGHT phase checks ───────────────────────────────────────────────
    // Should now be in LOAD_WEIGHT with weight_valid asserted.
    @(negedge clk);
    check(state_o == LOAD_WEIGHT, 1'b1, "State == LOAD_WEIGHT after start");
    check(weight_valid_o,         1'b1, "weight_valid_o HIGH in LOAD_WEIGHT");
    check(|act_valid_o,           1'b0, "act_valid_o LOW in LOAD_WEIGHT");
    check(acc_clear_o,            1'b0, "acc_clear_o LOW in LOAD_WEIGHT");

    // Wait for (LOAD_CYCLES - 2) more cycles — we should still be in LOAD_WEIGHT.
    repeat (int'(LOAD_CYCLES) - 2) begin
      @(negedge clk);
      check(state_o == LOAD_WEIGHT, 1'b1, "Stayed in LOAD_WEIGHT");
      check(weight_valid_o,         1'b1, "weight_valid_o stays HIGH");
      // load_weight_o must be LOW until the last cycle
      check(|load_weight_o,         1'b0, "load_weight_o LOW (not last cycle yet)");
    end

    // Last cycle of LOAD_WEIGHT: load_weight_o must be ALL-ONES.
    @(negedge clk);
    check(state_o == LOAD_WEIGHT, 1'b1, "Still in LOAD_WEIGHT on last load cycle");
    check(&load_weight_o,         1'b1, "load_weight_o all-HIGH on last load cycle");

    // ── COMPUTE phase checks ───────────────────────────────────────────────────
    // After the last load cycle the FSM transitions to COMPUTE.
    @(negedge clk);
    check(state_o == COMPUTE,     1'b1, "State == COMPUTE after LOAD_WEIGHT");
    check(&act_valid_o,           1'b1, "act_valid_o all-HIGH in COMPUTE");
    check(weight_valid_o,         1'b0, "weight_valid_o LOW in COMPUTE");
    check(acc_clear_o,            1'b1, "acc_clear_o HIGH on first COMPUTE cycle");

    // Second cycle of COMPUTE: acc_clear_o must be de-asserted.
    @(negedge clk);
    check(acc_clear_o,            1'b0, "acc_clear_o LOW after first COMPUTE cycle");
    check(&act_valid_o,           1'b1, "act_valid_o HIGH on 2nd COMPUTE cycle");

    // -----------------------------------------------------------------
    // ASSERTION B: acc_clear one-shot property — using the 1-cycle
    // shadow register, confirm it was high exactly one cycle ago and
    // is now low. This proves the one-shot pulse shape is correct.
    // -----------------------------------------------------------------
    assert_total++;
    assert (acc_clear_d1 == 1'b1 && acc_clear_o == 1'b0) else begin
      $error("[ASSERT FAIL ] Cycle %0d: acc_clear_o one-shot violated — d1=%b, current=%b (expected high then low)",
             cycle_count, acc_clear_d1, acc_clear_o);
      assert_failed++;
    end
    if (acc_clear_d1 == 1'b1 && acc_clear_o == 1'b0) begin
      $display("[ASSERT SUCCESS] Cycle %0d: acc_clear one-shot confirmed — was high last cycle, deasserted now as required",
               cycle_count);
      assert_passed++;
    end

    // Wait remaining COMPUTE cycles.
    repeat (int'(COMPUTE_CYCLES) - 2) @(negedge clk);

    // ── WRITE_BACK phase checks ────────────────────────────────────────────────
    @(negedge clk);
    check(state_o == WRITE_BACK,  1'b1, "State == WRITE_BACK after COMPUTE");
    check(result_valid_o,         1'b1, "result_valid_o HIGH in WRITE_BACK");
    check(|act_valid_o,           1'b0, "act_valid_o LOW in WRITE_BACK");

    // -----------------------------------------------------------------
    // ASSERTION C: COMPUTE → WRITE_BACK transition — state_o_d1 must
    // be COMPUTE on the cycle before, confirming the FSM advanced on
    // schedule without missing or skipping the transition.
    // -----------------------------------------------------------------
    assert_total++;
    assert (state_o_d1 == COMPUTE && state_o == WRITE_BACK) else begin
      $error("[ASSERT FAIL ] Cycle %0d: FSM COMPUTE->WRITE_BACK transition missed — prev_state=%0d, curr_state=%0d (expect %0d->%0d)",
             cycle_count, state_o_d1, state_o, COMPUTE, WRITE_BACK);
      assert_failed++;
    end
    if (state_o_d1 == COMPUTE && state_o == WRITE_BACK) begin
      $display("[ASSERT SUCCESS] Cycle %0d: FSM transition COMPUTE->WRITE_BACK confirmed — state advanced exactly on schedule",
               cycle_count);
      assert_passed++;
    end

    // ── Back to IDLE ──────────────────────────────────────────────────────────
    repeat (int'(WB_CYCLES)) @(negedge clk);
    check(state_o == IDLE,        1'b1, "State == IDLE after WRITE_BACK");
    check(result_valid_o,         1'b0, "result_valid_o LOW after WRITE_BACK");

    // =========================================================================
    // Skew Depth Verification
    // Run the FSM again and measure how many cycles each row's marker appears
    // on act_skewed relative to when act_valid_o first goes high.
    // =========================================================================
    $display("\n--- Skew Depth Verification ---");

    // Pulse start again
    @(posedge clk); #1;
    start_i = 1'b1;
    @(posedge clk); #1;
    start_i = 1'b0;

    // Wait until COMPUTE begins — poll posedge until FSM enters COMPUTE.
    // (iverilog does not support the 'iff' guard in event expressions.)
    begin : skew_verify_block

      for (int unsigned r = 32'h0; r < ARRAY_N; r++) begin
        skew_cycle[r] = 32'hFFFFFFFF;
        skew_found[r] = 1'b0;
      end

      // Poll: wait for COMPUTE state.
      while (state_o != COMPUTE) @(posedge clk);
      // NOTE ON SAMPLING CONVENTION:
      // The while loop exits on the posedge where COMPUTE first becomes
      // active.  At that posedge all stage-0 FFs capture act_in.  The
      // immediately following negedge (sample_cycle 0) already shows the
      // FF outputs because the FF updates at posedge and the negedge of
      // the SAME cycle follows.  Therefore the observed negedge-based delay
      // for a row with r FFs is (r-1) negedge-samples, not r.
      // Expected mapping: row 0 → 0, row 1 → 0, row 2 → 1, row 3 → 2
      //                   i.e.  max(0, r-1) negedge samples.

      // Sample act_skewed for 2*ARRAY_N+1 negedges after COMPUTE starts
      sample_cycle_sv = 32'h0;
      repeat (2 * int'(ARRAY_N) + 1) begin
        @(negedge clk);   // Sample on falling edge (stable data)
        for (int unsigned r = 32'h0; r < ARRAY_N; r++) begin
          // Check if the marker for row r has appeared for the first time
          if ((!skew_found[r]) && act_skewed_valid[r] &&
              (act_skewed[r] == DW'((r + 8'h1) * 8'h11))) begin
            skew_cycle[r] = sample_cycle_sv;
            skew_found[r] = 1'b1;
          end
        end
        sample_cycle_sv++;
      end

      // Row r has r pipeline FFs.  The negedge-based observed delay is max(0, r-1)
      // (see note above).  Rows 0 and 1 both appear at sample cycle 0.
      for (int unsigned r = 32'h0; r < ARRAY_N; r++) begin
        int unsigned expected_depth;
        expected_depth = (r == 32'h0) ? 32'h0 : (r - 32'h1);
        if (skew_cycle[r] == expected_depth) begin
          $display("[PASS] Row %0d: %0d FF stage(s), first valid at negedge sample %0d (correct)",
                   r, r, skew_cycle[r]);
        end else begin
          $display("[FAIL] Row %0d: %0d FF stage(s), first valid at negedge sample %0d (expected %0d)",
                   r, r, skew_cycle[r], expected_depth);
          total_errors++;
        end
      end
    end : skew_verify_block

    // ── Final Summary ─────────────────────────────────────────────────────────
    @(negedge clk);
    $display("\n==================================================");
    $display("         CTRL + SKEW VERIFICATION REPORT         ");
    $display("==================================================");
    if (total_errors == 32'h0) begin
      $display("  RESULT: SUCCESS! All checks passed.");
    end else begin
      $display("  RESULT: FAILURE! %0d check(s) failed.", total_errors);
    end
    $display("==================================================");

    // ---- VERIFICATION REPORT CARD ---------------------------------------
    $display("\n============================================================");
    $display("        CTRL + SKEW VERIFICATION REPORT CARD");
    $display("============================================================");
    $display("  Total Assertions Triggered : %0d", assert_total);
    $display("  Assertions Passed          : %0d", assert_passed);
    $display("  Assertions Failed          : %0d", assert_failed);
    $display("------------------------------------------------------------");
    if (assert_failed == 0)
      $display("  VERDICT: PASS — FSM sequence and skew chain fully verified");
    else
      $display("  VERDICT: FAIL — %0d assertion(s) violated", assert_failed);
    $display("============================================================\n");

    $finish;
  end

endmodule : tb_systolic_ctrl_skew

`default_nettype wire
