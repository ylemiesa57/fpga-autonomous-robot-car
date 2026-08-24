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

## Simulation status and debugging log

Block-level cocotb testbenches live in `sim/`. Current pass/fail state for every
test, the toolchain setup that makes them runnable without root, and the
investigation history behind the trickier failures are tracked in
[`sim/KNOWN_ISSUES.md`](sim/KNOWN_ISSUES.md).

That file is kept as a working engineering log rather than a summary, so it
records theories that turned out to be wrong as well as the fixes that landed.
For example, the `ccl_8conn.sv` address-aliasing theory and the `GEN_BITS`
wraparound theory were both empirically ruled out, and the real cause of
`cc_valid_out` never asserting for small blobs turned out to be a threshold
mismatch in `ccl_calc.sv`, where the divider kick-off required a blob larger
than the validity check did.

## Repo layout
- `hdl/` - SystemVerilog RTL, including CCL, centroid, lane pairing, HDMI output.
- `sim/` - cocotb tests and simulation helpers, plus
  [`sim/KNOWN_ISSUES.md`](sim/KNOWN_ISSUES.md): a running log of simulation
  status, root-cause investigations, and theories tested and ruled out.
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
# Example: run a cocotb test (see sim/KNOWN_ISSUES.md for toolchain setup)
python sim/test_lane_pipeline.py
```

## Hardware
Target part is configured in `build.tcl` as:
- `xc7s50csga324-1` (Urbana Spartan-7-50)

## Notes
- Lane pairing expects both left and right blobs to be present before asserting valid output.
- For noisy scenes, consider raising pixel tally thresholds or adding minimum area checks in `hdl/ccl_calc.sv`.

## License
MIT
