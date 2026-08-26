//`timescale 1ns/1ps
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
    // uio_in[5]   : START input pulse
    // uio_in[7:6] : error-budget selection
    //
    // uio_out[4]   : BUSY
    // uio_out[3]   : VALID
    // uio_out[2]   : escalation flag
    // uio_out[1:0] : selected precision
    // ================================================================

    reg [4:0] uio_out_reg;
    reg [7:0] out_reg;

    assign uo_out = out_reg;
    assign uio_out = {3'b000, uio_out_reg};
    assign uio_oe  = 8'b0001_1111;

    wire       start_in  = uio_in[5];
    wire [1:0] budget_in = uio_in[7:6];

    reg  start_d;
    wire start_pulse = start_in & ~start_d;

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

    reg signed [7:0] xr, xi, yr, yi;

    reg [1:0] precision;
    reg [1:0] budget_reg;
    reg [1:0] twiddle_index;
    reg       escalated;

    reg signed [7:0]  mult_a, mult_b;
    reg signed [15:0] p0, p1, p2, p3;

    reg signed [7:0] rot_re, rot_im;

    wire signed [15:0] rot_re_full;
    wire signed [15:0] rot_im_full;

    assign rot_re_full = (p0 - p1) >>> 7;
    assign rot_im_full = (p3 + p2) >>> 7;

    function [7:0] abs8;
        input signed [7:0] a;
        begin
            if (a < 0)
                abs8 = (~a) + 8'd1;
            else
                abs8 = a;
        end
    endfunction

    function [7:0] max4;
        input [7:0] a, b, c, d;
        reg [7:0] m;
        begin
            m = a;
            if (b > m) m = b;
            if (c > m) m = c;
            if (d > m) m = d;
            max4 = m;
        end
    endfunction

    function [7:0] qerr;
        input [7:0] a;
        input [1:0] p;
        begin
            case (p)
                2'd0:   qerr = a & 8'h0F;
                2'd1:   qerr = a & 8'h03;
                default: qerr = 8'h00;
            endcase
        end
    endfunction

    function signed [7:0] quantize8;
        input signed [7:0] a;
        input [1:0] p;
        begin
            case (p)
                2'd0:   quantize8 = (a >>> 4) <<< 4;
                2'd1:   quantize8 = (a >>> 2) <<< 2;
                default: quantize8 = a;
            endcase
        end
    endfunction

    // ================================================================
    // Precision-selection logic
    //
    // These signals are evaluated from the four registered operands.
    // S_DEC is entered only after Xr, Xi, Yr and Yi have been captured.
    // ================================================================

    wire [7:0] sensitivity_now =
        max4(abs8(xr), abs8(xi), abs8(yr), abs8(yi));

    wire [7:0] error4_now =
        max4(
            qerr(abs8(xr), 2'd0),
            qerr(abs8(xi), 2'd0),
            qerr(abs8(yr), 2'd0),
            qerr(abs8(yi), 2'd0)
        );

    wire [7:0] error6_now =
        max4(
            qerr(abs8(xr), 2'd1),
            qerr(abs8(xi), 2'd1),
            qerr(abs8(yr), 2'd1),
            qerr(abs8(yi), 2'd1)
        );

    wire [7:0] error_limit_now =
        (budget_reg == 2'd0) ? 8'd2  :
        (budget_reg == 2'd1) ? 8'd6  :
                               8'd12;

    wire [7:0] effective_limit =
        (sensitivity_now >= 8'd64) ?
        (error_limit_now >> 1) :
        error_limit_now;

    wire need_6bit = (error4_now > effective_limit);
    wire need_8bit = (error6_now > effective_limit);

    wire [1:0] selected_precision =
        need_6bit ? (need_8bit ? 2'd2 : 2'd1) : 2'd0;

    // ================================================================
    // Twiddle-factor LUT: +1, -j, -1, +j
    // ================================================================

    reg signed [7:0] tw_re, tw_im;

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
    // Main FSM
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
            uio_out_reg   <= 5'b0;

        end else begin
            start_d <= start_in;

            // VALID is asserted only during the four output states.
            uio_out_reg[3] <= 1'b0;

            case (state)

                // ----------------------------------------------------
                // IDLE / START
                // ----------------------------------------------------
                S_IDLE: begin
                    uio_out_reg[4] <= 1'b0;

                    if (start_pulse) begin
                        // Capture X_re together with START.
                        xr <= $signed(ui_in);
                        budget_reg <= budget_in;

                        uio_out_reg[4] <= 1'b1;
                        state <= S_XI;
                    end
                end

                // ----------------------------------------------------
                // Capture remaining three input bytes
                // ----------------------------------------------------
                S_XI: begin
                    xi    <= $signed(ui_in);
                    state <= S_YR;
                end

                S_YR: begin
                    yr    <= $signed(ui_in);
                    state <= S_YI;
                end

                S_YI: begin
                    yi    <= $signed(ui_in);
                    state <= S_DEC;
                end

                // ----------------------------------------------------
                // Select precision after all operands are registered.
                //
                // IMPORTANT FIX:
                // Update both the internal precision register AND the
                // externally visible status bits in this same state.
                // This prevents uio_out[1:0] from showing an older
                // precision value when the testbench observes VALID.
                // ----------------------------------------------------
                S_DEC: begin
                    precision <= selected_precision;
                    escalated <= (selected_precision == 2'd2);

                    uio_out_reg[2]   <= (selected_precision == 2'd2);
                    uio_out_reg[1:0] <= selected_precision;

                    state <= S_M0;
                end

                // ----------------------------------------------------
                // Four real multiplications
                // ----------------------------------------------------
                S_M0: begin
                    p0    <= mult_a * mult_b;
                    state <= S_M1;
                end

                S_M1: begin
                    p1    <= mult_a * mult_b;
                    state <= S_M2;
                end

                S_M2: begin
                    p2    <= mult_a * mult_b;
                    state <= S_M3;
                end

                S_M3: begin
                    p3    <= mult_a * mult_b;
                    state <= S_CALC;
                end

                // ----------------------------------------------------
                // Complex rotation
                // ----------------------------------------------------
                S_CALC: begin
                    rot_re <= rot_re_full[7:0];
                    rot_im <= rot_im_full[7:0];
                    state  <= S_O0;
                end

                // ----------------------------------------------------
                // Four output bytes
                //
                // Status bits are explicitly held consistent throughout
                // the output sequence.
                // ----------------------------------------------------
                S_O0: begin
                    out_reg             <= $signed(xr) + $signed(rot_re);
                    uio_out_reg[4]      <= 1'b0;
                    uio_out_reg[3]      <= 1'b1;
                    uio_out_reg[2]      <= escalated;
                    state               <= S_O1;
                end

                S_O1: begin
                    out_reg             <= $signed(xi) + $signed(rot_im);
                    uio_out_reg[3]      <= 1'b1;
                    uio_out_reg[2]      <= escalated;
                    state               <= S_O2;
                end

                S_O2: begin
                    out_reg             <= $signed(xr) - $signed(rot_re);
                    uio_out_reg[3]      <= 1'b1;
                    uio_out_reg[2]      <= escalated;
                    state               <= S_O3;
                end

                S_O3: begin
                    out_reg             <= $signed(xi) - $signed(rot_im);
                    uio_out_reg[3]      <= 1'b1;
                    uio_out_reg[2]      <= escalated;

                    twiddle_index <= twiddle_index + 2'd1;
                    state         <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end

            endcase
        end
    end

endmodule

`default_nettype wire
