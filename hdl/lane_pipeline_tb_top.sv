`timescale 1ns / 1ps
`default_nettype none

module lane_pipeline_tb_top #(
    parameter int PIPE_WIDTH = 200,
    parameter int PIPE_HEIGHT = 180
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        cc_pixel_valid,
    input  wire [11:0] cc_pixel_label,
    input  wire        cc_pixel_last,
    input  wire [8:0]  cc_pixel_h,
    input  wire [7:0]  cc_pixel_v,
    output wire [3:0]  blob_valid,
    output wire [31:0] blob_x0,
    output wire [31:0] blob_x1,
    output wire [31:0] blob_x2,
    output wire [31:0] blob_x3,
    output wire [31:0] blob_y0,
    output wire [31:0] blob_y1,
    output wire [31:0] blob_y2,
    output wire [31:0] blob_y3,
    output wire [31:0] blob_area0,
    output wire [31:0] blob_area1,
    output wire [31:0] blob_area2,
    output wire [31:0] blob_area3,
    output wire        lanes_valid,
    output wire [31:0] lane_left_x,
    output wire [31:0] lane_left_y,
    output wire [31:0] lane_right_x,
    output wire [31:0] lane_right_y
);

    wire [31:0] lane_h_avg [0:3];
    wire [31:0] lane_v_avg [0:3];
    wire [31:0] lane_area [0:3];
    wire [3:0]  lane_valid;

    cc_calculations #(
        .WIDTH(PIPE_WIDTH),
        .HEIGHT(PIPE_HEIGHT)
    ) lane_calc (
        .clk(clk),
        .rst(rst),
        .cc_pixel_valid(cc_pixel_valid),
        .cc_pixel_label(cc_pixel_label),
        .cc_pixel_last(cc_pixel_last),
        .cc_pixel_h(cc_pixel_h),
        .cc_pixel_v(cc_pixel_v),
        .h_avg_pos(lane_h_avg),
        .v_avg_pos(lane_v_avg),
        .blob_area(lane_area),
        .cc_valid_out(lane_valid)
    );

    assign blob_valid = lane_valid;
    assign blob_x0 = lane_h_avg[0];
    assign blob_x1 = lane_h_avg[1];
    assign blob_x2 = lane_h_avg[2];
    assign blob_x3 = lane_h_avg[3];
    assign blob_y0 = lane_v_avg[0];
    assign blob_y1 = lane_v_avg[1];
    assign blob_y2 = lane_v_avg[2];
    assign blob_y3 = lane_v_avg[3];
    assign blob_area0 = lane_area[0];
    assign blob_area1 = lane_area[1];
    assign blob_area2 = lane_area[2];
    assign blob_area3 = lane_area[3];

    lane_pair_filter #(
        .WIDTH(PIPE_WIDTH),
        .HEIGHT(PIPE_HEIGHT),
        .MIN_AREA(16),
        .MAX_AREA(32'h7fff_ffff),
        .MIN_LANE_WIDTH(PIPE_WIDTH/6),
        .MAX_LANE_WIDTH(PIPE_WIDTH),
        .MAX_Y_DELTA(PIPE_HEIGHT/2)
    ) lane_pair (
        .clk(clk),
        .rst(rst),
        .blob_x0(blob_x0),
        .blob_x1(blob_x1),
        .blob_x2(blob_x2),
        .blob_x3(blob_x3),
        .blob_y0(blob_y0),
        .blob_y1(blob_y1),
        .blob_y2(blob_y2),
        .blob_y3(blob_y3),
        .blob_area0(blob_area0),
        .blob_area1(blob_area1),
        .blob_area2(blob_area2),
        .blob_area3(blob_area3),
        .blob_valid(blob_valid),
        .lanes_valid(lanes_valid),
        .lane_left_x(lane_left_x),
        .lane_left_y(lane_left_y),
        .lane_right_x(lane_right_x),
        .lane_right_y(lane_right_y),
        .active_mask()
    );

endmodule

`default_nettype wire

