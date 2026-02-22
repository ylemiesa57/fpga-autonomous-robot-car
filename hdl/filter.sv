`default_nettype none
`timescale 1ns / 1ps
module filter (
  input wire clk,
  input wire rst,

  input wire data_in_valid,
  input wire [15:0] pixel_data_in,
  input wire [10:0] h_count_in,
  input wire [9:0] v_count_in,

  output logic data_out_valid,
  output logic [15:0] pixel_data_out,
  output logic [10:0] h_count_out,
  output logic [9:0] v_count_out
  );
  parameter K_SELECT = 0;
  parameter HRES = 1280;
  parameter VRES = 720;

  localparam KERNEL_DIMENSION = 3;
  logic [KERNEL_DIMENSION-1:0][15:0] buffs;
  logic b_to_c_valid;
  //have to add more stuff here:
  logic [10:0] h_count_buff; //hard code like a loser whatever
  logic [9:0] v_count_buff;

  line_buffer #(.HRES(HRES),
                .VRES(VRES))
    m_lbuff (
    .clk(clk),
    .rst(rst),
    .data_in_valid(data_in_valid),
    .pixel_data_in(pixel_data_in),
    .h_count_in(h_count_in),
    .v_count_in(v_count_in),
    .data_out_valid(b_to_c_valid),
    .line_buffer_out(buffs),
    .h_count_out(h_count_buff),
    .v_count_out(v_count_buff)
    );

  convolution #(
    .K_SELECT(K_SELECT) )
    mconv (
    .clk(clk),
    .rst(rst),
    .data_in(buffs),
    .data_in_valid(b_to_c_valid),
    .h_count_in(h_count_buff),
    .v_count_in(v_count_buff),
    .line_out(pixel_data_out),
    .data_out_valid(data_out_valid),
    .h_count_out(h_count_out),
    .v_count_out(v_count_out)
  );

endmodule

`default_nettype wire
