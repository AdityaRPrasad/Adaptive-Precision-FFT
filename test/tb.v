`timescale 1ns/1ps
`default_nettype none

module tb;

    reg        clk;
    reg        nreset;
    reg [7:0]  ui_in;

    wire [7:0] uo_out;
    reg [7:0]  uio_in;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;
    

    // DUT drives uio_out[4:0].
    // Testbench drives only the input pins:
    //   uio_in[7:6] = error budget
    //   uio_in[5]   = START
    reg [1:0] budget_tb;
    reg       start_tb;

    assign uio_in = {budget_tb, start_tb, 5'b00000};

    adaptive_fft_butterfly dut (
        .clk    (clk),
        .nreset (nreset),
        .ui_in  (ui_in),
        .uo_out (uo_out),
        .uio_in  (uio_in),
        .uio_out  (uio_out),
        .uio_oe  (uio_oe)
    );

    // ------------------------------------------------------------
    // Clock: 100 MHz, matching the 10 ns clock used in OpenLane.
    // ------------------------------------------------------------
  
    always #5 clk = ~clk;

    // ------------------------------------------------------------
    // Expected-result helper functions.
    // These reproduce the RTL's 4/6/8-bit quantization and
    // Q1.7 trivial twiddle arithmetic.
    // ------------------------------------------------------------

    function integer abs_i;
        input integer a;
        begin
            if (a < 0)
                abs_i = -a;
            else
                abs_i = a;
        end
    endfunction

    function integer quantize_model;
        input integer a;
        input integer p;
        begin
            case (p)
                0: quantize_model = (a >>> 4) <<< 4;
                1: quantize_model = (a >>> 2) <<< 2;
                default: quantize_model = a;
            endcase
        end
    endfunction

    function integer tw_re_model;
        input integer idx;
        begin
            case (idx)
                0: tw_re_model =  127;
                1: tw_re_model =    0;
                2: tw_re_model = -127;
                default: tw_re_model = 0;
            endcase
        end
    endfunction

    function integer tw_im_model;
        input integer idx;
        begin
            case (idx)
                0: tw_im_model =    0;
                1: tw_im_model = -127;
                2: tw_im_model =    0;
                default: tw_im_model = 127;
            endcase
        end
    endfunction

    function integer signed8;
        input integer a;
        integer t;
        begin
            t = a & 255;
            if (t >= 128)
                signed8 = t - 256;
            else
                signed8 = t;
        end
    endfunction

    function integer expected_precision;
        input integer xr_i;
        input integer xi_i;
        input integer yr_i;
        input integer yi_i;
        input integer budget_i;
        integer sensitivity;
        integer error4;
        integer error6;
        integer limit_i;
        integer effective_i;
        begin
            sensitivity = abs_i(xr_i);
            if (abs_i(xi_i) > sensitivity)
                sensitivity = abs_i(xi_i);
            if (abs_i(yr_i) > sensitivity)
                sensitivity = abs_i(yr_i);
            if (abs_i(yi_i) > sensitivity)
                sensitivity = abs_i(yi_i);

            error4 = abs_i(xr_i) & 15;
            if ((abs_i(xi_i) & 15) > error4)
                error4 = abs_i(xi_i) & 15;
            if ((abs_i(yr_i) & 15) > error4)
                error4 = abs_i(yr_i) & 15;
            if ((abs_i(yi_i) & 15) > error4)
                error4 = abs_i(yi_i) & 15;

            error6 = abs_i(xr_i) & 3;
            if ((abs_i(xi_i) & 3) > error6)
                error6 = abs_i(xi_i) & 3;
            if ((abs_i(yr_i) & 3) > error6)
                error6 = abs_i(yr_i) & 3;
            if ((abs_i(yi_i) & 3) > error6)
                error6 = abs_i(yi_i) & 3;

            case (budget_i)
                0: limit_i = 2;
                1: limit_i = 6;
                default: limit_i = 12;
            endcase

            if (sensitivity >= 64)
                effective_i = limit_i >> 1;
            else
                effective_i = limit_i;

            if (error4 > effective_i) begin
                if (error6 > effective_i)
                    expected_precision = 2;
                else
                    expected_precision = 1;
            end
            else begin
                expected_precision = 0;
            end
        end
    endfunction

    task automatic run_transaction;
        input integer tx_id;
        input integer xr_i;
        input integer xi_i;
        input integer yr_i;
        input integer yi_i;
        input integer budget_i;
        input integer twiddle_i;

        integer p_exp;
        integer qr_i;
        integer qi_i;
        integer wr_i;
        integer wi_i;
        integer rot_re_i;
        integer rot_im_i;
        integer z0r_i;
        integer z0i_i;
        integer z1r_i;
        integer z1i_i;

        integer observed_count;
        integer timeout_count;
        integer precision_seen;
        integer escalation_seen;
        integer failures;

        reg [7:0] expected_bytes [0:3];

        begin
            p_exp = expected_precision(
                xr_i, xi_i, yr_i, yi_i, budget_i
            );

            qr_i = quantize_model(yr_i, p_exp);
            qi_i = quantize_model(yi_i, p_exp);
            wr_i = tw_re_model(twiddle_i);
            wi_i = tw_im_model(twiddle_i);

            rot_re_i = signed8((qr_i * wr_i - qi_i * wi_i) >>> 7);
            rot_im_i = signed8((qr_i * wi_i + qi_i * wr_i) >>> 7);

            z0r_i = signed8(xr_i + rot_re_i);
            z0i_i = signed8(xi_i + rot_im_i);
            z1r_i = signed8(xr_i - rot_re_i);
            z1i_i = signed8(xi_i - rot_im_i);

            expected_bytes[0] = z0r_i & 8'hff;
            expected_bytes[1] = z0i_i & 8'hff;
            expected_bytes[2] = z1r_i & 8'hff;
            expected_bytes[3] = z1i_i & 8'hff;

            $display("");
            $display("------------------------------------------------------------");
            $display("TEST %0d", tx_id);
            $display("Input : X=(%0d,%0d) Y=(%0d,%0d) budget=%0d twiddle=%0d",
                     xr_i, xi_i, yr_i, yi_i, budget_i, twiddle_i);
            $display("Expect: precision=%0d  escalation=%0d",
                     p_exp, (p_exp == 2));
            $display("Expect: Z0=(%0d,%0d) Z1=(%0d,%0d)",
                     z0r_i, z0i_i, z1r_i, z1i_i);

            // Four successive input bytes:
            // cycle 1 = X_re, cycle 2 = X_im,
            // cycle 3 = Y_re, cycle 4 = Y_im.
            budget_tb = budget_i[1:0];

            ui_in = xr_i & 8'hff;
            start_tb = 1'b1;
            @(posedge clk);
            #1;
            start_tb = 1'b0;

            ui_in = xi_i & 8'hff;
            @(posedge clk);
            #1;

            ui_in = yr_i & 8'hff;
            @(posedge clk);
            #1;

            ui_in = yi_i & 8'hff;
            @(posedge clk);
            #1;

            // No more input data is required.
            ui_in = 8'h00;

            // Wait for VALID. The DUT needs DEC + 4 multiply cycles
            // + CALC before entering O0.
            observed_count = 0;
            timeout_count = 0;
            precision_seen = -1;
            escalation_seen = -1;
            failures = 0;

            while ((observed_count < 4) && (timeout_count < 30)) begin
                @(posedge clk);
                #1;

                if (uio_out[3] === 1'b1) begin
                    if (observed_count == 0) begin
                        precision_seen = uio_out[1:0];
                        escalation_seen = uio_out[2];

                        if (precision_seen !== p_exp[1:0]) begin
                            $display("ERROR: precision mismatch. Expected %0d, got %0d",
                                     p_exp, precision_seen);
                            failures = failures + 1;
                        end

                        if (escalation_seen !== (p_exp == 2)) begin
                            $display("ERROR: escalation mismatch. Expected %0d, got %0d",
                                     (p_exp == 2), escalation_seen);
                            failures = failures + 1;
                        end
                    end

                    if (uo_out !== expected_bytes[observed_count]) begin
                        $display("ERROR: output byte %0d mismatch. Expected %02h, got %02h",
                                 observed_count,
                                 expected_bytes[observed_count],
                                 uo_out);
                        failures = failures + 1;
                    end
                    else begin
                        $display("PASS : output byte %0d = %02h",
                                 observed_count, uo_out);
                    end

                    observed_count = observed_count + 1;
                end

                timeout_count = timeout_count + 1;
            end

            if (observed_count != 4) begin
                $display("ERROR: VALID timeout. Only %0d/4 output bytes received.",
                         observed_count);
                failures = failures + 1;
            end

            // Wait until the transaction has returned to IDLE.
            // This also confirms that BUSY is eventually deasserted.
            timeout_count = 0;
            while ((uio_out[4] !== 1'b0) && (timeout_count < 10)) begin
                @(posedge clk);
                #1;
                timeout_count = timeout_count + 1;
            end

            if (uio_out[4] !== 1'b0) begin
                $display("ERROR: BUSY did not return low.");
                failures = failures + 1;
            end

            if (failures == 0)
                $display("RESULT: TEST %0d PASSED", tx_id);
            else
                $display("RESULT: TEST %0d FAILED with %0d error(s)",
                         tx_id, failures);
        end
    endtask

    // ------------------------------------------------------------
    // START-hold test.
    // The DUT contains an edge detector, so holding START high
    // must not launch repeated transactions.
    // ------------------------------------------------------------
    task automatic test_start_hold;
        integer cycles;
        integer valid_count;
        begin
            $display("");
            $display("------------------------------------------------------------");
            $display("TEST 6: START edge-detector / held-START test");

            budget_tb = 2'd2;
            ui_in = 8'd0;
            start_tb = 1'b1;

            @(posedge clk);
            #1;

            ui_in = 8'd0;
            repeat (3) begin
                @(posedge clk);
                #1;
            end

            ui_in = 8'd0;
            repeat (3) begin
                @(posedge clk);
                #1;
            end

            ui_in = 8'd0;
            repeat (3) begin
                @(posedge clk);
                #1;
            end

            // Release START.
            start_tb = 1'b0;

            // The zero-input transaction should have produced exactly
            // four VALID cycles, not multiple transactions.
            valid_count = 0;
            cycles = 0;

            while (cycles < 12) begin
                @(posedge clk);
                #1;
                if (uio_out[3] === 1'b1)
                    valid_count = valid_count + 1;
                cycles = cycles + 1;
            end

            if (valid_count == 4)
                $display("PASS : held START produced exactly one transaction.");
            else
                $display("ERROR: held START produced %0d VALID cycles; expected 4.",
                         valid_count);
        end
    endtask

    // ------------------------------------------------------------
    // Main simulation
    // ------------------------------------------------------------
    initial begin
        clk       = 1'b0;
        budget_tb = 2'd0;
        start_tb  = 1'b0;
        ui_in     = 8'h00;
        nreset    = 1'b0;

        // Asynchronous reset.
        
        #20;
        nreset = 1'b1;

        #1;

        if (uio_oe !== 8'b00011111) begin
            $display("ERROR: Incorrect UIO output-enable: %08b", uio_oe);
            $fatal(1);
        end
        else begin
            $display("PASS : UIO output-enable = %08b", uio_oe);
        end


        // TEST 1:
        // Relaxed budget, low-magnitude operands.
        // Expected precision = 4-bit.
        // Twiddle index 0 = +1.
        run_transaction(
            1,  8, -4,  8, -4, 2, 0
        );

        // TEST 2:
        // Tight budget and operand 5.
        // Expected precision = 6-bit.
        // Twiddle index 1 = -j.
        run_transaction(
            2,  0, 0, 5, 0, 0, 1
        );

        // TEST 3:
        // Tight budget and operand 7.
        // Expected precision = 8-bit.
        // Twiddle index 2 = -1.
        run_transaction(
            3,  0, 0, 7, 0, 0, 2
        );

        // TEST 4:
        // Medium budget, mixed signed values.
        // Expected precision = 6-bit.
        // Twiddle index 3 = +j.
        run_transaction(
            4, 20, -12, -5, 7, 1, 3
        );

        // TEST 5:
        // High-sensitivity case. Tight budget forces 8-bit.
        // Twiddle index wraps back to 0.
        run_transaction(
            5, 100, -3, 7, -9, 0, 0
        );

        // TEST 6:
        // Verify START edge detection.
        test_start_hold();

        $display("");
        $display("============================================================");
        $display("ALL DIRECTED TESTS COMPLETED");
        $display("============================================================");

        #20;
        $finish;
    end

    // ------------------------------------------------------------
    // Global timeout so a broken DUT cannot hang the simulation.
    // ------------------------------------------------------------
    initial begin
        #1000;
        
        $finish;
    end

endmodule

`default_nettype wire
