module tm_choice (
        input wire [7:0] d, //data byte in
        output logic [8:0] q_m //transition minimized output
    );

    logic [3:0] ones_counter;
    always_comb begin
        ones_counter = 0;
        for (integer i = 0; i < 8; i = i + 1) begin
            if (d[i] == 1) begin
                ones_counter = ones_counter + 1;
            end
        end
        // option 2
        if (ones_counter > 4 || (ones_counter == 4 && d[0] == 0)) begin
            q_m[0] = d[0];
            for (integer i = 1; i < 8; i = i + 1) begin
                q_m[i] = ~(d[i] ^ q_m[i - 1]);
            end
            q_m[8] = 0;
        // option 1
        end else begin
            q_m[0] = d[0];
            for (integer i = 1; i < 8; i = i + 1) begin
                q_m[i] = d[i] ^ q_m[i - 1];
            end
            q_m[8] = 1;
        end
    end
 
endmodule