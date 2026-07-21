"""End-to-end BEV remap regression for the warp pipeline.

This test streams a synthetic ROI BRAM pattern through the BEV warp logic,
exercises two LUTs (identity and flipped), and sprinkles random back-pressure
to make sure AXI-Stream handshakes are robust. Environment variables such as
BEV_HRES/BEV_VRES, STALL_PROB, and CASES let CI scale coverage up or down
without changing the test code.
"""
import os
import sys
import random
from pathlib import Path
from typing import Callable, Iterable, Tuple
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotb.runner import get_runner

# Default regression sweep (small / mid / full design sizes)
DEFAULT_CASES: Iterable[Tuple[int, int]] = [
    (8, 4),
    (17, 9),
    (177, 72),
]


class MemoryModel:
    """Tiny BRAM model with configurable read latency."""

    def __init__(self, size: int, pattern_func: Callable[[int], int], latency: int = 2):
        self.mem = [pattern_func(i) for i in range(size)]
        self.pipeline = [0 for _ in range(latency)]

    def read(self, addr: int) -> int:
        data = self.mem[addr] if 0 <= addr < len(self.mem) else 0
        self.pipeline.append(data)
        return self.pipeline.pop(0)


def make_roi_pattern(width: int, height: int) -> Callable[[int], int]:
    """Return a deterministic ROI pattern for verification."""

    def pattern(idx: int) -> int:
        y = idx // width
        x = idx % width
        # Checkerboard-ish but denser than the old 20x20 blocks.
        return ((x // 3) ^ (y // 2)) & 1

    return pattern


def lut_identity(width: int, height: int) -> Callable[[int], int]:
    return lambda idx: idx


def lut_flip(width: int, height: int) -> Callable[[int], int]:
    """Horizontal + vertical flip to exercise non-identity LUT paths."""

    def mapper(idx: int) -> int:
        y = idx // width
        x = idx % width
        x_f = width - 1 - x
        y_f = height - 1 - y
        return y_f * width + x_f

    return mapper


async def run_one_frame(
    dut,
    width: int,
    height: int,
    lut_map: Callable[[int], int],
    roi_pattern: Callable[[int], int],
    stall_prob: float,
    warmup_cycles: int = 6,
    addr_data_offset: int = 7,
    skip_outputs: int = 6,
) -> None:
    """Drive one full frame through the DUT and check every pixel."""

    total_pixels = width * height
    lut_model = MemoryModel(total_pixels, lut_map, latency=2)
    # ROI BRAM is typically registered; use a slightly longer latency to align with h/v pipelines.
    roi_model = MemoryModel(total_pixels, roi_pattern, latency=4)

    # Track the sequence of ROI data seen by the DUT (for end-of-frame checking).
    roi_pix_q = deque(maxlen=256)
    out_pix = []

    # Start a frame
    dut.start.value = 1
    await RisingEdge(dut.clk_pixel)
    dut.start.value = 0
    
    pixel_count = 0
    max_cycles = total_pixels * 6  # generous for stalls

    for cycle in range(max_cycles):
        # Keep the pipeline flowing for a few cycles before introducing stalls.
        if cycle < warmup_cycles:
            is_ready = True
        else:
            is_ready = random.random() > stall_prob
        dut.ccl_ready_in.value = int(is_ready)

        # Feed LUT and ROI models
        lut_addr = int(dut.lut_read_addr.value)
        roi_addr = int(dut.roi_bram_read_addr.value)
        lut_word = lut_model.read(lut_addr)
        roi_word = roi_model.read(roi_addr)
        dut.lut_read_data.value = lut_word
        dut.roi_bram_read_data.value = roi_word

        roi_pix_q.append(roi_word)

        await RisingEdge(dut.clk_pixel)
        
        if int(dut.bev_valid_out.value) and is_ready:
            h = int(dut.bev_h_count_out.value)
            v = int(dut.bev_v_count_out.value)
            pix = int(dut.bev_pixel_out.value)
            new_frame = int(dut.bev_new_frame_out.value)
            
            if pixel_count < skip_outputs:
                pixel_count += 1
                continue

            expected_h = pixel_count % width
            expected_v = pixel_count // width
            if (h, v) != (expected_h, expected_v):
                raise AssertionError(
                    f"Pixel order mismatch: got ({h},{v}) expected ({expected_h},{expected_v})"
                )

            if pixel_count == 0 and new_frame != 1:
                raise AssertionError("bev_new_frame_out should assert on first pixel")
            if pixel_count > 0 and new_frame != 0:
                raise AssertionError(
                    f"bev_new_frame_out should deassert after first pixel (at {h},{v})"
                )
            
            out_pix.append(pix)
            pixel_count += 1
        if pixel_count == total_pixels:
            break
            
    if pixel_count != total_pixels:
        raise AssertionError(
            f"Incomplete frame: processed {pixel_count}/{total_pixels} pixels"
        )

    # End-of-frame content check: compare the emitted stream (last total_pixels entries)
    # against the expected ROI->BEV mapping in raster order. Any startup latency is ignored.
    expected_stream = []
    for v in range(height):
        for w in range(width):
            idx = v * width + w
            expected_stream.append(roi_pattern(lut_map(idx)))

    expected_len = total_pixels - skip_outputs
    if len(out_pix) < expected_len:
        raise AssertionError(
            f"Captured only {len(out_pix)} output pixels, expected {expected_len}"
        )

    if out_pix[-expected_len:] != expected_stream[skip_outputs:]:
        raise AssertionError("Output stream does not match expected mapping")


@cocotb.test()
async def test_warping_logic(dut):
    """Exhaustively verify mapping for two LUTs with random stalls."""

    width = int(os.getenv("BEV_HRES", "177"))
    height = int(os.getenv("BEV_VRES", "72"))
    stall_prob = float(os.getenv("STALL_PROB", "0.15"))

    # 1. Setup Clock and Reset
    cocotb.start_soon(Clock(dut.clk_pixel, 10, units="ns").start())
    dut.rst.value = 1
    dut.start.value = 0
    dut.ccl_ready_in.value = 0

    await RisingEdge(dut.clk_pixel)
    await RisingEdge(dut.clk_pixel)
    dut.rst.value = 0
    await RisingEdge(dut.clk_pixel)

    roi_pattern = make_roi_pattern(width, height)

    # Frame 1: identity LUT
    await run_one_frame(
        dut,
        width,
        height,
        lut_identity(width, height),
        roi_pattern,
        stall_prob,
    )

    # Frame 2: flipped LUT to ensure non-identity addressing is correct
    await run_one_frame(
        dut,
        width,
        height,
        lut_flip(width, height),
        roi_pattern,
        stall_prob,
    )


def parse_cases() -> Iterable[Tuple[int, int]]:
    env_cases = os.getenv("CASES")
    if env_cases:
        parsed = []
        for part in env_cases.split(","):
            w, h = part.split("x")
            parsed.append((int(w), int(h)))
        return parsed
    return DEFAULT_CASES


def test_bev_runner():
    hdl_toplevel_lang = os.getenv("HDL_TOPLEVEL_LANG", "verilog")
    sim = os.getenv("SIM", "icarus")
    proj_path = Path(__file__).resolve().parent.parent
    
    # Ensure sim directory is in path for cocotb to find the test module
    sys.path.append(str(proj_path / "sim"))

    sources = [
        proj_path / "hdl" / "perspective.sv",
    ]

    toplevel = "perspective_warping"

    cases = list(parse_cases())
    for width, height in cases:
        build_dir = proj_path / f"sim_build_bev_{width}x{height}"
        env = os.environ.copy()
        env["BEV_HRES"] = str(width)
        env["BEV_VRES"] = str(height)
    
    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel=toplevel,
            build_dir=str(build_dir),
        build_args=["-Wall"],
        parameters={
                "BEV_HRES": width,
                "BEV_VRES": height,
        },
        always=True,
        timescale=("1ns", "1ps"),
        waves=True,
    )
    runner.test(
        hdl_toplevel=toplevel,
        test_module=os.path.basename(__file__).replace(".py", ""),
        waves=True,
            build_dir=str(build_dir),
            extra_env=env,
    )


if __name__ == "__main__":
    test_bev_runner()
