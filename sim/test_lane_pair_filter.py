"""Lane pair filter smoke test: picks two best blobs per side and finds midpoints.

We drive four candidate blobs (x/y/area) into the module, wait for valid pulses,
and confirm the left/right selection logic filters out tiny blobs while keeping
the strongest pair. The runner compiles only lane_pair_filter for quick CI."""

import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotb.runner import get_runner


async def reset_dut(dut):
    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


def drive_blobs(dut, blobs):
    """blobs: list of dicts with keys valid,x,y,pixels"""
    validity_mask = 0
    for idx in range(4):
        blob = blobs[idx]
        dut.cc_x[idx].value = blob.get("x", 0)
        dut.cc_y[idx].value = blob.get("y", 0)
        dut.cc_pixels[idx].value = blob.get("pixels", 0)
        if blob.get("valid", False):
            validity_mask |= (1 << idx)
    dut.cc_valid.value = validity_mask


@cocotb.test()
async def test_basic_pairing(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)

    blobs = [
        {"valid": True, "x": 20, "y": 10, "pixels": 120},
        {"valid": True, "x": 140, "y": 12, "pixels": 160},
        {"valid": True, "x": 50, "y": 18, "pixels": 20},   # smaller, still processed
        {"valid": False},
    ]
    drive_blobs(dut, blobs)

    got_valid = False
    for _ in range(25):
        await RisingEdge(dut.clk)
        if dut.valid_midpoints.value:
            got_valid = True
            break

    dut._log.info(
        "basic: valid=%s left=%d right=%d",
        int(dut.valid_midpoints.value),
        int(dut.left_midpoint.value),
        int(dut.right_midpoint.value),
    )

    assert got_valid, "Expected a valid lane pair"
    assert int(dut.left_midpoint.value) == 20
    assert int(dut.right_midpoint.value) == 140


def test_lane_pair_filter_runner():
    proj_path = Path(__file__).resolve().parent.parent
    sim_build_dir = proj_path / "sim_build_lane_pair"
    sim = os.getenv("SIM", "icarus")

    sources = [
        proj_path / "hdl" / "lane_pair_filter.sv",
    ]

    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel="lane_pair_filter",
        build_dir=str(sim_build_dir),
        timescale=("1ns", "1ps"),
        always=True,
        waves=True,
    )
    runner.test(
        hdl_toplevel="lane_pair_filter",
        test_module="test_lane_pair_filter",
        build_dir=str(sim_build_dir),
        waves=True,
    )


if __name__ == "__main__":
    test_lane_pair_filter_runner()
