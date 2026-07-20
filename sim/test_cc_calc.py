"""Bring-up scaffold for the cc_calc centroid/area accumulator.

Right now this is a smoke harness that spins the clock and reset; once the
cc_calc interface stabilizes we can feed representative centroid sums and
assert on the outputs. Keeping the runner in place lets CI keep building the
RTL even while the stimulus is still TODO.
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

@cocotb.test()
async def test_calc(dut):
    """Smoke reset/clock bring-up for cc_calc (stimulus TODO)."""
    # TODO: drive representative blob accumulations once the DUT interface is final.

    dut._log.info("Starting cc_calc test...")

    # Start the clock
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

def test_cc_calc_runner():
    """Run the roi tester."""
    hdl_toplevel_lang = os.getenv("HDL_TOPLEVEL_LANG", "verilog")
    sim = os.getenv("SIM", "icarus")
    proj_path = Path(__file__).resolve().parent.parent
    sys.path.append(str(proj_path / "sim" / "model"))
    # These are the Verilog source files to be compiled
    sources = [
        proj_path / "hdl" / "ccl_calc.sv",
        proj_path / "hdl" / "divider.sv",
    ]
    build_test_args = ["-Wall"]
    # These are the parameters we are passing to the DUT
    parameters = {}
    sys.path.append(str(proj_path / "sim"))
    hdl_toplevel = "cc_calculations"
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
    test_cc_calc_runner()




