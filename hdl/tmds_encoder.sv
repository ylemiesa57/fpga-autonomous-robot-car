`timescale 1ns / 1ps
`default_nettype none
 
module tmds_encoder(
        input wire clk,
        input wire rst,
        input wire [7:0] video_data,  // video data (red, green or blue)
        input wire [1:0] control,   //for blue set to {vs,hs}, else will be 0
        input wire video_enable,    //choose between control (0) or video (1)
        output logic [9:0] tmds
    );
    logic [8:0] q_m;
 
    tm_choice mtm(
        .d(video_data),
        .q_m(q_m)
    );

    //your code here.
    logic [4:0] tally;

    logic [4:0] one_counter;
    logic [4:0] zero_counter;
    logic first_cond;
    logic second_cond;

    always_comb begin
      one_counter = 0;
      zero_counter = 0;
      for (integer i = 0; i < 8; i = i + 1) begin
        if (q_m[i] == 1) begin
          one_counter = one_counter + 1;
        end else begin
          zero_counter = zero_counter + 1;
        end
      end
    end

  always_ff @(posedge clk) begin
    if (rst) begin
      tmds <= 0;
      tally <= 0;
    end else begin
      if (!video_enable) begin
        tally <= 0;
        case (control) 
          2'b00: begin
            tmds <= 10'b1101010100;
          end
          2'b01: begin
            tmds <= 10'b0010101011;
          end
          2'b10: begin
            tmds <= 10'b0101010100;
          end
          2'b11: begin
            tmds <= 10'b1010101011;
          end 
          default: tmds <= tmds;
        endcase
      end else begin
        if ((tally == 0) || (one_counter == zero_counter)) begin
          tmds[9] <= ~q_m[8];
          tmds[8] <= q_m[8];
          tmds[7:0] <= (q_m[8]) ? q_m[7:0] : ~q_m[7:0];
          if (!q_m[8]) begin
            tally <= tally + zero_counter - one_counter;
          end else begin
            tally <= tally + one_counter - zero_counter;
          end
        end else begin
          if ((tally[4] == 0 && (one_counter > zero_counter)) || (tally[4] == 1 && (zero_counter > one_counter))) begin
            tmds[9] <= 1;
            tmds[8] <= q_m[8];
            tmds[7:0] <= ~q_m[7:0];
            tally <= tally + (q_m[8] ? 5'd2 : 0) + zero_counter - one_counter;
          end else begin
            tmds[9] <= 0;
            tmds[8] <= q_m[8];
            tmds[7:0] <= q_m[7:0];
            tally <= tally - (q_m[8] ? 0 : 5'd2) + one_counter - zero_counter;
          end
        end
      end
    end
  end
endmodule
 
`default_nettype wire