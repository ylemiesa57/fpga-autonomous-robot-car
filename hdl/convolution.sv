`timescale 1ns / 1ps
`default_nettype none


module convolution #(
    parameter KERNEL_DIMENSION = 3,
    parameter K_SELECT = 0
    )(
    input wire clk,
    input wire rst,
    input wire [KERNEL_DIMENSION-1:0][15:0] data_in,
    input wire [10:0] h_count_in,
    input wire [9:0] v_count_in,
    input wire data_in_valid,
    output logic data_out_valid,
    output logic [10:0] h_count_out,
    output logic [9:0] v_count_out,
    output logic [15:0] line_out
    );

    // Your code here!

    /* Note that the coeffs output of the kernels module
     * is packed in all dimensions, so coeffs should be
     * defined as `logic signed [2:0][2:0][7:0] coeffs`
     *
     * This is because iVerilog seems to be weird about passing
     * signals between modules that are unpacked in more
     * than one dimension - even though this is perfectly
     * fine Verilog.
     */
    
    logic [15:0] pixel_cache [2:0][2:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int r = 0; r < 3; r++) begin
                for (int c = 0; c < 3; c++) begin
                    pixel_cache[r][c] <= '0;
                end
            end
        end else begin
            if (data_in_valid) begin
                // transform pixel_cache
                pixel_cache[0][0] <= pixel_cache[0][1];
                pixel_cache[1][0] <= pixel_cache[1][1];
                pixel_cache[2][0] <= pixel_cache[2][1];
                pixel_cache[0][1] <= pixel_cache[0][2];
                pixel_cache[1][1] <= pixel_cache[1][2];
                pixel_cache[2][1] <= pixel_cache[2][2];
                pixel_cache[0][2] <= data_in[0];
                pixel_cache[1][2] <= data_in[1];
                pixel_cache[2][2] <= data_in[2];
            end
        end

    end

    logic signed [2:0][2:0][7:0] coeffs;
    logic signed [7:0] shift;

    kernels #(
        .K_SELECT(K_SELECT)
    ) kernel_inst(
        .rst(rst),
        .coeffs(coeffs),
        .shift(shift)
    );

    logic signed [9:0] pixel_cache_r_ker [2:0][2:0];
    logic signed [10:0] pixel_cache_g_ker [2:0][2:0];
    logic signed [9:0] pixel_cache_b_ker [2:0][2:0];

    logic signed [22:0] pixel_cache_r_sum;
    logic signed [22:0] pixel_cache_g_sum;
    logic signed [22:0] pixel_cache_b_sum;

    logic [4:0] pixel_cache_r_final;
    logic [5:0] pixel_cache_g_final;
    logic [4:0] pixel_cache_b_final;

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int r = 0; r < 3; r++) begin
                for (int c = 0; c < 3; c++) begin
                    pixel_cache_r_ker[r][c] <= '0;
                    pixel_cache_g_ker[r][c] <= '0;
                    pixel_cache_b_ker[r][c] <= '0;
                end
            end
            pixel_cache_r_sum <= 0;
            pixel_cache_r_final <= 0;
            pixel_cache_g_sum <= 0;
            pixel_cache_g_final <= 0;
            pixel_cache_b_sum <= 0;
            pixel_cache_b_final <= 0;
        end else begin
            // if (data_in_valid) begin
            for (integer i = 0; i < 3; i = i + 1) begin
                for (integer j = 0; j < 3; j = j + 1) begin
                    // mult & shift from kernel (cycle 1)
                    pixel_cache_r_ker[i][j] <= $signed({1'b0, pixel_cache[i][j][15:11]}) * $signed(coeffs[i][j]);
                    pixel_cache_g_ker[i][j] <= $signed({1'b0, pixel_cache[i][j][10:5]}) * $signed(coeffs[i][j]);
                    pixel_cache_b_ker[i][j] <= $signed({1'b0, pixel_cache[i][j][4:0]}) * $signed(coeffs[i][j]);
                end
            end

            // pixel_cache_r_ker[0][0] <= $signed({1'b0, pixel_cache[0][0][15:11]}) * $signed(coeffs[0][0]);
            // pixel_cache_g_ker[0][0] <= $signed({1'b0, pixel_cache[0][0][10:5]}) * $signed(coeffs[0][0]);
            // pixel_cache_b_ker[0][0] <= $signed({1'b0, pixel_cache[0][0][4:0]}) * $signed(coeffs[0][0]);

            // pixel_cache_r_ker[0][1] <= $signed({1'b0, pixel_cache[0][1][15:11]}) * $signed(coeffs[0][1]);
            // pixel_cache_g_ker[0][1] <= $signed({1'b0, pixel_cache[0][1][10:5]}) * $signed(coeffs[0][1]);
            // pixel_cache_b_ker[0][1] <= $signed({1'b0, pixel_cache[0][1][4:0]}) * $signed(coeffs[0][1]);

            // pixel_cache_r_ker[0][2] <= $signed({1'b0, pixel_cache[0][2][15:11]}) * $signed(coeffs[0][2]);
            // pixel_cache_g_ker[0][2] <= $signed({1'b0, pixel_cache[0][2][10:5]}) * $signed(coeffs[0][2]);
            // pixel_cache_b_ker[0][2] <= $signed({1'b0, pixel_cache[0][2][4:0]}) * $signed(coeffs[0][2]);


            // pixel_cache_r_ker[1][0] <= $signed({1'b0, pixel_cache[1][0][15:11]}) * $signed(coeffs[1][0]);
            // pixel_cache_g_ker[1][0] <= $signed({1'b0, pixel_cache[1][0][10:5]}) * $signed(coeffs[1][0]);
            // pixel_cache_b_ker[1][0] <= $signed({1'b0, pixel_cache[1][0][4:0]}) * $signed(coeffs[1][0]);

            // pixel_cache_r_ker[1][1] <= $signed({1'b0, pixel_cache[1][1][15:11]}) * $signed(coeffs[1][1]);
            // pixel_cache_g_ker[1][1] <= $signed({1'b0, pixel_cache[1][1][10:5]}) * $signed(coeffs[1][1]);
            // pixel_cache_b_ker[1][1] <= $signed({1'b0, pixel_cache[1][1][4:0]}) * $signed(coeffs[1][1]);

            // pixel_cache_r_ker[1][2] <= $signed({1'b0, pixel_cache[1][2][15:11]}) * $signed(coeffs[1][2]);
            // pixel_cache_g_ker[1][2] <= $signed({1'b0, pixel_cache[1][2][10:5]}) * $signed(coeffs[1][2]);
            // pixel_cache_b_ker[1][2] <= $signed({1'b0, pixel_cache[1][2][4:0]}) * $signed(coeffs[1][2]);


            // pixel_cache_r_ker[2][0] <= $signed({1'b0, pixel_cache[2][0][15:11]}) * $signed(coeffs[2][0]);
            // pixel_cache_g_ker[2][0] <= $signed({1'b0, pixel_cache[2][0][10:5]}) * $signed(coeffs[2][0]);
            // pixel_cache_b_ker[2][0] <= $signed({1'b0, pixel_cache[2][0][4:0]}) * $signed(coeffs[2][0]);

            // pixel_cache_r_ker[2][1] <= $signed({1'b0, pixel_cache[2][1][15:11]}) * $signed(coeffs[2][1]);
            // pixel_cache_g_ker[2][1] <= $signed({1'b0, pixel_cache[2][1][10:5]}) * $signed(coeffs[2][1]);
            // pixel_cache_b_ker[2][1] <= $signed({1'b0, pixel_cache[2][1][4:0]}) * $signed(coeffs[2][1]);

            // pixel_cache_r_ker[2][2] <= $signed({1'b0, pixel_cache[2][2][15:11]}) * $signed(coeffs[2][2]);
            // pixel_cache_g_ker[2][2] <= $signed({1'b0, pixel_cache[2][2][10:5]}) * $signed(coeffs[2][2]);
            // pixel_cache_b_ker[2][2] <= $signed({1'b0, pixel_cache[2][2][4:0]}) * $signed(coeffs[2][2]);

            // combine r, g, b (cycle 2)
            pixel_cache_r_sum <= (pixel_cache_r_ker[0][0] + pixel_cache_r_ker[0][1] + pixel_cache_r_ker[0][2] + pixel_cache_r_ker[1][0] + pixel_cache_r_ker[1][1] + pixel_cache_r_ker[1][2] + pixel_cache_r_ker[2][0] + pixel_cache_r_ker[2][1] + pixel_cache_r_ker[2][2]) >>> shift;
            pixel_cache_g_sum <= (pixel_cache_g_ker[0][0] + pixel_cache_g_ker[0][1] + pixel_cache_g_ker[0][2] + pixel_cache_g_ker[1][0] + pixel_cache_g_ker[1][1] + pixel_cache_g_ker[1][2] + pixel_cache_g_ker[2][0] + pixel_cache_g_ker[2][1] + pixel_cache_g_ker[2][2]) >>> shift;
            pixel_cache_b_sum <= (pixel_cache_b_ker[0][0] + pixel_cache_b_ker[0][1] + pixel_cache_b_ker[0][2] + pixel_cache_b_ker[1][0] + pixel_cache_b_ker[1][1] + pixel_cache_b_ker[1][2] + pixel_cache_b_ker[2][0] + pixel_cache_b_ker[2][1] + pixel_cache_b_ker[2][2]) >>> shift;

            // restrict value to normal size for r, g, & b (cycle 3)
            if ((pixel_cache_r_sum) > 31) begin
                pixel_cache_r_final <= 5'd31;
            end else if ((pixel_cache_r_sum) < 0) begin
                pixel_cache_r_final <= 5'd0;
            end else begin
                pixel_cache_r_final <= pixel_cache_r_sum[4:0];
            end

            if ((pixel_cache_g_sum) > 63) begin
                pixel_cache_g_final <= 6'd63;
            end else if ((pixel_cache_g_sum) < 0) begin
                pixel_cache_g_final <= 6'd0;
            end else begin
                pixel_cache_g_final <= pixel_cache_g_sum[5:0];
            end

            if ((pixel_cache_b_sum) > 31) begin
                pixel_cache_b_final <= 5'd31;
            end else if ((pixel_cache_b_sum) < 0) begin
                pixel_cache_b_final <= 5'd0;
            end else begin
                pixel_cache_b_final <= pixel_cache_b_sum[4:0];
            end
        end
        // end
    end

    logic [15:0] line_out_data;
    assign line_out_data = {pixel_cache_r_final, pixel_cache_g_final, pixel_cache_b_final};

    // pipelining (h_count_out, v_count_out, data_out_valid)
    logic [10:0] h_count_out_pipe[3:0];
    logic [9:0] v_count_out_pipe[3:0];
    logic data_out_valid_pipe[3:0];

    always_ff @(posedge clk) begin
        // Make sure to have your output be set with registered logic!
        // Otherwise you'll have timing violations.
        h_count_out_pipe[0] <= h_count_in;
        v_count_out_pipe[0] <= v_count_in;
        data_out_valid_pipe[0] <= data_in_valid;
        for (int i = 1; i < 4; i = i + 1) begin
            h_count_out_pipe[i] <= h_count_out_pipe[i - 1];
            v_count_out_pipe[i] <= v_count_out_pipe[i - 1];
            data_out_valid_pipe[i] <= data_out_valid_pipe[i - 1];
        end
    end

    assign data_out_valid = data_out_valid_pipe[3];
    assign h_count_out = h_count_out_pipe[3];
    assign v_count_out = v_count_out_pipe[3];
    assign line_out = line_out_data;
endmodule

`default_nettype wire

