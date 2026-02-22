`timescale 1ns / 1ps
`default_nettype none

// Camera-to-HDMI top integration: generates all clock domains, captures the
// OV7670-style camera bus, blurs/warps the frame into bird's-eye view, runs
// CCL/centroid/lane pairing, and overlays results on the HDMI output while
// also feeding motor/PWM controls. LEDs and switches expose debug status
// (clock locks, overlay enable, lane validity) without needing a logic analyzer.
module top_level
    (
        input wire          clk_100mhz,
        output logic [15:0] led,
        // camera bus
        input wire [7:0]    camera_d, // 8 parallel data wires
        output logic        cam_xclk, // XC driving camera
        input wire          cam_h_sync, // camera h_sync wire
        input wire          cam_v_sync, // camera v_sync wire
        input wire          cam_pclk, // camera pixel clock
        inout wire          i2c_scl, // i2c inout clock
        inout wire          i2c_sda, // i2c inout data
        input wire [15:0]   sw,
        input wire [3:0]    btn,
        output logic [2:0]  rgb0,
        output logic [2:0] rgb1,
        // motor PH/EN (PMOD-B)
        output logic        left_motor_en,
        output logic        left_motor_ph,
        output logic        right_motor_en,
        output logic        right_motor_ph,
        // hdmi port
        output logic [2:0]  hdmi_tx_p, //hdmi output signals (positives) (blue, green, red)
        output logic [2:0]  hdmi_tx_n, //hdmi output signals (negatives) (blue, green, red)
        output logic        hdmi_clk_p, hdmi_clk_n, //differential hdmi clock
        // SDRAM (DDR3) ports
        inout wire [15:0]   ddr3_dq, //data input/output
        inout wire [1:0]    ddr3_dqs_n, //data input/output differential strobe (negative)
        inout wire [1:0]    ddr3_dqs_p, //data input/output differential strobe (positive)
        output wire [13:0]  ddr3_addr, //address
        output wire [2:0]   ddr3_ba, //bank address
        output wire         ddr3_ras_n, //row active strobe
        output wire         ddr3_cas_n, //column active strobe
        output wire         ddr3_we_n, //write enable
        output wire         ddr3_reset_n, //reset (active low!!!)
        output wire         ddr3_clk_p, //general differential clock (p)
        output wire         ddr3_clk_n, //general differential clock (n)
        output wire         ddr3_clke, //clock enable
        output wire [1:0]   ddr3_dm, //data mask
        output wire         ddr3_odt //on-die termination (helps impedance match)
    );

    // Turn off LEDs
    assign rgb1 = 0;

    // Clock and Reset Signals
    logic          sys_rst_camera;
    logic          sys_rst_pixel;
    logic          sys_rst_controller;

    logic          clk_camera;
    logic          clk_pixel;
    logic          clk_5x;
    logic          clk_xc;

    logic clk_camera_locked;

    logic          clk_100_passthrough;

    // clocking wizards to generate the clock speeds we need for our different domains
    // clk_camera: 200MHz, fast enough to comfortably sample the cameera's PCLK (50MHz)
    cw_hdmi_clk_wiz wizard_hdmi(
        .sysclk(clk_100_passthrough),
        .clk_pixel(clk_pixel),
        .clk_tmds(clk_5x),
        .reset(0)
    );

    logic clk_controller;
    logic clk_ddr3;
    logic i_ref_clk;
    logic clk_ddr3_90;

    logic lab06_clk_locked;

    lab06_clk_wiz lcw(
        .reset(btn[0]),
        .clk_in1(clk_100mhz),
        .clk_camera(clk_camera),
        .clk_xc(clk_xc),
        .clk_passthrough(clk_100_passthrough),
        .clk_controller(clk_controller),
        .clk_ddr3(clk_ddr3),
        .clk_ddr3_90(clk_ddr3_90),
        .locked(lab06_clk_locked)
    );

    assign i_ref_clk = clk_camera;

    (* mark_debug = "true" *) wire ddr3_clk_locked;

    assign ddr3_clk_locked = lab06_clk_locked;
    assign clk_camera_locked = lab06_clk_locked;

    // assign camera's xclk to pmod port: drive the operating clock of the camera!
    // this port also is specifically set to high drive by the XDC file.
    assign cam_xclk = clk_xc;
    // assign sys_rst_camera = btn[0]; //use for resetting camera side of logic
    // assign sys_rst_pixel = btn[0]; //use for resetting hdmi/draw side of logic

    // video signal generator signals
    logic           h_sync_hdmi;
    logic           v_sync_hdmi;
    logic [10:0]    h_count_hdmi;
    logic [9:0]     v_count_hdmi;
    logic           active_draw_hdmi;
    logic           new_frame_hdmi;
    logic [5:0]     frame_count_hdmi;

    // rgb output values
    logic [7:0]     red,green,blue;

    // ** Handling input from the camera **

    // synchronizers to prevent metastability
    logic [7:0]     camera_d_buf [1:0];
    logic           cam_h_sync_buf [1:0];
    logic           cam_v_sync_buf [1:0];
    logic           cam_pclk_buf [1:0];

    logic           sys_rst_camera_buf [1:0];
    logic           sys_rst_pixel_buf [1:0];
    logic           sys_rst_controller_buf [1:0];

    always_ff @(posedge clk_pixel )begin
        sys_rst_pixel_buf <= {btn[0], sys_rst_pixel_buf[1]};
    end
    assign sys_rst_pixel = sys_rst_pixel_buf[0];

    always_ff @(posedge clk_controller )begin
        sys_rst_controller_buf <= {btn[0], sys_rst_controller_buf[1]};
    end
    assign sys_rst_controller = sys_rst_controller_buf[0];

    always_ff @(posedge clk_camera) begin
        camera_d_buf <= {camera_d, camera_d_buf[1]};
        cam_pclk_buf <= {cam_pclk, cam_pclk_buf[1]};
        cam_h_sync_buf <= {cam_h_sync, cam_h_sync_buf[1]};
        cam_v_sync_buf <= {cam_v_sync, cam_v_sync_buf[1]};
        sys_rst_camera_buf <= {btn[0], sys_rst_camera_buf[1]};
    end

    assign sys_rst_camera = sys_rst_camera_buf[0] || !clk_camera_locked;

    logic [10:0]    camera_h_count;
    logic [9:0]     camera_v_count;
    logic [15:0]    camera_pixel;
    logic           camera_valid;

    // pixel_reconstruct module
    // hook it up to buffered inputs.
    pixel_reconstruct pixel_reconstruct_inst (
        .clk(clk_camera),
        .rst(sys_rst_camera),
        .camera_pclk(cam_pclk_buf[0]),
        .camera_h_sync(cam_h_sync_buf[0]),
        .camera_v_sync(cam_v_sync_buf[0]),
        .camera_data(camera_d_buf[0]),
        .pixel_valid(camera_valid),
        .pixel_h_count(camera_h_count),
        .pixel_v_count(camera_v_count),
        .pixel_data(camera_pixel)
    );

    // CDC: move from camera clock to pixel clock, then blur in pixel domain
    logic        cdc_empty;
    logic        cdc_valid;
    logic [15:0] cdc_pixel;
    logic [10:0] cdc_h_count;
    logic [9:0]  cdc_v_count;

    // 1280x720 convolution of gaussian blur (pixel domain, post-CDC)
    logic [10:0] fgb_h_count;  // h_count from filter module
    logic [9:0]  fgb_v_count;  // v_count from filter module
    logic [15:0] fgb_pixel;    // pixel data from filter module
    logic        fgb_valid;    // valid signal for filter module

    logic [15:0] frame_buff_dram; // data out of DRAM frame buffer

    // write memory to DRAM and read it
    // out, over a couple AXI-Stream data pipelines.

    // the high_definition_frame_buffer module does all of the
    // "top-level wiring" for the FIFOs, the stacker and unstacker
    // traffic generator, and the IP memory controller.
    // it needs:
    // 1. filtered pixel input, to write to the frame buffer
    // 2. output connection to the HDMI/ next segment output
    // 3. the wires that connect to our DRAM chip

    // CDC FIFO: camera domain -> pixel domain
    xpm_fifo_async #(
       .CASCADE_HEIGHT(0),
       .CDC_SYNC_STAGES(2),
       .DOUT_RESET_VALUE("0"),
       .ECC_MODE("no_ecc"),
       .EN_SIM_ASSERT_ERR("warning"),
       .FIFO_MEMORY_TYPE("auto"),
       .FIFO_READ_LATENCY(1),
       .FIFO_WRITE_DEPTH(64),
       .FULL_RESET_VALUE(0),
       .PROG_EMPTY_THRESH(10),
       .PROG_FULL_THRESH(10),
       .RD_DATA_COUNT_WIDTH(1),
       .READ_DATA_WIDTH(37),
       .READ_MODE("std"),
       .RELATED_CLOCKS(0),
       .SIM_ASSERT_CHK(0),
       .USE_ADV_FEATURES("0707"),
       .WAKEUP_TIME(0),
       .WRITE_DATA_WIDTH(37),
       .WR_DATA_COUNT_WIDTH(1)
    ) cdc_fifo (
        .wr_clk(clk_camera),
        .full(),
        .din({camera_h_count, camera_v_count, camera_pixel}),
        .wr_en(camera_valid),
        .rd_clk(clk_pixel),
        .empty(cdc_empty),
        .dout({cdc_h_count, cdc_v_count, cdc_pixel}),
        .rd_en(1'b1)
    );
    assign cdc_valid = ~cdc_empty;

    // Gaussian blur in pixel domain after CDC
    filter #(.K_SELECT(1), .HRES(1280), .VRES(720)) filter_blur (
        .clk(clk_pixel),
        .rst(sys_rst_pixel),
        .data_in_valid(cdc_valid),
        .pixel_data_in(cdc_pixel),
        .h_count_in(cdc_h_count),
        .v_count_in(cdc_v_count),
        .data_out_valid(fgb_valid),
        .pixel_data_out(fgb_pixel),
        .h_count_out(fgb_h_count),
        .v_count_out(fgb_v_count)
    );

    high_definition_frame_buffer highdef_fb(
        // Input data from camera/pixel reconstructor
        .clk_camera      (clk_pixel),       // write side now in pixel domain after CDC/blur
        .sys_rst_camera  (sys_rst_pixel),
        .camera_valid    (fgb_valid),
        .camera_pixel    (fgb_pixel),
        .camera_h_count  (fgb_h_count),
        .camera_v_count  (fgb_v_count),
        
        // Output data to HDMI display pipeline
        .clk_pixel       (clk_pixel),
        .sys_rst_pixel   (sys_rst_pixel),
        .active_draw_hdmi(active_draw_hdmi),
        .h_count_hdmi    (h_count_hdmi[10:0]),
        .v_count_hdmi    (v_count_hdmi[9:0]),
        .frame_buff_dram (frame_buff_dram[15:0]),

        // Clock/reset signals for UberDDR3 controller
        .clk_controller  (clk_controller),
        .clk_ddr3        (clk_ddr3),
        .clk_ddr3_90     (clk_ddr3_90),
        .i_ref_clk       (i_ref_clk),
        .i_rst           (sys_rst_controller),
        .ddr3_clk_locked (ddr3_clk_locked),

        // Bus wires to connect FPGA to SDRAM chip
        .ddr3_dq         (ddr3_dq[15:0]),
        .ddr3_dqs_n      (ddr3_dqs_n[1:0]),
        .ddr3_dqs_p      (ddr3_dqs_p[1:0]),
        .ddr3_addr       (ddr3_addr[13:0]),
        .ddr3_ba         (ddr3_ba[2:0]),
        .ddr3_ras_n      (ddr3_ras_n),
        .ddr3_cas_n      (ddr3_cas_n),
        .ddr3_we_n       (ddr3_we_n),
        .ddr3_reset_n    (ddr3_reset_n),
        .ddr3_clk_p      (ddr3_clk_p),
        .ddr3_clk_n      (ddr3_clk_n),
        .ddr3_clke       (ddr3_clke),
        .ddr3_dm         (ddr3_dm[1:0]),
        .ddr3_odt        (ddr3_odt)
    );
    
    // NEW DRAM STUFF ENDS HERE: below here should look familiar from last week!

    // IMAGE PROCESSING

    //split frame_buff into 3 8 bit color channels (5:6:5 adjusted accordingly)
    //these drive the HDMI path directly from DDR rather than from the filtered stream
    logic [7:0] fb_red, fb_green, fb_blue;
    always_ff @(posedge clk_pixel) begin
        fb_red   <= {frame_buff_dram[15:11], 3'b0};
        fb_green <= {frame_buff_dram[10:5],  2'b0};
        fb_blue  <= {frame_buff_dram[4:0],  3'b0};
    end

    // Base video plane that the overlay mux will fall back to.
    // Drive it directly from the frame buffer taps so we always
    // have camera imagery underlaying the debug graphics.
    always_ff @(posedge clk_pixel) begin
        if (sys_rst_pixel) begin
            red   <= 8'h00;
            green <= 8'h00;
            blue  <= 8'h00;
        end else begin
            red   <= fb_red;
            green <= fb_green;
            blue  <= fb_blue;
        end
    end
 
    // RGB to YCrCb

    //output of rgb to ycrcb conversion (10 bits due to module):
    logic [9:0] y_full, cr_full, cb_full; //ycrcb conversion of full pixel
    //bottom 8 of y, cr, cb conversions:
    logic [7:0] y, cr, cb; //ycrcb conversion of full pixel
    //Convert RGB of full pixel to YCrCb
    //See lecture 07 for YCrCb discussion.
    //Module has a 3 cycle latency
    rgb_to_ycrcb rgbtoycrcb_m(
        .clk(clk_pixel),
        .r(fb_red),
        .g(fb_green),
        .b(fb_blue),
        .y(y_full),
        .cr(cr_full),
        .cb(cb_full)
    );

    //take lower 8 of full outputs.
    // treat cr as signed numbers, invert the MSB to get an unsigned equivalent ( [-128,128) maps to [0,256) )
    assign cr = {!cr_full[7],cr_full[6:0]};

    //threshold module (apply masking threshold):
    logic [7:0] lower_threshold;
    logic [7:0] upper_threshold;
    logic mask; //Whether or not thresholded pixel is 1 or 0

    //threshold values used to determine what value  passes:
    assign lower_threshold = 8'b10010000;
    assign upper_threshold = 8'b11100000;

    //Thresholder: Takes in the full selected channel and
    //based on upper and lower bounds provides a binary mask bit
    // * 1 if selected channel is within the bounds (inclusive)
    // * 0 if selected channel is not within the bounds
    threshold mt(
       .clk(clk_pixel),
       .rst(sys_rst_pixel),
       .pixel(cr),
       .lower_bound(lower_threshold),
       .upper_bound(upper_threshold),
       .mask(mask) //single bit if pixel within mask.
    );

    // We downsample the 1280x720 mask by 4 in both directions so the BEV path works on ~320x180 data.
    // Bump to 2-bit shifts (divide by 4) to shrink ROI/LUT BRAM usage.
    parameter DS_H_SHIFT = 1;
    parameter DS_V_SHIFT = 1;

    // Set to 1 to stub out the BEV/CCL heavy blocks for faster synth timing checks.
    parameter STUB_HEAVY = 0;
    parameter DS_H_RES   = (1280 >> DS_H_SHIFT);
    parameter DS_V_RES   = (720  >> DS_V_SHIFT);
    parameter DS_H_BITS  = $clog2(DS_H_RES);
    parameter DS_V_BITS  = $clog2(DS_V_RES);

    logic [DS_H_BITS-1:0] ds_h_count;
    logic [DS_V_BITS-1:0] ds_v_count;
    logic                 ds_valid;
    logic                 ds_mask;
    logic [10:0]          ds_h_count_raw;
    logic [9:0]           ds_v_count_raw;
    logic                 ds_stage_valid;
    logic                 ds_stage_mask;
    logic                 ds_control;

    // Stage 1 : stash the raw HDMI counters + mask bit every cycle
    // so we have a clean, in-sync copy right before the decimator makes decisions.
    always_ff @(posedge clk_pixel) begin
        if (sys_rst_pixel) begin
            ds_h_count_raw <= '0;
            ds_v_count_raw <= '0;
            ds_stage_valid <= 1'b0;
            ds_stage_mask  <= 1'b0;
        end else begin
            ds_h_count_raw <= h_count_hdmi;
            ds_v_count_raw <= v_count_hdmi;
            ds_stage_valid <= active_draw_hdmi;
            ds_stage_mask  <= mask;
        end
    end

    assign ds_control = ds_stage_valid &&
                        (ds_h_count_raw[DS_H_SHIFT-1:0] == 0) &&
                        (ds_v_count_raw[DS_V_SHIFT-1:0] == 0);

    // Stage 2: when the decimator says “yup, keep this pixel,” we latch the downsampled coords
    // and pulse ds_valid for exactly one cycle so every later block sees a tidy packet.
    always_ff @(posedge clk_pixel) begin
        if (sys_rst_pixel) begin
            ds_valid   <= 1'b0;
            ds_h_count <= '0;
            ds_v_count <= '0;
            ds_mask    <= 1'b0;
        end else if (ds_control) begin
            ds_valid   <= 1'b1;
            ds_h_count <= ds_h_count_raw[DS_H_SHIFT +: DS_H_BITS];
            ds_v_count <= ds_v_count_raw[DS_V_SHIFT +: DS_V_BITS];
            ds_mask    <= ds_stage_mask;
        end else begin
            ds_valid <= 1'b0;
        end
    end

    logic valid_roi_mem;
    logic roi_mask_pixel;

    // We define the ROI bounds in downsampled coordinates so they line up with the BEV geometry.
    parameter ROI_SRC_MIN_H = 296;
    parameter ROI_SRC_MAX_H = 1004; // exclusive
    parameter ROI_SRC_MIN_V = 432;
    parameter ROI_SRC_MAX_V = 720;  // exclusive (doubled height vs old window)
    parameter ROI_MIN_H = (ROI_SRC_MIN_H + (1 << DS_H_SHIFT) - 1) >> DS_H_SHIFT;
    parameter ROI_MAX_H = (ROI_SRC_MAX_H - 1) >> DS_H_SHIFT;
    parameter ROI_MIN_V = (ROI_SRC_MIN_V + (1 << DS_V_SHIFT) - 1) >> DS_V_SHIFT;
    parameter ROI_MAX_V = (ROI_SRC_MAX_V - 1) >> DS_V_SHIFT;
    parameter ROI_WIDTH  = ROI_MAX_H - ROI_MIN_H + 1;
    parameter ROI_HEIGHT = ROI_MAX_V - ROI_MIN_V + 1;
    parameter ROI_B_DEPTH = ROI_WIDTH * ROI_HEIGHT;
    parameter ROI_B_SIZE  = $clog2(ROI_B_DEPTH);
    parameter BRAM18_CAPACITY_BITS = 18 * 1024;
    parameter BRAM36_CAPACITY_BITS = 2 * BRAM18_CAPACITY_BITS;
    parameter ROI_BRAM_BITS        = ROI_B_DEPTH; // 1 bit per entry
    parameter ROI_BRAM18_USED      = (ROI_BRAM_BITS + BRAM18_CAPACITY_BITS - 1) / BRAM18_CAPACITY_BITS;
    parameter ROI_BRAM36_USED      = (ROI_BRAM_BITS + BRAM36_CAPACITY_BITS - 1) / BRAM36_CAPACITY_BITS;
    logic [ROI_B_SIZE-1:0] roi_addra;
    logic [ROI_B_SIZE-1:0] roi_read_addr;
    logic                  roi_bram_read_bit;

    region_of_interest #(
        .MIN_H(ROI_MIN_H),
        .MAX_H(ROI_MAX_H),
        .MIN_V(ROI_MIN_V),
        .MAX_V(ROI_MAX_V),
        .PIXEL_WIDTH(1)
    ) lane_roi (
        .clk(clk_pixel),
        .rst(sys_rst_pixel),
        .valid(ds_valid),
        .h_count({{(11-DS_H_BITS){1'b0}}, ds_h_count}),
        .v_count({{(10-DS_V_BITS){1'b0}}, ds_v_count}),
        .pixel_data(ds_mask),               // We only stash a single mask bit per pixel instead of full RGB565.
        .addra(roi_addra),
        .valid_roi_mem(valid_roi_mem),
        .roi_mem(roi_mask_pixel)
    );

    xilinx_true_dual_port_read_first_1_clock_ram #(
        .RAM_WIDTH(1),
        .RAM_DEPTH(ROI_B_DEPTH)
    ) lane_roi_bram (
        .addra(roi_addra),
        .clka(clk_pixel),
        .wea(valid_roi_mem),
        .dina(roi_mask_pixel),
        .ena(1'b1),
        .rsta(sys_rst_pixel),
        .regcea(1'b1),
        .douta(),
        .addrb(roi_read_addr),
        .web(1'b0),
        .dinb(1'b0),
        .enb(1'b1),
        .rstb(sys_rst_pixel),
        .regceb(1'b1),
        .doutb(roi_bram_read_bit)
    );

    /* We pipe the ROI bits through the warp -> FIFO -> CCL pipeline next. */
    parameter BEV_HRES = ROI_WIDTH;
    parameter BEV_VRES = ROI_HEIGHT;
    parameter BEV_H_BITS = $clog2(BEV_HRES);
    parameter BEV_V_BITS = $clog2(BEV_VRES);

    // We need BEV_HRES * BEV_VRES entries (17 bits each) so we can index back into the ROI BRAM.
    parameter LUT_DEPTH = BEV_HRES * BEV_VRES;
    parameter BEV_LUT_BITS = LUT_DEPTH * 17;
    localparam LUT_ADDR_BITS = $clog2(LUT_DEPTH);
    parameter BEV_LUT_BRAM18_USED = (BEV_LUT_BITS + BRAM18_CAPACITY_BITS - 1) / BRAM18_CAPACITY_BITS;
    parameter BEV_LUT_BRAM36_USED = (BEV_LUT_BITS + BRAM36_CAPACITY_BITS - 1) / BRAM36_CAPACITY_BITS;
    logic [16:0] warp_lut_addr;
    logic [16:0] warp_lut_data; // raw ROM output
    logic [16:0] warp_lut_data_r; // registered ROM output for timing
    
    generate
        if (!STUB_HEAVY) begin : gen_bev_lut
            xilinx_single_port_ram_read_first #(
                .RAM_WIDTH(17),                       // We store ROI indices at 17 bits wide.
                .RAM_DEPTH(LUT_DEPTH), 
                .RAM_PERFORMANCE("HIGH_PERFORMANCE"), 
                .INIT_FILE("bev_lut.mem")             // The file you generated
            ) bev_lut_rom (
                .addra(warp_lut_addr[LUT_ADDR_BITS-1:0]),
                .dina(17'b0),       // ROM, never write
                .clka(clk_pixel),
                .wea(1'b0),
                .ena(1'b1),
                .rsta(sys_rst_pixel),
                .regcea(1'b1),
                .douta(warp_lut_data)
            );
            // Add an explicit output register to ease timing.
            always_ff @(posedge clk_pixel) begin
                warp_lut_data_r <= warp_lut_data;
            end
        end else begin : stub_bev_lut
            assign warp_lut_data     = '0;
            assign warp_lut_data_r   = '0;
        end
    endgenerate

    // Here we sling the ROI address wires.
    logic [16:0] warp_roi_addr; // Now 17 bits to match the LUT output.
    logic        roi_bram_read_bit_r; // registered ROI bit for timing
    
    // This warp core goes through the LUT map to create BEV pixels.
    logic warp_bev_pixel, warp_bev_valid, warp_bev_new_frame, bev_fifo_s_ready;
    logic [BEV_H_BITS-1:0] warp_bev_h; 
    logic [BEV_V_BITS-1:0] warp_bev_v;
    
    // We still drop the warped pixels into an async FIFO 
    parameter BEV_AXIS_PAD = 5;
    parameter BEV_AXIS_WIDTH = BEV_AXIS_PAD + 1 + BEV_V_BITS + BEV_H_BITS + 1;
    parameter BEV_FIFO_DEPTH = 128; // shrunk to ease timing/BRAM
    parameter BEV_FIFO_BITS = BEV_FIFO_DEPTH * BEV_AXIS_WIDTH;
    parameter BEV_FIFO_BRAM18_USED = (BEV_FIFO_BITS + BRAM18_CAPACITY_BITS - 1) / BRAM18_CAPACITY_BITS;
    parameter BEV_FIFO_BRAM36_USED = (BEV_FIFO_BITS + BRAM36_CAPACITY_BITS - 1) / BRAM36_CAPACITY_BITS;
    logic [BEV_AXIS_WIDTH-1:0] bev_fifo_m_data;
    logic bev_fifo_m_valid, bev_fifo_m_ready;
    logic bev_fifo_pop;
    logic bev_fifo_m_ready_r;
    logic bev_fifo_full, bev_fifo_empty, bev_fifo_prog_full;

    // CCL / centroid signals shared across both real and stubbed builds.
    logic        ccl_valid, ccl_last;
    logic [11:0] ccl_label;
    logic [BEV_H_BITS-1:0]  ccl_x; 
    logic [BEV_V_BITS-1:0]  ccl_y;
    
    logic [10:0] lane_h_avg [0:3];
    logic [9:0]  lane_v_avg [0:3];
    logic [31:0] lane_area [0:3];
    logic [3:0]  lane_valid;
    // Buffered copies for downstream overlay/lane pairing.
    logic [10:0] lane_h_avg_q [0:3];
    logic [9:0]  lane_v_avg_q [0:3];
    logic [31:0] lane_area_q [0:3];
    logic [3:0]  lane_valid_q;
    logic [31:0] blobs_x [0:3];
    logic [31:0] blobs_y [0:3];
    logic [3:0]  blobs_valid;

    // We simply feed the same ROI address into port B of the BRAM, then register the bit.
    assign roi_read_addr = warp_roi_addr[ROI_B_SIZE-1:0]; 

    logic warp_bev_pixel_r, warp_bev_valid_r, warp_bev_new_frame_r;
    logic [BEV_H_BITS-1:0] warp_bev_h_r; 
    logic [BEV_V_BITS-1:0] warp_bev_v_r;

    generate
        if (!STUB_HEAVY) begin : gen_bev_path
            // Register the ROI BRAM output for timing margin.
            always_ff @(posedge clk_pixel) begin
                if (sys_rst_pixel) begin
                    roi_bram_read_bit_r <= 1'b0;
                end else begin
                    roi_bram_read_bit_r <= roi_bram_read_bit;
                end
            end

            // Register warp outputs before FIFO to break LUT/ROI -> warp -> FIFO path.
            // logic warp_bev_pixel_r, warp_bev_valid_r, warp_bev_new_frame_r;
            // logic [BEV_H_BITS-1:0] warp_bev_h_r; 
            // logic [BEV_V_BITS-1:0] warp_bev_v_r;

            perspective_warping #(
                .BEV_HRES(BEV_HRES),
                .BEV_VRES(BEV_VRES)
            ) bev_warp (
                .clk_pixel(clk_pixel), 
                .rst(sys_rst_pixel), 
                .start(1'b1), 
                .ccl_ready_in(bev_fifo_s_ready),
                
                // We grab the precomputed sampling addresses from the LUT ROM we built in Python.
                .lut_read_addr(warp_lut_addr), 
                .lut_read_data(warp_lut_data_r), 
                
                // We stream individual ROI bits straight out of the BRAM.
                .roi_bram_read_addr(warp_roi_addr), 
                .roi_bram_read_data(roi_bram_read_bit_r),
                
                // We hand the warped stream to the rest of the BEV pipeline.
                .bev_pixel_out(warp_bev_pixel), 
                .bev_valid_out(warp_bev_valid),
                .bev_h_count_out(warp_bev_h), 
                .bev_v_count_out(warp_bev_v), 
                .bev_new_frame_out(warp_bev_new_frame)
            );

            always_ff @(posedge clk_pixel) begin
                if (sys_rst_pixel) begin
                    warp_bev_pixel_r     <= 1'b0;
                    warp_bev_valid_r     <= 1'b0;
                    warp_bev_new_frame_r <= 1'b0;
                    warp_bev_h_r         <= '0;
                    warp_bev_v_r         <= '0;
                end else begin
                    warp_bev_pixel_r     <= warp_bev_pixel;
                    warp_bev_valid_r     <= warp_bev_valid;
                    warp_bev_new_frame_r <= warp_bev_new_frame;
                    warp_bev_h_r         <= warp_bev_h;
                    warp_bev_v_r         <= warp_bev_v;
                end
            end

            // This FIFO (First-In First-Out) memory block is used to store the stream 
            // of BEV (Bird's Eye View) pixels coming out of the perspective warping 
            // core before passing them to the Connected Components Labeling (CCL) logic.
            //

            //  - If you want to change FIFO size or its parameters:
            //     - Change BEV_FIFO_DEPTH to adjust depth (capacity).
            //     - Change BEV_AXIS_WIDTH if the data bus size changes.
            //     - We use "fwft" (First-Word Fall-Through) mode to simplify the ready/valid handshake
            //       and prevent data loss due to pipeline latency skidding.

            logic bev_fifo_wr_rst_busy;
            xpm_fifo_sync #(
                .DOUT_RESET_VALUE("0"),
                .ECC_MODE("no_ecc"),
                .FIFO_MEMORY_TYPE("auto"),
                .FIFO_READ_LATENCY(0), // Latency is 0 in FWFT mode (conceptually)
                .FIFO_WRITE_DEPTH(BEV_FIFO_DEPTH),
                .FULL_RESET_VALUE(0),
                .PROG_EMPTY_THRESH(10),
                .PROG_FULL_THRESH(BEV_FIFO_DEPTH-10),
                .RD_DATA_COUNT_WIDTH($clog2(BEV_FIFO_DEPTH)+1),
                .READ_DATA_WIDTH(BEV_AXIS_WIDTH),
                .READ_MODE("fwft"), // CHANGED TO FWFT
                .SIM_ASSERT_CHK(0),
                .USE_ADV_FEATURES("0707"),
                .WAKEUP_TIME(0),
                .WRITE_DATA_WIDTH(BEV_AXIS_WIDTH),
                .WR_DATA_COUNT_WIDTH($clog2(BEV_FIFO_DEPTH)+1)
            ) bev_fifo (
                .rst(sys_rst_pixel),
                .wr_clk(clk_pixel),
                .wr_en(warp_bev_valid_r & bev_fifo_s_ready), // Gate write with ready to prevent duplicates during stall
                .din({{BEV_AXIS_PAD{1'b0}}, warp_bev_new_frame_r, warp_bev_v_r, warp_bev_h_r, warp_bev_pixel_r}),
                .full(bev_fifo_full),
                .wr_ack(),
                .overflow(),
                .wr_rst_busy(bev_fifo_wr_rst_busy),

                .rd_en(bev_fifo_pop),
                .dout(bev_fifo_m_data),
                .empty(bev_fifo_empty),
                .data_valid(bev_fifo_m_valid), // In FWFT, this indicates valid data is on dout
                .underflow(),
                .rd_rst_busy(),

                .prog_empty(),
                .prog_full(bev_fifo_prog_full),
                .sleep(1'b0),
                .injectsbiterr(1'b0),
                .injectdbiterr(1'b0),
                .sbiterr(),
                .dbiterr(),
                .rd_data_count(),
                .wr_data_count()
            );

            // Gate ready signal with reset busy to prevent early writes
            assign bev_fifo_s_ready = ~bev_fifo_prog_full && ~bev_fifo_wr_rst_busy;
            
            // In FWFT mode:
            // - Data is valid on 'dout' whenever 'empty' is low (or data_valid is high).
            // - Asserting 'rd_en' ACKNOWLEDGES the current data and moves to the next.
            // - We must only ACK if the consumer (CCL) accepts the data (ready=1).
            assign bev_fifo_pop = bev_fifo_m_ready & ~bev_fifo_empty;

            // We turn the FIFO bus back into something human-readable.
            logic fifo_bev_pixel, fifo_bev_new_frame;
            logic [BEV_H_BITS-1:0] fifo_bev_h; 
            logic [BEV_V_BITS-1:0] fifo_bev_v;
            logic [BEV_AXIS_PAD-1:0] bev_fifo_pad_unused;
            assign {bev_fifo_pad_unused, fifo_bev_new_frame, fifo_bev_v, fifo_bev_h, fifo_bev_pixel} = bev_fifo_m_data;

            // REMOVED: Manual pipeline stage and ready-skid logic. 
            // Direct connection ensures no dropped pixels.
            
            // First: the actual 8-connect CCL pass.
            cle_module_8conn #(
                .WIDTH(BEV_HRES), 
                .HEIGHT(BEV_VRES), 
                .LABEL_BITS(10),
                .MAX_COMPONENTS(4)
            ) bev_ccl (
                .clk(clk_pixel),
                .rst(sys_rst_pixel),
                .s_axis_valid(~bev_fifo_empty), // Data is valid if FIFO not empty
                .s_axis_data(fifo_bev_pixel),
                .s_axis_ready(bev_fifo_m_ready), // CCL tells us when it consumes
                .m_axis_valid(ccl_valid),
                .m_axis_label(ccl_label),
                .m_axis_x(ccl_x),
                .m_axis_y(ccl_y),
                .m_axis_last(ccl_last),
                .m_axis_ready(1'b1)
            );

            // Then we average each blob to get a rough lane center before feeding lane pairing.
            // Pipeline the CCL outputs once before the centroid math.
            logic        ccl_valid_r, ccl_last_r;
            logic [11:0] ccl_label_r;
            logic [BEV_H_BITS-1:0]  ccl_x_r; 
            logic [BEV_V_BITS-1:0]  ccl_y_r;
            always_ff @(posedge clk_pixel) begin
                if (sys_rst_pixel) begin
                    ccl_valid_r <= 1'b0;
                    ccl_last_r  <= 1'b0;
                    ccl_label_r <= '0;
                    ccl_x_r     <= '0;
                    ccl_y_r     <= '0;
                end else begin
                    ccl_valid_r <= ccl_valid;
                    ccl_last_r  <= ccl_last;
                    ccl_label_r <= ccl_label;
                    ccl_x_r     <= ccl_x;
                    ccl_y_r     <= ccl_y;
                end
            end

            cc_calculations #(
                .WIDTH(BEV_HRES),
                .HEIGHT(BEV_VRES),
                .MAX_BLOBS(4)
            ) lane_calc (
                .clk(clk_pixel),
                .rst(sys_rst_pixel),
                .cc_pixel_valid(ccl_valid_r),
                .cc_pixel_label(ccl_label_r),
                .cc_pixel_last(ccl_last_r),
                .cc_pixel_h(ccl_x_r),
                .cc_pixel_v(ccl_y_r),
                .h_avg_pos(lane_h_avg),
                .v_avg_pos(lane_v_avg),
                .blob_area(lane_area),
                .cc_valid_out(lane_valid)
            );
        end else begin : stub_bev_path
            assign bev_fifo_s_ready  = 1'b1;
            assign warp_lut_addr     = '0;
            assign warp_roi_addr     = '0;
            assign warp_bev_pixel    = 1'b0;
            assign warp_bev_valid    = 1'b0;
            assign warp_bev_new_frame= 1'b0;
            assign warp_bev_h        = '0;
            assign warp_bev_v        = '0;
            assign bev_fifo_m_valid  = 1'b0;
            assign bev_fifo_m_data   = '0;
            assign bev_fifo_m_ready  = 1'b1;

            assign warp_bev_pixel_r     = 1'b0;
            assign warp_bev_valid_r     = 1'b0;
            assign warp_bev_new_frame_r = 1'b0;
            assign warp_bev_h_r         = '0;
            assign warp_bev_v_r         = '0;

            assign ccl_valid = 1'b0;
            assign ccl_last  = 1'b0;
            assign ccl_label = '0;
            assign ccl_x     = '0;
            assign ccl_y     = '0;

            for (genvar stub_lane = 0; stub_lane < 4; stub_lane = stub_lane + 1) begin : stub_lane_zero
                assign lane_h_avg[stub_lane] = '0;
                assign lane_v_avg[stub_lane] = '0;
                assign lane_area[stub_lane]  = '0;
            end
            assign lane_valid = 4'b0;
        end
    endgenerate
    // Signals for holding final lane outputs and mask to show which are active from the lane_pair_filter
    // logic        lanes_valid;
    // logic [31:0] lane_left_x, lane_left_y;
    // logic [31:0] lane_right_x, lane_right_y;
    // logic [3:0]  lane_active_mask;

    // Stage 3: freeze the centroid math for a tick.
    // We copy the averages/areas/valid bits into *_q so everyone downstream
    // reads a stable snapshot instead of chasing numbers that are still moving.
    integer lane_idx;
    // lane_valid_q = sticky note that says “slot N actually had a blob this frame”.
    // Four bits in, four bits out, so the lane_pair_filter knows which entries are legit.
    always_ff @(posedge clk_pixel) begin
        if (sys_rst_pixel) begin
            // On reset, clear all buffered averages and area values, and mark all as invalid.
            for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1) begin
                lane_h_avg_q[lane_idx] <= '0;
                lane_v_avg_q[lane_idx] <= '0;
                lane_area_q[lane_idx]  <= '0;
            end
            lane_valid_q <= 4'b0;
        end else begin
            // Normal case: every clock, grab new values from centroid calc, buffer them for stable use.
            
            for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1) begin
                lane_h_avg_q[lane_idx] <= lane_h_avg[lane_idx];
                lane_v_avg_q[lane_idx] <= lane_v_avg[lane_idx];
                lane_area_q[lane_idx]  <= lane_area[lane_idx];
            end
            lane_valid_q <= lane_valid;
        end
    end

    logic [10:0] left_midpoint;
    logic [10:0] right_midpoint;
    logic [10:0] total_midpoint;

    logic valid_midpoints;
    logic [3:0] lane_active_mask;
    logic [17:0] lane_left_x_calc;
    logic [17:0] lane_right_x_calc;
    logic [17:0] lane_mid_x_calc;
    logic [10:0] lane_left_screen_x;
    logic [10:0] lane_right_screen_x;
    logic [10:0] lane_mid_screen_x;
    logic        lanes_valid;
    logic [2:0]  lane_count;
    
    // Bypass switch to force simple pairing of the first two blobs (for debug bring-up).
    localparam BYPASS_LANE_PAIR = 1'b0;

    // Feed lane_pair_filter from the registered centroid stage (lane_*_q) to shorten timing into pairing.
    lane_pair_filter #(
        .WIDTH(BEV_HRES),
        .HEIGHT(BEV_VRES)
    ) lane_pairing (
        .clk(clk_pixel),
        .rst(sys_rst_pixel),
        .cc_valid(lane_valid_q),

        .cc_x(lane_h_avg_q),
        .cc_y(lane_v_avg_q),
        .cc_pixels(lane_area_q),

        .left_midpoint(left_midpoint),
        .right_midpoint(right_midpoint),
        .total_midpoint(total_midpoint),
        .valid_midpoints(valid_midpoints)
    );

    // Bypass accumulates any seen blob0/blob1 within a frame and uses their last positions.
    logic [1:0] lane_seen;
    logic [10:0] lane_x_seen [0:1];
    always_ff @(posedge clk_pixel) begin
        if (sys_rst_pixel || new_frame_hdmi) begin
            lane_seen    <= 2'b0;
            lane_x_seen[0] <= 11'd0;
            lane_x_seen[1] <= 11'd0;
        end else begin
            if (lane_valid[0]) begin
                lane_seen[0]    <= 1'b1;
                lane_x_seen[0]  <= lane_h_avg[0];
            end
            if (lane_valid[1]) begin
                lane_seen[1]    <= 1'b1;
                lane_x_seen[1]  <= lane_h_avg[1];
            end
        end
    end

    wire        valid_midpoints_bypass = lane_seen[0] & lane_seen[1];
    wire [10:0] left_midpoint_bypass   = lane_x_seen[0];
    wire [10:0] right_midpoint_bypass  = lane_x_seen[1];
    wire [10:0] total_midpoint_bypass  = (lane_x_seen[0] + lane_x_seen[1]) >> 1;

    wire        valid_midpoints_sel   = BYPASS_LANE_PAIR ? valid_midpoints_bypass   : valid_midpoints;
    wire [10:0] left_midpoint_sel     = BYPASS_LANE_PAIR ? left_midpoint_bypass     : left_midpoint;
    wire [10:0] right_midpoint_sel    = BYPASS_LANE_PAIR ? right_midpoint_bypass    : right_midpoint;
    wire [10:0] total_midpoint_sel    = BYPASS_LANE_PAIR ? total_midpoint_bypass    : total_midpoint;

    // Stretch midpoint valid and hold values for one extra cycle to avoid missing a pulse.
    logic        valid_midpoints_hold;
    logic [10:0] left_midpoint_hold;
    logic [10:0] right_midpoint_hold;
    logic [10:0] total_midpoint_hold;

    always_ff @(posedge clk_pixel) begin
        if (sys_rst_pixel) begin
            valid_midpoints_hold <= 1'b0;
            left_midpoint_hold   <= '0;
            right_midpoint_hold  <= '0;
            total_midpoint_hold  <= '0;
        end else begin
            valid_midpoints_hold <= valid_midpoints_sel;
            left_midpoint_hold   <= left_midpoint_sel;
            right_midpoint_hold  <= right_midpoint_sel;
            total_midpoint_hold  <= total_midpoint_sel;
        end
    end

    // Use stretched/held values if present.
    wire        valid_midpoints_eff = valid_midpoints_hold | valid_midpoints_sel;
    wire [10:0] left_midpoint_eff   = valid_midpoints_hold ? left_midpoint_hold  : left_midpoint_sel;
    wire [10:0] right_midpoint_eff  = valid_midpoints_hold ? right_midpoint_hold : right_midpoint_sel;
    wire [10:0] total_midpoint_eff  = valid_midpoints_hold ? total_midpoint_hold : total_midpoint_sel;

    // Convert BEV-space lane midpoints back to full-resolution coordinates and clip to HDMI bounds.
    always_comb begin
        lane_left_x_calc    = 18'd0;
        lane_right_x_calc   = 18'd0;
        lane_left_screen_x  = 11'd0;
        lane_right_screen_x = 11'd0;
        lane_mid_screen_x   = 11'd0;
        lanes_valid         = valid_midpoints_eff;
        lane_count          = 3'd0;

        if (valid_midpoints_eff) begin
            lane_left_x_calc  = (left_midpoint_eff  << DS_H_SHIFT) + ROI_SRC_MIN_H;
            lane_right_x_calc = (right_midpoint_eff << DS_H_SHIFT) + ROI_SRC_MIN_H;
            lane_mid_x_calc   = (total_midpoint_eff << DS_H_SHIFT) + ROI_SRC_MIN_H;

            lane_left_screen_x  = (lane_left_x_calc  > 18'd1279) ? 11'd1279 : lane_left_x_calc[10:0];
            lane_right_screen_x = (lane_right_x_calc > 18'd1279) ? 11'd1279 : lane_right_x_calc[10:0];
            lane_mid_screen_x   = (lane_mid_x_calc   > 18'd1279) ? 11'd1279 : lane_mid_x_calc[10:0];
        end

        // Count how many blob slots are valid (0–4). Shown on LEDs[14:12] in binary.
        lane_count = lane_valid_q[0] + lane_valid_q[1] + lane_valid_q[2] + lane_valid_q[3];
    end

    // Frame-align the lane screen coordinates to the HDMI frame boundary.
    logic [10:0] lane_left_screen_x_frame;
    logic [10:0] lane_right_screen_x_frame;
    logic [10:0] lane_mid_screen_x_frame;
    logic        lanes_valid_frame;
    always_ff @(posedge clk_pixel) begin
        if (sys_rst_pixel) begin
            lane_left_screen_x_frame  <= 11'd0;
            lane_right_screen_x_frame <= 11'd0;
            lane_mid_screen_x_frame   <= 11'd0;
            lanes_valid_frame         <= 1'b0;
        end else if (new_frame_hdmi) begin
            lane_left_screen_x_frame  <= lane_left_screen_x;
            lane_right_screen_x_frame <= lane_right_screen_x;
            lane_mid_screen_x_frame   <= lane_mid_screen_x;
            lanes_valid_frame         <= lanes_valid;
        end
    end

    logic [7:0] left_motor_pwm_duty;
    logic [7:0] right_motor_pwm_duty;

    motor_guidance #(
        .WIDTH(1280)
    ) motor_control (
        .clk(clk_pixel),
        .rst(sys_rst_pixel),
        .valid_midpoint(valid_midpoints),
        .midpoint_calc(lane_mid_screen_x_frame),
        .left_motor_pwm(left_motor_pwm_duty),
        .right_motor_pwm(right_motor_pwm_duty)
    );

    logic left_motor_en_sig;
    logic right_motor_en_sig;

    // For simple testing
    // logic [7:0] test_left_duty;
    // logic [7:0] test_right_duty;

    // always_comb begin
    //     test_left_duty = 200;
    //     test_right_duty = 200;
    // end

    pwm left_motor_pwm (
        .clk(clk_pixel),
        .rst(sys_rst_pixel),
        .dc_in(left_motor_pwm_duty),
        .sig_out(left_motor_en_sig)
    );

    pwm right_motor_pwm (
        .clk(clk_pixel),
        .rst(sys_rst_pixel),
        .dc_in(right_motor_pwm_duty),
        .sig_out(right_motor_en_sig)
    );
    
    always_comb begin
        left_motor_en = left_motor_en_sig;
        left_motor_ph = 0;
        right_motor_en = right_motor_en_sig;
        right_motor_ph = 0;
    end



    // Calculated/converted screen-coordinates and next-stage validity flag.
    // These signals will be used when actually rendering overlays in the video feed.

    // This always_comb block takes the average (central) positions in downsampled
    // coords and converts them back to "global" pixel coordinates. We multiply up
    // by the downsampling shift and add the ROI origin offsets.
    // always_comb begin
    //     lane_left_x_calc  = (lane_left_x[15:0]  << DS_H_SHIFT) + ROI_SRC_MIN_H;
    //     lane_right_x_calc = (lane_right_x[15:0] << DS_H_SHIFT) + ROI_SRC_MIN_H;
    //     lane_left_y_calc  = (lane_left_y[15:0]  << DS_V_SHIFT) + ROI_SRC_MIN_V;
    //     lane_right_y_calc = (lane_right_y[15:0] << DS_V_SHIFT) + ROI_SRC_MIN_V;
    // end

    // Overlay/video mux signals: holds overlay color values & enables. These connect to the annotation renderer.
    logic        overlay_active;
    logic [7:0]  overlay_red;
    logic [7:0]  overlay_green;
    logic [7:0]  overlay_blue;
    logic [7:0]  output_red;
    logic [7:0]  output_green;
    logic [7:0]  output_blue;
    logic        overlay_enable;

    // Switch [0] on the board enables or disables the overlay display.
    // Switches [5:1] select which debug plane is routed to HDMI.
    assign overlay_enable = sw[0];

    // Debug video mode encoding (selected with sw[5:1])
    typedef enum logic [2:0] {
        MODE_CAMERA   = 3'd0,
        MODE_THRESH   = 3'd1,
        MODE_ROI      = 3'd2,
        MODE_BLOBS    = 3'd3,
        MODE_CCL      = 3'd4,
        MODE_CENTROID = 3'd5
    } video_mode_t;

    video_mode_t video_mode;
    // Mapping:
    // 00000 -> camera feed
    // 00001 -> threshold mask
    // 00010 -> ROI mask
    // 00011 -> blob centroids (see which of the 4 slots are alive)
    // 00100 -> blob activity (CCL shorthand)
    // 00101 -> centroid/overlay view
    always_comb begin
        case (sw[5:1])
            5'd1: video_mode = MODE_THRESH;
            5'd2: video_mode = MODE_ROI;
            5'd3: video_mode = MODE_BLOBS;
            5'd4: video_mode = MODE_CCL;
            5'd5: video_mode = MODE_CENTROID;
            default: video_mode = MODE_CAMERA;
        endcase
    end

    // Convenience helper to keep ROI highlighting readable.
    logic roi_window_active;
    assign roi_window_active = (h_count_hdmi >= ROI_SRC_MIN_H) && (h_count_hdmi < ROI_SRC_MAX_H) &&
                               (v_count_hdmi >= ROI_SRC_MIN_V) && (v_count_hdmi < ROI_SRC_MAX_V);

    // Binary mask debug plane (threshold output rendered as grayscale)
    logic [7:0] thresh_red_dbg;
    logic [7:0] thresh_green_dbg;
    logic [7:0] thresh_blue_dbg;
    assign thresh_red_dbg   = mask ? 8'hFF : 8'h00;
    assign thresh_green_dbg = thresh_red_dbg;
    assign thresh_blue_dbg  = thresh_red_dbg;

    // ROI mask: highlight ROI region and show mask hits as lime pixels inside window.
    logic [7:0] roi_red_dbg;
    logic [7:0] roi_green_dbg;
    logic [7:0] roi_blue_dbg;
    always_comb begin
        if (roi_window_active) begin
            roi_red_dbg   = mask ? 8'h00 : 8'h00;
            roi_green_dbg = mask ? 8'hFF : 8'h20;
            roi_blue_dbg  = mask ? 8'h00 : 8'h20;
        end else begin
            roi_red_dbg   = 8'h00;
            roi_green_dbg = 8'h00;
            roi_blue_dbg  = 8'h00;
        end
    end

    // Annotation overlay module: draws visual lane overlays where detected, based on screen coordinates.
    // Only active if overlay_enable and overlay_active are both true.
    lane_annotation lane_overlay (
        .clk(clk_pixel),
        .rst(sys_rst_pixel),
        .lanes_valid(lanes_valid_frame),
        .lane_left_x(lane_left_screen_x_frame),
        .lane_right_x(lane_right_screen_x_frame),
        .lane_mid_x(lane_mid_screen_x_frame),
        .h_count(h_count_hdmi),
        .v_count(v_count_hdmi),
        .overlay_active(overlay_active),
        .overlay_red(overlay_red),
        .overlay_green(overlay_green),
        .overlay_blue(overlay_blue)
    );

    // Simplified video mux: only lane_annotation overlay vs. raw camera.
    // Optional ROI debug view: enable with sw[1].
    logic [7:0] roi_red_q, roi_green_q, roi_blue_q;
    always_ff @(posedge clk_pixel) begin
        if (sys_rst_pixel) begin
            roi_red_q   <= 8'd0;
            roi_green_q <= 8'd0;
            roi_blue_q  <= 8'd0;
        end else begin
            roi_red_q   <= roi_red_dbg;
            roi_green_q <= roi_green_dbg;
            roi_blue_q  <= roi_blue_dbg;
        end
    end

    always_comb begin
        if (sw[1]) begin
            // ROI debug plane
            output_red   = roi_red_q;
            output_green = roi_green_q;
            output_blue  = roi_blue_q;
        end else if (overlay_enable && overlay_active) begin
            output_red   = overlay_red;
            output_green = overlay_green;
            output_blue  = overlay_blue;
        end else begin
            output_red   = red;
            output_green = green;
            output_blue  = blue;
        end
    end

    // Align RGB and sync/control into a single pipeline stage before TMDS,
    // so the base image and overlay share the same latency to the serializer.
    logic [7:0] output_red_q, output_green_q, output_blue_q;
    logic       active_draw_q;
    logic       h_sync_q, v_sync_q;

    always_ff @(posedge clk_pixel) begin
        if (sys_rst_pixel) begin
            output_red_q   <= 8'd0;
            output_green_q <= 8'd0;
            output_blue_q  <= 8'd0;
            active_draw_q  <= 1'b0;
            h_sync_q       <= 1'b0;
            v_sync_q       <= 1'b0;
        end else begin
            output_red_q   <= output_red;
            output_green_q <= output_green;
            output_blue_q  <= output_blue;
            active_draw_q  <= active_draw_hdmi;
            h_sync_q       <= h_sync_hdmi;
            v_sync_q       <= v_sync_hdmi;
        end
    end

    // The "expansion and clipping" step is needed because blob centroids are calculated in downsampled
    // (low-resolution, ROI-aligned) coordinates, which are suitable for processing and detection but not for display.

    // Without expansion, overlays would appear misplaced or "compressed"; without clipping, out-of-bounds writes
    // could occur, distorting the annotation or rendering logic.

    // Stage 4: after we scale the centroids back to 1280x720, we park them here.
    // Think of it as a “final answer” register so the overlay doesn’t see half-baked coordinates.
    // always_ff @(posedge clk_pixel) begin
    //     if (sys_rst_pixel) begin
    //         // On reset, just zero out all coordinate and valid signals.
    //         // lanes_valid_d       <= 1'b0;
    //         // lane_left_screen_x  <= '0;
    //         // lane_right_screen_x <= '0;
    //         // lane_left_screen_y  <= '0;
    //         // lane_right_screen_y <= '0;
    //     end else begin
    //         // lanes_valid_d <= lanes_valid;
    //         if (lanes_valid) begin
    //             // Horizontal clipping for left lane x
    //             if (lane_left_x_calc > 18'd1279)
    //                 lane_left_screen_x <= 11'd1279;
    //             else
    //                 lane_left_screen_x <= lane_left_x_calc[10:0];

    //             // Horizontal clipping for right lane x
    //             if (lane_right_x_calc > 18'd1279)
    //                 lane_right_screen_x <= 11'd1279;
    //             else
    //                 lane_right_screen_x <= lane_right_x_calc[10:0];

    //             // Vertical clipping for left lane y
    //             // if (lane_left_y_calc > 17'd719)
    //             //     lane_left_screen_y <= 10'd719;
    //             // else
    //             //     lane_left_screen_y <= lane_left_y_calc[9:0];

    //             // Vertical clipping for right lane y
    //             if (lane_right_y_calc > 17'd719)
    //                 lane_right_screen_y <= 10'd719;
    //             else
    //                 lane_right_screen_y <= lane_right_y_calc[9:0];
    //         end
    //     end
    // end

    // assign left_lane_detected  = lanes_valid_d && (lane_left_screen_x  != 11'd0 || lane_left_screen_y  != 10'd0);
    // assign right_lane_detected = lanes_valid_d && (lane_right_screen_x != 11'd0 || lane_right_screen_y != 10'd0);

    // // 2. Blob Manager (Accumulator + Parallel Divider)
    // cc_calculations #(.WIDTH(708), .HEIGHT(146)) cc_calc_inst (
    //     .clk(clk_camera),
    //     .rst(sys_rst_camera),
    //     .cc_pixel_valid(ccl_valid),
    //     .cc_pixel_label(ccl_label),
    //     .cc_pixel_last(ccl_last),
    //     .cc_pixel_h(ccl_x),
    //     .cc_pixel_v(ccl_y),

    //     .h_avg_pos(blobs_x),
    //     .v_avg_pos(blobs_y),
    //     .cc_valid_out(blobs_valid)
    // );


    // HDMI video signal generator
    video_sig_gen vsg(
        .pixel_clk(clk_pixel),
        .rst(sys_rst_pixel),
        .h_count(h_count_hdmi),
        .v_count(v_count_hdmi),
        .v_sync(v_sync_hdmi),
        .h_sync(h_sync_hdmi),
        .new_frame(new_frame_hdmi),
        .active_draw(active_draw_hdmi),
        .frame_count(frame_count_hdmi)
    );

    // HDMI Output
    logic [9:0] tmds_10b [0:2]; //output of each TMDS encoder!
    logic       tmds_signal [2:0]; //output of each TMDS serializer!

    //three tmds_encoders (blue, green, red)
    //note green should have no control signal like red
    //the blue channel DOES carry the two sync signals:
    //  * control[0] = horizontal sync signal
    //  * control[1] = vertical sync signal

    tmds_encoder tmds_red(
        .clk(clk_pixel),
        .rst(sys_rst_pixel),
        .video_data(output_red_q),
        .control(2'b0),
        .video_enable(active_draw_q),
        .tmds(tmds_10b[2])
    );
    tmds_encoder tmds_green(
        .clk(clk_pixel),
        .rst(sys_rst_pixel),
        .video_data(output_green_q),
        .control(2'b0),
        .video_enable(active_draw_q),
        .tmds(tmds_10b[1])
    );
    tmds_encoder tmds_blue(
        .clk(clk_pixel),
        .rst(sys_rst_pixel),
        .video_data(output_blue_q),
        .control({v_sync_q,h_sync_q}),
        .video_enable(active_draw_q),
        .tmds(tmds_10b[0])
    );

    //three tmds_serializers (blue, green, red):
    //MISSING: two more serializers for the green and blue tmds signals.
    tmds_serializer red_ser(
        .clk_pixel(clk_pixel),
        .clk_5x(clk_5x),
        .rst(sys_rst_pixel),
        .tmds_in(tmds_10b[2]),
        .tmds_out(tmds_signal[2])
    );
    tmds_serializer green_ser(
        .clk_pixel(clk_pixel),
        .clk_5x(clk_5x),
        .rst(sys_rst_pixel),
        .tmds_in(tmds_10b[1]),
        .tmds_out(tmds_signal[1])
    );
    tmds_serializer blue_ser(
        .clk_pixel(clk_pixel),
        .clk_5x(clk_5x),
        .rst(sys_rst_pixel),
        .tmds_in(tmds_10b[0]),
        .tmds_out(tmds_signal[0])
    );

    //output buffers generating differential signals:
    //three for the r,g,b signals and one that is at the pixel clock rate
    //the HDMI receivers use recover logic coupled with the control signals asserted
    //during blanking and sync periods to synchronize their faster bit clocks off
    //of the slower pixel clock (so they can recover a clock of about 742.5 MHz from
    //the slower 74.25 MHz clock)
    OBUFDS OBUFDS_blue (.I(tmds_signal[0]), .O(hdmi_tx_p[0]), .OB(hdmi_tx_n[0]));
    OBUFDS OBUFDS_green(.I(tmds_signal[1]), .O(hdmi_tx_p[1]), .OB(hdmi_tx_n[1]));
    OBUFDS OBUFDS_red  (.I(tmds_signal[2]), .O(hdmi_tx_p[2]), .OB(hdmi_tx_n[2]));
    OBUFDS OBUFDS_clock(.I(clk_pixel), .O(hdmi_clk_p), .OB(hdmi_clk_n));

    // register writes to the camera

    // The OV5640 has an I2C bus connected to the board, which is used
    // for setting all the hardware settings (gain, white balance,
    // compression, image quality, etc) needed to start the camera up.
    // We've taken care of setting these all these values for you:
    // "rom.mem" holds a sequence of bytes to be sent over I2C to get
    // the camera up and running, and we've written a design that sends
    // them just after a reset completes.

    // If the camera is not giving data, press your reset button.

    logic  busy, bus_active;
    logic  cr_init_valid, cr_init_ready;

    logic request_config;
  
    parameter DELAY_CLOCK_CYCLES = 200_000_000 * 1;
    logic [$clog2(DELAY_CLOCK_CYCLES):0] count_delay;

    logic [1:0] camera_setup_btn_buf;
    
    always_ff @(posedge clk_camera) begin
        
        // synchronizer buffers for btn[2]
        camera_setup_btn_buf <= {btn[2], camera_setup_btn_buf[1]};

        // baby state machine; delay 1 second after button press, then inititate I2C command sequence
        if (sys_rst_camera) begin
            request_config <= 1'b0;
            cr_init_valid  <= 1'b0;
            count_delay <= 'b0;
        end else if (camera_setup_btn_buf[0]) begin // when btn[2] gets pressed
            request_config <= 1'b1;
            cr_init_valid  <= 1'b0;
            count_delay <= 'b0;
        end else if (request_config) begin
            if (count_delay >= DELAY_CLOCK_CYCLES) begin
                cr_init_valid  <= 1'b1;
                request_config <= 1'b0;
                count_delay <= 'b0;
            end else begin
                count_delay <= count_delay + 1;
            end
        end else if (cr_init_valid && cr_init_ready) begin
            cr_init_valid <= 1'b0;
            count_delay <= 'b0;
        end
    end

    logic [23:0] bram_dout;
    logic [7:0]  bram_addr;

    // ROM holding pre-built camera settings to send
    xilinx_single_port_ram_read_first
    #(
        .RAM_WIDTH(24),
        .RAM_DEPTH(256),
        .RAM_PERFORMANCE("HIGH_PERFORMANCE"),
        .INIT_FILE("rom.mem")
    ) registers
    (
        .addra(bram_addr),     // Address bus, width determined from RAM_DEPTH
        .dina(24'b0),          // RAM input data, width determined from RAM_WIDTH
        .clka(clk_camera),     // Clock
        .wea(1'b0),            // Write enable
        .ena(1'b1),            // RAM Enable, for additional power savings, disable port when not in use
        .rsta(sys_rst_camera), // Output reset (does not affect memory contents)
        .regcea(1'b1),         // Output register enable
        .douta(bram_dout)      // RAM output data, width determined from RAM_WIDTH
    );

    logic [23:0] registers_dout;
    logic [7:0]  registers_addr;
    assign registers_dout = bram_dout;
    assign bram_addr = registers_addr;

    logic       con_scl_i, con_scl_o, con_scl_t;
    logic       con_sda_i, con_sda_o, con_sda_t;

    // NOTE these also have pullup specified in the xdc file!
    // access our inouts properly as tri-state pins
    IOBUF IOBUF_scl (.I(con_scl_o), .IO(i2c_scl), .O(con_scl_i), .T(con_scl_t) );
    IOBUF IOBUF_sda (.I(con_sda_o), .IO(i2c_sda), .O(con_sda_i), .T(con_sda_t) );

    // provided module to send data BRAM -> I2C
    camera_registers crw
    (   .clk_in(clk_camera),
        .rst_in(sys_rst_camera),
        .init_valid(cr_init_valid),
        .init_ready(cr_init_ready),
        .scl_i(con_scl_i),
        .scl_o(con_scl_o),
        .scl_t(con_scl_t),
        .sda_i(con_sda_i),
        .sda_o(con_sda_o),
        .sda_t(con_sda_t),
        .bram_dout(registers_dout),
        .bram_addr(registers_addr)
    );
    // a handful of debug signals for writing to registers

    // assign rgb0[0] = crw.bus_active;
    // assign rgb0[2] = ~clk_camera_locked;
    // assign rgb0[1] = 0;
  
    // LED quick-reference (from LSB to MSB):
    //  0: frame heartbeat (stretched new_frame_hdmi)
    //  1: CCL activity pulse (stretched ccl_valid)
    //  2: lane midpoint valid pulse (stretched valid_midpoints)
    //  3: I2C init FSM wants to send
    //  4: I2C init FSM got an ack
    //  5: overlay_enable switch (SW0)
    //  6: lanes_valid flag from lane pairing
    //  7-10: lane_active_mask debug bits (which blobs passed filtering)
    // 11: any_blob (OR of mask)
    // 12: reserved / lanes_valid_d (if re-enabled)
    // 14-12: lane_count (binary number of active blobs)
    // 15: unused (dark)

    // Stretch pulses so LEDs are human-visible.
    localparam integer LED_STRETCH = 22'd4_000_000; // ~55ms at ~74MHz pixel clock
    logic [21:0] led_frame_cnt, led_ccl_cnt, led_mid_cnt;
    logic        ccl_activity;

    // Treat any BEV/CCL stream activity as “CCL activity” so the LED still pulses even if CCL
    // never emits a label (helps debug early-stage data starvation).
    assign ccl_activity = ccl_valid | bev_fifo_m_valid | ds_valid;
    always_ff @(posedge clk_pixel) begin
        if (sys_rst_pixel) begin
            led_frame_cnt <= '0;
            led_ccl_cnt   <= '0;
            led_mid_cnt   <= '0;
        end else begin
            led_frame_cnt <= (new_frame_hdmi)     ? LED_STRETCH : (led_frame_cnt ? led_frame_cnt - 1'b1 : led_frame_cnt);
            led_ccl_cnt   <= (ccl_activity)       ? LED_STRETCH : (led_ccl_cnt   ? led_ccl_cnt   - 1'b1 : led_ccl_cnt);
            led_mid_cnt   <= (valid_midpoints)    ? LED_STRETCH : (led_mid_cnt   ? led_mid_cnt   - 1'b1 : led_mid_cnt);
        end
    end

    assign lane_active_mask = lane_valid_q;

    // LED map (pipeline observability):
    //  0: frame heartbeat (stretched new_frame_hdmi)
    //  1: CCL/stream activity (stretched ccl_valid | bev_fifo_m_valid | ds_valid)
    //  2: lane midpoint valid (stretched valid_midpoints)
    //  3: camera register init FSM wants to send
    //  4: camera register init FSM got an ack
    //  5: overlay_enable switch (SW0)
    //  6: lanes_valid (paired lanes found)
    //  7: bev_fifo_m_valid (FIFO has data for CCL)
    //  8: bev_fifo_m_ready (CCL ready to consume FIFO)
    //  9: ccl_valid (labels flowing)
    // 10: warp_bev_valid_r (warp producing pixels post-register)
    // 11: roi_bram_read_bit_r (are there any 1s in ROI being read?)
    // 12: valid_midpoints_sel  (lane_pair_filter/bypass found midpoints this cycle)
    // 13: lanes_valid_frame (frame-aligned lanes snapshot)
    // 14: lane_count[0] (LSB of blob count)
    // 15: lane_count[1] (MSB of blob count) — count up to 3 shown; for >3 both bits high
    assign led[0]  = |led_frame_cnt;
    assign led[1]  = |led_ccl_cnt;
    assign led[2]  = |led_mid_cnt;
    assign led[3]  = cr_init_valid;
    assign led[4]  = cr_init_ready;
    assign led[5]  = overlay_enable;
    assign led[6]  = lanes_valid;
    assign led[7]  = bev_fifo_m_valid;
    assign led[8]  = bev_fifo_m_ready;
    assign led[9]  = ccl_valid;
    assign led[10] = warp_bev_valid_r;
    assign led[11] = roi_bram_read_bit_r;
    assign led[12] = valid_midpoints_sel;
    assign led[13] = lanes_valid_frame;
    assign led[14] = lane_count[0];
    assign led[15] = lane_count[1];

endmodule // top_level

`default_nettype wire