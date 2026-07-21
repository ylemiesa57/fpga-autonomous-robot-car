# Simulation status (as of 2026-07-21)

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
| `test_cle_stress.py`, `test_lane_pipeline.py`, `test_roi.py` | Not run this pass -- `test_roi.py` in particular streams a full frame and didn't finish within this tool's ~40s-per-call budget in an earlier attempt. Worth revisiting with more time budgeted per call. |

## Takeaway

Several of the CCL/CLE and BEV/lane-pairing block-level tests are currently
failing for what look like genuine RTL or test-vs-interface issues, not flaky
setup problems. Worth a closer look when there's time to actually dig into the
union-find/label-equivalence logic and the lane-pairing interface history.
