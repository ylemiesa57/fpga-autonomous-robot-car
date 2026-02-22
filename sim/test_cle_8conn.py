"""Golden-model comparison for cle_module_8conn with focus on latency/handshake.

This suite rebuilds the 8-connected CCL in Python, drives frames through the
DUT with randomized bubbles, and asserts that region connectivity matches the
reference even if label numbers differ. It is meant to catch regressions in the
streaming interface as well as the union-find conflict resolution.
"""

import os
import sys
import random
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotb.runner import get_runner

# =============================================================================
# Reference Implementation: 8-Connected CCL using Union-Find
# =============================================================================

def connected_components(frame):
    """Reference 8-connected CCL implementation using Union-Find"""
    height = len(frame)
    width = len(frame[0])
    labels = [[0] * width for _ in range(height)]
    parent = {}

    def make_set(label):
        parent[label] = label

    def find(label):
        root = label
        while parent[root] != root:
            root = parent[root]
        # Path compression
        curr = label
        while curr != root:
            nxt = parent[curr]
            parent[curr] = root
            curr = nxt
        return root

    def union(a, b):
        root_a = find(a)
        root_b = find(b)
        if root_a != root_b:
            if root_a < root_b:
                parent[root_b] = root_a
            else:
                parent[root_a] = root_b

    next_label = 1
    for y in range(height):
        for x in range(width):
            if frame[y][x] == 0:
                continue

            # 8-connectivity neighbors: Left, Top-Left, Top, Top-Right
            neighbors = []
            if x > 0 and labels[y][x-1] != 0:
                neighbors.append(labels[y][x-1])
            if x > 0 and y > 0 and labels[y-1][x-1] != 0:
                neighbors.append(labels[y-1][x-1])
            if y > 0 and labels[y-1][x] != 0:
                neighbors.append(labels[y-1][x])
            if x < width - 1 and y > 0 and labels[y-1][x+1] != 0:
                neighbors.append(labels[y-1][x+1])

            if not neighbors:
                chosen = next_label
                make_set(chosen)
                next_label += 1
            else:
                chosen = min(neighbors)
                for n in neighbors:
                    if n != chosen:
                        union(chosen, n)
            
            labels[y][x] = chosen

    # Relabel to root labels
    result = [[0] * width for _ in range(height)]
    for y in range(height):
        for x in range(width):
            lab = labels[y][x]
            result[y][x] = 0 if lab == 0 else find(lab)
    return result


def count_components(ref_grid):
    """Count unique non-zero labels"""
    labels = set()
    for row in ref_grid:
        for lab in row:
            if lab != 0:
                labels.add(lab)
    return len(labels)


# =============================================================================
# Test Infrastructure
# =============================================================================

async def reset_dut(dut):
    """Reset the DUT"""
    dut.rst.value = 1
    dut.s_axis_valid.value = 0
    dut.m_axis_ready.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def drive_frame(dut, frame):
    """Send frame pixel-by-pixel"""
    for row in frame:
        for bit in row:
            dut.s_axis_data.value = bit
            dut.s_axis_valid.value = 1
            while True:
                await RisingEdge(dut.clk)
                if dut.s_axis_ready.value.integer == 1:
                    break
            dut.s_axis_valid.value = 0
            # Small random delay
            if random.random() < 0.1:
                await RisingEdge(dut.clk)
    dut.s_axis_data.value = 0


async def collect_outputs(dut, total_pixels, timeout_cycles=200000):
    """Collect labeled pixels from output"""
    records = []
    seen_last = False
    max_cycles = max(timeout_cycles, total_pixels * 50)
    
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if dut.m_axis_valid.value.integer == 1:
            x = int(dut.m_axis_x.value)
            y = int(dut.m_axis_y.value)
            label = int(dut.m_axis_label.value)
            records.append((x, y, label))
            if dut.m_axis_last.value.integer == 1:
                seen_last = True
            if len(records) == total_pixels and seen_last:
                return records
    
    raise AssertionError(
        f"Timeout: got {len(records)} of {total_pixels} outputs"
    )


async def verify_frame(dut, frame, name="frame"):
    """Verify DUT output matches reference"""
    height = len(frame)
    width = len(frame[0])
    total = width * height
    
    ref_grid = connected_components(frame)
    expected = [(x, y, ref_grid[y][x]) for y in range(height) for x in range(width)]
    
    collector = cocotb.start_soon(collect_outputs(dut, total))
    await drive_frame(dut, frame)
    outputs = await collector
    
    assert len(outputs) == total, f"{name}: Got {len(outputs)}, expected {total}"
    
    # Verify region consistency (labels may differ but regions must match)
    ref_map = {}
    for (obs_x, obs_y, obs_label), (exp_x, exp_y, exp_label) in zip(outputs, expected):
        assert (obs_x, obs_y) == (exp_x, exp_y), f"{name}: Coord mismatch"
        
        if exp_label == 0:
            assert obs_label == 0, f"{name}: BG pixel ({obs_x},{obs_y}) has label {obs_label}"
            continue
        
        assert obs_label != 0, f"{name}: FG pixel ({obs_x},{obs_y}) has label 0"
        
        if exp_label in ref_map:
            assert obs_label == ref_map[exp_label], \
                f"{name}: Label inconsistency at ({obs_x},{obs_y})"
        else:
            assert obs_label not in ref_map.values(), \
                f"{name}: Label collision at ({obs_x},{obs_y})"
            ref_map[exp_label] = obs_label
    
    print(f"  {name}: PASS ({count_components(ref_grid)} components)")


# =============================================================================
# Test Pattern Generators
# =============================================================================

def make_all_background(w, h):
    return [[0] * w for _ in range(h)]

def make_all_foreground(w, h):
    return [[1] * w for _ in range(h)]

def make_single_pixel(w, h, px=None, py=None):
    frame = [[0] * w for _ in range(h)]
    px = px if px is not None else w // 2
    py = py if py is not None else h // 2
    frame[py][px] = 1
    return frame

def make_diagonal_bridge(w, h):
    """Two blobs connected only by diagonal"""
    frame = [[0] * w for _ in range(h)]
    if h > 0 and w > 1:
        frame[0][0] = 1
        frame[0][1] = 1
    if h > 1 and w > 2:
        frame[1][2] = 1
    if h > 2 and w > 2:
        frame[2][1] = 1
        frame[2][2] = 1
    return frame

def make_cross(w, h):
    frame = [[0] * w for _ in range(h)]
    cx, cy = w // 2, h // 2
    for y in range(max(0, cy-2), min(h, cy+3)):
        if 0 <= cx < w:
            frame[y][cx] = 1
    for x in range(max(0, cx-2), min(w, cx+3)):
        if 0 <= cy < h:
            frame[cy][x] = 1
    return frame

def make_two_blobs(w, h):
    frame = [[0] * w for _ in range(h)]
    # Top-left blob
    for y in range(min(3, h)):
        for x in range(min(3, w)):
            frame[y][x] = 1
    # Bottom-right blob (with gap)
    for y in range(max(0, h-3), h):
        for x in range(max(0, w-3), w):
            if y >= 5 or x >= 5:
                frame[y][x] = 1
    return frame

def make_chessboard(w, h):
    """Alternating pixels - all connected in 8-conn"""
    return [[(x + y) % 2 for x in range(w)] for y in range(h)]

def make_random(w, h, density=0.25):
    return [[1 if random.random() < density else 0 for _ in range(w)] for _ in range(h)]


# =============================================================================
# Test Cases
# =============================================================================

@cocotb.test()
async def test_all_background(dut):
    """All background - expect all labels = 0"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    try:
        W, H = int(dut.WIDTH.value), int(dut.HEIGHT.value)
    except:
        W, H = 20, 15
    print(f"\n=== test_all_background ({W}x{H}) ===")
    await reset_dut(dut)
    await verify_frame(dut, make_all_background(W, H), "all_background")


@cocotb.test()
async def test_all_foreground(dut):
    """All foreground - single component"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    try:
        W, H = int(dut.WIDTH.value), int(dut.HEIGHT.value)
    except:
        W, H = 20, 15
    print(f"\n=== test_all_foreground ({W}x{H}) ===")
    await reset_dut(dut)
    await verify_frame(dut, make_all_foreground(W, H), "all_foreground")


