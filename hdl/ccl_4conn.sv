`timescale 1ns / 1ps
`default_nettype none

module tpss_ccl #(
    parameter WIDTH = 128,
    parameter HEIGHT = 128,
    parameter LABEL_BITS = 12
)(
    input wire clk,
    input wire rst,

    // Input Stream (From FIFO)
    input wire        s_axis_valid,
    input wire        s_axis_data, // 0=Background, 1=our bev scene, based on the bev output
    output logic      s_axis_ready,

    // final labels and their validity
    output logic                   m_axis_valid,
    output logic [LABEL_BITS-1:0]  m_axis_data,
    output logic                   m_axis_last,
    input wire                     m_axis_ready
);

    // memory
    localparam MEM_DEPTH = WIDTH * HEIGHT;
    localparam ADDR_BITS = $clog2(MEM_DEPTH);

    logic [LABEL_BITS-1:0] bram [0:MEM_DEPTH-1];
    logic [ADDR_BITS-1:0]  addr_a, addr_b;
    logic [LABEL_BITS-1:0] din_a, din_b;
    logic [LABEL_BITS-1:0] dout_a, dout_b;
    logic                  we_a, we_b;

    // Row buffers store the top neighbor so we avoid extra BRAM reads
    logic [LABEL_BITS-1:0] prev_row_label [0:WIDTH-1];
    logic [LABEL_BITS-1:0] curr_row_label [0:WIDTH-1];

    always_ff @(posedge clk) begin
        if (we_a) bram[addr_a] <= din_a;
        dout_a <= bram[addr_a];
    end
    always_ff @(posedge clk) begin
        if (we_b) bram[addr_b] <= din_b;
        dout_b <= bram[addr_b];
    end

    // state machine stuff
    typedef enum {
        IDLE,
        P1_FETCH_TOP,
        P1_PROCESS,
        RESOLVE_INIT,
        RESOLVE_FIND_ROOT_A,
        RESOLVE_FIND_ROOT_B,
        RESOLVE_MERGE,
        P2_READ,
        P2_FIND_ROOT,
        P2_FIND_ROOT_LOOP,
        P2_OUTPUT
    } state_t;

    state_t state;
    
    logic [ADDR_BITS-1:0]  pixel_idx;
    logic [LABEL_BITS-1:0] next_new_label;
    logic [LABEL_BITS-1:0] left_label; // Register for L_left
    logic [LABEL_BITS-1:0] top_label;  // L_top (buffered row data)
    logic [LABEL_BITS-1:0] root_a, root_b;
    logic [LABEL_BITS-1:0] curr_p2_label;
    logic [LABEL_BITS-1:0] p2_search_label;
    logic [LABEL_BITS-1:0] label_to_write;
    logic conflict_pending;
    integer i;

    wire is_first_row = (pixel_idx < WIDTH);
    wire is_first_col = (pixel_idx % WIDTH == 0);

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            pixel_idx <= 0;
            next_new_label <= 1;
            left_label <= 0;
            s_axis_ready <= 0;
            m_axis_valid <= 0;
            we_a <= 0; we_b <= 0;
            for (i = 0; i < WIDTH; i++) begin
                prev_row_label[i] <= 0;
                curr_row_label[i] <= 0;
            end
            conflict_pending <= 0;
            label_to_write <= 0;
            top_label <= 0;
        end else begin
            // Default pulldowns
            we_a <= 0; we_b <= 0;
            m_axis_valid <= 0;
            m_axis_last <= 0;

            case (state)
                IDLE: begin
                    pixel_idx <= 0;
                    next_new_label <= 1;
                    left_label <= 0;
                    s_axis_ready <= 1; // Open valve
                    if (s_axis_valid) begin
                        state <= P1_FETCH_TOP;
                    end
                end

                // pass 1 : labelling and mergin
                
                // Step 1: Read 'Top' neighbor from BRAM
                P1_FETCH_TOP: begin
                    s_axis_ready <= 0;
                    top_label <= prev_row_label[pixel_idx % WIDTH];
                    state <= P1_PROCESS;
                end

                // Step 2: Check neighbors and assign label
                P1_PROCESS: begin
                    conflict_pending <= 0;
                    label_to_write <= 0;
                    
                    if (s_axis_data == 0) begin
                        // Background
                        label_to_write <= 0;
                        left_label <= 0;
                    end else begin
                        // Foreground
                        logic [LABEL_BITS-1:0] l_L, l_T;
                        l_L = is_first_col ? 0 : left_label;
                        l_T = is_first_row ? 0 : top_label;

                        if (l_L == 0 && l_T == 0) begin
                            // New Object
                            label_to_write <= next_new_label;
                            left_label <= next_new_label;
                            next_new_label <= next_new_label + 1;
                        end else if (l_L != 0 && l_T == 0) begin
                            // Copy Left
                            label_to_write <= l_L;
                            left_label <= l_L;
                        end else if (l_L == 0 && l_T != 0) begin
                            // Copy Top
                            label_to_write <= l_T;
                            left_label <= l_T;
                        end else if (l_L == l_T) begin
                            // Match
                            label_to_write <= l_L;
                            left_label <= l_L;
                        end else begin
                            // CONFLICT (l_L != l_T)
                            // We default to l_L for this pixel, but we must MERGE l_L and l_T in BRAM.
                            label_to_write <= l_L;
                            left_label <= l_L;
                            
                            // Trigger Resolution
                            state <= RESOLVE_INIT;
                            root_a <= l_L;
                            root_b <= l_T;
                            conflict_pending <= 1;
                        end
                    end
                    
                    // Write the label for *this* pixel
                    addr_a <= pixel_idx;
                    din_a <= label_to_write;
                    we_a <= 1;
                    curr_row_label[pixel_idx % WIDTH] <= label_to_write;
                    
                    // Increment
                    if (!conflict_pending) begin
                            pixel_idx <= pixel_idx + 1;
                        if (pixel_idx == MEM_DEPTH - 1) begin
                            state <= P2_READ; // End of Frame
                            pixel_idx <= 0;
                        end else begin
                            s_axis_ready <= 1; // Request next pixel
                                state <= P1_FETCH_TOP;
                                if ((pixel_idx % WIDTH) == WIDTH - 1) begin
                                    for (int j = 0; j < WIDTH; j++) begin
                                        prev_row_label[j] <= curr_row_label[j];
                                    end
                                end
                        end
                    end
                end

                // --- CONFLICT RESOLUTION (UNION-FIND) ---
                
                RESOLVE_INIT: begin
                    we_a <= 0; // Stop writing current pixel
                    // Start finding root for A
                    addr_b <= root_a;
                    state <= RESOLVE_FIND_ROOT_A;
                end

                RESOLVE_FIND_ROOT_A: begin
                    if (dout_b == root_a) begin
                        // Found Root A
                        addr_b <= root_b; // Start finding root B
                        state <= RESOLVE_FIND_ROOT_B;
                    end else begin
                        // Keep traversing up
                        root_a <= dout_b;
                        addr_b <= dout_b;
                    end
                end

                RESOLVE_FIND_ROOT_B: begin
                    if (dout_b == root_b) begin
                        // Found Root B
                        state <= RESOLVE_MERGE;
                    end else begin
                        // Keep traversing up
                        root_b <= dout_b;
                        addr_b <= dout_b;
                    end
                end

                RESOLVE_MERGE: begin
                    // Point larger root to smaller root
                    if (root_a < root_b) begin
                        addr_a <= root_b;
                        din_a  <= root_a;
                        we_a   <= 1;
                    end else if (root_b < root_a) begin
                        addr_a <= root_a;
                        din_a  <= root_b;
                        we_a   <= 1;
                    end
                    // Conflict Resolved. Resume stream.
                    pixel_idx <= pixel_idx + 1;
                    if (pixel_idx == MEM_DEPTH - 1) state <= P2_READ;
                    else begin
                        s_axis_ready <= 1;
                        state <= P1_FETCH_TOP;
                    end
                end

                //pass 2: flatten and output

                P2_READ: begin
                    addr_b <= pixel_idx; // Read stored label
                    state <= P2_FIND_ROOT;
                end

                P2_FIND_ROOT: begin
                    // This is the recursive "Path Compression" or just simple lookup
                    // Simplest HW: Iterate until dout_b == address
                    // dout_b holds the parent of the pixel we just read
                    p2_search_label <= dout_b;
                    state <= P2_FIND_ROOT_LOOP;
                end

                P2_FIND_ROOT_LOOP: begin
                    addr_b <= p2_search_label;
                    if (dout_b == p2_search_label || dout_b == 0) begin
                        curr_p2_label <= p2_search_label;
                        state <= P2_OUTPUT;
                    end else begin
                        p2_search_label <= dout_b;
                    end
                end

                P2_OUTPUT: begin
                    m_axis_valid <= 1;
                    m_axis_data <= curr_p2_label;
                    if (pixel_idx == MEM_DEPTH - 1) begin
                        m_axis_last <= 1;
                        if (m_axis_ready) begin
                           state <= IDLE;
                           pixel_idx <= 0;
                        end
                    end else begin
                        if (m_axis_ready) begin
                            pixel_idx <= pixel_idx + 1;
                            state <= P2_READ;
                        end
                    end
                end

            endcase
        end
    end

endmodule
`default_nettype wire