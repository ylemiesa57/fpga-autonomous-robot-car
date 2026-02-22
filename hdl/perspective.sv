`default_nettype none
`timescale 1ns / 1ps

module perspective_warping #(
    parameter int BEV_HRES = 708,
    parameter int BEV_VRES = 146
)(
    input wire clk_pixel,
    input wire rst,
    input wire start,
    input wire ccl_ready_in, 

    // LUT Interface (Address = 320*180 ~ 57k -> 16 bits is fine)
    output logic [16:0] lut_read_addr,
    // LUT Data (Content = ROI Index ~ 103k -> NEEDS 17 BITS)
    input wire [16:0]   lut_read_data, 

    // ROI Buffer Interface
    output logic [16:0] roi_bram_read_addr,
    input wire          roi_bram_read_data,

    // BEV Stream Output
    output logic        bev_pixel_out,
    output logic        bev_valid_out,
    output logic [$clog2(BEV_HRES)-1:0]  bev_h_count_out,
    output logic [$clog2(BEV_VRES)-1:0]  bev_v_count_out,
    output logic        bev_new_frame_out
);

    localparam int BEV_H_BITS = $clog2(BEV_HRES);
    localparam int BEV_V_BITS = $clog2(BEV_VRES);

    logic [BEV_H_BITS-1:0] h_count;
    logic [BEV_V_BITS-1:0] v_count;
    logic       frame_active;
    
    // Pipeline Enable
    logic pipe_en;
    assign pipe_en = ccl_ready_in; 

    always_ff @(posedge clk_pixel) begin
        if (rst) begin
            h_count <= 0;
            v_count <= 0;
            frame_active <= 0;
            lut_read_addr <= 0;
        end else if (start && !frame_active) begin
            frame_active <= 1;
            h_count <= 0;
            v_count <= 0;
            lut_read_addr <= 0; // Reset address pointer
        end else if (frame_active && pipe_en) begin
            // OPTIMIZATION: Just increment address instead of multiplying v*320+h
            lut_read_addr <= lut_read_addr + 1;
            
            if (h_count == BEV_HRES-1) begin
                h_count <= 0;
                if (v_count == BEV_VRES-1) begin
                    v_count <= 0;
                    frame_active <= 0; 
                    lut_read_addr <= 0; // Reset for safety
                end else begin
                    v_count <= v_count + 1;
                end
            end else begin
                h_count <= h_count + 1;
            end
        end
    end

    // --- Pipeline Delays (latency compensation) ---
    logic [BEV_H_BITS-1:0] h_d [6:0];
    logic [BEV_V_BITS-1:0] v_d [6:0];
    logic       val_d [6:0];
    logic       nf_d [6:0];

    always_ff @(posedge clk_pixel) begin
        if (rst) begin
            for (int i = 0; i < 7; i++) begin
                h_d[i] <= 0; v_d[i] <= 0; val_d[i] <= 0; nf_d[i] <= 0;
            end
            roi_bram_read_addr <= 0;
        end else if (pipe_en) begin
            // Stage 1 Input
            h_d[0] <= h_count;
            v_d[0] <= v_count;
            val_d[0] <= frame_active;
            nf_d[0] <= (frame_active && h_count == 0 && v_count == 0);

            // Shift Stages
            for (int i = 0; i < 6; i++) begin
                h_d[i+1] <= h_d[i];
                v_d[i+1] <= v_d[i];
                val_d[i+1] <= val_d[i];
                nf_d[i+1] <= nf_d[i];
            end
            
            // Memory Data Path
            // Cycle 0: lut_read_addr set
            // Cycle 1: LUT internal read
            // Cycle 2: lut_read_data available -> Assign to ROI Addr
            roi_bram_read_addr <= lut_read_data; 
            
            // Cycle 3: ROI internal read
            // Cycle 4: roi_bram_read_data available -> Output
        end
    end

    // Output Assignments
    always_ff @(posedge clk_pixel) begin
        if (rst) begin
            bev_valid_out <= 0;
        end else if (pipe_en) begin
            bev_pixel_out     <= roi_bram_read_data;
            bev_h_count_out   <= h_d[6];
            bev_v_count_out   <= v_d[6];
            bev_new_frame_out <= nf_d[6];
            bev_valid_out     <= val_d[6];
        end
    end

endmodule