@cocotb.test()
async def test_single_pixel(dut):
    """Single pixel"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    try:
        W, H = int(dut.WIDTH.value), int(dut.HEIGHT.value)
    except:
        W, H = 20, 15
    print(f"\n=== test_single_pixel ({W}x{H}) ===")
    await reset_dut(dut)
    await verify_frame(dut, make_single_pixel(W, H), "single_pixel")


@cocotb.test()
async def test_diagonal_bridge(dut):
    """8-connectivity diagonal test"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    try:
        W, H = int(dut.WIDTH.value), int(dut.HEIGHT.value)
    except:
        W, H = 20, 15
    print(f"\n=== test_diagonal_bridge ({W}x{H}) ===")
    await reset_dut(dut)
    await verify_frame(dut, make_diagonal_bridge(W, H), "diagonal_bridge")


@cocotb.test()
async def test_cross(dut):
    """Cross shape - all connected"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    try:
        W, H = int(dut.WIDTH.value), int(dut.HEIGHT.value)
    except:
        W, H = 20, 15
    print(f"\n=== test_cross ({W}x{H}) ===")
    await reset_dut(dut)
    await verify_frame(dut, make_cross(W, H), "cross")


@cocotb.test()
async def test_two_blobs(dut):
    """Two separate blobs"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    try:
        W, H = int(dut.WIDTH.value), int(dut.HEIGHT.value)
    except:
        W, H = 20, 15
    print(f"\n=== test_two_blobs ({W}x{H}) ===")
    await reset_dut(dut)
    await verify_frame(dut, make_two_blobs(W, H), "two_blobs")


@cocotb.test()
async def test_chessboard(dut):
    """Chessboard - all connected in 8-conn"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    try:
        W, H = int(dut.WIDTH.value), int(dut.HEIGHT.value)
    except:
        W, H = 20, 15
    print(f"\n=== test_chessboard ({W}x{H}) ===")
    await reset_dut(dut)
    await verify_frame(dut, make_chessboard(W, H), "chessboard")


@cocotb.test()
async def test_random_frames(dut):
    """Multiple random frames"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    try:
        W, H = int(dut.WIDTH.value), int(dut.HEIGHT.value)
    except:
        W, H = 20, 15
    print(f"\n=== test_random_frames ({W}x{H}) ===")
    
    for i, density in enumerate([0.1, 0.2, 0.3]):
        await reset_dut(dut)
        await verify_frame(dut, make_random(W, H, density), f"random_{i}_d{density}")


# =============================================================================
# Test Runner
# =============================================================================

def test_cle_8conn_runner():
    sim = os.getenv("SIM", "icarus")
    proj_path = Path(__file__).resolve().parent.parent
    sim_build_dir = proj_path / "sim_build_cle"
    
    sys.path.append(str(proj_path / "sim"))

    sources = [
        proj_path / "hdl" / "cle_module_8conn.sv",
        proj_path / "hdl" / "xilinx_true_dual_port_read_first_1_clock_ram.v",
    ]
    
    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel="cle_module_8conn",
        always=True,
        build_args=["-Wall", "-g2012"],
        parameters={
            "WIDTH": 20,
            "HEIGHT": 15,
            "LABEL_BITS": 12,
            "MAX_COMPONENTS": 64  # Increased for chessboard pattern
        },
        timescale=("1ns", "1ps"),
        build_dir=str(sim_build_dir),
        waves=True,
    )
    runner.test(
        hdl_toplevel="cle_module_8conn",
        test_module=os.path.basename(__file__).replace(".py", ""),
        build_dir=str(sim_build_dir),
        waves=True,
    )

if __name__ == "__main__":
    test_cle_8conn_runner()

