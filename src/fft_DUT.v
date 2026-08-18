`timescale 1ns/1ps
`default_nettype none

module adaptive_fft_butterfly (
    input  wire       clk,
    input  wire       nreset,
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe
);

    // ================================================================
    // Tiny Tapeout interface
    //
    // Dedicated:
    //   clk      : clock
    //   nreset   : active-low asynchronous reset
    //
    // ui_in[7:0]:
    //   Four successive input bytes after START:
    //       byte 0 = X_re
    //       byte 1 = X_im
    //       byte 2 = Y_re
    //       byte 3 = Y_im
    //
    // uo_out[7:0]:
    //   Four successive output bytes while VALID=1:
    //       byte 0 = Z0_re
    //       byte 1 = Z0_im
    //       byte 2 = Z1_re
    //       byte 3 = Z1_im
    //
    // uio[5]   : START input pulse
    // uio[7:6] : error-budget selection input
    //            00 = tight
    //            01 = medium
    //            10 = relaxed
    //            11 = relaxed
    //
    // uio[4]   : BUSY output
    // uio[3]   : VALID output
    // uio[2]   : 8-bit escalation flag
    // uio[1:0] : selected precision
    //            00 = 4-bit
    //            01 = 6-bit
    //            10 = 8-bit
    // ================================================================

    reg [4:0] uio_out_reg;
    reg [7:0] out_reg;

    assign uio_out = {3'b000, uio_out_reg};

    assign uio_oe = 8'b00011111;
    
    // Upper three bidirectional pins are inputs during operation.
   

    assign uo_out = out_reg;

    wire       start_in  = uio_in[5];
    wire [1:0] budget_in = uio_in[7:6];


    // ================================================================
    // START edge detector
    // Prevents a continuously-high START from starting repeated
    // transactions.
    // ================================================================

    reg start_d;

    wire start_pulse = start_in & ~start_d;


    // ================================================================
    // Controller states
    // ================================================================

    localparam [3:0]
        S_IDLE = 4'd0,
        S_XI   = 4'd1,
        S_YR   = 4'd2,
        S_YI   = 4'd3,
        S_DEC  = 4'd4,
        S_M0   = 4'd5,
        S_M1   = 4'd6,
        S_M2   = 4'd7,
        S_M3   = 4'd8,
        S_CALC = 4'd9,
        S_O0   = 4'd10,
        S_O1   = 4'd11,
        S_O2   = 4'd12,
        S_O3   = 4'd13;

    reg [3:0] state;


    // ================================================================
    // Input operand registers
    // ================================================================

    reg signed [7:0] xr;
    reg signed [7:0] xi;
    reg signed [7:0] yr;
    reg signed [7:0] yi;


    // ================================================================
    // Adaptive precision controller
    //
    // precision:
    //   00 = 4-bit
    //   01 = 6-bit
    //   10 = 8-bit
    // ================================================================

    reg [1:0] precision;

    reg [1:0] budget_reg;

    reg [1:0] twiddle_index;

    reg escalated;


    // ================================================================
    // Shared multiplier datapath
    //
    // Four real multiplications implement one complex multiplication:
    //
    //   p0 = Yr * Wr
    //   p1 = Yi * Wi
    //   p2 = Yi * Wr
    //   p3 = Yr * Wi
    //
    // Re(YW) = p0 - p1
    // Im(YW) = p3 + p2
    //
    // The same multiplier hardware is reused over four clock cycles.
    // ================================================================

    reg signed [7:0]  mult_a;
    reg signed [7:0]  mult_b;

    reg signed [15:0] p0;
    reg signed [15:0] p1;
    reg signed [15:0] p2;
    reg signed [15:0] p3;


    // ================================================================
    // Complex rotated value
    // ================================================================

    reg signed [7:0] rot_re;
    reg signed [7:0] rot_im;


    // ================================================================
    // Absolute-value function
    // ================================================================

    function [7:0] abs8;
        input signed [7:0] a;

        begin
            if (a < 0)
                abs8 = (~a) + 8'd1;
            else
                abs8 = a;
        end
    endfunction


    // ================================================================
    // Four-input maximum
    //
    // Used as the hardware-friendly sensitivity metric:
    //
    // S = max(|Xr|, |Xi|, |Yr|, |Yi|)
    // ================================================================

    function [7:0] max4;
        input [7:0] a;
        input [7:0] b;
        input [7:0] c;
        input [7:0] d;

        reg [7:0] m;

        begin
            m = a;

            if (b > m)
                m = b;

            if (c > m)
                m = c;

            if (d > m)
                m = d;

            max4 = m;
        end
    endfunction


    // ================================================================
    // Low-cost quantization-error estimator
    //
    // 4-bit:
    //   four LSBs are discarded
    //
    // 6-bit:
    //   two LSBs are discarded
    //
    // 8-bit:
    //   no LSBs are discarded
    //
    // This avoids building a second quantized arithmetic datapath.
    // ================================================================

    function [7:0] qerr;
        input [7:0] a;
        input [1:0] p;

        begin

            case (p)

                2'd0:
                    qerr = a & 8'h0F;

                2'd1:
                    qerr = a & 8'h03;

                default:
                    qerr = 8'h00;

            endcase

        end
    endfunction


    // ================================================================
    // Precision reduction
    //
    // 4-bit -> retain upper four bits
    // 6-bit -> retain upper six bits
    // 8-bit -> retain all bits
    // ================================================================

    function signed [7:0] quantize8;

        input signed [7:0] a;
        input [1:0] p;

        begin

            case (p)

                2'd0:
                    quantize8 = (a >>> 4) <<< 4;

                2'd1:
                    quantize8 = (a >>> 2) <<< 2;

                default:
                    quantize8 = a;

            endcase

        end

    endfunction


    // ================================================================
    // Sensitivity estimate
    // ================================================================

    wire [7:0] sensitivity_now;

    assign sensitivity_now =
        max4(
            abs8(xr),
            abs8(xi),
            abs8(yr),
            abs8(yi)
        );


    // ================================================================
    // 4-bit estimated error
    // ================================================================

    wire [7:0] error4_now;

    assign error4_now =
        max4(
            qerr(abs8(xr), 2'd0),
            qerr(abs8(xi), 2'd0),
            qerr(abs8(yr), 2'd0),
            qerr(abs8(yi), 2'd0)
        );


    // ================================================================
    // 6-bit estimated error
    // ================================================================

    wire [7:0] error6_now;

    assign error6_now =
        max4(
            qerr(abs8(xr), 2'd1),
            qerr(abs8(xi), 2'd1),
            qerr(abs8(yr), 2'd1),
            qerr(abs8(yi), 2'd1)
        );


    // ================================================================
    // Error-budget thresholds
    //
    // This is the hardware representation of E_max.
    // The larger budget code allows more quantization error.
    // ================================================================

    wire [7:0] error_limit_now;

    assign error_limit_now =
        (budget_reg == 2'd0) ? 8'd2  :
        (budget_reg == 2'd1) ? 8'd6  :
                               8'd12;


    // ================================================================
    // Sensitivity-aware error threshold
    //
    // High sensitivity means less error is tolerated.
    // ================================================================

    wire [7:0] effective_limit;

    assign effective_limit =
        (sensitivity_now >= 8'd64) ?
        (error_limit_now >> 1) :
        error_limit_now;


    // ================================================================
    // Progressive precision decision
    //
    // 4-bit first.
    //
    // If 4-bit error exceeds the allowable error:
    //       4 -> 6
    //
    // If 6-bit error still exceeds the allowable error:
    //       6 -> 8
    //
    // Otherwise remain at the lower precision.
    // ================================================================

    wire need_6bit;
    wire need_8bit;

    assign need_6bit =
        (error4_now > effective_limit);

    assign need_8bit =
        (error6_now > effective_limit);


    wire [1:0] selected_precision;

    assign selected_precision =
        need_6bit ?
            (need_8bit ? 2'd2 : 2'd1) :
            2'd0;


    // ================================================================
    // Internal twiddle LUT
    //
    // Q1.7 representation:
    //
    // index 0 : +1
    // index 1 : -j
    // index 2 : -1
    // index 3 : +j
    //
    // These are the compact trivial radix-2 twiddles used by the
    // physical butterfly demonstrator.
    // ================================================================

    reg signed [7:0] tw_re;
    reg signed [7:0] tw_im;

    always @* begin

        case (twiddle_index)

            2'd0: begin
                tw_re =  8'sd127;
                tw_im =  8'sd0;
            end

            2'd1: begin
                tw_re =  8'sd0;
                tw_im = -8'sd127;
            end

            2'd2: begin
                tw_re = -8'sd127;
                tw_im =  8'sd0;
            end

            default: begin
                tw_re =  8'sd0;
                tw_im =  8'sd127;
            end

        endcase

    end


    // ================================================================
    // Shared multiplier operand selection
    // ================================================================

    always @* begin

        case (state)

            S_M0: begin
                mult_a = quantize8(yr, precision);
                mult_b = tw_re;
            end

            S_M1: begin
                mult_a = quantize8(yi, precision);
                mult_b = tw_im;
            end

            S_M2: begin
                mult_a = quantize8(yi, precision);
                mult_b = tw_re;
            end

            S_M3: begin
                mult_a = quantize8(yr, precision);
                mult_b = tw_im;
            end

            default: begin
                mult_a = 8'sd0;
                mult_b = 8'sd0;
            end

        endcase

    end


    // ================================================================
    // Main sequential controller
    // ================================================================

    always @(posedge clk or negedge nreset) begin

        if (!nreset) begin

            state         <= S_IDLE;

            start_d       <= 1'b0;

            xr            <= 8'sd0;
            xi            <= 8'sd0;
            yr            <= 8'sd0;
            yi            <= 8'sd0;

            precision     <= 2'd0;
            budget_reg    <= 2'd0;

            twiddle_index <= 2'd0;

            escalated     <= 1'b0;

            p0            <= 16'sd0;
            p1            <= 16'sd0;
            p2            <= 16'sd0;
            p3            <= 16'sd0;

            rot_re        <= 8'sd0;
            rot_im        <= 8'sd0;

            out_reg       <= 8'd0;

            uio_out       <= 5'b0;

        end

        else begin

            start_d <= start_in;

            // VALID is asserted only during output cycles.
            uio_out[3] <= 1'b0;


            case (state)


                // ====================================================
                // IDLE / START
                // ====================================================

                S_IDLE: begin

                    uio_out[4]   <= 1'b0;
                    uio_out[2]   <= escalated;
                    uio_out[1:0] <= precision;

                    if (start_pulse) begin

                        xr <= $signed(ui_in);

                        budget_reg <= budget_in;

                        uio_out[4] <= 1'b1;

                        state <= S_XI;

                    end

                end


                // ====================================================
                // Capture Xi
                // ====================================================

                S_XI: begin

                    xi <= $signed(ui_in);

                    state <= S_YR;

                end


                // ====================================================
                // Capture Yr
                // ====================================================

                S_YR: begin

                    yr <= $signed(ui_in);

                    state <= S_YI;

                end


                // ====================================================
                // Capture Yi
                // ====================================================

                S_YI: begin

                    yi <= $signed(ui_in);

                    state <= S_DEC;

                end


                // ====================================================
                // Precision-selection state
                //
                // Important: all four operands are now registered.
                // Therefore sensitivity/error estimation uses the
                // current butterfly rather than stale values.
                // ====================================================

                S_DEC: begin

                    precision <= selected_precision;

                    escalated <=
                        (selected_precision == 2'd2);

                    state <= S_M0;

                end


                // ====================================================
                // Shared multiplication cycle 0
                //
                // p0 = Yr * Wr
                // ====================================================

                S_M0: begin

                    p0 <= mult_a * mult_b;

                    state <= S_M1;

                end


                // ====================================================
                // Shared multiplication cycle 1
                //
                // p1 = Yi * Wi
                // ====================================================

                S_M1: begin

                    p1 <= mult_a * mult_b;

                    state <= S_M2;

                end


                // ====================================================
                // Shared multiplication cycle 2
                //
                // p2 = Yi * Wr
                // ====================================================

                S_M2: begin

                    p2 <= mult_a * mult_b;

                    state <= S_M3;

                end


                // ====================================================
                // Shared multiplication cycle 3
                //
                // p3 = Yr * Wi
                // ====================================================

                S_M3: begin

                    p3 <= mult_a * mult_b;

                    state <= S_CALC;

                end


                // ====================================================
                // Complex multiplication
                //
                // Re(YW) = p0 - p1
                // Im(YW) = p3 + p2
                //
                // Q1.7 scaling -> arithmetic right shift by 7.
                // ====================================================

                S_CALC: begin

                    rot_re <= $signed((p0 - p1) >>> 7);

                    rot_im <= $signed((p3 + p2) >>> 7);

                    state <= S_O0;

                end


                // ====================================================
                // Radix-2 butterfly output 0 real
                //
                // Z0 = X + YW
                // ====================================================

                S_O0: begin

                    out_reg <=
                        $signed(xr) +
                        $signed(rot_re);

                    uio_out[4] <= 1'b0;
                    uio_out[3] <= 1'b1;

                    state <= S_O1;

                end


                // ====================================================
                // Radix-2 butterfly output 0 imaginary
                // ====================================================

                S_O1: begin

                    out_reg <=
                        $signed(xi) +
                        $signed(rot_im);

                    uio_out[3] <= 1'b1;

                    state <= S_O2;

                end


                // ====================================================
                // Radix-2 butterfly output 1 real
                //
                // Z1 = X - YW
                // ====================================================

                S_O2: begin

                    out_reg <=
                        $signed(xr) -
                        $signed(rot_re);

                    uio_out[3] <= 1'b1;

                    state <= S_O3;

                end


                // ====================================================
                // Radix-2 butterfly output 1 imaginary
                // ====================================================

                S_O3: begin

                    out_reg <=
                        $signed(xi) -
                        $signed(rot_im);

                    uio_out[3] <= 1'b1;

                    uio_out[2] <= escalated;

                    uio_out[1:0] <= precision;

                    // Rotate to the next internal twiddle.
                    twiddle_index <=
                        twiddle_index + 2'd1;

                    state <= S_IDLE;

                end


                default: begin

                    state <= S_IDLE;

                end

            endcase

        end

    end

endmodule
   

                    

`default_nettype wire
