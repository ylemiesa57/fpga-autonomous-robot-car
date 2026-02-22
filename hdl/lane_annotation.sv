`timescale 1ns / 1ps
`default_nettype none

// Tiny overlay renderer: we paint a full-height bar anywhere the HDMI raster column matches a lane X coordinate.
// CROSS_HALF becomes the horizontal tolerance (how many pixels around the centroid column we still treat as “on”).
module lane_annotation #(
    parameter integer CROSS_HALF = 2
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        lanes_valid,
    input  wire [10:0] lane_left_x,
    input  wire [10:0] lane_right_x,
    input  wire [10:0] lane_mid_x,
    input  wire [10:0] h_count,
    input  wire [9:0]  v_count,
    output logic       overlay_active,
    output logic [7:0] overlay_red,
    output logic [7:0] overlay_green,
    output logic [7:0] overlay_blue
);

    logic [10:0] left_dx;
    logic [10:0] right_dx;
    logic [10:0] mid_dx;
    logic [10:0] left_dy;
    logic [10:0] right_dy;
    logic        left_column_on;
    logic        right_column_on;
    logic        mid_column_on;
    logic        center_column_on;

    always_comb begin
        center_column_on = (h_count == 11'd640); // fixed center column (1280/2) always white

        if (lane_left_x >= h_count)
            left_dx = lane_left_x - h_count;
        else
            left_dx = h_count - lane_left_x;

        if (lane_right_x >= h_count)
            right_dx = lane_right_x - h_count;
        else
            right_dx = h_count - lane_right_x;

        if (lane_mid_x >= h_count)
            mid_dx = lane_mid_x - h_count;
        else
            mid_dx = h_count - lane_mid_x;

        left_column_on  = lanes_valid && (left_dx  <= CROSS_HALF);
        right_column_on = lanes_valid && (right_dx <= CROSS_HALF);
        mid_column_on   = lanes_valid && (mid_dx   <= CROSS_HALF);
        
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            overlay_active <= 1'b0;
            overlay_red    <= 8'd0;
            overlay_green  <= 8'd0;
            overlay_blue   <= 8'd0;
        end else begin
            if (center_column_on || left_column_on || right_column_on || mid_column_on) begin
                overlay_active <= 1'b1;
                // priority: center white > both edges white > mid yellow > left red > right cyan
                if (center_column_on) begin
                    overlay_red   <= 8'hFF;
                    overlay_green <= 8'hFF;
                    overlay_blue  <= 8'hFF;
                end else if (left_column_on && right_column_on) begin
                    overlay_red   <= 8'hFF;
                    overlay_green <= 8'hFF;
                    overlay_blue  <= 8'hFF;
                end else if (mid_column_on) begin
                    overlay_red   <= 8'hFF;
                    overlay_green <= 8'hFF;
                    overlay_blue  <= 8'h20;
                end else if (left_column_on) begin
                    overlay_red   <= 8'hFF;
                    overlay_green <= 8'h20;
                    overlay_blue  <= 8'h20;
                end else begin
                    overlay_red   <= 8'h20;
                    overlay_green <= 8'hFF;
                    overlay_blue  <= 8'hFF;
                end
            end else begin
                overlay_active <= 1'b0;
                overlay_red    <= 8'd0;
                overlay_green  <= 8'd0;
                overlay_blue   <= 8'd0;
            end
        end
    end

endmodule

`default_nettype wire

