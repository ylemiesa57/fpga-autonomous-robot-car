`timescale 1ns / 1ps
`default_nettype none

module command_fifo #(parameter DEPTH=16, parameter WIDTH=16)(
        input wire clk,
        input wire rst,
        input wire write,
        input wire [WIDTH-1:0] command_in,
        output logic full,

        output logic [WIDTH-1:0] command_out,
        input wire read,
        output logic empty
    );

    logic [$clog2(DEPTH)-1:0]   write_pointer;
    logic [$clog2(DEPTH)-1:0]   read_pointer;
    logic [WIDTH-1:0] fifo [DEPTH-1:0]; //makes BRAM with one unpacked and one packed dimension

    logic new_read;

    // command_out & empty & full control
    always_comb begin
        if (rst) begin
            command_out = 0;
            full = 0;
            empty = 1;
        end else begin
            empty = (read_pointer == write_pointer) ? 1 : 0;
            full = (((write_pointer == (DEPTH-1)) && (read_pointer == 0)) || ((write_pointer + 1) == read_pointer)) ? 1 : 0;
            command_out = fifo[read_pointer];
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            write_pointer <= 0;
            read_pointer <= 0;
        end else begin
            if (write && !full) begin
                fifo[write_pointer] <= command_in;
                write_pointer <= write_pointer + 1;
            end 
            if (read && !empty) begin
                // fifo[read_pointer] <= 0;
                read_pointer <= read_pointer + 1;
            end
        end
    end

endmodule
`default_nettype wire
