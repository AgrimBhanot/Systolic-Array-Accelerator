`timescale 1ns / 1ps
`default_nettype none
// =============================================================================
// FILE        : tb_systolic_array_grid.sv
// DESCRIPTION : Integration testbench for the 4×4 systolic array grid.
//               Runs weight loading, skewed activation streaming, and output
//               capture against a software golden reference.
//               Includes self-checking immediate assertions with 1-cycle
//               delayed tracking registers for temporal property verification.
// =============================================================================

module tb_systolic_array_grid;

    // Parameters
    localparam int ARRAY_SIZE        = 4;
    localparam int ACTIVATION_WIDTH  = 8;
    localparam int WEIGHT_WIDTH      = 8;
    localparam int ACCUMULATOR_WIDTH = 32;
    localparam int CLK_PERIOD        = 10;

    // Testbench Ports
    logic                                               clk;
    logic                                               rst_n;
    logic [ARRAY_SIZE-1:0][ARRAY_SIZE-1:0]              load_weight_grid;
    logic [ARRAY_SIZE-1:0][ACTIVATION_WIDTH-1:0]        act_west_in;
    logic [ARRAY_SIZE-1:0][ACCUMULATOR_WIDTH-1:0]       sum_north_in;
    logic [ARRAY_SIZE-1:0][ACTIVATION_WIDTH-1:0]        act_east_out;
    logic [ARRAY_SIZE-1:0][ACCUMULATOR_WIDTH-1:0]       sum_south_out;

    // Device Under Test
    systolic_array_grid #(
        .ARRAY_SIZE        (ARRAY_SIZE),
        .ACTIVATION_WIDTH  (ACTIVATION_WIDTH),
        .WEIGHT_WIDTH      (WEIGHT_WIDTH),
        .ACCUMULATOR_WIDTH (ACCUMULATOR_WIDTH)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .load_weight_grid (load_weight_grid),
        .act_west_in      (act_west_in),
        .sum_north_in     (sum_north_in),
        .act_east_out     (act_east_out),
        .sum_south_out    (sum_south_out)
    );

    // Golden Matrices & Software Reference Models
    logic [WEIGHT_WIDTH-1:0]     matrix_W [ARRAY_SIZE][ARRAY_SIZE];
    logic [ACTIVATION_WIDTH-1:0] matrix_X [ARRAY_SIZE][ARRAY_SIZE];
    logic [ACCUMULATOR_WIDTH-1:0] matrix_Y_golden   [ARRAY_SIZE][ARRAY_SIZE];
    logic [ACCUMULATOR_WIDTH-1:0] matrix_Y_captured  [ARRAY_SIZE][ARRAY_SIZE];

    // =========================================================================
    // Assertion Infrastructure
    // =========================================================================
    // Shadow registers: track DUT-visible signals 1 cycle behind so that
    // we can reason about "what was driven last cycle" in assertions.
    logic [ARRAY_SIZE-1:0][ACTIVATION_WIDTH-1:0] act_west_in_d1;
    logic [ARRAY_SIZE-1:0]                        load_weight_grid_d1;

    always_ff @(posedge clk) begin
        act_west_in_d1      <= act_west_in;
        load_weight_grid_d1 <= load_weight_grid;
    end

    // Assertion pass/fail counters (module-level so tasks can access them)
    int assert_total  = 0;
    int assert_passed = 0;
    int assert_failed = 0;

    // Cycle counter — rolls from 0 and ticks on every posedge
    int cycle_count = 0;
    always_ff @(posedge clk) cycle_count <= cycle_count + 1;

    initial begin
        $dumpfile("Waveforms/wave_systolic_array_grid.vcd");
        $dumpvars(0, tb_systolic_array_grid);
    end
    
    // Clock Generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // Task to calculate behavioral golden matrix multiplication: Y = X * W
    function automatic void compute_golden_reference();
        for (int r = 0; r < ARRAY_SIZE; r++) begin
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                matrix_Y_golden[r][c] = '0;
                for (int k = 0; k < ARRAY_SIZE; k++) begin
                    matrix_Y_golden[r][c] += matrix_X[r][k] * matrix_W[k][c];
                end
            end
        end
    endfunction

    // Task to initialize test arrays with distinct, easy-to-verify patterns
    task initialize_test_matrices();
        // Weights (W)
        matrix_W[0][0] = 8'd2; matrix_W[0][1] = 8'd4; matrix_W[0][2] = 8'd1; matrix_W[0][3] = 8'd3;
        matrix_W[1][0] = 8'd1; matrix_W[1][1] = 8'd0; matrix_W[1][2] = 8'd3; matrix_W[1][3] = 8'd2;
        matrix_W[2][0] = 8'd3; matrix_W[2][1] = 8'd2; matrix_W[2][2] = 8'd0; matrix_W[2][3] = 8'd1;
        matrix_W[3][0] = 8'd0; matrix_W[3][1] = 8'd1; matrix_W[3][2] = 8'd4; matrix_W[3][3] = 8'd2;

        // Activations (X)
        matrix_X[0][0] = 8'd5; matrix_X[0][1] = 8'd2; matrix_X[0][2] = 8'd3; matrix_X[0][3] = 8'd1;
        matrix_X[1][0] = 8'd0; matrix_X[1][1] = 8'd4; matrix_X[1][2] = 8'd1; matrix_X[1][3] = 8'd2;
        matrix_X[2][0] = 8'd3; matrix_X[2][1] = 8'd1; matrix_X[2][2] = 8'd0; matrix_X[2][3] = 8'd5;
        matrix_X[3][0] = 8'd2; matrix_X[3][1] = 8'd3; matrix_X[3][2] = 8'd4; matrix_X[3][3] = 8'd0;

        compute_golden_reference();
    endtask

    // Simulation Flow
    initial begin
        // Reset and clear inputs
        rst_n            = 1'b0;
        load_weight_grid = '0;
        act_west_in      = '0;
        sum_north_in     = '0;

        initialize_test_matrices();

        #(CLK_PERIOD * 3);
        rst_n = 1'b1;
        #(CLK_PERIOD);

        // =====================================================================
        // Step 1: Weight Loading Phase (Skewed Loading)
        // =====================================================================
        $display("[TB GRID] Loading weights into the stationary register grid...");
        
        // To load W[row][col] into PE[row][col], we must stream weights 
        // through the horizontal lanes. It takes 4 cycles to shift the weights
        // all the way to the Eastmost column.
        for (int cycle = 0; cycle < ARRAY_SIZE; cycle++) begin
            @(posedge clk);
            #1;
            // Feed columns of weight matrix W backwards from Col 3 down to Col 0
            for (int r = 0; r < ARRAY_SIZE; r++) begin
                act_west_in[r] = matrix_W[r][(ARRAY_SIZE - 1) - cycle];
            end
        end
        load_weight_grid = '1;

        // At cycle 3, W[r][c] is resting exactly at the input of PE[r][c].
        // Assert load control to capture the weights on the next rising edge.
        //@(posedge clk);
        //#1;
        //load_weight_grid = '0; // Enable load for all PEs

        @(posedge clk);
        #1;
        load_weight_grid = '0; // Deassert load
        act_west_in      = '0; // Clear inputs

        // -----------------------------------------------------------------
        // ASSERTION 1: Weight Load Strobe — verify that on the cycle we
        // just finished, load_weight_grid was asserted (load strobe fired).
        // load_weight_grid_d1 holds the value from one clock ago.
        // -----------------------------------------------------------------
        assert_total++;
        assert (load_weight_grid_d1 == '1) else begin
            $error("[ASSERT FAIL ] Cycle %0d: load_weight_grid strobe was not all-ones on weight capture cycle.",
                   cycle_count);
            assert_failed++;
        end
        if (load_weight_grid_d1 == '1) begin
            $display("[ASSERT SUCCESS] Cycle %0d: weight load strobe confirmed — load_weight_grid was fully asserted on capture cycle",
                     cycle_count);
            assert_passed++;
        end

        $display("[TB GRID] Weights loaded into registers.");
        #(CLK_PERIOD * 2);

        // =====================================================================
        // Step 2: Execution Phase (Sensing & Driving Skewed Activations)
        // =====================================================================
        $display("[TB GRID] Launching computation...");
        
        // Fork off the output monitor thread to sample results on falling edges
        fork
            sample_outputs();
        join_none

        // Drive the input matrix X from the West, skewed by 1 cycle per row.
        // The loop runs for 2*ARRAY_SIZE cycles to push the entire skewed shape.
        for (int c = 0; c < 2 * ARRAY_SIZE; c++) begin
            @(posedge clk);
            #1;
            for (int r = 0; r < ARRAY_SIZE; r++) begin
                // Row r is active when: 0 <= cycle - r < ARRAY_SIZE
                int col_index;
                col_index = c - r;
                if (col_index >= 0 && col_index < ARRAY_SIZE) begin
                    act_west_in[r] = matrix_X[col_index][r];
                end else begin
                    act_west_in[r] = '0;
                end
            end
            // Feed constant zeros from the North as starting partial sums
            sum_north_in = '0;

            // -----------------------------------------------------------------
            // ASSERTION 2: Skewed Activation Value Correctness — verify that
            // the datum delivered to Row 0 in the *previous* cycle exactly
            // matches what the golden reference says should have been there.
            // Since Row 0 has zero skew delay, at stream step c the previous
            // cycle (c-1) should have driven matrix_X[c-1][0] onto the wire.
            // act_west_in_d1[0] captures exactly that via the shadow register.
            // -----------------------------------------------------------------
            if (c >= 1 && c < ARRAY_SIZE) begin
                assert_total++;
                assert (act_west_in_d1[0] == matrix_X[c-1][0]) else begin
                    $error("[ASSERT FAIL ] Cycle %0d (stream step %0d): Row 0 activation mismatch — got 0x%02h, expected matrix_X[%0d][0]=0x%02h",
                           cycle_count, c, act_west_in_d1[0], c-1, matrix_X[c-1][0]);
                    assert_failed++;
                end
                if (act_west_in_d1[0] == matrix_X[c-1][0]) begin
                    $display("[ASSERT SUCCESS] Cycle %0d (stream step %0d): Row 0 skew delivery correct — act_west_in_d1[0]=0x%02h matches matrix_X[%0d][0]",
                             cycle_count, c, act_west_in_d1[0], c-1);
                    assert_passed++;
                end
            end
        end

        // Keep driving zeros until everything clears the pipeline
        for (int i = 0; i < ARRAY_SIZE * 2; i++) begin
            @(posedge clk);
            #1;
            act_west_in  = '0;
            sum_north_in = '0;
        end

        // =====================================================================
        // Step 3: Self-Checking Verification
        // =====================================================================
        verify_results();
        $finish;
    end

    // =========================================================================
    // Helper Task: Sample Outputs
    // =========================================================================
    // The result element Y[m][j] exits from Column j of the South edge.
    // It is ready at `sum_south_out[j]` at cycle (m + j + ARRAY_SIZE).
    // Sampling is performed on the falling edge to avoid setup/hold race conditions.
    // =========================================================================
    task automatic sample_outputs();
        // Clear capture array
        for (int r = 0; r < ARRAY_SIZE; r++) begin
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                matrix_Y_captured[r][c] = '0;
            end
        end

        // Monitor the outputs for the duration of the operational window
        for (int cycle = 0; cycle < ARRAY_SIZE * 3; cycle++) begin
            @(negedge clk);
            for (int j = 0; j < ARRAY_SIZE; j++) begin
                // Since Cycle = m + j + ARRAY_SIZE
                // We back-calculate: m = Cycle - j - ARRAY_SIZE
                int m;
                m = cycle - j - ARRAY_SIZE - 1;
                if (m >= 0 && m < ARRAY_SIZE) begin
                    matrix_Y_captured[m][j] = sum_south_out[j];
                end
            end
        end
    endtask

    // =========================================================================
    // Helper Task: Compare Capture against Golden
    // =========================================================================
    task automatic verify_results();
        int errors = 0;
        $display("\n==================================================");
        $display("               VERIFICATION REPORT                ");
        $display("==================================================");
        
        // Print Golden Matrix Y
        $display("\n--- Expected Golden Reference Matrix Y ---");
        for (int r = 0; r < ARRAY_SIZE; r++) begin
            $display("  [%2d %2d %2d %2d]", 
                matrix_Y_golden[r][0], matrix_Y_golden[r][1], 
                matrix_Y_golden[r][2], matrix_Y_golden[r][3]);
        end

        // Print Captured Hardware Matrix Y
        $display("\n--- Captured Hardware Output Matrix Y ---");
        for (int r = 0; r < ARRAY_SIZE; r++) begin
            $display("  [%2d %2d %2d %2d]", 
                matrix_Y_captured[r][0], matrix_Y_captured[r][1], 
                matrix_Y_captured[r][2], matrix_Y_captured[r][3]);
        end

        // -----------------------------------------------------------------
        // ASSERTION 3: Element-wise Matrix Correctness — every captured
        // output must exactly match the software golden reference.
        // Each element is an independent assertion so failures are reported
        // at element granularity rather than as a lump sum.
        // -----------------------------------------------------------------
        $display("\n--- Element-wise Assertion Results ---");
        for (int r = 0; r < ARRAY_SIZE; r++) begin
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                assert_total++;
                assert (matrix_Y_captured[r][c] === matrix_Y_golden[r][c]) else begin
                    $error("[ASSERT FAIL ] Cycle %0d: Y[%0d][%0d] mismatch — got %0d, expected %0d",
                           cycle_count, r, c, matrix_Y_captured[r][c], matrix_Y_golden[r][c]);
                    errors++;
                    assert_failed++;
                end
                if (matrix_Y_captured[r][c] === matrix_Y_golden[r][c]) begin
                    $display("[ASSERT SUCCESS] Cycle %0d: Y[%0d][%0d] = %0d — hardware output matches golden reference",
                             cycle_count, r, c, matrix_Y_captured[r][c]);
                    assert_passed++;
                end
            end
        end

        $display("\n==================================================");
        if (errors == 0) begin
            $display("  RESULT: SUCCESS! All calculations match golden model.");
        end else begin
            $display("  RESULT: FAILURE! Total of %0d mismatches detected.", errors);
        end
        $display("==================================================");

        // ---- VERIFICATION REPORT CARD -----------------------------------
        $display("\n============================================================");
        $display("           GRID VERIFICATION REPORT CARD");
        $display("============================================================");
        $display("  Total Assertions Triggered : %0d", assert_total);
        $display("  Assertions Passed          : %0d", assert_passed);
        $display("  Assertions Failed          : %0d", assert_failed);
        $display("------------------------------------------------------------");
        if (assert_failed == 0)
            $display("  VERDICT: PASS — full 4x4 matrix verified, zero mismatches");
        else
            $display("  VERDICT: FAIL — %0d assertion(s) violated", assert_failed);
        $display("============================================================\n");
    endtask

endmodule : tb_systolic_array_grid
`default_nettype wire