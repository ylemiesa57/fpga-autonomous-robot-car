`timescale 1ns / 1ps
`default_nettype none

// From lab 2
module pwm (
    input wire clk,
    input wire rst,
    input wire [7:0] dc_in,
    output logic sig_out
);
 
    logic [31:0] count;
    logic [7:0] dc_reg;

    logic [17:0] dc_reg_shift;

    counter mc (
        .clk(clk),
        .rst(rst),
        .period(255000),
        .count(count)
    );

    always_ff @(posedge clk) begin
        if (count >= 13000) begin
            dc_reg <= dc_in;
        end
    end

    assign dc_reg_shift = dc_reg << 10;
    assign sig_out = count < dc_reg_shift; //very simple threshold check

endmodule

`default_nettype wire
