`default_nettype none

`timescale 1ns / 1ps

// Selects the strongest blob on each side of the image center and emits their midpoints.
// Four candidate blobs enter with validity, centroid x/y, and pixel count. The logic keeps
// the two largest-area blobs per side of MID_H (WIDTH/2), biases the lower blob heavier
// when two candidates exist, and asserts valid_midpoints only when both sides are present.
module lane_pair_filter #(
    parameter WIDTH = 706,
    parameter HEIGHT = 146
)(
    input wire clk, 
    input wire rst,
    
    input wire [3:0] cc_valid,
    input wire [10:0] cc_x [3:0],
    input wire [9:0] cc_y [3:0],
    input wire [31:0] cc_pixels [3:0],

    output logic [10:0] left_midpoint,
    output logic [10:0] right_midpoint,
    output logic [10:0] total_midpoint,
    output logic valid_midpoints
);

    localparam MID_H = WIDTH / 2;

    // Stage 1: pick the two largest-area blobs on each side of MID_H (no helper function).
    integer left_top_idx_s1, left_bot_idx_s1;
    integer right_top_idx_s1, right_bot_idx_s1;
    integer left_top_idx_d, left_bot_idx_d;
    integer right_top_idx_d, right_bot_idx_d;

    always_comb begin
        left_top_idx_d  = -1;
        left_bot_idx_d  = -1;
        right_top_idx_d = -1;
        right_bot_idx_d = -1;

        for (integer i = 0; i < 4; i = i + 1) begin
            if (cc_valid[i]) begin
                if (cc_x[i] < MID_H) begin
                    if (left_top_idx_d == -1 || cc_pixels[i] > cc_pixels[left_top_idx_d]) begin
                        left_bot_idx_d = left_top_idx_d;
                        left_top_idx_d = i;
                    end else if (left_bot_idx_d == -1 || cc_pixels[i] > cc_pixels[left_bot_idx_d]) begin
                        left_bot_idx_d = i;
                    end
                end else begin
                    if (right_top_idx_d == -1 || cc_pixels[i] > cc_pixels[right_top_idx_d]) begin
                        right_bot_idx_d = right_top_idx_d;
                        right_top_idx_d = i;
                    end else if (right_bot_idx_d == -1 || cc_pixels[i] > cc_pixels[right_bot_idx_d]) begin
                        right_bot_idx_d = i;
                    end
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            left_top_idx_s1  <= -1;
            left_bot_idx_s1  <= -1;
            right_top_idx_s1 <= -1;
            right_bot_idx_s1 <= -1;
        end else begin
            left_top_idx_s1  <= left_top_idx_d;
            left_bot_idx_s1  <= left_bot_idx_d;
            right_top_idx_s1 <= right_top_idx_d;
            right_bot_idx_s1 <= right_bot_idx_d;
        end
    end

    // Stage 2: midpoint math based on registered indices.
    logic [10:0] left_ccs_midpoint_s2;
    logic [10:0] right_ccs_midpoint_s2;
    logic        left_sel_s2, right_sel_s2;

    always_ff @(posedge clk) begin
        if (rst) begin
            left_ccs_midpoint_s2  <= '0;
            right_ccs_midpoint_s2 <= '0;
            total_midpoint        <= '0;
            left_midpoint         <= '0;
            right_midpoint        <= '0;
            valid_midpoints       <= 1'b0;
        end else begin
            left_ccs_midpoint_s2  <= '0;
            right_ccs_midpoint_s2 <= '0;
            total_midpoint        <= '0;
            left_midpoint         <= '0;
            right_midpoint        <= '0;
            valid_midpoints       <= 1'b0;
            left_sel_s2           <= 1'b0;
            right_sel_s2          <= 1'b0;

            // Left side midpoint: if two candidates, weight bottom heavier; otherwise take single x.
            if (left_top_idx_s1 != -1) begin
                left_sel_s2 <= 1'b1;
                if (left_bot_idx_s1 != -1) begin
                    integer top_idx, bot_idx;
                    if (cc_y[left_top_idx_s1] > cc_y[left_bot_idx_s1]) begin
                        bot_idx = left_top_idx_s1;
                        top_idx = left_bot_idx_s1;
                    end else begin
                        bot_idx = left_bot_idx_s1;
                        top_idx = left_top_idx_s1;
                    end
                    left_ccs_midpoint_s2 <= ((cc_x[bot_idx] * 3) + cc_x[top_idx]) >> 2;
                end else begin
                    left_ccs_midpoint_s2 <= cc_x[left_top_idx_s1];
                end
            end

            // Right side midpoint
            if (right_top_idx_s1 != -1) begin
                right_sel_s2 <= 1'b1;
                if (right_bot_idx_s1 != -1) begin
                    integer top_idx, bot_idx;
                    if (cc_y[right_top_idx_s1] > cc_y[right_bot_idx_s1]) begin
                        bot_idx = right_top_idx_s1;
                        top_idx = right_bot_idx_s1;
                    end else begin
                        bot_idx = right_bot_idx_s1;
                        top_idx = right_top_idx_s1;
                    end
                    right_ccs_midpoint_s2 <= ((cc_x[bot_idx] * 3) + cc_x[top_idx]) >> 2;
                end else begin
                    right_ccs_midpoint_s2 <= cc_x[right_top_idx_s1];
                end
            end

            if (left_sel_s2 && right_sel_s2) begin
                total_midpoint  <= (left_ccs_midpoint_s2 + right_ccs_midpoint_s2) >> 1;
                left_midpoint   <= left_ccs_midpoint_s2;
                right_midpoint  <= right_ccs_midpoint_s2;
                valid_midpoints <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire