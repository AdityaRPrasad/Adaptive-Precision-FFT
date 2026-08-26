//`timescale 1ns/1ps
`default_nettype none

module tt_um_adityarprasad_fft (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,

    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,

    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    wire _unused_uio = &{1'b0, uio_in[4:0]};
    
    adaptive_fft_butterfly dut (
        .clk    (clk),
        .nreset (rst_n),

        .ui_in  (ui_in),
        .uo_out (uo_out),

        .uio_in (uio_in),
        .uio_out(uio_out),
        .uio_oe (uio_oe)
    );

endmodule

`default_nettype wire
