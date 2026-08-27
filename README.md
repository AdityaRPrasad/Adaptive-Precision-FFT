![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# An Error-Budget-Driven Adaptive-Precision Architecture for Efficient FFT Processing

- [Read the documentation for project](docs/info.md)


## What is this?

# Adaptive-Precision FFT Butterfly

This project implements a hardware-efficient adaptive-precision radix-2 FFT butterfly processing element. The design dynamically selects between 4-bit, 6-bit, and 8-bit arithmetic based on an input-dependent sensitivity estimate and an estimated quantization-error constraint.

Instead of always performing the butterfly operation at the maximum precision, the design attempts to use the lowest precision that satisfies the configured error budget. This provides a hardware-oriented approach to reducing arithmetic cost while maintaining output quality within the selected error constraint.

The design accepts two complex input values through an 8-bit multiplexed interface and produces two complex butterfly outputs through an 8-bit multiplexed output interface. A small finite-state machine controls operand capture, adaptive precision selection, time-multiplexed arithmetic, result generation, and output sequencing.

The design is intended as a reusable FFT processing element rather than a complete N-point FFT engine. Multiple such butterfly processing elements could be incorporated into a larger FFT architecture.

Research Contribution : The primary contribution of this project is an error-budget-aware adaptive-precision FFT butterfly architecture that selects the arithmetic precision dynamically for each computation. Conventional fixed-precision FFT hardware uses the same arithmetic width for every operation, including cases where the input values do not require maximum precision. In this design, the controller evaluates hardware-friendly indicators derived from the current input operands and an estimated quantization-error measure. These indicators are compared against a programmable error budget to determine the minimum acceptable precision.

## Enable GitHub actions to build the results page

- [Enabling GitHub Pages](https://tinytapeout.com/faq/#my-github-action-is-failing-on-the-pages-part)

## Design summary
The design implements a complex radix-2 FFT butterfly processing element with adaptive arithmetic precision.

Input data

Two complex input values are processed:

X=X
re
	​
+jX
im
	​
Y=Y
re
	​
+jY
im
	​
The four signed 8-bit input components are supplied sequentially through the ui_in[7:0] interface:

X_re
X_im
Y_re
Y_im
Adaptive precision

The controller automatically selects one of three arithmetic precision modes:

Precision encoding	Arithmetic precision
00	4-bit
01	6-bit
10	8-bit

The selected precision is determined from:

an input-dependent sensitivity estimate, and
an estimated quantization-error measure.

The estimated error is compared with the programmable 2-bit error budget. The controller attempts to use the lowest precision first and escalates when necessary.

Arithmetic architecture

The datapath uses time-multiplexed arithmetic. Multiplication hardware is reused across multiple clock cycles under control of a finite-state machine. This reduces hardware duplication compared with a fully parallel butterfly implementation.

The FSM performs the following major functions:

Capture the multiplexed input operands.
Evaluate the precision-selection criteria.
Select the appropriate arithmetic precision.
Perform the required time-multiplexed arithmetic operations.
Generate the butterfly results.
Sequentially present the output bytes.
Output data

The butterfly produces two complex outputs:

Z
0
	​
=Z0
re
	​
+jZ0
im
	​
Z
1
	​
=Z1
re
	​
+jZ1
im
	​
The four signed 8-bit output components are supplied sequentially through uo_out[7:0]:

Z0_re
Z0_im
Z1_re
Z1_im
Control and status interface

The bidirectional I/O pins are allocated as follows:

Pin(s)	Function
uio[7:6]	2-bit error-budget input
uio[5]	START input
uio[4]	BUSY status output
uio[3]	VALID status output
uio[2]	Precision-escalation status output
uio[1:0]	Selected-precision status output

## How it works

The design begins in an idle state, waiting for the START signal on uio[5].

When START is asserted, the first input byte, X_re, is captured. The remaining input values are then supplied sequentially through the shared 8-bit input interface:

X_re
X_im
Y_re
Y_im

The 2-bit error budget is supplied through uio[7:6].

After all input operands have been captured, the controller evaluates the adaptive precision-selection logic. The decision is based on a hardware-friendly sensitivity estimate derived from the input operands and an estimated quantization-error measure.

The controller first attempts to use 4-bit arithmetic. If the estimated error satisfies the configured error budget, 4-bit precision is selected. Otherwise, the controller escalates to 6-bit precision. If the error constraint is still not satisfied, the controller selects 8-bit precision.

The selected precision is reported through uio[1:0] using the following encoding:

00 = 4-bit
01 = 6-bit
10 = 8-bit

The uio[2] signal provides a precision-escalation status indication, while uio[4] indicates that the processing element is busy.

The butterfly arithmetic is performed using a time-multiplexed datapath. Arithmetic resources, including the multiplier, are reused over multiple clock cycles. The FSM sequences these operations and stores the intermediate results required to calculate the final complex butterfly outputs.

Once processing is complete, VALID is asserted on uio[3]. The four output bytes are then presented sequentially on uo_out[7:0] in the following order:

Z0_re
Z0_im
Z1_re
Z1_im

This architecture allows the processing element to adapt its arithmetic precision to the current input conditions while attempting to satisfy the selected error budget. By combining adaptive precision with time-multiplexed arithmetic reuse, the design targets a compact hardware implementation suitable for integration into larger FFT systems.
