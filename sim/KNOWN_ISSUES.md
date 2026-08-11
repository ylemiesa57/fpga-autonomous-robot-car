# Simulation status (as of 2026-07-22)

Ran the full cocotb test suite in `sim/` for the first time end-to-end (previous
automated passes only ever got as far as installing the toolchain and running one
or two smoke tests). Notes below so this doesn't need to be rediscovered.

## Toolchain setup without root

`iverilog` isn't available via `apt-get install` in a sandboxed/no-root CI
environment. It can still be installed from the `.deb` without root:

```bash
apt-get download iverilog
dpkg-deb -x iverilog_*.deb extracted
# iverilog looks for its module dir at usr/x86_64-linux-gnu/ivl relative to
# the binary's install prefix, not usr/lib/x86_64-linux-gnu/ivl where the
# .deb actually puts it -- mirror it there:
mkdir -p root/usr/x86_64-linux-gnu
cp -r extracted/usr/lib/x86_64-linux-gnu/ivl root/usr/x86_64-linux-gnu/ivl
cp -r extracted/usr/bin/* root/usr/bin/
export PATH="$(pwd)/root/usr/bin:$PATH"
```

Also needs `cocotb<2.0` -- these tests use `cocotb.runner`, which was removed/
relocated in cocotb 2.x.

## Test results

Ran every `sim/test_*.py` directly (`python3 sim/test_X.py`). Results:

| Test | Result |
|---|---|
| `test_cc_calc.py` | PASS |
| `test_ccl_calc.py` | **FAIL** -- `cc_valid_out` flags never go high (all 0000), no valid blobs produced. Consistent across 3 reruns with different random seeds, so not a flaky/timing fluke. Not investigated further -- understanding the two-pass BRAM CCL + centroid pipeline (`hdl/ccl_calc.sv`, `hdl/divider.sv`) well enough to be confident about a fix needs more context than a scheduled pass can safely verify. |
| `test_ccl_8conn.py` | 8/12 PASS, 4 FAIL (`test_chessboard`, `test_vertical_stripes`, `test_labyrinth`, `test_randomized_multi_frame`) -- all fail with "Label inconsistency", i.e. the same source-region ends up with two different DUT labels. Looks like a real union-find/label-equivalence bug in `hdl/ccl_8conn.sv` that only shows up on denser/larger-component patterns, not a testbench issue. |
| `test_cle_8conn.py` | 1/8 PASS (`test_all_background`), 7 FAIL -- every foreground pixel comes back with label 0, even the very first pixel in `test_single_pixel`. Same flavor of bug as `test_ccl_8conn.py`, in the standalone `hdl/cle_module_8conn.sv` variant. |
| `test_bev.py` | Was **not runnable at all** -- the whole file had every line of the leading docstring + import block indented by one stray space, an `IndentationError` at the module's first line. Fixed in this pass (just removed the stray leading space, no logic touched). Now runs and reports a genuine functional failure: `test_warping_logic` fails with "Output stream does not match expected mapping" against `hdl/perspective.sv`. Not investigated further. |
| `test_lane_pair_filter.py` | **FAIL to even start** -- `AttributeError: lane_pair_filter contains no object named blob_x0`. The test drives signals `blob_x0..3`, but the actual RTL (`hdl/lane_pair_filter.sv`) exposes `cc_valid`, `cc_x[3:0]`, `cc_y[3:0]`, `cc_pixels[3:0]` -- a completely different, array-based port interface. This test looks like it was written against an earlier version of the module and never updated; fixing it means rewriting the drive/collect logic around the current array ports, which is more than a small fix. |
| `test_cle_stress.py` | **PASS** (3/3: `test_saturation_many_singletons`, `test_diagonal_islands_merge`, `test_sparse_noise_under_limit`). Standalone `cle_module_8conn` holds up under the stress patterns this file targets, unlike the plain unit test above -- consistent with `test_ccl_8conn.py`/`test_cle_8conn.py`'s failures needing denser/multi-frame patterns to surface. |
| `test_lane_pipeline.py` | **FAIL** -- `test_two_blobs_with_noise` asserts `valid_midpoints` should go high even with salt-and-pepper noise present; DUT reports `lane_valid=0000` for the whole run, so no midpoint is ever asserted. This exercises the full pipeline (`cle_module_8conn` -> `ccl_calc` -> `lane_pair_filter` -> `divider`), so it's consistent with (and doesn't add new information beyond) the CCL/CLE label bugs and the `lane_pair_filter` interface mismatch already documented above -- likely just another symptom of those, not a fourth independent bug. |
| `test_roi.py` | **PASS** (ran to completion this pass, ~137s real time in a single call with a larger time budget instead of backgrounding across calls) -- streams the full 1280x720 frame through `region_of_interest`, no assertion failures. Per its own docstring the test only drives realistic coordinates and logs progress rather than checking output content in detail ("a bring-up harness for future assertions"), so a clean pass here confirms the interface holds up under full-frame throughput, not that ROI's cropping output is pixel-verified. |

