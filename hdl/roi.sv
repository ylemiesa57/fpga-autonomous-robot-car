`default_nettype none
`timescale 1ns / 1ps
module region_of_interest #(
    parameter MIN_H = 296,
    parameter MAX_H = 1004,
    parameter MIN_V = 574,
    parameter MAX_V = 720,
    parameter PIXEL_WIDTH = 16,
    parameter ROI_WIDTH = MAX_H - MIN_H + 1,
    parameter ROI_HEIGHT = MAX_V - MIN_V + 1,
    parameter ROI_DEPTH = ROI_WIDTH * ROI_HEIGHT,
    parameter ROI_SIZE = $clog2(ROI_DEPTH)
)(
    input wire clk, 
    input wire rst,
    input wire valid,
    input wire [10:0] h_count,
    input wire [9:0] v_count,
    input wire [PIXEL_WIDTH-1:0] pixel_data,
    output logic [ROI_SIZE-1:0] addra,
    output logic valid_roi_mem,
    output logic [PIXEL_WIDTH-1:0] roi_mem
);

    always_ff @(posedge clk) begin
        if (rst) begin
            addra <= 0;
            valid_roi_mem <= 0;
            roi_mem <= 0;
        end else begin
            if (valid &&
                (h_count >= MIN_H && h_count <= MAX_H) &&
                (v_count >= MIN_V && v_count <= MAX_V)) begin
                addra <= (h_count - MIN_H) + ((v_count - MIN_V) * ROI_WIDTH);
                valid_roi_mem <= 1'b1;
                roi_mem <= pixel_data;
            end else begin
                valid_roi_mem <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire