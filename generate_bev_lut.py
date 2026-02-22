#!/usr/bin/env python3

# Simple BEV LUT generator (no numpy dependency).
# Keeps the LUT dimensions aligned with the RTL values in top_level.sv.
#
# Geometry (mirrors the downsampled ROI in top_level.sv):
#   DS_H_SHIFT = 1, DS_V_SHIFT = 1
#   ROI_SRC_H: [296, 1004) -> ROI_WIDTH  = 354
#   ROI_SRC_V: [432,  720) -> ROI_HEIGHT = 144
ROI_WIDTH = 354
ROI_HEIGHT = 144
BEV_WIDTH = ROI_WIDTH
BEV_HEIGHT = ROI_HEIGHT

# Optional: drop in a real homography here. Default is identity mapping.
# The values are in ROI-local coordinates (0..ROI_WIDTH/HEIGHT-1).
def map_bev_to_roi(u: int, v: int) -> tuple[int, int]:
    # Identity: direct 1:1 from BEV to ROI space.
    return u, v


def clamp(val: int, lo: int, hi: int) -> int:
    return max(lo, min(val, hi))


def generate(path: str):
    entries = []
    for v in range(BEV_HEIGHT):
        for u in range(BEV_WIDTH):
            src_x, src_y = map_bev_to_roi(u, v)
            src_x = clamp(src_x, 0, ROI_WIDTH - 1)
            src_y = clamp(src_y, 0, ROI_HEIGHT - 1)
            linear_addr = src_y * ROI_WIDTH + src_x
            entries.append(linear_addr)

    with open(path, "w") as f:
        for val in entries:
            f.write(f"{val:05X}\n")  # 17-bit address -> 5 hex digits
    print(f"Wrote {len(entries)} entries to {path}")


if __name__ == "__main__":
    # Vivado looks for bev_lut.mem in the project root (INIT_FILE in top_level.sv).
    generate("bev_lut.mem")
    # Also drop a copy into data/ for convenience.
    try:
        generate("data/bev_lut.mem")
    except FileNotFoundError:
        print("Note: data/ directory not found; skipped secondary copy.")

