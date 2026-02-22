# FPGA Autonomous Robot Car

End-to-end FPGA pipeline for real-time lane detection, centroiding, and HDMI overlay, built for the Urbana Spartan-7 platform. The design streams camera frames through DDR3, performs connected-component labeling, computes lane midpoints, and renders lane overlays and guidance markers directly in hardware.

## Highlights
- Real-time lane detection with 4-blob connected component labeling.
- Pipelined centroid math and lane pairing to stabilize HDMI overlays.
- Frame-aligned annotation (left/right/midpoint bars + fixed centerline).
- Vivado build flow with one-shot `build.tcl` script.
- Cocotb-based simulation testbench coverage for key blocks.

## Architecture (high level)
1. Image ingest and buffering: camera stream -> DDR3 frame buffer.
2. Preprocess: blur, threshold, ROI, perspective warp.
3. CCL + centroiding: 4-blob connected component labeling and centroid math.
4. Lane pairing: selects dominant blobs per side and computes midpoints.
5. Overlay: HDMI output with left/right/midpoint indicators.

## Repo layout
- `hdl/` - SystemVerilog RTL, including CCL, centroid, lane pairing, HDMI output.
- `sim/` - cocotb tests and simulation helpers.
- `data/` - memory init files (if used).
- `xdc/` - pin constraints.
- `build.tcl` - Vivado build script (synth -> place -> route -> bitstream).
- `updates-bb-branch.md` - detailed pipeline and blob-handling notes.

## Build (Vivado)
Requirements: Vivado (Spartan-7 support), Xilinx tools in PATH.

```tcl
vivado -mode batch -source build.tcl
```

Build outputs land in `obj/` (ignored by git).

## Simulation
This repo uses cocotb + iverilog for several block-level tests.

```bash
# Example: run cocotb tests (set up your Python venv first)
python -m pytest sim/test_lane_pipeline.py
```

## Hardware
Target part is configured in `build.tcl` as:
- `xc7s50csga324-1` (Urbana Spartan-7-50)

## Notes
- Lane pairing expects both left and right blobs to be present before asserting valid output.
- For noisy scenes, consider raising pixel tally thresholds or adding minimum area checks in `hdl/ccl_calc.sv`.

## License
MIT
