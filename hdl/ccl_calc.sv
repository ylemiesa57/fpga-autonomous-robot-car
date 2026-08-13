`default_nettype none

`timescale 1ns / 1ps

module cc_calculations #(
    parameter WIDTH      = 708,
    parameter HEIGHT     = 146,
    parameter MAX_BLOBS  = 4
)(
    input wire clk,
    input wire rst,
    
    // Stream from CCL
    input wire cc_pixel_valid,
    input wire [11:0] cc_pixel_label, 
    // just to be safe we can have as many blobs as we want on our screen! but we only have 4 lane markers
    // so we will only consider 4 blobs on our screen at a time.
    input wire cc_pixel_last,
    input wire [8:0] cc_pixel_h,
    input wire [7:0] cc_pixel_v,
    // Outputs to Lane Pairing
    output logic [10:0] h_avg_pos [0:MAX_BLOBS-1],
    output logic [9:0]  v_avg_pos [0:MAX_BLOBS-1],
    output logic [31:0] blob_area [0:MAX_BLOBS-1],
    output logic [MAX_BLOBS-1:0]  cc_valid_out
);

    // Track accumulated sums for each blob index (1-based labels mapped to 0-based indices).
    logic [31:0] h_pos_sum   [0:MAX_BLOBS-1];
    logic [31:0] v_pos_sum   [0:MAX_BLOBS-1];
    logic [31:0] pixel_tally [0:MAX_BLOBS-1];
    logic [MAX_BLOBS-1:0]  div_in_valid;
    logic [MAX_BLOBS-1:0]  div_h_out_valid;
    logic [MAX_BLOBS-1:0]  div_v_out_valid;
    logic [31:0] div_h_quotient [0:MAX_BLOBS-1];
    logic [31:0] div_v_quotient [0:MAX_BLOBS-1];
    logic [10:0] h_result       [0:MAX_BLOBS-1];
    logic [9:0]  v_result       [0:MAX_BLOBS-1];
    logic [MAX_BLOBS-1:0]  h_ready;
    logic [MAX_BLOBS-1:0]  v_ready;

    integer i;
    integer idx;

    always_ff @(posedge clk) begin
        if (rst) begin
            div_in_valid <= 0;
            cc_valid_out <= 0;
            h_ready <= 0;
            v_ready <= 0;
            for (i = 0; i < MAX_BLOBS; i = i + 1) begin
                h_pos_sum[i] <= 0;
                v_pos_sum[i] <= 0;
                pixel_tally[i] <= 0;
                h_avg_pos[i] <= 0;
                v_avg_pos[i] <= 0;
                blob_area[i] <= 0;
                h_result[i] <= 0;
                v_result[i] <= 0;
            end
        end else begin
            idx = 0;
            // 1. We accumulate centroid sums while the frame is active.
            if (cc_pixel_valid) begin
                if (cc_pixel_label >= 1 && cc_pixel_label <= MAX_BLOBS) begin
                    idx = cc_pixel_label - 1;
                    h_pos_sum[idx]   <= h_pos_sum[idx] + cc_pixel_h;
                    v_pos_sum[idx]   <= v_pos_sum[idx] + cc_pixel_v;
                    pixel_tally[idx] <= pixel_tally[idx] + 1;
                end
            end

            // 2. At end-of-frame we only kick off dividers for blobs that actually saw pixels.
            div_in_valid <= '0;
            if (cc_pixel_last) begin
                for (i = 0; i < MAX_BLOBS; i = i + 1) begin
                    div_in_valid[i] <= (pixel_tally[i] > 5);
                end
            end

            // 3. We add pipelining to the divider results and publish valid blobs once both averages are ready.
            for (i = 0; i < MAX_BLOBS; i = i + 1) begin
                if (div_h_out_valid[i]) begin
                    h_result[i] <= div_h_quotient[i];
                    h_ready[i]  <= 1'b1;
                end
                if (div_v_out_valid[i]) begin
                    v_result[i] <= div_v_quotient[i];
                    v_ready[i]  <= 1'b1;
                end
                if (h_ready[i] && v_ready[i]) begin
                    if (pixel_tally[i] > 5) begin
                        h_avg_pos[i] <= h_result[i];
                        v_avg_pos[i] <= v_result[i];
                        blob_area[i] <= pixel_tally[i];
                        cc_valid_out[i] <= 1;
                    end else begin
                        cc_valid_out[i] <= 0;
                        blob_area[i] <= 0;
                    end
                    // We clear the accumulators so the next frame starts fresh.
                    h_pos_sum[i] <= 0;
                    v_pos_sum[i] <= 0;
                    pixel_tally[i] <= 0;
                    h_ready[i] <= 0;
                    v_ready[i] <= 0;
                end
            end
        end
    end

    // We keep two divider pairs running in parallel.
    generate
        genvar j;
        for (j = 0; j < MAX_BLOBS; j = j + 1) begin : gen_divs
            divider #( .WIDTH(32) ) h_calc (
                .clk(clk),
                .rst(rst),
                .dividend(h_pos_sum[j]),
                .divisor(pixel_tally[j]),
                .data_in_valid(div_in_valid[j]),
                .quotient(div_h_quotient[j]),
                .remainder(),
                .data_out_valid(div_h_out_valid[j]),
                .error(),
                .busy()
            );

            divider #( .WIDTH(32) ) v_calc (
                .clk(clk),
                .rst(rst),
                .dividend(v_pos_sum[j]),
                .divisor(pixel_tally[j]),
                .data_in_valid(div_in_valid[j]),
                .quotient(div_v_quotient[j]),
                .remainder(),
                .data_out_valid(div_v_out_valid[j]),
                .error(),
                .busy()
            );
        end
    endgenerate

endmodule

`default_nettype wire