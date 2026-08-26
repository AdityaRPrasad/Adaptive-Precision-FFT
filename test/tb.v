`timescale 1ns/1ps


module tb;

    // ============================================================
    // TOP-LEVEL TESTBENCH SIGNALS
    // ============================================================

    reg        clk;
    reg        rst_n;
    reg        ena;

    reg [7:0]  ui_in;
    reg [7:0]  uio_in;
    
    wire [7:0] uo_out;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;

`ifdef GL_TEST
    supply1 VPWR;
    supply0 VGND;
`endif


    // ============================================================
    // LEGACY DIRECTED-TEST CONTROL SIGNALS
    //
    // These are retained only because the helper tasks below still
    // reference them. The tasks are NOT executed by the main
    // simulation block during Cocotb testing.
    // ============================================================

    reg [1:0] budget_tb;
    reg       start_tb;


    // ============================================================
    // DUT
    // ============================================================

    tt_um_adityarprasad_fft dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .ui_in   (ui_in),
        .uo_out  (uo_out),
        .ena     (ena),
        .uio_in  (uio_in),
        .uio_out (uio_out),
        .uio_oe  (uio_oe)
`ifdef GL_TEST
        ,
        .VPWR(VPWR),
        .VGND(VGND)
`endif
    );


    // ============================================================
    // CLOCK
    //
    // tb.v is the ONLY clock generator.
    //
    // Period = 10 ns
    // ============================================================

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // ============================================================
    // HELPER FUNCTIONS
    //
    // Retained from the original directed Verilog testbench.
    // ============================================================

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


    // ============================================================
    // EXPECTED PRECISION MODEL
    //
    // 0 = 4-bit
    // 1 = 6-bit
    // 2 = 8-bit
    // ============================================================

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


    // ============================================================
    // RUN ONE TRANSACTION
    //
    // IMPORTANT:
    // This task is retained from the original Verilog testbench,
    // but it is NOT called during Cocotb testing.
    // ============================================================

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
                xr_i,
                xi_i,
                yr_i,
                yi_i,
                budget_i
            );


            qr_i = quantize_model(yr_i, p_exp);
            qi_i = quantize_model(yi_i, p_exp);

            wr_i = tw_re_model(twiddle_i);
            wi_i = tw_im_model(twiddle_i);


            rot_re_i =
                signed8(
                    (qr_i * wr_i - qi_i * wi_i) >>> 7
                );

            rot_im_i =
                signed8(
                    (qr_i * wi_i + qi_i * wr_i) >>> 7
                );


            z0r_i = signed8(xr_i + rot_re_i);
            z0i_i = signed8(xi_i + rot_im_i);

            z1r_i = signed8(xr_i - rot_re_i);
            z1i_i = signed8(xi_i - rot_im_i);


            expected_bytes[0] = z0r_i & 8'hFF;
            expected_bytes[1] = z0i_i & 8'hFF;
            expected_bytes[2] = z1r_i & 8'hFF;
            expected_bytes[3] = z1i_i & 8'hFF;


            $display("");
            $display("------------------------------------------------------------");
            $display("TEST %0d", tx_id);

            $display(
                "Input : X=(%0d,%0d) Y=(%0d,%0d) budget=%0d twiddle=%0d",
                xr_i,
                xi_i,
                yr_i,
                yi_i,
                budget_i,
                twiddle_i
            );

            $display(
                "Expect: precision=%0d escalation=%0d",
                p_exp,
                (p_exp == 2)
            );

            $display(
                "Expect: Z0=(%0d,%0d) Z1=(%0d,%0d)",
                z0r_i,
                z0i_i,
                z1r_i,
                z1i_i
            );


            // Legacy task behavior.
            budget_tb = budget_i[1:0];

            start_tb = 1'b0;
            ui_in = 8'h00;

            @(negedge clk);


            ui_in = xr_i & 8'hFF;
            start_tb = 1'b1;

            @(posedge clk);
            #1;

            @(negedge clk);

            start_tb = 1'b0;


            ui_in = xi_i & 8'hFF;

            @(posedge clk);
            #1;

            @(negedge clk);


            ui_in = yr_i & 8'hFF;

            @(posedge clk);
            #1;

            @(negedge clk);


            ui_in = yi_i & 8'hFF;

            @(posedge clk);
            #1;

            @(negedge clk);


            ui_in = 8'h00;


            observed_count = 0;
            timeout_count = 0;
            failures = 0;


            while (
                (observed_count < 4) &&
                (timeout_count < 50)
            ) begin

                @(posedge clk);
                #1;

                if (uio_out[3] === 1'b1) begin

                    if (observed_count == 0) begin

                        precision_seen = uio_out[1:0];
                        escalation_seen = uio_out[2];


                        if (
                            precision_seen !== p_exp[1:0]
                        ) begin

                            $display(
                                "ERROR: precision mismatch. Expected %0d, got %0d",
                                p_exp,
                                precision_seen
                            );

                            failures = failures + 1;

                        end


                        if (
                            escalation_seen !== (p_exp == 2)
                        ) begin

                            $display(
                                "ERROR: escalation mismatch. Expected %0d, got %0d",
                                (p_exp == 2),
                                escalation_seen
                            );

                            failures = failures + 1;

                        end

                    end


                    if (
                        uo_out !==
                        expected_bytes[observed_count]
                    ) begin

                        $display(
                            "ERROR: output byte %0d mismatch. Expected %02h, got %02h",
                            observed_count,
                            expected_bytes[observed_count],
                            uo_out
                        );

                        failures = failures + 1;

                    end
                    else begin

                        $display(
                            "PASS : output byte %0d = %02h",
                            observed_count,
                            uo_out
                        );

                    end


                    observed_count =
                        observed_count + 1;

                end


                timeout_count =
                    timeout_count + 1;

            end


            if (observed_count != 4) begin

                $display(
                    "ERROR: VALID timeout. Only %0d/4 output bytes received.",
                    observed_count
                );

                failures = failures + 1;

            end


            timeout_count = 0;


            while (
                (uio_out[4] !== 1'b0) &&
                (timeout_count < 10)
            ) begin

                @(posedge clk);
                #1;

                timeout_count =
                    timeout_count + 1;

            end


            if (uio_out[4] !== 1'b0) begin

                $display(
                    "ERROR: BUSY did not return low."
                );

                failures = failures + 1;

            end


            if (failures == 0) begin

                $display(
                    "RESULT: TEST %0d PASSED",
                    tx_id
                );

            end
            else begin

                $display(
                    "RESULT: TEST %0d FAILED with %0d error(s)",
                    tx_id,
                    failures
                );

            end

        end

    endtask


    // ============================================================
    // START HOLD TEST
    //
    // Retained from the original Verilog testbench, but NOT called
    // during Cocotb testing.
    // ============================================================

    task automatic test_start_hold;

        integer cycles;
        integer valid_count;

        begin

            $display("");
            $display("------------------------------------------------------------");
            $display(
                "TEST 6: START edge-detector / held-START test"
            );


            budget_tb = 2'd2;

            start_tb = 1'b0;
            ui_in = 8'd0;

            @(negedge clk);


            ui_in = 8'd0;
            start_tb = 1'b1;

            @(posedge clk);
            #1;


            @(negedge clk);
            ui_in = 8'd0;

            @(posedge clk);
            #1;


            @(negedge clk);
            ui_in = 8'd0;

            @(posedge clk);
            #1;


            @(negedge clk);
            ui_in = 8'd0;

            @(posedge clk);
            #1;


            @(negedge clk);

            repeat (3) begin

                @(posedge clk);
                #1;

            end


            start_tb = 1'b0;


            valid_count = 0;
            cycles = 0;


            while (cycles < 20) begin

                @(posedge clk);
                #1;

                if (uio_out[3] === 1'b1)
                    valid_count =
                        valid_count + 1;

                cycles =
                    cycles + 1;

            end


            if (valid_count == 4) begin

                $display(
                    "PASS : held START produced exactly one transaction."
                );

            end
            else begin

                $display(
                    "ERROR: held START produced %0d VALID cycles; expected 4.",
                    valid_count
                );

            end

        end

    endtask


    // ============================================================
    // MAIN SIMULATION INITIALIZATION
    //
    // Cocotb owns:
    //   - reset sequencing
    //   - ui_in stimulus
    //   - uio_in stimulus
    //   - START
    //   - output checking
    //
    // Therefore:
    //   - DO NOT call run_transaction()
    //   - DO NOT call test_start_hold()
    //   - DO NOT call $finish
    // ============================================================

    initial begin

        rst_n     = 1'b0;
        ena       = 1'b1;

        ui_in     = 8'h00;
        uio_in    = 8'h00;

        budget_tb = 2'd0;
        start_tb  = 1'b0;

    end


endmodule

`default_nettype wire
