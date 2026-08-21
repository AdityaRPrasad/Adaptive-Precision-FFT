# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadWrite, ReadOnly


def signed_to_byte(value):
    """Convert a signed integer to an 8-bit two's-complement value."""
    return value & 0xFF


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start")

    # ============================================================
    # CLOCK
    # ============================================================

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
    # TEST 1 INPUT VALUES
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
    # PREPARE UIO INPUT
    #
    # uio_in[7:6] = error budget
    # uio_in[5]   = START
    # ============================================================

    base_uio = budget << 6

    # ============================================================
    # SEND X_re AND ASSERT START
    #
    # The DUT samples X_re when START is asserted in S_IDLE.
    # ============================================================

    dut._log.info("Pulse START")

    dut.ui_in.value = signed_to_byte(x_re)
    dut.uio_in.value = base_uio | (1 << 5)

    await RisingEdge(dut.clk)

    # ============================================================
    # SEND X_im AND CLEAR START
    # ============================================================

    dut.ui_in.value = signed_to_byte(x_im)
    dut.uio_in.value = base_uio

    await RisingEdge(dut.clk)

    # ============================================================
    # SEND Y_re
    # ============================================================

    dut.ui_in.value = signed_to_byte(y_re)

    await RisingEdge(dut.clk)

    # ============================================================
    # SEND Y_im
    # ============================================================

    dut.ui_in.value = signed_to_byte(y_im)

    await RisingEdge(dut.clk)

    # Clear input after all operands are captured.
    dut.ui_in.value = 0
    dut.uio_in.value = base_uio

    # ============================================================
    # WAIT FOR VALID
    #
    # uio_out[3] = VALID
    # ============================================================

    dut._log.info("Waiting for VALID")

    valid = 0

    for _ in range(100):
        await RisingEdge(dut.clk)

        status = int(dut.uio_out.value)
        valid = (status >> 3) & 0x1

        if valid:
            break

    assert valid == 1, "Timeout: VALID was never asserted"

    # ============================================================
    # CHECK STATUS
    #
    # uio_out[1:0] = precision
    # uio_out[2]   = escalation
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
    # READ OUTPUTS
    #
    # IMPORTANT:
    # VALID corresponds to the first output byte being available.
    #
    # Read byte 0 immediately.
    # Then advance one clock for each remaining output byte.
    # ============================================================

    actual_outputs = []

    # Byte 0 = Z0_re
    await ReadOnly()
    actual_outputs.append(int(dut.uo_out.value))

    for _ in range(3):
        await RisingEdge(dut.clk)
        await ReadOnly()
        actual_outputs.append(int(dut.uo_out.value))

    # ============================================================
    # CHECK OUTPUTS
    # ============================================================

    names = [
        "Z0_re",
        "Z0_im",
        "Z1_re",
        "Z1_im"
    ]

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
            f"expected 0x{expected:02X}, "
            f"got 0x{actual:02X}"
        )

    dut._log.info("FFT TEST PASSED")
