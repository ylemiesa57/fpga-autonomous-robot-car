"""Stress and capacity tests for cle_module_8conn.

These cases push label-count limits (MAX_COMPONENTS), diagonal connectivity, and
sparse-noise robustness to ensure the streaming CCL handles corner cases while
respecting the configured component cap. The helper histogram functions make it
easy to sanity-check how labels are being reused.
"""

import os
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotb.runner import get_runner


# Helpers
async def reset_dut(dut):
    dut.rst.value = 1
    dut.s_axis_valid.value = 0
    dut.m_axis_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def drive_frame(dut, frame, random_gaps=True):
    for row in frame:
        for bit in row:
            dut.s_axis_data.value = bit
            dut.s_axis_valid.value = 1
            while True:
                await RisingEdge(dut.clk)
                if dut.s_axis_ready.value.integer:
                    break
            dut.s_axis_valid.value = 0
            if random_gaps and random.random() < 0.2:
                await RisingEdge(dut.clk)
    dut.s_axis_data.value = 0
    await RisingEdge(dut.clk)


async def collect_outputs(dut, total_pixels, timeout=200000):
    records = []
    seen_last = False

    def _safe_int(sig):
        """Convert a signal to int, resolving X/Z to 0."""
        b = sig.value.binstr.lower()
        if "x" in b or "z" in b:
            b = b.replace("x", "0").replace("z", "0")
            return int(b, 2)
        return int(sig.value)

    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.m_axis_valid.value.integer:
            x = _safe_int(dut.m_axis_x)
            y = _safe_int(dut.m_axis_y)
            label = _safe_int(dut.m_axis_label)
            records.append((x, y, label))
            if dut.m_axis_last.value.integer:
                seen_last = True
            if seen_last and len(records) == total_pixels:
                return records
    raise AssertionError(f"Timeout waiting for {total_pixels} pixels, got {len(records)}")


def distinct_labels(records):
    return {lbl for (_, _, lbl) in records if lbl != 0}


def summarize_labels(records, top=8):
    """Return a sorted histogram of label usage (label -> count)."""
    hist = {}
    for _, _, lbl in records:
        if lbl == 0:
            continue
        hist[lbl] = hist.get(lbl, 0) + 1
    items = sorted(hist.items(), key=lambda kv: kv[1], reverse=True)
    return items[:top], len(hist)


# Patterns 
def make_many_singletons(width, height, count):
    frame = [[0] * width for _ in range(height)]
    pts = set()
    rng = random.Random(42)
    while len(pts) < count and len(pts) < width * height:
        pts.add((rng.randrange(width), rng.randrange(height)))
    for x, y in pts:
        frame[y][x] = 1
    return frame


def make_diagonal_islands(width, height):
    frame = [[0] * width for _ in range(height)]
    for i in range(min(width, height)):
        frame[i][i] = 1
        if i + 1 < width:
            frame[i][i + 1] = 1
    return frame


def make_sparse_noise(width, height, density=0.1):
    rng = random.Random(7)
    return [[1 if rng.random() < density else 0 for _ in range(width)] for _ in range(height)]


# Tests 
@cocotb.test()
async def test_saturation_many_singletons(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    W = int(getattr(dut, "WIDTH", 32))
    H = int(getattr(dut, "HEIGHT", 24))
    maxc = int(getattr(dut, "MAX_COMPONENTS", 8))

    frame = make_many_singletons(W, H, count=maxc * 3)
    await reset_dut(dut)
    collector = cocotb.start_soon(collect_outputs(dut, W * H))
    await drive_frame(dut, frame)
    recs = await collector

    labs = distinct_labels(recs)
    top_hist, uniq = summarize_labels(recs, top=12)
    bg = sum(1 for _, _, lbl in recs if lbl == 0)
    fg = len(recs) - bg
    print(f"[many_singletons] uniq labels (non-zero): {uniq}, MAX_COMPONENTS={maxc}")
    print(f"[many_singletons] FG pixels: {fg}, BG pixels: {bg}")
    print(f"[many_singletons] Top label counts: {top_hist}")

    assert len(labs) <= maxc, f"Expected <= {maxc} labels, saw {len(labs)}"


@cocotb.test()
async def test_diagonal_islands_merge(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    W = int(getattr(dut, "WIDTH", 32))
    H = int(getattr(dut, "HEIGHT", 24))

    frame = make_diagonal_islands(W, H)
    await reset_dut(dut)
    collector = cocotb.start_soon(collect_outputs(dut, W * H))
    await drive_frame(dut, frame)
    recs = await collector

    labs = distinct_labels(recs)
    # All diagonal islands should merge into one component in 8-connect
    assert len(labs) == 1, f"Expected 1 merged blob, saw {len(labs)}"


@cocotb.test()
async def test_sparse_noise_under_limit(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    W = int(getattr(dut, "WIDTH", 32))
    H = int(getattr(dut, "HEIGHT", 24))
    maxc = int(getattr(dut, "MAX_COMPONENTS", 8))

    frame = make_sparse_noise(W, H, density=0.05)
    await reset_dut(dut)
    collector = cocotb.start_soon(collect_outputs(dut, W * H))
    await drive_frame(dut, frame)
    recs = await collector

    labs = distinct_labels(recs)
    assert len(labs) <= maxc, f"Sparse noise exceeded component cap: {len(labs)} > {maxc}"


# Runner 
def test_cle_stress_runner():
    sim = os.getenv("SIM", "icarus")
    proj = Path(__file__).resolve().parent.parent
    sim_build = proj / "sim_build_cle_stress"

    sources = [
        proj / "hdl" / "cle_module_8conn.sv",
        proj / "hdl" / "xilinx_true_dual_port_read_first_1_clock_ram.v",
    ]

    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel="cle_module_8conn",
        always=True,
        build_args=["-Wall", "-g2012"],
        parameters={
            "WIDTH": 32,
            "HEIGHT": 24,
            "LABEL_BITS": 10,
            "MAX_COMPONENTS": 8,
        },
        timescale=("1ns", "1ps"),
        build_dir=str(sim_build),
        waves=True,
    )
    runner.test(
        hdl_toplevel="cle_module_8conn",
        test_module=os.path.basename(__file__).replace(".py", ""),
        build_dir=str(sim_build),
        waves=True,
    )


if __name__ == "__main__":
    test_cle_stress_runner()

