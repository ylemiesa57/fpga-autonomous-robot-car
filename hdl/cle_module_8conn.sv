`timescale 1ns / 1ps
`default_nettype none

// We treat the incoming BEV mask as a streamed image and run a two-pass 8-connect CCL.
// Pass 1 walks the image in raster order, hands out provisional labels, and builds a BRAM-based union-find table.
// Whenever we see conflicts between neighbor labels, we pause to resolve them in BRAM before continuing.
// After the frame is stored, Pass 2 replays every pixel, compresses the union-find chains,
// and streams out the final label plus x/y coordinates so downstream logic can compute centroids.
// Connected Components Labeling (8-connectivity) Main Module
module cle_module_8conn #(
    parameter int WIDTH = 354,
    parameter int HEIGHT = 144,
    parameter int LABEL_BITS = 10,
    parameter int MAX_COMPONENTS = 16 // Unused in BRAM version logic but kept for interface compatibility
)(
    input wire clk,
    input wire rst,

    // Input Stream (From FIFO)
    input wire s_axis_valid,          // New pixel available
    input wire s_axis_data,           // Binary input: foreground/background
    output logic s_axis_ready,        // Ready for next pixel

    // Output Stream (Label + Coordinates)
    output logic m_axis_valid,
    output logic [LABEL_BITS-1:0] m_axis_label,
    output logic [$clog2(WIDTH)-1:0] m_axis_x,
    output logic [$clog2(HEIGHT)-1:0] m_axis_y,
    output logic m_axis_last,
    input wire m_axis_ready
);

    // --- BRAM DEFINITIONS ---
    localparam MEM_DEPTH = WIDTH * HEIGHT;    // Total number of pixels (frame size)
    localparam ADDR_BITS = $clog2(MEM_DEPTH); // Required bits for addressing all pixels
    localparam GEN_BITS = 2; // Generation bits to track frame validity
    // Generation tags keep stale BRAM entries from being misread after a new frame starts.
    localparam ENTRY_WIDTH = LABEL_BITS + GEN_BITS;
    localparam X_BITS = $clog2(WIDTH);
    localparam Y_BITS = $clog2(HEIGHT);

    // BRAM Port/Signal Declarations
    logic [ADDR_BITS-1:0] addr_a;            // Address for Port A (read/write)
    logic [ADDR_BITS-1:0] addr_b;            // Address for Port B (read-only)
    logic [ENTRY_WIDTH-1:0] din_a;           // Data in for Port A
    logic [ENTRY_WIDTH-1:0] din_b;           // Data in for Port B (unused/const)
    logic [ENTRY_WIDTH-1:0] dout_a;          // Data out from Port A
    logic [ENTRY_WIDTH-1:0] dout_b;          // Data out from Port B (main BRAM readback)
    logic we_a;                              // Write enable for Port A

    // Instantiate dual-port RAM for storing labels
    xilinx_true_dual_port_read_first_1_clock_ram #(
        .RAM_WIDTH(ENTRY_WIDTH),
        .RAM_DEPTH(MEM_DEPTH)
    ) label_table_bram (
        .addra(addr_a),       // Address port A
        .clka(clk),           // Clock
        .wea(we_a),           // Write enable
        .dina(din_a),         // Data input A
        .ena(1'b1),           // Enable always
        .rsta(rst),           // Reset
        .regcea(1'b1),        // Clock-enable output reg (A)
        .douta(dout_a),       // Data output A

        // Port B settings
        .addrb(addr_b),
        .web(1'b0),
        .dinb('0),
        .enb(1'b1),
        .rstb(rst),
        .regceb(1'b1),
        .doutb(dout_b)
    );

    // Line buffer for previous row (for accessing neighbors above)
    logic [LABEL_BITS-1:0] row_buffer [0:WIDTH-1];
    logic [GEN_BITS-1:0] row_buffer_gen [0:WIDTH-1];

    // State definition for the main state machine
    typedef enum {
        IDLE,
        P1_WAIT_PIXEL,
        P1_PROCESS,
        RESOLVE_INIT,
        RESOLVE_FIND_A,
        RESOLVE_CHECK_A,
        RESOLVE_FIND_B,
        RESOLVE_CHECK_B,
        RESOLVE_MERGE,
        P2_READ,
        P2_WAIT,
        P2_TRAVERSE,
        P2_OUTPUT
    } state_t;

    state_t state;

    // Pixel/position tracking
    logic [ADDR_BITS-1:0] pixel_idx;    // Linear pixel index progress
    logic [X_BITS-1:0] curr_x;          // X coordinate (for output)
    logic [Y_BITS-1:0] curr_y;          // Y coordinate (for output)

    // Label bookkeeping
    logic [LABEL_BITS-1:0] next_new_label;     // Next free label (incremented on new component)
    logic [LABEL_BITS-1:0] reg_left;           // Stored label for left neighbor
    logic [LABEL_BITS-1:0] win_top [0:2];      // Win_top[0]=NW, [1]=N, [2]=NE: previous row labels for neighbor access
    logic [LABEL_BITS-1:0] root_a;             // Used for union-find conflict resolution (first root)
    logic [LABEL_BITS-1:0] root_b;             // Used for union-find conflict resolution (second root)
    logic                  curr_pixel_bit;     // Latched value of current pixel (foreground/background)
    logic                  pixel_active;       // Indicates the current pixel is being processed
    logic                  last_pixel_flag;    // Tracks when current output is the final pixel of the frame
    logic [GEN_BITS-1:0]   curr_generation;    // Generation tag for current frame

    // Bitmask to ensure each neighbor is processed for conflicts only once
    // conflict_mask[0]=L, [1]=NW, [2]=N, [3]=NE (cleared after each merge attempt)
    logic [3:0] conflict_mask; 
    
    // Temporary helper nets (declared once to satisfy synthesis restrictions)
    integer rb;
    integer ahead_idx;
    logic [LABEL_BITS-1:0] idle_start_ne;
    logic [LABEL_BITS-1:0] wait_ne_value;
    logic [LABEL_BITS-1:0] row_prime_value;
    logic [LABEL_BITS-1:0] ahead_value;
    logic [LABEL_BITS-1:0] L;
    logic [LABEL_BITS-1:0] NW;
    logic [LABEL_BITS-1:0] N;
    logic [LABEL_BITS-1:0] NE;
    logic [LABEL_BITS-1:0] chosen_label;
    logic                  conflict_found;
    logic [LABEL_BITS-1:0] parent_a;
    logic [GEN_BITS-1:0]   read_gen_a;
    logic [LABEL_BITS-1:0] read_label_a;
    logic [LABEL_BITS-1:0] parent_b;
    logic [GEN_BITS-1:0]   read_gen_b;
    logic [LABEL_BITS-1:0] read_label_b;
    logic [LABEL_BITS-1:0] parent_label;
    logic [GEN_BITS-1:0]   read_gen_p2;
    logic [LABEL_BITS-1:0] read_label_p2;

    // Main logic in always_ff, runs on clock
    always_ff @(posedge clk) begin
        idle_start_ne   = '0;
        wait_ne_value   = '0;
        row_prime_value = '0;
        ahead_value     = '0;
        ahead_idx       = 0;
        L               = '0;
        NW              = '0;
        N               = '0;
        NE              = '0;
        chosen_label    = '0;
        conflict_found  = 1'b0;
        parent_a        = '0;
        read_gen_a      = '0;
        read_label_a    = '0;
        parent_b        = '0;
        read_gen_b      = '0;
        read_label_b    = '0;
        parent_label    = '0;
        read_gen_p2     = '0;
        read_label_p2   = '0;
        if (rst) begin
            // On reset, initialize all major variables & state
            state <= IDLE;
            pixel_idx <= 0;
            curr_x <= 0;
            curr_y <= 0;
            next_new_label <= 1;
            s_axis_ready <= 0;
            m_axis_valid <= 0;
            m_axis_last <= 0;
            we_a <= 0;
            reg_left <= 0;
            win_top[0] <= 0;
            win_top[1] <= 0;
            win_top[2] <= 0;
            conflict_mask <= 4'b1111; // All neighbor conflicts to check (none resolved yet)
            curr_pixel_bit <= 0;
            pixel_active <= 0;
            last_pixel_flag <= 0;
            curr_generation <= '0;
            for (rb = 0; rb < WIDTH; rb = rb + 1) begin
                row_buffer[rb] <= 0;
                row_buffer_gen[rb] <= '0;
            end
        end else begin
            // These lines reset write enable and output valid after use in previous cycle
            we_a <= 0;
            m_axis_valid <= 0;
            m_axis_last <= 0;

            // FSM handles overall process (labeling, conflict resolution, relabeling output)
            case (state)
                IDLE: begin
                    // Start from the beginning for a new image
                    pixel_idx <= 0;
                    curr_x <= 0;
                    curr_y <= 0;
                    next_new_label <= 1;
                    reg_left <= 0;
                    win_top[0] <= 0;
                    win_top[1] <= 0;
                    conflict_mask <= 4'b1111;
                    pixel_active <= 0;
                    curr_pixel_bit <= 0;
                    m_axis_valid <= 0;
                    m_axis_last <= 0;
                    s_axis_ready <= 1;
                    if (s_axis_valid) begin
                        curr_pixel_bit <= s_axis_data;
                        pixel_active <= 1;
                        s_axis_ready <= 0;
                        idle_start_ne = '0;
                        if (WIDTH > 1 && row_buffer_gen[1] == curr_generation) begin
                            idle_start_ne = row_buffer[1];
                        end
                        win_top[2] <= idle_start_ne;
                        state <= P1_PROCESS;
                    end else begin
                        state <= P1_WAIT_PIXEL;
                    end
                end

                P1_WAIT_PIXEL: begin
                    s_axis_ready <= 1;
                    if (s_axis_valid) begin
                        curr_pixel_bit <= s_axis_data;
                        pixel_active <= 1;
                        s_axis_ready <= 0;
                        wait_ne_value = '0;
                        if (WIDTH > 1 && row_buffer_gen[1] == curr_generation) begin
                            wait_ne_value = row_buffer[1];
                        end
                        win_top[2] <= wait_ne_value;
                        state <= P1_PROCESS;
                    end
                end

                P1_PROCESS: begin
                    if (pixel_active) begin
                        m_axis_valid <= 0;
                        m_axis_last <= 0;

                        // 1. Map Window to Neighbors:
                        // L = left pixel label, NW = northwest, N = north, NE = northeast
                        L = (curr_x == 0) ? 0 : reg_left;
                        NW = (curr_x == 0 || curr_y == 0) ? 0 : win_top[0];
                        N = (curr_y == 0) ? 0 : win_top[1];
                        NE = (curr_x == WIDTH - 1 || curr_y == 0) ? 0 : win_top[2];

                        chosen_label   = 0;
                        conflict_found = 0;

                        if (curr_pixel_bit) begin
                            // 2. Pick the "Winning" Label (Priority: L -> NW -> N -> NE); else next_new_label
                            if (L) begin
                                chosen_label = L;
                            end else if (NW) begin
                                chosen_label = NW;
                            end else if (N) begin
                                chosen_label = N;
                            end else if (NE) begin
                                chosen_label = NE;
                    end else begin
                                chosen_label = next_new_label;
                            end


                            // Check for conflicting neighbor labels -- if so, resolve root/union (one at a time)

                            if (L && (L != chosen_label) && conflict_mask[0]) begin
                                conflict_found = 1;
                                root_a = chosen_label;
                                root_b = L;
                                conflict_mask[0] <= 0;
                            // Each else/if follows the 8-connectivity neighbor priority order

                            end else if (NW && (NW != chosen_label) && conflict_mask[1]) begin
                                conflict_found = 1;
                                root_a = chosen_label;
                                root_b = NW;
                                conflict_mask[1] <= 0;
                            end else if (N && (N != chosen_label) && conflict_mask[2]) begin
                                conflict_found = 1;
                                root_a = chosen_label;
                                root_b = N;
                                conflict_mask[2] <= 0;
                            end else if (NE && (NE != chosen_label) && conflict_mask[3]) begin
                                conflict_found = 1;
                                root_a = chosen_label;
                                root_b = NE;
                                conflict_mask[3] <= 0;
                            end
                        end

                        if (conflict_found) begin
                            s_axis_ready <= 0;     // Pause FIFO while resolving label collision
                            state <= RESOLVE_INIT; // Begin conflict (union-find style) processing
                        end else begin
                            // No conflicts this round - commit this label to BRAM and advance
                            
                            // If just assigned a new label, increment to next free label for future segments
                            if (curr_pixel_bit && chosen_label == next_new_label) begin
                                next_new_label <= next_new_label + 1;
                            end

                            // Save chosen label to BRAM (for pass 2 and possible future lookups)
                            addr_a <= pixel_idx;
                            din_a <= {chosen_label, curr_generation}; // 0 if background
                            we_a <= 1;

                            // Record for next pixel's left neighbor and update current row buffer
                            reg_left <= chosen_label;
                            row_buffer[curr_x] <= chosen_label;
                            row_buffer_gen[curr_x] <= curr_generation;

                            // Update window for northwest/north/northeast for next pixel
                            win_top[0] <= win_top[1];         // NW <= N
                            win_top[1] <= win_top[2];         // N <= NE
                            if (curr_x < WIDTH - 2) begin     // NE = next row_buffer slot (if available)
                                ahead_idx = curr_x + 2;
                                ahead_value = '0;
                                if ((ahead_idx >= 0) && (ahead_idx < WIDTH) && (row_buffer_gen[ahead_idx] == curr_generation)) begin
                                    ahead_value = row_buffer[ahead_idx];
                                end
                                win_top[2] <= ahead_value;
                            end else begin
                                win_top[2] <= 0;                        // Set NE to zero at right-most
                            end

                            conflict_mask <= 4'b1111; // Reset mask for next pixel

                            // If last pixel in frame, move to pass 2 (output)
                            if (pixel_idx == MEM_DEPTH - 1) begin
                                s_axis_ready <= 0; // Stop consuming input
                                pixel_idx <= 0;    // Reset for output

                                curr_x <= 0;
                                curr_y <= 0;
                                pixel_active <= 0;
                                state <= P2_READ;
                            end else begin

                                s_axis_ready <= 1;           // Accept more pixels
                                pixel_idx <= pixel_idx + 1;  // Next pixel
                                if (curr_x == WIDTH - 1) begin
                                    // End of row, go to next
                                    curr_x <= 0;
                                    curr_y <= curr_y + 1;
                                    win_top[0] <= 0;
                                    win_top[1] <= 0;
                                    row_prime_value = '0;
                                    if (WIDTH > 1 && row_buffer_gen[1] == curr_generation) begin
                                        row_prime_value = row_buffer[1];
                                    end
                                    win_top[2] <= row_prime_value; // Pre-prime NE (row startup)
                                end else begin
                                    curr_x <= curr_x + 1;        // Move to next column

                                end
                                pixel_active <= 0;
                                state <= P1_WAIT_PIXEL;
                            end
                        end
                    end
                end

                RESOLVE_INIT: begin
                    // Set up root tracing for union-find (of conflicting neighbors)
                    addr_b <= root_a;
                    state <= RESOLVE_FIND_A;
                end

                RESOLVE_FIND_A: begin
                    // Begin scanning BRAM to find root representative for root_a
                    state <= RESOLVE_CHECK_A;
                end

                RESOLVE_CHECK_A: begin
                    // Traverse until at root of chosen_label (root_a)
                    read_gen_a = dout_b[GEN_BITS-1:0];
                    read_label_a = dout_b[ENTRY_WIDTH-1:GEN_BITS];
                    if (read_gen_a == curr_generation) begin
                        parent_a = read_label_a;
                    end else begin
                        parent_a = addr_b;
                    end
                    if (parent_a == addr_b) begin
                        // root found for root_a
                        root_a <= parent_a;
                        addr_b <= root_b;
                        state <= RESOLVE_FIND_B;
                        end else begin
                        // Follow the parent pointer to next label
                        addr_b <= parent_a;
                        state <= RESOLVE_FIND_A;
                    end
                end

                RESOLVE_FIND_B: begin
                    // Similar to A, setup for B's label chain traversal
                    state <= RESOLVE_CHECK_B;
                end

                RESOLVE_CHECK_B: begin
                    // Traverse until at root of root_b
                    read_gen_b = dout_b[GEN_BITS-1:0];
                    read_label_b = dout_b[ENTRY_WIDTH-1:GEN_BITS];
                    if (read_gen_b == curr_generation) begin
                        parent_b = read_label_b;
                    end else begin
                        parent_b = addr_b;
                    end
                    if (parent_b == addr_b) begin
                        // root found for root_b
                        root_b <= parent_b;
                        state <= RESOLVE_MERGE;
                    end else begin
                        // Keep traversing upward in label tree
                        addr_b <= parent_b;
                        state <= RESOLVE_FIND_B;
                            end
                        end

                RESOLVE_MERGE: begin
                    // If roots are different, merge them (union operation)
                    if (root_a != root_b) begin
                        if (root_a < root_b) begin
                            addr_a <= root_b;
                            din_a <= {root_a, curr_generation};
                            we_a <= 1;
                            end else begin
                            addr_a <= root_a;
                            din_a <= {root_b, curr_generation};
                            we_a <= 1;
                        end
                    end
                    s_axis_ready <= 0; // Still paused; must retry pixel in P1_PROCESS
                    state <= P1_PROCESS; // Go back to normal pass 1 logic
                end

                P2_READ: begin
                    // Initiate label read for next pixel
                    m_axis_valid <= 0;
                    m_axis_last <= 0;
                    addr_b <= pixel_idx;
                    state <= P2_WAIT;
                end

                P2_WAIT: begin
                    // Wait state to allow BRAM output to be available
                    state <= P2_TRAVERSE;
                end

                P2_TRAVERSE: begin
                    // "Path compression"/lookup through union-find tree,
                    // keep following parent pointers until root, or if label is background (0)
                    read_gen_p2 = dout_b[GEN_BITS-1:0];
                    read_label_p2 = dout_b[ENTRY_WIDTH-1:GEN_BITS];
                    if (read_gen_p2 == curr_generation) begin
                        parent_label = read_label_p2;
                    end else begin
                        parent_label = addr_b;
                    end

                    if ((parent_label == addr_b) || (parent_label == '0)) begin
                        // Final label/root found for this pixel
                        logic is_last_pixel;
                        is_last_pixel = ((curr_x == WIDTH - 1) && (curr_y == HEIGHT - 1));
                        m_axis_valid <= 1;
                        m_axis_label <= parent_label;
                        m_axis_x <= curr_x;
                        m_axis_y <= curr_y;
                        m_axis_last <= is_last_pixel;
                        last_pixel_flag <= is_last_pixel;
                        state <= P2_OUTPUT;
                    end else begin
                        // Otherwise, keep traversing label equivalence chain
                        addr_b <= parent_label;
                        state <= P2_WAIT;
                    end
                end

                P2_OUTPUT: begin
                    // Output one labeled pixel per cycle
                    if (m_axis_ready) begin
                        if (last_pixel_flag) begin
                            // Last pixel in image/frame. Signal completion.
                            last_pixel_flag <= 0;
                            curr_generation <= curr_generation + 1'b1;
                            state <= IDLE;
                        end else begin

                            pixel_idx <= pixel_idx + 1;
                            if (curr_x == WIDTH - 1) begin
                                // End of row, go to next
                                curr_x <= 0;
                                curr_y <= curr_y + 1;
                            end else begin
                                curr_x <= curr_x + 1;
                            end
                            last_pixel_flag <= 0;
                            state <= P2_READ;
                        end
                    end
                end

            endcase
        end
    end

endmodule

`default_nettype wire