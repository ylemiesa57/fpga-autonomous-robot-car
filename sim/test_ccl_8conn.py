"""Functional regression for cle_module_8conn against a Python union-find golden.

The helpers here generate small frames with known 8-connect topology, stream
them into the DUT with optional random bubbles, and verify that the output
labels preserve region equivalence (labels may be renumbered but connectivity
must match the reference). This keeps the streaming handshakes honest while
exercising the conflict-resolution path.
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
        # Path compression for efficient lookups
        root = label
        while parent[root] != root:
            root = parent[root]
        # Compress path
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
            # Smaller label becomes parent for consistency
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
                neighbors.append(labels[y][x-1])             # left
            if x > 0 and y > 0 and labels[y-1][x-1] != 0:
                neighbors.append(labels[y-1][x-1])           # top-left
            if y > 0 and labels[y-1][x] != 0:
                neighbors.append(labels[y-1][x])             # top
            if x < width - 1 and y > 0 and labels[y-1][x+1] != 0:
                neighbors.append(labels[y-1][x+1])           # top-right

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
    """Count unique non-zero labels in reference grid"""
    labels = set()
    for row in ref_grid:
        for lab in row:
            if lab != 0:
                labels.add(lab)
    return len(labels)


def print_frame(frame, title="Frame"):
    """Debug helper to visualize a frame"""
    print(f"\n{title}:")
    for row in frame:
        print("".join(['#' if p else '.' for p in row]))


def print_labels(grid, title="Labels"):
    """Debug helper to visualize labels"""
    print(f"\n{title}:")
    for row in grid:
        print(" ".join([f"{l:2d}" if l else " ." for l in row]))


# =============================================================================
# Test Infrastructure
# =============================================================================

def flatten_frame(frame):
    """Flatten 2D frame to 1D stream for hardware input"""
    for row in frame:
        for bit in row:
            yield bit


async def reset_dut(dut):
    """Reset the DUT to known state"""
    dut.rst.value = 1
    dut.s_axis_valid.value = 0
    dut.m_axis_ready.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def drive_frame(dut, frame, random_delays=True):
    """Send frame pixel-by-pixel to DUT with AXI stream handshaking"""
    for bit in flatten_frame(frame):
        dut.s_axis_data.value = bit
        dut.s_axis_valid.value = 1
        while True:
            await RisingEdge(dut.clk)
            if dut.s_axis_ready.value.integer == 1:
                break
        dut.s_axis_valid.value = 0
        # Random delays to stress handshaking
        if random_delays and random.random() < 0.3:
            await RisingEdge(dut.clk)
            
    dut.s_axis_data.value = 0
    await RisingEdge(dut.clk)


async def collect_outputs(dut, total_pixels, timeout_cycles=100000):
    """Collect labeled pixels from DUT output stream"""
    records = []
    seen_last = False
    max_cycles = max(timeout_cycles, total_pixels * 20)
    
    for cycle in range(max_cycles):
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
        f"Timeout after {max_cycles} cycles waiting for {total_pixels} outputs; got {len(records)} entries"
    )


async def verify_frame(dut, frame, frame_name="frame"):
    """Run frame through DUT and verify against reference"""
    height = len(frame)
    width = len(frame[0])
    total_pixels = width * height
    
    # Generate reference
    ref_grid = connected_components(frame)
    expected_stream = [
        (x, y, ref_grid[y][x]) for y in range(height) for x in range(width)
    ]
    
    # Run through DUT
    collector = cocotb.start_soon(collect_outputs(dut, total_pixels))
    await drive_frame(dut, frame)
    outputs = await collector
    
    assert len(outputs) == total_pixels, f"{frame_name}: Got {len(outputs)} outputs, expected {total_pixels}"
    
    # Verify labels match (allowing different label values as long as regions consistent)
    ref_map = {}  # ref_label -> dut_label mapping
    
    for idx, (obs, exp) in enumerate(zip(outputs, expected_stream)):
        obs_x, obs_y, obs_label = obs
        exp_x, exp_y, exp_label = exp
        
        assert (obs_x, obs_y) == (exp_x, exp_y), \
            f"{frame_name}: Coordinate mismatch at idx {idx}: Got ({obs_x},{obs_y}), Exp ({exp_x},{exp_y})"
        
        if exp_label == 0:
            assert obs_label == 0, \
                f"{frame_name}: Background pixel at ({obs_x},{obs_y}) has label {obs_label}, expected 0"
            continue
        else:
            assert obs_label != 0, \
                f"{frame_name}: Foreground pixel at ({obs_x},{obs_y}) has label 0, expected non-zero"
        
        if exp_label in ref_map:
            expected_dut_label = ref_map[exp_label]
            assert obs_label == expected_dut_label, \
                f"{frame_name}: Label inconsistency at ({obs_x},{obs_y}). " \
                f"Ref label {exp_label} previously mapped to DUT label {expected_dut_label}, now got {obs_label}"
        else:
            if obs_label in ref_map.values():
                old_ref = [k for k, v in ref_map.items() if v == obs_label][0]
                raise AssertionError(
                    f"{frame_name}: Label collision at ({obs_x},{obs_y}). " \
                    f"DUT label {obs_label} already mapped to ref label {old_ref}, " \
                    f"now trying to map to ref label {exp_label}"
                )
            ref_map[exp_label] = obs_label
    
    num_components = count_components(ref_grid)
    print(f"  {frame_name}: PASS ({num_components} components)")
    return True


# =============================================================================
# Test Pattern Generators
# =============================================================================

def make_all_background(width, height):
    """All zeros - no foreground"""
    return [[0] * width for _ in range(height)]


def make_all_foreground(width, height):
    """All ones - single component"""
    return [[1] * width for _ in range(height)]


def make_single_pixel(width, height, x=None, y=None):
    """Single foreground pixel"""
    frame = [[0] * width for _ in range(height)]
    px = x if x is not None else width // 2
    py = y if y is not None else height // 2
    frame[py][px] = 1
    return frame


def make_diagonal_bridge(width, height):
    """Two blobs connected only by diagonal - tests 8-connectivity
    
    Pattern:
      ##.
      ..#
      .##
    
    In 8-connectivity, all should be one component (diagonal connects)
    """
    frame = [[0] * width for _ in range(height)]
    min_dim = min(width, height)
    
    # Top-left blob
    if height > 0 and width > 1:
        frame[0][0] = 1
        frame[0][1] = 1
    
    # Bottom-right blob connected diagonally
    if height > 1 and width > 1:
        frame[1][2 if width > 2 else 1] = 1
    if height > 2 and width > 2:
        frame[2][1] = 1
        frame[2][2] = 1
    
    return frame


def make_cross_shape(width, height):
    """Cross/plus shape - all connected
    
    Pattern:
      .#.
      ###
      .#.
    """
    frame = [[0] * width for _ in range(height)]
    cx, cy = width // 2, height // 2
    
    # Vertical bar
    for y in range(max(0, cy - 2), min(height, cy + 3)):
        if 0 <= cx < width:
            frame[y][cx] = 1
    
    # Horizontal bar
    for x in range(max(0, cx - 2), min(width, cx + 3)):
        if 0 <= cy < height:
            frame[cy][x] = 1
    
    return frame


def make_t_shape(width, height):
    """T shape pattern"""
    frame = [[0] * width for _ in range(height)]
    cx = width // 2
    
    # Horizontal top bar
    for x in range(max(0, cx - 2), min(width, cx + 3)):
        if height > 0:
            frame[0][x] = 1
    
    # Vertical stem
    for y in range(min(height, 5)):
        if 0 <= cx < width:
            frame[y][cx] = 1
    
    return frame


def make_two_separate_blobs(width, height):
    """Two separate blobs that should NOT connect"""
    frame = [[0] * width for _ in range(height)]
    
    # Left blob (top-left corner)
    for y in range(min(3, height)):
        for x in range(min(3, width)):
            frame[y][x] = 1
    
    # Right blob (bottom-right corner) - with gap
    for y in range(max(0, height - 3), height):
        for x in range(max(0, width - 3), width):
            # Ensure gap exists
            if y >= 5 or x >= 5:
                frame[y][x] = 1
    
    return frame


def make_chessboard(width, height):
    """Alternating pixels - in 8-conn, diagonals connect!
    
    Pattern:
      #.#.#
      .#.#.
      #.#.#
    
    In 8-connectivity, ALL foreground pixels form ONE component
    """
    frame = [[0] * width for _ in range(height)]
    for y in range(height):
        for x in range(width):
            if (x + y) % 2 == 0:
                frame[y][x] = 1
    return frame


def make_vertical_stripes(width, height):
    """Vertical stripes - each column is separate component"""
    frame = [[0] * width for _ in range(height)]
    for y in range(height):
        for x in range(0, width, 2):  # Every other column
            frame[y][x] = 1
    return frame


def make_horizontal_stripes(width, height):
    """Horizontal stripes - each row is separate component"""
    frame = [[0] * width for _ in range(height)]
    for y in range(0, height, 2):  # Every other row
        for x in range(width):
            frame[y][x] = 1
    return frame


def make_labyrinth(width, height):
    """Complex maze-like pattern - worst case for CCL per TPSS paper"""
    frame = [[0] * width for _ in range(height)]
    
    # Create a maze-like pattern with many turns
    for y in range(height):
        for x in range(width):
            # Horizontal passages every 3 rows
            if y % 3 == 0:
                frame[y][x] = 1
            # Vertical connectors
            elif x % 5 == (y // 3) % 5:
                frame[y][x] = 1
    
    return frame


def make_random_frame(width, height, density=0.25):
    """Random frame with given foreground density"""
    return [[1 if random.random() < density else 0 for _ in range(width)] for _ in range(height)]


# =============================================================================
# Test Cases
# =============================================================================

@cocotb.test()
async def test_all_background(dut):
    """Test: All background pixels - expect all labels = 0"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    
    try:
        WIDTH = int(dut.WIDTH.value)
        HEIGHT = int(dut.HEIGHT.value)
    except:
        WIDTH, HEIGHT = 20, 15
    
    print(f"\n=== test_all_background ({WIDTH}x{HEIGHT}) ===")
    await reset_dut(dut)
    
    frame = make_all_background(WIDTH, HEIGHT)
    await verify_frame(dut, frame, "all_background")


