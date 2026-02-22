`timescale 1ns / 1ps
`default_nettype none

// Lightweight wrapper to exercise the BEV FIFO -> CCL -> centroid -> lane pairing chain.
// A small synchronous FIFO feeds cle_module_8conn. Outputs are routed through cc_calculations
// and lane_pair_filter, and key internal signals are exposed for cocotb-driven debug.
// Parameters let simulations stub heavy logic while keeping the wiring honest:
//  - STUB_CCL: replace CCL with a simple raster counter that emits two labels
//  - STUB_PAIR: bypass lane_pair_filter and forward centroid outputs directly
//  - FRONTEND_SLICE: add a FIFO->CCL register slice to mirror top_level timing
//  - PACK_W encodes {new_frame, v, h, pixel} to match top_level packing
module lane_pipeline_wrapper #(
    parameter int WIDTH           = 16,
    parameter int HEIGHT          = 12,
    parameter int LABEL_BITS      = 12,
    parameter int MAX_COMPONENTS  = 8,
    parameter int FIFO_DEPTH      = 64,
    parameter bit STUB_CCL        = 1'b0,
    parameter bit STUB_PAIR       = 1'b0,
    parameter bit FRONTEND_SLICE  = 1'b0,  // mimic top-level FIFO->CCL register slice when set
    // Pack like top_level: {new_frame, v, h, pixel}, sized from WIDTH/HEIGHT
    parameter int PACK_W          = 1 + $clog2(WIDTH) + $clog2(HEIGHT) + 1
)(
    input  wire clk,
    input  wire rst,

    // Stimulus stream (acts like BEV pixel stream)
    input  wire s_axis_valid,
    input  wire s_axis_data,
    output wire s_axis_ready,

    // FIFO -> CCL tap points (packed payload)
    output wire                      bev_fifo_m_valid,
    output wire [PACK_W-1:0]         bev_fifo_m_data,
    output wire                      bev_fifo_m_ready,
    output wire                      bev_fifo_full,
    output wire                      bev_fifo_empty,

    // CCL outputs
    output wire                     ccl_valid,
    output wire [LABEL_BITS-1:0]    ccl_label,
    output wire [$clog2(WIDTH)-1:0] ccl_x,
    output wire [$clog2(HEIGHT)-1:0] ccl_y,
    output wire                     ccl_last,

    // Centroid outputs
    output wire [10:0] lane_h_avg   [0:3],
    output wire [9:0]  lane_v_avg   [0:3],
    output wire [31:0] lane_area    [0:3],
    output wire [3:0]  lane_valid,
    output logic [10:0] lane_h_avg_q[0:3],
    output logic [9:0]  lane_v_avg_q[0:3],
    output logic [31:0] lane_area_q [0:3],
    output logic [3:0]  lane_valid_q,

    // Lane pairing
    output logic       valid_midpoints,
    output logic [10:0] left_midpoint,
    output logic [10:0] right_midpoint,

    // Debug
    output wire [$clog2(FIFO_DEPTH):0] fifo_count_dbg,
    output wire                        ccl_ready_dbg,
    output wire [15:0]                 fg_count_dbg,
    output wire                        ccl_s_axis_valid_dbg,
    output wire                        ccl_s_axis_ready_dbg,
    output wire                        ccl_s_axis_data_dbg,
    output wire [15:0]                 pix_sent_dbg,
    output wire [15:0]                 pix_accepted_dbg,
    // CCL internal debug taps
    output wire [2:0]                  ccl_state_dbg,
    output wire [$clog2(WIDTH*HEIGHT)-1:0] ccl_pix_idx_dbg
);

    // -------------------------------------------------------------------------
    // Tiny synchronous FIFO (packed) between warp and CCL.
    // -------------------------------------------------------------------------
    localparam int FIFO_BITS  = $clog2(FIFO_DEPTH);

    wire  ccl_s_ready;
    // Optional registered slice between FIFO and CCL to mirror top-level timing break.
    logic fifo_out_valid_r;
    logic fifo_out_data_r;
    wire  fifo_out_valid;
    wire  fifo_out_data;
    logic [FIFO_BITS:0] fifo_count;
    logic [PACK_W-1:0]  fifo_mem [0:FIFO_DEPTH-1];
    logic [FIFO_BITS-1:0] wr_ptr, rd_ptr;
    wire  fifo_full, fifo_empty;

    assign fifo_full   = (fifo_count == FIFO_DEPTH);
    assign fifo_empty  = (fifo_count == 0);
    assign s_axis_ready   = ~fifo_full && ccl_s_ready;
    assign bev_fifo_full  = fifo_full;
    assign bev_fifo_empty = fifo_empty;
    assign fifo_count_dbg = {{($clog2(FIFO_DEPTH)+1){1'b0}}} | fifo_count;

    assign bev_fifo_m_valid = ~fifo_empty;
    assign bev_fifo_m_ready = ccl_s_ready;
    assign bev_fifo_m_data  = fifo_mem[rd_ptr];

    assign ccl_ready_dbg        = ccl_s_ready;
    assign ccl_s_axis_valid_dbg = fifo_out_valid;
    assign ccl_s_axis_ready_dbg = ccl_s_ready;
    assign ccl_s_axis_data_dbg  = fifo_out_data;

    logic [15:0] fg_count;
    assign fg_count_dbg = fg_count;
    logic [15:0] pix_sent, pix_acc;
    assign pix_sent_dbg     = pix_sent;
    assign pix_accepted_dbg = pix_acc;

    // h/v counters to pack BEV coordinates with pixels (row-major).
    logic [$clog2(WIDTH)-1:0]  h_ctr;
    logic [$clog2(HEIGHT)-1:0] v_ctr;

    always_ff @(posedge clk) begin
        if (rst) begin
            fifo_count <= '0;
            wr_ptr     <= '0;
            rd_ptr     <= '0;
            fg_count   <= '0;
            pix_sent   <= '0;
            pix_acc    <= '0;
            h_ctr      <= '0;
            v_ctr      <= '0;
        end else begin
            if (s_axis_valid && s_axis_ready) begin
                // Pack like top_level: {new_frame, v, h, pixel}
                fifo_mem[wr_ptr] <= {1'b0, v_ctr, h_ctr, s_axis_data};
                wr_ptr           <= wr_ptr + 1'b1;
                fifo_count       <= fifo_count + 1'b1;
                pix_sent         <= pix_sent + 1'b1;
                // Advance coordinates row-major
                if (h_ctr == WIDTH-1) begin
                    h_ctr <= '0;
                    if (v_ctr == HEIGHT-1)
                        v_ctr <= '0;
                    else
                        v_ctr <= v_ctr + 1'b1;
                end else begin
                    h_ctr <= h_ctr + 1'b1;
                end
            end
            if (fifo_out_valid && ccl_s_ready) begin
                rd_ptr     <= rd_ptr + 1'b1;
                fifo_count <= fifo_count - 1'b1;
                pix_acc    <= pix_acc + 1'b1;
                if (fifo_out_data)
                    fg_count <= fg_count + 1'b1;
            end
        end
    end

    // Optional register slice to break FIFO->CCL combinational path like top-level.
    generate
        if (FRONTEND_SLICE) begin : gen_fe_slice
            always_ff @(posedge clk) begin
                if (rst) begin
                    fifo_out_valid_r <= 1'b0;
                    fifo_out_data_r  <= 1'b0;
                end else begin
                    fifo_out_valid_r <= ~fifo_empty;
                    fifo_out_data_r  <= fifo_mem[rd_ptr][0];
                end
            end
            assign fifo_out_valid = fifo_out_valid_r;
            assign fifo_out_data  = fifo_out_data_r;
        end else begin : gen_direct_path
            assign fifo_out_valid = ~fifo_empty;
            assign fifo_out_data  = fifo_mem[rd_ptr][0];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // CCL (stubbed by default for simulation stability)
    // -------------------------------------------------------------------------
    generate
        if (STUB_CCL) begin : gen_stub_ccl
            // Simple raster counter that emits a label=1 for any foreground pixel.
            logic [$clog2(WIDTH)-1:0]  stub_x;
            logic [$clog2(HEIGHT)-1:0] stub_y;
            assign ccl_ready_dbg = 1'b1;
            assign ccl_s_ready   = 1'b1;
            assign ccl_valid     = fifo_out_valid && fifo_out_data;
            assign ccl_label     = (stub_x < (WIDTH/2)) ? { {(LABEL_BITS-1){1'b0}}, 1'b1 }
                                                        : { {(LABEL_BITS-2){1'b0}}, 2'b10 };
            assign ccl_x         = stub_x;
            assign ccl_y         = stub_y;
            assign ccl_last      = fifo_out_valid && (stub_x == WIDTH-1) && (stub_y == HEIGHT-1);

            always_ff @(posedge clk) begin
                if (rst) begin
                    stub_x <= '0;
                    stub_y <= '0;
                end else if (fifo_out_valid) begin
                    if (stub_x == WIDTH-1) begin
                        stub_x <= '0;
                        if (stub_y == HEIGHT-1)
                            stub_y <= '0;
                        else
                            stub_y <= stub_y + 1'b1;
                    end else begin
                        stub_x <= stub_x + 1'b1;
                    end
                end
            end
        end else begin : gen_real_ccl
            cle_module_8conn #(
                .WIDTH(WIDTH),
                .HEIGHT(HEIGHT),
                .LABEL_BITS(LABEL_BITS),
                .MAX_COMPONENTS(MAX_COMPONENTS)
            ) ccl (
                .clk(clk),
                .rst(rst),
                .s_axis_valid(fifo_out_valid),
                .s_axis_data(fifo_out_data),
                .s_axis_ready(ccl_s_ready),
                .m_axis_valid(ccl_valid),
                .m_axis_label(ccl_label),
                .m_axis_x(ccl_x),
                .m_axis_y(ccl_y),
                .m_axis_last(ccl_last),
                .m_axis_ready(1'b1)
            );
            assign ccl_state_dbg   = ccl.state;
            assign ccl_pix_idx_dbg = ccl.pixel_idx;
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Centroid calculations
    // -------------------------------------------------------------------------
    cc_calculations #(
        .WIDTH(WIDTH),
        .HEIGHT(HEIGHT)
    ) centroid (
        .clk(clk),
        .rst(rst),
        .cc_pixel_valid(ccl_valid),
        .cc_pixel_label(ccl_label),
        .cc_pixel_last(ccl_last),
        .cc_pixel_h(ccl_x),
        .cc_pixel_v(ccl_y),
        .h_avg_pos(lane_h_avg),
        .v_avg_pos(lane_v_avg),
        .blob_area(lane_area),
        .cc_valid_out(lane_valid)
    );

    // Buffer into *_q like top_level does.
    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 4; i = i + 1) begin
                lane_h_avg_q[i] <= '0;
                lane_v_avg_q[i] <= '0;
                lane_area_q[i]  <= '0;
            end
            lane_valid_q <= '0;
        end else begin
            for (i = 0; i < 4; i = i + 1) begin
                lane_h_avg_q[i] <= lane_h_avg[i];
                lane_v_avg_q[i] <= lane_v_avg[i];
                lane_area_q[i]  <= lane_area[i];
            end
            lane_valid_q <= lane_valid;
        end
    end

    // -------------------------------------------------------------------------
    // Lane pairing (real filter)
    // -------------------------------------------------------------------------
    lane_pair_filter #(
        .WIDTH(WIDTH),
        .HEIGHT(HEIGHT)
    ) lane_pairing (
        .clk(clk),
        .rst(rst),
        .cc_valid(lane_valid_q),
        .cc_x(lane_h_avg_q),
        .cc_y(lane_v_avg_q),
        .cc_pixels(lane_area_q),
        .left_midpoint(left_midpoint),
        .right_midpoint(right_midpoint),
        .total_midpoint(),
        .valid_midpoints(valid_midpoints)
    );

endmodule

`default_nettype wire

