`timescale 1ns / 1ps
`default_nettype none

module divider #(parameter WIDTH = 32)
    (
        input wire clk,
        input wire rst,
        input wire [WIDTH-1:0] dividend,
        input wire [WIDTH-1:0] divisor,
        input wire data_in_valid,
        output logic [WIDTH-1:0] quotient,
        output logic [WIDTH-1:0] remainder,
        output logic data_out_valid,
        output logic error,
        output logic busy
    );

    typedef enum logic [0:0] {RESTING, DIVIDING} state_t;

    state_t state;
    logic [WIDTH-1:0] quotient_g;
    logic [WIDTH-1:0] dividend_h;
    logic [WIDTH-1:0] divisor_h;

    always_ff @(posedge clk) begin
        if (rst) begin
            quotient_g      <= '0;
            dividend_h      <= '0;
            divisor_h       <= '0;
            quotient        <= '0;
            remainder       <= '0;
            busy            <= 1'b0;
            error           <= 1'b0;
            data_out_valid  <= 1'b0;
            state           <= RESTING;
        end else begin
            data_out_valid <= 1'b0;
            case (state)
                RESTING: begin
                    busy   <= 1'b0;
                    error  <= 1'b0;
                    if (data_in_valid) begin
                        if (divisor == '0) begin
                            quotient       <= '0;
                            remainder      <= dividend;
                            error          <= 1'b1;
                            data_out_valid <= 1'b1;
                        end else begin
                            state       <= DIVIDING;
                            quotient_g  <= '0;
                            dividend_h  <= dividend;
                            divisor_h   <= divisor;
                            busy        <= 1'b1;
                        end
                    end
                end
                DIVIDING: begin
                    if (dividend_h == '0) begin
                        state           <= RESTING;
                        quotient        <= quotient_g;
                        remainder       <= '0;
                        busy            <= 1'b0;
                        error           <= 1'b0;
                        data_out_valid  <= 1'b1;
                    end else if (divisor_h == '0) begin
                        state           <= RESTING;
                        quotient        <= '0;
                        remainder       <= '0;
                        busy            <= 1'b0;
                        error           <= 1'b1;
                        data_out_valid  <= 1'b1;
                    end else if (dividend_h < divisor_h) begin
                        state           <= RESTING;
                        quotient        <= quotient_g;
                        remainder       <= dividend_h;
                        busy            <= 1'b0;
                        error           <= 1'b0;
                        data_out_valid  <= 1'b1;
                    end else begin
                        dividend_h <= dividend_h - divisor_h;
                        quotient_g <= quotient_g + 1'b1;
                        busy       <= 1'b1;
                        error      <= 1'b0;
                    end
                end
                default: begin
                    state          <= RESTING;
                    busy           <= 1'b0;
                    error          <= 1'b0;
                    data_out_valid <= 1'b0;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