@cocotb.test()
async def test_all_foreground(dut):
    """Test: All foreground pixels - expect single component"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    
    try:
        WIDTH = int(dut.WIDTH.value)
        HEIGHT = int(dut.HEIGHT.value)
    except:
        WIDTH, HEIGHT = 20, 15
    
    print(f"\n=== test_all_foreground ({WIDTH}x{HEIGHT}) ===")
    await reset_dut(dut)
    
    frame = make_all_foreground(WIDTH, HEIGHT)
    await verify_frame(dut, frame, "all_foreground")


@cocotb.test()
async def test_single_pixel(dut):
    """Test: Single foreground pixel - one component"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    
    try:
        WIDTH = int(dut.WIDTH.value)
        HEIGHT = int(dut.HEIGHT.value)
    except:
        WIDTH, HEIGHT = 20, 15
    
    print(f"\n=== test_single_pixel ({WIDTH}x{HEIGHT}) ===")
    await reset_dut(dut)
    
    # Test pixel at center
    frame = make_single_pixel(WIDTH, HEIGHT)
    await verify_frame(dut, frame, "single_pixel_center")
    
    await reset_dut(dut)
    
    # Test pixel at corner
    frame = make_single_pixel(WIDTH, HEIGHT, 0, 0)
    await verify_frame(dut, frame, "single_pixel_corner")


