"""Unit test for ccl_calc: validates centroid math and per-label validity.

We stream a handcrafted set of labeled pixels, pulse cc_pixel_last to start the
divider stage, and then watch for cc_valid_out bits to assert with the expected
h/v averages. Labels with too few pixels should never assert valid. The runner
compiles both ccl_calc and its divider helper into a dedicated sim_build dir.
"""

import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb.runner import get_runner


def build_test_frame():
    """Return a list of (label, h, v) tuples for a single frame."""
    frame = []
    # Label 1: six pixels around (10, 20)
    for dx in range(6):
        frame.append((1, 10 + dx, 20 + dx // 2))
    # Label 2: only three pixels -> should stay invalid
    for dx in range(3):
        frame.append((2, 40 + dx, 60))
    # Label 3: eight pixels around (100, 70)
    for dx in range(8):
        frame.append((3, 100 + dx, 70 + (dx % 2)))
    # Label 4: no pixels -> stays invalid
    return frame


async def drive_frame(dut, pixels):
    dut.cc_pixel_valid.value = 0
    dut.cc_pixel_last.value = 0
    await RisingEdge(dut.clk)

    for label, h, v in pixels:
        dut.cc_pixel_valid.value = 1
        dut.cc_pixel_label.value = label
        dut.cc_pixel_h.value = h
        dut.cc_pixel_v.value = v
        dut.cc_pixel_last.value = 0
        await RisingEdge(dut.clk)

    # Pulse last to kick off dividers
    dut.cc_pixel_valid.value = 0
    dut.cc_pixel_label.value = 0
    dut.cc_pixel_h.value = 0
    dut.cc_pixel_v.value = 0
    dut.cc_pixel_last.value = 1
    await RisingEdge(dut.clk)
    dut.cc_pixel_last.value = 0


@cocotb.test()
async def test_cc_calculations_basic(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    frame = build_test_frame()
    await drive_frame(dut, frame)
    await RisingEdge(dut.clk)
    dut._log.info(f"div_in_valid after frame: {int(dut.div_in_valid.value):04b}")

    # Expected averages
    label_to_idx = {1: 0, 2: 1, 3: 2, 4: 3}
    expected = {
        0: {
            "valid": True,
            "h": sum(10 + dx for dx in range(6)) // 6,
            "v": sum(20 + dx // 2 for dx in range(6)) // 6,
        },
        1: {"valid": False},
        2: {
            "valid": True,
            "h": sum(100 + dx for dx in range(8)) // 8,
            "v": sum(70 + (dx % 2) for dx in range(8)) // 8,
        },
        3: {"valid": False},
    }

    seen = set()
    timeout_cycles = 20000
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        flags = int(dut.cc_valid_out.value)
        for idx in range(4):
            if idx in seen:
                continue
            if flags & (1 << idx):
                exp = expected[idx]
                assert exp["valid"], f"Unexpected valid for label {idx+1}"
                h_avg = int(dut.h_avg_pos[idx].value)
                v_avg = int(dut.v_avg_pos[idx].value)
                assert h_avg == exp["h"], f"h_avg mismatch for label {idx+1}: got {h_avg}, exp {exp['h']}"
                assert v_avg == exp["v"], f"v_avg mismatch for label {idx+1}: got {v_avg}, exp {exp['v']}"
                seen.add(idx)

    # Labels that didn't meet pixel threshold should remain invalid
    final_flags = int(dut.cc_valid_out.value)
    dut._log.info(f"Final cc_valid_out flags: {final_flags:04b}")
    assert 0 in seen and 2 in seen, "Valid blobs not produced"
    assert final_flags & (1 << 1) == 0, "Label 2 should be invalid"
    assert final_flags & (1 << 3) == 0, "Label 4 should be invalid"


def test_ccl_calc_runner():
    hdl_toplevel_lang = os.getenv("HDL_TOPLEVEL_LANG", "verilog")
    sim = os.getenv("SIM", "icarus")
    proj_path = Path(__file__).resolve().parent.parent
    sim_build_dir = proj_path / "sim_build_ccl_calc"

    sources = [
        proj_path / "hdl" / "ccl_calc.sv",
        proj_path / "hdl" / "divider.sv",
    ]

    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel="cc_calculations",
        build_dir=str(sim_build_dir),
        timescale=("1ns", "1ps"),
        always=True,
        waves=True,
    )
    runner.test(
        hdl_toplevel="cc_calculations",
        test_module="test_ccl_calc",
        build_dir=str(sim_build_dir),
        waves=True,
    )


if __name__ == "__main__":
    test_ccl_calc_runner()

