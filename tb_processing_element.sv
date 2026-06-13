`timescale 1ns / 1ps
`default_nettype none

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
        
        $display("[TB PE] Success. All single PE unit tests passed.");
        $finish;
    end

endmodule : tb_processing_element
`default_nettype wire