@cocotb.test()
async def test_diagonal_bridge(dut):
    """Test: 8-connectivity diagonal bridging"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    
    try:
        WIDTH = int(dut.WIDTH.value)
        HEIGHT = int(dut.HEIGHT.value)
    except:
        WIDTH, HEIGHT = 20, 15
    
    print(f"\n=== test_diagonal_bridge ({WIDTH}x{HEIGHT}) ===")
    await reset_dut(dut)
    
    frame = make_diagonal_bridge(WIDTH, HEIGHT)
    ref_grid = connected_components(frame)
    num_components = count_components(ref_grid)
    print(f"  Diagonal bridge should have 1 component (8-conn), ref says: {num_components}")
    
    await verify_frame(dut, frame, "diagonal_bridge")


@cocotb.test()
async def test_cross_shape(dut):
    """Test: Cross/plus shape - all connected"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    
    try:
        WIDTH = int(dut.WIDTH.value)
        HEIGHT = int(dut.HEIGHT.value)
    except:
        WIDTH, HEIGHT = 20, 15
    
    print(f"\n=== test_cross_shape ({WIDTH}x{HEIGHT}) ===")
    await reset_dut(dut)
    
    frame = make_cross_shape(WIDTH, HEIGHT)
    await verify_frame(dut, frame, "cross_shape")


