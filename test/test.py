# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly


def signed_to_byte(value):
    """Convert a signed integer to an 8-bit two's-complement value."""
    return value & 0xFF


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start")

    # Clock: 10 us period
    clock = Clock(dut.clk, 10, unit="us")
    cocotb.start_soon(clock.start())

    # ============================================================
    # RESET
    # ============================================================

    dut._log.info("Reset")

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0

    await ClockCycles(dut.clk, 10)

    dut.rst_n.value = 1

    await ClockCycles(dut.clk, 2)

    # ============================================================
    # TEST VALUES
    #
    # X = (8, -4)
    # Y = (8, -4)
    # budget = 2
    #
    # Expected from your simulation log:
    # precision = 0
    # escalation = 0
    # Z0 = (8, -20)
    # Z1 = (8, 12)
    # ============================================================

    x_re = 8
    x_im = -4
    y_re = 8
    y_im = -4

    budget = 2

    expected_precision = 0
    expected_escalation = 0

    expected_outputs = [
        signed_to_byte(8),     # Z0_re
        signed_to_byte(-20),   # Z0_im
        signed_to_byte(8),     # Z1_re
        signed_to_byte(12)     # Z1_im
    ]

    dut._log.info(
        f"Input: X=({x_re},{x_im}) "
        f"Y=({y_re},{y_im}) "
        f"budget={budget}"
    )

    # ============================================================
    # SET ERROR BUDGET
    #
    # uio_in[7:6] = budget
    # ============================================================

    base_uio = budget << 6
    dut.uio_in.value = base_uio

    await RisingEdge(dut.clk)

    # ============================================================
    # PULSE START
    #
    # START = uio_in[5]
    # ============================================================

    dut._log.info("Pulse START")

    dut.uio_in.value = base_uio | (1 << 5)

    await RisingEdge(dut.clk)

    dut.uio_in.value = base_uio

    # ============================================================
    # SEND FOUR INPUT BYTES
    #
    # byte 0 = X_re
    # byte 1 = X_im
    # byte 2 = Y_re
    # byte 3 = Y_im
    # ============================================================

    input_bytes = [
        signed_to_byte(x_re),
        signed_to_byte(x_im),
        signed_to_byte(y_re),
        signed_to_byte(y_im)
    ]

    for value in input_bytes:
        dut.ui_in.value = value
        await RisingEdge(dut.clk)

    # Clear input after sending all four bytes
    dut.ui_in.value = 0

    # ============================================================
    # WAIT FOR VALID
    #
    # uio_out[3] = VALID
    # ============================================================

    dut._log.info("Waiting for VALID")

    valid = 0

    for _ in range(100):
        await RisingEdge(dut.clk)
        
        valid = (int(dut.uio_out.value) >> 3) & 0x1

        if valid:
            break

    assert valid == 1, "Timeout: VALID was never asserted"

    # ============================================================
    # CHECK STATUS BITS
    #
    # uio_out[2]   = escalation
    # uio_out[1:0] = precision
    # ============================================================
    
    status = int(dut.uio_out.value)

    precision = status & 0b11
    escalation = (status >> 2) & 0b1

    dut._log.info(
        f"Status: precision={precision}, "
        f"escalation={escalation}"
    )

    assert precision == expected_precision, (
        f"Expected precision {expected_precision}, "
        f"got {precision}"
    )

    assert escalation == expected_escalation, (
        f"Expected escalation {expected_escalation}, "
        f"got {escalation}"
    )

    # ============================================================
    # READ FOUR SUCCESSIVE OUTPUT BYTES
    #
    # byte 0 = Z0_re
    # byte 1 = Z0_im
    # byte 2 = Z1_re
    # byte 3 = Z1_im
    # ============================================================

    actual_outputs = []

    # Read the first output immediately when VALID is detected
    actual_outputs.append(int(dut.uo_out.value))

    # Read the remaining three outputs
    for _ in range(3):
        await RisingEdge(dut.clk)
        actual_outputs.append(int(dut.uo_out.value))

    # ============================================================
    # CHECK OUTPUTS
    # ============================================================

    names = ["Z0_re", "Z0_im", "Z1_re", "Z1_im"]

    for name, actual, expected in zip(
        names,
        actual_outputs,
        expected_outputs
    ):
        dut._log.info(
            f"{name}: expected=0x{expected:02X}, "
            f"actual=0x{actual:02X}"
        )

        assert actual == expected, (
            f"{name} failed: "
            f"expected {expected}, got {actual}"
        )

    dut._log.info("FFT TEST PASSED")