## Takeaway

Several of the CCL/CLE and BEV/lane-pairing block-level tests are currently
failing for what look like genuine RTL or test-vs-interface issues, not flaky
setup problems. `test_cle_stress.py` passing while `test_ccl_8conn.py`/
`test_cle_8conn.py` fail suggests the union-find/label-equivalence bug is
pattern-density-dependent rather than universal. `test_lane_pipeline.py`'s
failure looks like it's downstream of the already-documented CCL/CLE and
lane_pair_filter issues rather than a separate bug. Worth a closer look when
there's time to actually dig into the union-find/label-equivalence logic and
the lane-pairing interface history. `test_roi.py` still needs a run with a
much larger time budget than this tool's per-call limit allows.

## Update 2026-07-24: root cause found for the CCL/CLE "label 0" and label-inconsistency failures

Traced this all the way through instead of just re-confirming the symptom. Root cause is a genuine
address-space collision, not a logic typo, and it explains every symptom documented above at once:

**The bug:** `cle_module_8conn.sv`'s single BRAM (`label_table_bram`) is used for two unrelated purposes
that share the same address space with no separation:
1. **Pixel-address space** (Pass 1 main write, Pass 2 initial read): `addr = pixel_idx` (0..`MEM_DEPTH-1`),
   storing "this pixel's assigned label."
2. **Label space** (union-find parent pointers, written in `RESOLVE_MERGE`, read while tracing roots in
   `RESOLVE_FIND_A/B` and `P2_TRAVERSE`): `addr = <a label value>` (1..`next_new_label-1`), storing "this
   label's parent label."