@cocotb.test()
async def test_two_separate_blobs(dut):
    """Test: Two separate blobs - should be 2 components"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    
    try:
        WIDTH = int(dut.WIDTH.value)
        HEIGHT = int(dut.HEIGHT.value)
    except:
        WIDTH, HEIGHT = 20, 15
    
    print(f"\n=== test_two_separate_blobs ({WIDTH}x{HEIGHT}) ===")
    await reset_dut(dut)
    
    frame = make_two_separate_blobs(WIDTH, HEIGHT)
    ref_grid = connected_components(frame)
    num_components = count_components(ref_grid)
    print(f"  Two blobs should have 2 components, ref says: {num_components}")
    
    await verify_frame(dut, frame, "two_separate_blobs")


@cocotb.test()
async def test_chessboard(dut):
    """Test: Chessboard pattern - in 8-conn, all form ONE component via diagonals"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    
    try:
        WIDTH = int(dut.WIDTH.value)
        HEIGHT = int(dut.HEIGHT.value)
    except:
        WIDTH, HEIGHT = 20, 15
    
    print(f"\n=== test_chessboard ({WIDTH}x{HEIGHT}) ===")
    await reset_dut(dut)
    
    frame = make_chessboard(WIDTH, HEIGHT)
    ref_grid = connected_components(frame)
    num_components = count_components(ref_grid)
    print(f"  Chessboard in 8-conn should have 1 component, ref says: {num_components}")
    
    await verify_frame(dut, frame, "chessboard")


@cocotb.test()
async def test_vertical_stripes(dut):
    """Test: Vertical stripes - separate columns"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    
    try:
        WIDTH = int(dut.WIDTH.value)
        HEIGHT = int(dut.HEIGHT.value)
    except:
        WIDTH, HEIGHT = 20, 15
    
    print(f"\n=== test_vertical_stripes ({WIDTH}x{HEIGHT}) ===")
    await reset_dut(dut)
    
    frame = make_vertical_stripes(WIDTH, HEIGHT)
    ref_grid = connected_components(frame)
    num_components = count_components(ref_grid)
    print(f"  Vertical stripes should have {(WIDTH + 1) // 2} components, ref says: {num_components}")
    
    await verify_frame(dut, frame, "vertical_stripes")


@cocotb.test()
async def test_horizontal_stripes(dut):
    """Test: Horizontal stripes - separate rows"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    
    try:
        WIDTH = int(dut.WIDTH.value)
        HEIGHT = int(dut.HEIGHT.value)
    except:
        WIDTH, HEIGHT = 20, 15
    
    print(f"\n=== test_horizontal_stripes ({WIDTH}x{HEIGHT}) ===")
    await reset_dut(dut)
    
    frame = make_horizontal_stripes(WIDTH, HEIGHT)
    ref_grid = connected_components(frame)
    num_components = count_components(ref_grid)
    print(f"  Horizontal stripes should have {(HEIGHT + 1) // 2} components, ref says: {num_components}")
    
    await verify_frame(dut, frame, "horizontal_stripes")


