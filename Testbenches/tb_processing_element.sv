`timescale 1ns / 1ps
`default_nettype none
// =============================================================================
// FILE        : tb_processing_element.sv
// DESCRIPTION : Unit testbench for the Processing Element (PE) module.
//               Includes self-checking immediate assertions with 1-cycle
//               delayed tracking registers for temporal property verification.
// =============================================================================

module tb_processing_element;

    // Parameters
    localparam int ACTIVATION_WIDTH  = 8;
    localparam int WEIGHT_WIDTH      = 8;
    localparam int ACCUMULATOR_WIDTH = 32;
    localparam int CLK_PERIOD        = 10;

    // Testbench Signals
    logic                          clk;
    logic                          rst_n;
    logic                          load_weight;
    logic [ACTIVATION_WIDTH-1:0]   act_in;
    logic [ACCUMULATOR_WIDTH-1:0]  sum_in;
    logic [ACTIVATION_WIDTH-1:0]   act_out;
    logic [ACCUMULATOR_WIDTH-1:0]  sum_out;

    // =========================================================================
    // Assertion Infrastructure
    // =========================================================================
    // 1-cycle delayed tracking registers — these shadow the DUT inputs one
    // clock behind so we can write temporal assertions like "output one cycle
    // after input" without needing concurrent SVA (which iverilog doesn't support).
    logic [ACTIVATION_WIDTH-1:0]  act_in_d1;    // act_in delayed by 1 cycle
    logic [ACCUMULATOR_WIDTH-1:0] sum_in_d1;    // sum_in delayed by 1 cycle
    logic                         load_weight_d1; // load_weight delayed by 1 cycle

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_in_d1      <= '0;
            sum_in_d1      <= '0;
            load_weight_d1 <= 1'b0;
        end else begin
            act_in_d1      <= act_in;
            sum_in_d1      <= sum_in;
            load_weight_d1 <= load_weight;
        end
    end

    // Assertion pass/fail counters
    int assert_total  = 0;
    int assert_passed = 0;
    int assert_failed = 0;

    // Cycle counter for readable assertion messages
    int cycle_count = 0;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cycle_count <= 0;
        else        cycle_count <= cycle_count + 1;
    end

    // Device Under Test (DUT)
    processing_element #(
        .ACTIVATION_WIDTH  (ACTIVATION_WIDTH),
        .WEIGHT_WIDTH      (WEIGHT_WIDTH),
        .ACCUMULATOR_WIDTH (ACCUMULATOR_WIDTH)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .load_weight (load_weight),
        .act_in      (act_in),
        .sum_in      (sum_in),
        .act_out     (act_out),
        .sum_out     (sum_out)
    );
    
    initial begin
        $dumpfile("Waveforms/wave_processing_element.vcd");
        $dumpvars(0, tb_processing_element);
    end
    
    // Clock Generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // Test Sequence
    initial begin
        // Initialize inputs
        rst_n       = 1'b0;
        load_weight = 1'b0;
        act_in      = '0;
        sum_in      = '0;

        // Apply Reset
        #(CLK_PERIOD * 2);
        rst_n = 1'b1;
        #(CLK_PERIOD);

        $display("[TB PE] Starting Unit Tests...");

        // ==========================================
        // Test Case 1: Load Weight
        // ==========================================
        // We want to load weight = 12 (0x0C)
        @(posedge clk);
        #1; // Post-edge delay to mimic non-blocking assignment
        act_in      = 8'd12;
        load_weight = 1'b1;

        @(posedge clk);
        #1;
        load_weight = 1'b0; // Deassert weight load
        act_in      = 8'd0;  // Clear input activation

        // -----------------------------------------------------------------
        // ASSERTION 1: Weight Capture — one cycle after load_weight was
        // asserted, act_out should have forwarded the loaded value (12).
        // We use act_in_d1 (the delayed shadow) as the expected weight.
        // -----------------------------------------------------------------
        assert_total++;
        assert (act_out == act_in_d1) else begin
            $error("[ASSERT FAIL ] Cycle %0d: Weight not captured correctly. act_out=%0d, expected act_in_d1=%0d",
                   cycle_count, act_out, act_in_d1);
            assert_failed++;
        end
        if (act_out == act_in_d1) begin
            $display("[ASSERT SUCCESS] Cycle %0d: weight capture confirmed — act_out correctly reflects loaded value (%0d)",
                     cycle_count, act_out);
            assert_passed++;
        end

        $display("[TB PE] Weight loaded. Internal register should now be 12.");

        // ==========================================
        // Test Case 2: Standard MAC Accumulation
        // ==========================================
        // Cycle A: Feed act_in = 5, sum_in = 100
        // Expected product = 5 * 12 = 60
        // Expected sum_out (on next cycle) = 100 + 60 = 160
        // Expected act_out (on next cycle) = 5
        @(posedge clk);
        #1;
        act_in = 8'd5;
        sum_in = 32'd100;

        @(posedge clk);
        #1;
        $display("[TB PE] Cycle 1 Output: act_out = %d (Expected: 5), sum_out = %d (Expected: 160)", act_out, sum_out);
        if (act_out !== 5 || sum_out !== 160) begin
            $display("[TB PE] ERROR: Cycle 1 mismatch!");
            $finish;
        end

        // -----------------------------------------------------------------
        // ASSERTION 2: MAC Accumulation — verify that sum_out is exactly
        // sum_in_d1 + (act_in_d1 * weight=12). Since weight_reg holds 12
        // and act_in_d1 = 5, we expect sum_in_d1(100) + 60 = 160.
        // -----------------------------------------------------------------
        assert_total++;
        assert (sum_out == (sum_in_d1 + 32'(act_in_d1) * 32'd12)) else begin
            $error("[ASSERT FAIL ] Cycle %0d: MAC accumulation wrong. sum_out=%0d, expected=%0d",
                   cycle_count, sum_out, sum_in_d1 + 32'(act_in_d1) * 32'd12);
            assert_failed++;
        end
        if (sum_out == (sum_in_d1 + 32'(act_in_d1) * 32'd12)) begin
            $display("[ASSERT SUCCESS] Cycle %0d: MAC accumulation correct — sum_out=%0d matches sum_in(%0d) + act(%0d)*w(12)",
                     cycle_count, sum_out, sum_in_d1, act_in_d1);
            assert_passed++;
        end

        // Cycle B: Feed act_in = 3, sum_in = 200
        // Expected product = 3 * 12 = 36
        // Expected sum_out = 200 + 36 = 236
        // Expected act_out = 3
        act_in = 8'd3;
        sum_in = 32'd200;

        @(posedge clk);
        #1;
        $display("[TB PE] Cycle 2 Output: act_out = %d (Expected: 3), sum_out = %d (Expected: 236)", act_out, sum_out);
        if (act_out !== 3 || sum_out !== 236) begin
            $display("[TB PE] ERROR: Cycle 2 mismatch!");
            $finish;
        end

        // ==========================================
        // Test Case 3: Verify Asynchronous Reset
        // ==========================================
        rst_n = 1'b0;
        #2; // Asynchronous action
        if (act_out !== 0 || sum_out !== 0) begin
            $display("[TB PE] ERROR: Asynchronous reset failed to clear outputs instantly!");
            $finish;
        end

        // -----------------------------------------------------------------
        // ASSERTION 3: Asynchronous Reset — outputs must be zero within
        // 2 ns of rst_n deassertion (no clock edge needed — this is async).
        // -----------------------------------------------------------------
        assert_total++;
        assert (act_out == '0 && sum_out == '0) else begin
            $error("[ASSERT FAIL ] Cycle %0d: async reset did not clear outputs. act_out=%0d sum_out=%0d",
                   cycle_count, act_out, sum_out);
            assert_failed++;
        end
        if (act_out == '0 && sum_out == '0) begin
            $display("[ASSERT SUCCESS] Cycle %0d: async reset verified — all outputs cleared to zero within 2 ns of rst_n low",
                     cycle_count);
            assert_passed++;
        end

        $display("[TB PE] Success. All single PE unit tests passed.");

        // ---- VERIFICATION REPORT CARD -----------------------------------
        $display("\n============================================================");
        $display("            PE VERIFICATION REPORT CARD");
        $display("============================================================");
        $display("  Total Assertions Triggered : %0d", assert_total);
        $display("  Assertions Passed          : %0d", assert_passed);
        $display("  Assertions Failed          : %0d", assert_failed);
        $display("------------------------------------------------------------");
        if (assert_failed == 0)
            $display("  VERDICT: PASS — all assertions satisfied, PE is compliant");
        else
            $display("  VERDICT: FAIL — %0d assertion(s) violated", assert_failed);
        $display("============================================================\n");
        $finish;
    end

endmodule : tb_processing_element
`default_nettype wire