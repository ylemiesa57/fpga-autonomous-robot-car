"""Throughput smoke test for region_of_interest cropping logic.

The test streams a full 1280x720 ramp through the ROI module using fixed
MIN/MAX bounds defined below. It currently focuses on driving the interface
with realistic coordinates and logging progress rather than strict content
checks; it is meant as a bring-up harness for future assertions.
"""

import cocotb
import os
import sys
import random
from pathlib import Path
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, First
from cocotb.runner import get_runner
# The test file name, used for module discovery
test_file = os.path.basename(__file__).replace(".py", "")

# Parameters for the test simulation
HRES_TEST = 1280
VRES_TEST = 720
MIN_H_TEST = 296
MAX_H_TEST = 1004
MIN_V_TEST = 574
MAX_V_TEST = 720

@cocotb.test()
async def test_roi(dut):
    """Test for region_of_interest module"""
    dut._log.info("Starting region_of_interest test...")

    # Start the clock
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    # Reset
    dut.rst.value = 1
    dut.h_count.value = 0
    dut.v_count.value = 0
    dut.valid.value = 0
    dut.pixel_data.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 2)

    dut._log.info("Finished first stage of reset. Beginning passing in of pixel values")

    for v in range(VRES_TEST):
        for h in range(HRES_TEST):
            # Send in a pixel for each pixel in a standard 1280 x 720
            dut.valid.value = 1
            dut.h_count.value = h
            dut.v_count.value = v
            pixel_value = h
            dut.pixel_data.value = pixel_value
            await ClockCycles(dut.clk, 1)
            dut.valid.value = 0
            await ClockCycles(dut.clk, 1)
    
    dut._log.info("Passed in all pixels")
    await ClockCycles(dut.clk, 5)

def test_roi_runner():
    """Run the roi tester."""
    hdl_toplevel_lang = os.getenv("HDL_TOPLEVEL_LANG", "verilog")
    sim = os.getenv("SIM", "icarus")
    proj_path = Path(__file__).resolve().parent.parent
    sys.path.append(str(proj_path / "sim" / "model"))
    # These are the Verilog source files to be compiled
    sources = [
        proj_path / "hdl" / "roi.sv",
    ]
    build_test_args = ["-Wall"]
    # These are the parameters we are passing to the DUT
    parameters = {'MIN_H': MIN_H_TEST, 'MAX_H': MAX_H_TEST, 'MIN_V': MIN_V_TEST, 'MAX_V': MAX_V_TEST}
    sys.path.append(str(proj_path / "sim"))
    hdl_toplevel = "region_of_interest"
    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel=hdl_toplevel,
        always=True,
        build_args=build_test_args,
        parameters=parameters,
        timescale = ('1ns','1ps'),
        waves=True
    )
    run_test_args = []
    runner.test(
        hdl_toplevel=hdl_toplevel,
        test_module=test_file,
        test_args=run_test_args,
        waves=True
    )

if __name__ == "__main__":
    test_roi_runner()
    