@cocotb.test()
async def test_labyrinth(dut):
    """Test: Labyrinth pattern - stress test per TPSS paper"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    
    try:
        WIDTH = int(dut.WIDTH.value)
        HEIGHT = int(dut.HEIGHT.value)
    except:
        WIDTH, HEIGHT = 20, 15
    
    print(f"\n=== test_labyrinth ({WIDTH}x{HEIGHT}) ===")
    await reset_dut(dut)
    
    frame = make_labyrinth(WIDTH, HEIGHT)
    ref_grid = connected_components(frame)
    num_components = count_components(ref_grid)
    print(f"  Labyrinth has {num_components} components")
    
    await verify_frame(dut, frame, "labyrinth")


@cocotb.test()
async def test_randomized_multi_frame(dut):
    """Test: Multiple random frames with varying densities"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    
    try:
        WIDTH = int(dut.WIDTH.value)
        HEIGHT = int(dut.HEIGHT.value)
    except:
        WIDTH, HEIGHT = 20, 15
    
    NUM_FRAMES = 10
    print(f"\n=== test_randomized_multi_frame ({WIDTH}x{HEIGHT}, {NUM_FRAMES} frames) ===")
    
    densities = [0.1, 0.2, 0.25, 0.3, 0.4, 0.5, 0.1, 0.25, 0.35, 0.15]
    
    for i in range(NUM_FRAMES):
        await reset_dut(dut)
        density = densities[i % len(densities)]
        frame = make_random_frame(WIDTH, HEIGHT, density)
        await verify_frame(dut, frame, f"random_frame_{i+1}_density_{density}")


@cocotb.test()
async def test_t_shape(dut):
    """Test: T shape pattern"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    
    try:
        WIDTH = int(dut.WIDTH.value)
        HEIGHT = int(dut.HEIGHT.value)
    except:
        WIDTH, HEIGHT = 20, 15
    
    print(f"\n=== test_t_shape ({WIDTH}x{HEIGHT}) ===")
    await reset_dut(dut)
    
    frame = make_t_shape(WIDTH, HEIGHT)
    await verify_frame(dut, frame, "t_shape")


# =============================================================================
# Test Runner
# =============================================================================

def test_ccl_8conn_runner():
    hdl_toplevel_lang = os.getenv("HDL_TOPLEVEL_LANG", "verilog")
    sim = os.getenv("SIM", "icarus")
    proj_path = Path(__file__).resolve().parent.parent
    sim_build_dir = proj_path / "sim_build_ccl"
    
    sys.path.append(str(proj_path / "sim"))

    sources = [
        proj_path / "hdl" / "ccl_8conn.sv",
        proj_path / "hdl" / "xilinx_true_dual_port_read_first_1_clock_ram.v",
    ]
    
    toplevel = "tpss_ccl_8conn"
    
    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel=toplevel, 
        always=True,
        build_args=["-Wall", "-g2012"],  # Enable SystemVerilog 2012
        parameters={
            "WIDTH": 20,       # Smaller size for faster testing
            "HEIGHT": 15,
            "LABEL_BITS": 12,
            "MAX_COMPONENTS": 64
        },
        timescale=("1ns", "1ps"),
        build_dir=str(sim_build_dir),
        waves=True,
    )
    runner.test(
        hdl_toplevel=toplevel,
        test_module=os.path.basename(__file__).replace(".py", ""),
        build_dir=str(sim_build_dir),
        waves=True,
    )

if __name__ == "__main__":
    test_ccl_8conn_runner()
