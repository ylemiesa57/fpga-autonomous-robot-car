`default_nettype none
`timescale 1ns / 1ps
module line_buffer #(
    parameter KERNEL_SIZE = 3,
    parameter HRES = 1280,
    parameter VRES = 720
    )(
            input wire clk, //system clock
            input wire rst, //system reset

            input wire [10:0] h_count_in, //current h_count being read
            input wire [9:0] v_count_in, //current v_count being read
            input wire [15:0] pixel_data_in, //incoming pixel
            input wire data_in_valid, //incoming  valid data signal

            output logic [KERNEL_SIZE-1:0][15:0] line_buffer_out, //output pixels of data
            output logic [10:0] h_count_out, //current h_count being read
            output logic [9:0] v_count_out, //current v_count being read
            output logic data_out_valid //valid data out signal
  );

  logic [1:0] bram_selector;
  always_ff @(posedge clk) begin
    if (rst) begin
      bram_selector <= 0;
    end
    if (h_count_in == HRES - 1 && data_in_valid) begin
      if (bram_selector == 2'b11) begin
        bram_selector <= 2'b00;
      end else begin
        bram_selector <= bram_selector + 1;
      end
    end
  end

  logic [KERNEL_SIZE:0][15:0] interim_line_buffer_out;

  generate
    genvar i;
    for (i = 0; i < KERNEL_SIZE + 1; i = i + 1) begin
      // to help you get started, here's a bram instantiation.
      // you'll want to create one BRAM for each row in the kernel, plus one more to
      // buffer incoming data from the wire:
      xilinx_true_dual_port_read_first_1_clock_ram #(
        .RAM_WIDTH(16),
        .RAM_DEPTH(HRES),
        .RAM_PERFORMANCE("HIGH_PERFORMANCE")) line_buffer_ram (
        .clka(clk),     // Clock
                //writing port:
                .addra(h_count_in),   // Port A address bus,
                .dina(pixel_data_in),     // Port A RAM input data
                .wea(data_in_valid && i == bram_selector),       // Port A write enable
                //reading port:
                .addrb(h_count_in),   // Port B address bus,
                .doutb(interim_line_buffer_out[i]),    // Port B RAM output data,
                .douta(),   // Port A RAM output data, width determined from RAM_WIDTH
                .dinb(16'b0),     // Port B RAM input data, width determined from RAM_WIDTH
                .web(1'b0),       // Port B write enable
                .ena(1'b1),       // Port A RAM Enable
                .enb(1'b1),       // Port B RAM Enable,
                .rsta(1'b0),     // Port A output reset
                .rstb(1'b0),     // Port B output reset
                .regcea(1'b1), // Port A output register enable
                .regceb(1'b1) // Port B output register enable
              );
          end
  endgenerate

  always_comb begin
    if (rst) begin
      line_buffer_out = 0;
    end else begin
      if (bram_selector == 2'b00) begin
        line_buffer_out[0] = interim_line_buffer_out[1];
        line_buffer_out[1] = interim_line_buffer_out[2];
        line_buffer_out[2] = interim_line_buffer_out[3];
      end else if (bram_selector == 2'b01) begin
        line_buffer_out[0] = interim_line_buffer_out[2];
        line_buffer_out[1] = interim_line_buffer_out[3];
        line_buffer_out[2] = interim_line_buffer_out[0];
      end else if (bram_selector == 2'b10) begin
        line_buffer_out[0] = interim_line_buffer_out[3];
        line_buffer_out[1] = interim_line_buffer_out[0];
        line_buffer_out[2] = interim_line_buffer_out[1];
      end else begin
        line_buffer_out[0] = interim_line_buffer_out[0];
        line_buffer_out[1] = interim_line_buffer_out[1];
        line_buffer_out[2] = interim_line_buffer_out[2];
      end    
    end
  end

  // pipelining (h_count_out, v_count_out, data_out_valid)
  logic [10:0] h_count_out_pipe[1:0];
  logic [9:0] v_count_out_pipe[1:0];
  logic data_out_valid_pipe[1:0];

  always_ff @(posedge clk) begin
    h_count_out_pipe[0] <= h_count_in;
    if (v_count_in >= 2) begin
      v_count_out_pipe[0] <= (v_count_in - 2);
    end else if (v_count_in == 0) begin
      v_count_out_pipe[0] <= (VRES - 2);
    end else begin
      v_count_out_pipe[0] <= (VRES - 1);
    end
    data_out_valid_pipe[0] <= data_in_valid;
    for (int i = 1; i < 2; i = i + 1) begin
      h_count_out_pipe[i] <= h_count_out_pipe[i - 1];
      v_count_out_pipe[i] <= v_count_out_pipe[i - 1];
      data_out_valid_pipe[i] <= data_out_valid_pipe[i - 1];
    end
  end
  always_comb begin
    if (rst) begin
      h_count_out = 0;
      v_count_out = 0;
      data_out_valid = 0;
    end else begin
      h_count_out = h_count_out_pipe[1];
      v_count_out = v_count_out_pipe[1];
      data_out_valid = data_out_valid_pipe[1];
    end
  end

endmodule


`default_nettype wire

