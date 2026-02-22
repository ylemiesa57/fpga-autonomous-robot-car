`default_nettype none
module evt_counter
    #(
        parameter MAX_COUNT = 115199
    )
    (   input wire          clk,
        input wire          rst,
        input wire          evt,
        output logic[23:0]  count
    );
    always_ff @(posedge clk) begin
        if (rst) begin
            count <= 16'b0;
        end else begin
            /* your code here */
            if (evt) begin
                if (count < MAX_COUNT) begin
                    count <= count + 1;
                end else begin
                    count <= 0;
                end
            end
        end
    end
endmodule
`default_nettype wire