Both use the exact same `addr_a`/`addr_b` and the exact same underlying BRAM entries. Since labels are
small sequential integers starting at 1, `addr = <label N>` is numerically indistinguishable from
`addr = <pixel index N>` — reading "what is label 1's parent?" and reading "what is pixel 1's assigned
label?" hit the identical BRAM entry. Confirmed by instrumenting/reproducing: in `test_single_pixel`
(single FG pixel at pixel_idx 0, label 1 assigned), Pass 2 first reads `addr=0` (pixel space, correctly
gets label `1`), then — per the current code — treats that `1` as an address and reads `addr=1`. Address 1
is *also* a real pixel (pixel index 1, i.e. (1,0)), which is background and was written with label `0`
during Pass 1. `P2_TRAVERSE`'s termination check (`parent_label == addr_b || parent_label == '0`) sees the
stray `0` from that unrelated background pixel's entry and incorrectly treats it as "root found, label 0,"
which is exactly the observed bug. The same aliasing explains `test_ccl_8conn.py`'s "label inconsistency"
failures on denser patterns: two different pixels can resolve through different accidental collisions and
land on different final labels for what should be the same component, since the "root" they converge on
depends on whatever unrelated pixel happens to occupy the aliased address, not on any real union-find
structure. `hdl/ccl_8conn.sv`'s two-pass CCL uses the same BRAM-address-as-label-index pattern (confirmed
by inspection — same `addr_a <= root_b` / `din_a <= {root_a, ...}` shape in its merge logic) and is very
likely hitting the identical bug, though not independently re-traced pixel-by-pixel.

**Why not fixed in this pass:** the correct fix is to give label-space lookups their own address range
(e.g. offset every label-space `addr_a`/`addr_b` by `MEM_DEPTH`, size the BRAM to `2*MEM_DEPTH` deep, and
widen `ADDR_BITS` accordingly) rather than a one-line patch — and because the current code reuses `addr_b`
itself as the "is this a self-loop / root" comparison value (`parent_a == addr_b`), decoupling the two
address spaces means introducing a separate "label currently being traced" signal so that comparison still
means the same thing once addresses are offset. That's edits across `RESOLVE_INIT`, `RESOLVE_FIND_A`,
`RESOLVE_CHECK_A`, `RESOLVE_FIND_B`, `RESOLVE_CHECK_B`, `RESOLVE_MERGE`, and `P2_TRAVERSE` (and the
equivalent states in `ccl_8conn.sv`), touching core FSM control flow in a module with no independent
formal/hardware verification available in this sandbox beyond cocotb simulation. That crosses the line
from "small, confidently verifiable fix" into a real redesign of the label-storage scheme, so it wasn't
attempted blind in an unsupervised run — flagging with the exact mechanism instead so the actual fix (in
both `cle_module_8conn.sv` and `ccl_8conn.sv`) can be scoped and reviewed properly, ideally with a
dedicated session rather than folded into the daily rotation.

## Update 2026-08-01: the ccl_8conn.sv address-aliasing theory doesn't hold up

Re-read `hdl/ccl_8conn.sv` in full to independently re-trace the "very likely hitting
the identical bug" claim from the 07-24 update above, instead of leaving it
unconfirmed. It does not hold up on closer reading: `ccl_8conn.sv` is a genuinely
different, more careful design from `cle_module_8conn.sv`, not just a superficial
match on `addr_a <= root_b` / `din_a <= {root_a, ...}` shape.

The module's own header comment says as much (`BRAM stores parent ADDRESSES (not
compact labels)` / `A root pixel stores its own address: BRAM[addr] = addr`) - unlike
`cle_module_8conn.sv`, there is only one address space here. Parent pointers *are*
literal pixel addresses throughout Pass 1's union-find (`RESOLVE_INIT` through
`RESOLVE_MERGE`) and Pass 2's root-chase (`P2_READ` through `P2_TRAVERSE`), so there's
no pixel-space-vs-label-space collision to alias against. Staleness (distinguishing "a
previous frame wrote this BRAM entry" from "this frame hasn't touched it yet, treat it
as its own root") is instead handled with an explicit 2-bit generation tag
(`GEN_BITS`/`curr_generation`, stored alongside every parent pointer and compared on
every read) rather than by re-purposing `BG_MARKER`/address collisions the way
`cle_module_8conn.sv` does. So the specific address-aliasing bug documented above for
`cle_module_8conn.sv` does not apply to this module - that part of the 07-24 note was
a reasonable hypothesis from the code shape alone, but not correct once you read past
the merge/traverse states into how staleness is actually tracked.

That doesn't mean `ccl_8conn.sv` is bug-free - `test_ccl_8conn.py` genuinely fails 4/12
(`test_chessboard`, `test_vertical_stripes`, `test_labyrinth`,
`test_randomized_multi_frame`, per the run documented above), so there's a real,
separate bug here worth finding. One concrete lead worth checking first, noticed while
reading the generation logic: `GEN_BITS = 2` gives only 4 distinct generation values
(1, 2, 3, 0, 1, 2, 3, 0, ...), and `curr_generation` increments once per frame with no
special-case at the wraparound (`curr_generation <= curr_generation + 1'b1`). Any BRAM
entry that goes 4 frames without being rewritten would have its stale generation tag
alias back onto the current one and get misread as fresh, current-frame data instead
of stale/background - which would line up with `test_randomized_multi_frame` in
particular. This wouldn't explain the three single-frame failures on its own though
(`test_chessboard`/`test_vertical_stripes`/`test_labyrinth` are dense-pattern, not
multi-frame, per their names), so there's likely still a second, independent bug for
those - not traced further this pass. No RTL toolchain (`iverilog`/`cocotb`) was set
up in this pass to actually re-run the suite and confirm either lead against real
simulation output; this is a static-reading correction and a new lead, not a
verified fix - flagging both for whoever picks this up next rather than guessing at a
patch for either without being able to run it.

## Update 2026-08-08: GEN_BITS wraparound theory empirically ruled out for `ccl_8conn.sv`

Got the RTL toolchain running this pass (`iverilog` 11.0 installed from the `.deb`
per the instructions above, `cocotb<2.0`) and actually tested the 07-24/08-01
`GEN_BITS=2` wraparound hypothesis instead of leaving it as an untested lead.

First reran `sim/test_ccl_8conn.py` unmodified to confirm the documented baseline
still holds: 8/12 pass, same 4 failures as every prior run
(`test_chessboard`, `test_vertical_stripes`, `test_labyrinth`,
`test_randomized_multi_frame`), all "Label inconsistency" assertion failures.

Then reran with `GEN_BITS` overridden to 4 (16 distinct generation values instead
of 4) via the test runner's `parameters` dict — `GEN_BITS` is a genuinely free
module parameter here (`ENTRY_WIDTH = ADDR_BITS + GEN_BITS`, BRAM sizes to it
automatically), so this is a clean, non-invasive way to test the theory without
touching FSM logic. If the 08-01 wraparound theory were the (or a) cause,
`test_randomized_multi_frame` — the one test the theory specifically targeted —
should pass or at least change behavior with 4x more headroom before a stale
generation tag could alias back onto the current one over the same 10-frame run.

It didn't: identical 8/12 result, same 4 tests failing, `test_randomized_multi_frame`
still fails on `random_frame_2` (frame 2 of 10 — nowhere near enough frames for
even 4 generation values, let alone 16, to wrap around). This rules out generation
aliasing as the cause for `test_randomized_multi_frame`, not just for the three
single-frame pattern tests the 08-01 note already excluded it from. All 4 failures
now look like symptoms of one shared root cause — most likely the union-find/
label-equivalence bug in the merge logic itself, given that all 4 failing tests are
specifically the denser/multi-component patterns (chessboard, vertical stripes,
a labyrinth maze, and randomized frames with multiple blobs) while every simple
low-component-count test (`test_single_pixel`, `test_diagonal_bridge`,
`test_cross_shape`, `test_two_separate_blobs`, `test_t_shape`,
`test_horizontal_stripes`) passes clean. Reverted the `GEN_BITS=4` test-runner
change after confirming (no source or test file changes kept — this pass only adds
this documentation update).

**Still not attempted:** actually tracing the union-find merge/resolve FSM
(`RESOLVE_INIT` through `RESOLVE_MERGE`, `P2_TRAVERSE`) step-by-step against a
failing multi-component case like `test_chessboard` to find the real bug. That's a
genuine FSM logic trace, not a parameter experiment, and deserves a dedicated
session rather than being squeezed into a daily rotation slot — flagging the
narrowed-down lead (single shared root cause, density/component-count dependent,
not generation-related) for whoever picks this up next.

## Update 2026-08-11: `test_roi.py` run to completion

Previous passes couldn't finish this test because backgrounding a long-running process
doesn't survive across this tool's separate per-call subprocess boundary. Ran it in a
single call with a larger time budget instead (iverilog 11.0 from the `.deb`, `cocotb<2.0`,
same toolchain setup as documented above) and it completed in ~137s real time, passing
cleanly. Table above updated. No RTL or test changes made -- this only closes out the
"couldn't even run it" gap, it doesn't add new content-level assertions to the test itself
(see the row above for what the test does and doesn't check).
