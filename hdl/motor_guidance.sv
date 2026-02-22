`timescale 1ns / 1ps
`default_nettype none

module motor_guidance #(
    parameter WIDTH = 1280
)(
    input wire clk,
    input wire rst,
    input wire valid_midpoint,
    input wire [10:0] midpoint_calc,

    output logic [7:0] left_motor_pwm,
    output logic [7:0] right_motor_pwm
);
    localparam SCR_MID = WIDTH / 2;

    localparam MIDDLE_RANGE = 100;

    localparam SAMPLE_SIZE = 10;

    localparam COUNTER_SIZE = $clog2(SAMPLE_SIZE);

    logic [COUNTER_SIZE - 1: 0] counter;

    always_ff @(posedge clk) begin
        if (rst) begin
            left_motor_pwm <= '0;
            right_motor_pwm <= '0;
        end else begin
            if (valid_midpoint) begin
                // Keep straight range
                if (counter < (SAMPLE_SIZE - 1)) begin
                    counter <= counter + 1;
                end else begin
                    counter <= 0;
                    if (midpoint_calc >= (SCR_MID - 100) && midpoint_calc <= (SCR_MID + 100)) begin
                        left_motor_pwm <= 200;
                        right_motor_pwm <= 200;
                    end else if (midpoint_calc < (SCR_MID - 100)) begin
                        // Turn slightly left
                        left_motor_pwm <= 200;
                        right_motor_pwm <= 250;
                    end else begin
                        // Turn slightly right
                        left_motor_pwm <= 250;
                        right_motor_pwm <= 200;
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire