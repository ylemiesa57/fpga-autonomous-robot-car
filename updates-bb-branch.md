BB Heavy Stub – What Changed
============================================

Goal
----
Make lane detection less noisy, use up to four blobs, and show midlines clearly on HDMI.

Main code changes
-----------------
- "hdl/ccl_calc.sv"
  - Handles up to 4 blobs (labels 1–4) with a clean "idx = label - 1" mapping.
  - Accumulates sums/areas for all four, kicks dividers only when pixels seen.
  - Publishes averages and areas for all valid blobs.

- "hdl/lane_pair_filter.sv"
  - Inputs widened to 4 blobs.
  - Picks the two largest-area blobs on each side of the image midpoint.
  - Orders the pair by Y (bottom weighted 3:1 vs top) to get left/right midpoints.
  - Only asserts valid when both sides exist; computes total midpoint.

- "hdl/top_level.sv"
  - Wires centroid math for 4 blobs through to the pairing stage.
  - Disables the bypass so filtered pairing is used.
  - Computes screen-space left/right and midpoint X positions and frame-aligns them.

- "hdl/lane_annotation.sv"
  - Draws left (red), right (cyan), midpoint (yellow) bars; overlaps go white.
  - Always draws a fixed white center column at x = 1280/2 (640) for reference.

Usage notes
-----------
- Lanes are valid only if both left and right blobs are found after filtering.
- If noise still dominates, increase the pixel_tally threshold or add a min-area check in "ccl_calc".
- LEDs: lane_count now reflects up to four valid blobs; center-line always visible on HDMI for alignment.

Branch context
--------------
- Branch: "bb-heavy-stub"
- Purpose: Heavier blob handling and clearer visual debugging for lane pairing/overlay.
- From bad lane annotation branch
- Improvements BUT
CORE FILES WERE CHANGED: top_level, filter, calc, ccl
- a lot of pipelining done as well

Pipelining summary in "top_level.sv"
------------------------------------
- **CCL & Centroid Pipeline:** 
  - Blurred pixels are written to DRAM via a pipelined memory controller, then read out for CCL.
  - Connected Component Labeling (CCL) is streamed, followed by pipelined centroid calculations which now process up to 4 blobs in parallel.
- **Lane Pairing:** 
  - Outputs of centroid logic are held in flip-flops for stability before entering the lane pairing filter.
  - Lane pair filter logic is pipelined to register the results before making pairing/midpoint decisions.
- **Screen Coordinate Transform:** 
  - Lane midpoints are computed and then pipelined through combinational logic for scaling and clipping to screen coordinates.
  - All overlay and annotation coordinates are frame-aligned (registered) at the HDMI frame boundary to avoid visual tearing.
- **Overlay:** 
  - Lane overlay logic itself is pipelined (both combinational and clocked sections) to use registered, frame-aligned positions.
- **Throughout:** 
  - All long-latency blocks (e.g., memory, arithmetic, CCL, centroid, lane filtering) use pipelining or explicit "hold" registers to ensure timing and clean handoff between each stage.
  - Final signals are stable and frame-locked before being handed to the HDMI drawing logic, preventing glitches and misalignments.



