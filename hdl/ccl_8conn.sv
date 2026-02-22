`timescale 1ns / 1ps
`default_nettype none

// TPSS-CCL 8-Connectivity Implementation
// =======================================
// This module implements Two-Pass Scan-line CCL using address-based union-find.
// 
// Key design decisions (per TPSS paper):
// - BRAM stores parent ADDRESSES (not compact labels)
// - A root pixel stores its own address: BRAM[addr] = addr
// - Union-find chase follows addresses until parent == addr (root found)
// - Pass 2 compacts root addresses to sequential labels 1, 2, 3...
//
// Pass 1: Scan image, assign parent pointers, resolve conflicts via union-find
// Pass 2: Chase each pixel to root, map roots to compact labels, output

module tpss_ccl_8conn #(
    parameter int WIDTH = 708,
    parameter int HEIGHT = 146,
    parameter int LABEL_BITS = 12,      // Output label width (compact labels)
    parameter int GEN_BITS = 2,
    parameter int MAX_COMPONENTS = 256  // Max distinct components for compaction
)(
    input wire clk,
    input wire rst,

    // Input Stream (From FIFO)
    input wire s_axis_valid,
    input wire s_axis_data,             // Binary: 1=foreground, 0=background
    output logic s_axis_ready,

    // Output Stream (Label + Coordinates)
    output logic m_axis_valid,
    output logic [LABEL_BITS-1:0] m_axis_label,
    output logic [$clog2(WIDTH)-1:0] m_axis_x,
    output logic [$clog2(HEIGHT)-1:0] m_axis_y,
    output logic m_axis_last,
    input wire m_axis_ready
);

    // --- PARAMETERS ---
    localparam MEM_DEPTH = WIDTH * HEIGHT;
    localparam ADDR_BITS = $clog2(MEM_DEPTH);
    localparam ENTRY_WIDTH = ADDR_BITS + GEN_BITS;  // Parent address + generation
    localparam X_BITS = $clog2(WIDTH);
    localparam Y_BITS = $clog2(HEIGHT);
    localparam COMPACT_ADDR_BITS = $clog2(MAX_COMPONENTS);

    // --- BRAM for parent pointers (indexed by pixel address) ---
    logic [ADDR_BITS-1:0] addr_a;
    logic [ADDR_BITS-1:0] addr_b;
    logic [ENTRY_WIDTH-1:0] din_a;
    logic [ENTRY_WIDTH-1:0] dout_a;
    logic [ENTRY_WIDTH-1:0] dout_b;
    logic we_a;

    xilinx_true_dual_port_read_first_1_clock_ram #(
        .RAM_WIDTH(ENTRY_WIDTH),
        .RAM_DEPTH(MEM_DEPTH)
    ) parent_bram (
        .addra(addr_a),
        .clka(clk),
        .wea(we_a),
        .dina(din_a),
        .ena(1'b1),
        .rsta(rst),
        .regcea(1'b1),
        .douta(dout_a),
        .addrb(addr_b),
        .web(1'b0),
        .dinb('0),
        .enb(1'b1),
        .rstb(rst),
        .regceb(1'b1),
        .doutb(dout_b)
    );

    // --- Root-to-compact-label mapping (for Pass 2) ---
    // Small table: root_addr -> compact_label
    logic [ADDR_BITS-1:0] root_map_addr [0:MAX_COMPONENTS-1];
    logic [LABEL_BITS-1:0] root_map_label [0:MAX_COMPONENTS-1];
    logic [COMPACT_ADDR_BITS-1:0] num_roots;
    logic [LABEL_BITS-1:0] next_compact_label;

    // --- Line buffer for previous row (stores parent addresses) ---
    logic [ADDR_BITS-1:0] row_buffer [0:WIDTH-1];
    logic [GEN_BITS-1:0] row_buffer_gen [0:WIDTH-1];

    // --- State Machine ---
    typedef enum logic [4:0] {
        IDLE,
        P1_WAIT_PIXEL,
        P1_PROCESS,
        RESOLVE_INIT,
        RESOLVE_FIND_A,
        RESOLVE_WAIT_A,     // Extra wait for BRAM latency
        RESOLVE_CHECK_A,
        RESOLVE_FIND_B,
        RESOLVE_WAIT_B,     // Extra wait for BRAM latency
        RESOLVE_CHECK_B,
        RESOLVE_MERGE,
        P2_READ,
        P2_WAIT1,           // First wait cycle
        P2_WAIT2,           // Second wait cycle (for output register)
        P2_TRAVERSE,
        P2_LOOKUP,
        P2_OUTPUT
    } state_t;

    state_t state;

    // --- Pixel/position tracking ---
    logic [ADDR_BITS-1:0] pixel_idx;
    logic [X_BITS-1:0] curr_x;
    logic [Y_BITS-1:0] curr_y;

    // --- Address-based bookkeeping ---
    logic [ADDR_BITS-1:0] reg_left;           // Left neighbor's parent address
    logic [ADDR_BITS-1:0] win_top [0:2];      // [0]=NW, [1]=N, [2]=NE parent addresses
    logic [ADDR_BITS-1:0] root_a;             // Root address during conflict resolution
    logic [ADDR_BITS-1:0] root_b;             // Second root address
    logic [ADDR_BITS-1:0] chosen_addr;        // Chosen parent address for current pixel
    logic [ADDR_BITS-1:0] p2_root_addr;       // Root address found during Pass 2

    // --- Control signals ---
    logic curr_pixel_bit;
    logic pixel_active;
    logic last_pixel_flag;
    logic [GEN_BITS-1:0] curr_generation;
    logic [3:0] conflict_mask; 

    // --- Combinational signals for neighbor lookup ---
    logic [ADDR_BITS-1:0] L_addr, NW_addr, N_addr, NE_addr;
    logic L_valid, NW_valid, N_valid, NE_valid;
    
    // --- Background marker: use all 1s (invalid address) to distinguish from address 0 ---
    localparam [ADDR_BITS-1:0] BG_MARKER = {ADDR_BITS{1'b1}};
    
    // --- Temporary signals for FSM (replacing automatic variables) ---
    logic [ADDR_BITS-1:0] temp_chosen;
    logic [ADDR_BITS-1:0] final_addr;
    logic [GEN_BITS-1:0] read_gen;
    logic [ADDR_BITS-1:0] read_addr;
    logic [ADDR_BITS-1:0] parent_ptr;
    logic [LABEL_BITS-1:0] compact_label;
    logic found_in_map;
    integer ahead_idx;
    integer i;

    // Neighbor address computation (combinational)
    always_comb begin
        // Default: no valid neighbors (use BG_MARKER)
        L_addr = BG_MARKER;
        NW_addr = BG_MARKER;
        N_addr = BG_MARKER;
        NE_addr = BG_MARKER;
        L_valid = 1'b0;
        NW_valid = 1'b0;
        N_valid = 1'b0;
        NE_valid = 1'b0;

        // Left neighbor (same row, previous column)
        if (curr_x != 0) begin
            L_addr = reg_left;
            L_valid = (reg_left != BG_MARKER);
        end

        // Northwest neighbor (previous row, previous column)
        if (curr_x != 0 && curr_y != 0) begin
            NW_addr = win_top[0];
            NW_valid = (win_top[0] != BG_MARKER);
        end

        // North neighbor (previous row, same column)
        if (curr_y != 0) begin
            N_addr = win_top[1];
            N_valid = (win_top[1] != BG_MARKER);
        end

        // Northeast neighbor (previous row, next column)
        if (curr_x != WIDTH - 1 && curr_y != 0) begin
            NE_addr = win_top[2];
            NE_valid = (win_top[2] != BG_MARKER);
        end
    end

    // --- Main FSM ---
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            pixel_idx <= '0;
            curr_x <= '0;
            curr_y <= '0;
            s_axis_ready <= 1'b0;
            m_axis_valid <= 1'b0;
            m_axis_last <= 1'b0;
            m_axis_label <= '0;
            m_axis_x <= '0;
            m_axis_y <= '0;
            we_a <= 1'b0;
            addr_a <= '0;
            addr_b <= '0;
            din_a <= '0;
            reg_left <= BG_MARKER;
            win_top[0] <= BG_MARKER;
            win_top[1] <= BG_MARKER;
            win_top[2] <= BG_MARKER;
            root_a <= '0;
            root_b <= '0;
            chosen_addr <= BG_MARKER;
            p2_root_addr <= BG_MARKER;
            conflict_mask <= 4'b1111;
            curr_pixel_bit <= 1'b0;
            pixel_active <= 1'b0;
            last_pixel_flag <= 1'b0;
            curr_generation <= 2'd1;  // Start at 1 so gen-0 stale data won't match
            num_roots <= '0;
            next_compact_label <= 1;
            
            for (i = 0; i < WIDTH; i = i + 1) begin
                row_buffer[i] <= BG_MARKER;
                row_buffer_gen[i] <= '0;
            end
            for (i = 0; i < MAX_COMPONENTS; i = i + 1) begin
                root_map_addr[i] <= '0;
                root_map_label[i] <= '0;
            end
        end else begin
            // Default: clear one-cycle signals
            we_a <= 1'b0;
            m_axis_valid <= 1'b0;
            m_axis_last <= 1'b0;

            case (state)
                // ============================================================
                // IDLE: Wait for new frame, initialize state
                // ============================================================
                IDLE: begin
                    pixel_idx <= '0;
                    curr_x <= '0;
                    curr_y <= '0;
                    reg_left <= BG_MARKER;
                    win_top[0] <= BG_MARKER;
                    win_top[1] <= BG_MARKER;
                    win_top[2] <= BG_MARKER;
                    conflict_mask <= 4'b1111;
                    pixel_active <= 1'b0;
                    num_roots <= '0;
                    next_compact_label <= 1;
                    
                    // Clear root map for new frame
                    for (i = 0; i < MAX_COMPONENTS; i = i + 1) begin
                        root_map_addr[i] <= BG_MARKER;
                        root_map_label[i] <= '0;
                    end

                    s_axis_ready <= 1'b1;
                    if (s_axis_valid) begin
                        curr_pixel_bit <= s_axis_data;
                        pixel_active <= 1'b1;
                        s_axis_ready <= 1'b0;
                        // Pre-load NE for first pixel (col 1 of previous row if valid)
                        if (WIDTH > 1 && row_buffer_gen[1] == curr_generation) begin
                            win_top[2] <= row_buffer[1];
                        end else begin
                            win_top[2] <= BG_MARKER;
                        end
                        state <= P1_PROCESS;
                    end else begin
                        state <= P1_WAIT_PIXEL;
                    end
                end

                // ============================================================
                // P1_WAIT_PIXEL: Wait for next pixel from input stream
                // ============================================================
                P1_WAIT_PIXEL: begin
                    s_axis_ready <= 1'b1;
                    if (s_axis_valid) begin
                        curr_pixel_bit <= s_axis_data;
                        pixel_active <= 1'b1;
                        s_axis_ready <= 1'b0;
                        // Update win_top[2] for NE neighbor (if at start of new row)
                        if (curr_x == 0 && WIDTH > 1) begin
                            if (row_buffer_gen[1] == curr_generation) begin
                                win_top[2] <= row_buffer[1];
                            end else begin
                                win_top[2] <= BG_MARKER;
                            end
                        end
                        state <= P1_PROCESS;
                    end
                end

                // ============================================================
                // P1_PROCESS: Process current pixel, detect conflicts
                // ============================================================
                P1_PROCESS: begin
                    if (pixel_active) begin
                        // Compute temp_chosen for conflict detection
                        if (L_valid) begin
                            temp_chosen = L_addr;
                        end else if (NW_valid) begin
                            temp_chosen = NW_addr;
                        end else if (N_valid) begin
                            temp_chosen = N_addr;
                        end else if (NE_valid) begin
                            temp_chosen = NE_addr;
                        end else begin
                            temp_chosen = pixel_idx;
                        end

                        if (curr_pixel_bit) begin
                            // Foreground pixel: set chosen_addr
                            chosen_addr <= temp_chosen;

                            // Check for conflicts: any neighbor differs from chosen?
                            if (L_valid && (L_addr != temp_chosen) && conflict_mask[0]) begin
                                root_a <= temp_chosen;
                                root_b <= L_addr;
                                conflict_mask[0] <= 1'b0;
                                s_axis_ready <= 1'b0;
                                state <= RESOLVE_INIT;
                            end else if (NW_valid && (NW_addr != temp_chosen) && conflict_mask[1]) begin
                                root_a <= temp_chosen;
                                root_b <= NW_addr;
                                conflict_mask[1] <= 1'b0;
                                s_axis_ready <= 1'b0;
                                state <= RESOLVE_INIT;
                            end else if (N_valid && (N_addr != temp_chosen) && conflict_mask[2]) begin
                                root_a <= temp_chosen;
                                root_b <= N_addr;
                                conflict_mask[2] <= 1'b0;
                                s_axis_ready <= 1'b0;
                                state <= RESOLVE_INIT;
                            end else if (NE_valid && (NE_addr != temp_chosen) && conflict_mask[3]) begin
                                root_a <= temp_chosen;
                                root_b <= NE_addr;
                                conflict_mask[3] <= 1'b0;
                                s_axis_ready <= 1'b0;
                                state <= RESOLVE_INIT;
                            end else begin
                                // No conflict: commit and advance
                                final_addr = temp_chosen;

                                // Write parent pointer to BRAM
                                addr_a <= pixel_idx;
                                din_a <= {final_addr, curr_generation};
                                we_a <= 1'b1;

                                // Update left neighbor and row buffer
                                reg_left <= final_addr;
                                row_buffer[curr_x] <= final_addr;
                                row_buffer_gen[curr_x] <= curr_generation;

                                // Shift window for next pixel
                                win_top[0] <= win_top[1];
                                win_top[1] <= win_top[2];
                                ahead_idx = curr_x + 2;
                                if (curr_x < WIDTH - 2 && ahead_idx < WIDTH) begin
                                    if (row_buffer_gen[ahead_idx] == curr_generation) begin
                                        win_top[2] <= row_buffer[ahead_idx];
                                    end else begin
                                        win_top[2] <= BG_MARKER;
                                    end
                                end else begin
                                    win_top[2] <= BG_MARKER;
                                end

                                conflict_mask <= 4'b1111;

                                // Check if frame complete
                                if (pixel_idx == MEM_DEPTH - 1) begin
                                    s_axis_ready <= 1'b0;
                                    pixel_idx <= '0;
                                    curr_x <= '0;
                                    curr_y <= '0;
                                    pixel_active <= 1'b0;
                                    state <= P2_READ;
                                end else begin
                                    s_axis_ready <= 1'b1;
                                    pixel_idx <= pixel_idx + 1;
                                    if (curr_x == WIDTH - 1) begin
                                        curr_x <= '0;
                                        curr_y <= curr_y + 1;
                                        win_top[0] <= BG_MARKER;
                                        win_top[1] <= BG_MARKER;
                                        // Pre-load NE for new row
                                        if (WIDTH > 1 && row_buffer_gen[1] == curr_generation) begin
                                            win_top[2] <= row_buffer[1];
                                        end else begin
                                            win_top[2] <= BG_MARKER;
                                        end
                                    end else begin
                                        curr_x <= curr_x + 1;
                                    end
                                    pixel_active <= 1'b0;
                                    state <= P1_WAIT_PIXEL;
                                end
                            end
                        end else begin
                            // Background pixel: parent = BG_MARKER
                            chosen_addr <= BG_MARKER;
                            
                            // Write BG_MARKER to BRAM to mark background
                            addr_a <= pixel_idx;
                            din_a <= {BG_MARKER, curr_generation};
                            we_a <= 1'b1;

                            // Update left neighbor and row buffer
                            reg_left <= BG_MARKER;
                            row_buffer[curr_x] <= BG_MARKER;
                            row_buffer_gen[curr_x] <= curr_generation;

                            // Shift window
                            win_top[0] <= win_top[1];
                            win_top[1] <= win_top[2];
                                ahead_idx = curr_x + 2;
                            if (curr_x < WIDTH - 2 && ahead_idx < WIDTH) begin
                                if (row_buffer_gen[ahead_idx] == curr_generation) begin
                                    win_top[2] <= row_buffer[ahead_idx];
                                end else begin
                                    win_top[2] <= BG_MARKER;
                                end
                            end else begin
                                win_top[2] <= BG_MARKER;
                            end

                            conflict_mask <= 4'b1111;

                            // Check if frame complete
                            if (pixel_idx == MEM_DEPTH - 1) begin
                                s_axis_ready <= 1'b0;
                                pixel_idx <= '0;
                                curr_x <= '0;
                                curr_y <= '0;
                                pixel_active <= 1'b0;
                                state <= P2_READ;
                            end else begin
                                s_axis_ready <= 1'b1;
                                pixel_idx <= pixel_idx + 1;
                                if (curr_x == WIDTH - 1) begin
                                    curr_x <= '0;
                                    curr_y <= curr_y + 1;
                                    win_top[0] <= BG_MARKER;
                                    win_top[1] <= BG_MARKER;
                                    if (WIDTH > 1 && row_buffer_gen[1] == curr_generation) begin
                                        win_top[2] <= row_buffer[1];
                                    end else begin
                                        win_top[2] <= BG_MARKER;
                                    end
                                end else begin
                                    curr_x <= curr_x + 1;
                                end
                                pixel_active <= 1'b0;
                                state <= P1_WAIT_PIXEL;
                            end
                        end
                    end
                end

                // ============================================================
                // RESOLVE_INIT: Start root-finding for conflict resolution
                // ============================================================
                RESOLVE_INIT: begin
                    addr_b <= root_a;
                    state <= RESOLVE_FIND_A;
                end

                // ============================================================
                // RESOLVE_FIND_A: First wait cycle for BRAM read
                // ============================================================
                RESOLVE_FIND_A: begin
                    state <= RESOLVE_WAIT_A;
                end

                // ============================================================
                // RESOLVE_WAIT_A: Second wait cycle (output register)
                // ============================================================
                RESOLVE_WAIT_A: begin
                    state <= RESOLVE_CHECK_A;
                end

                // ============================================================
                // RESOLVE_CHECK_A: Check if root_a is at its root
                // ============================================================
                RESOLVE_CHECK_A: begin
                    read_gen = dout_b[GEN_BITS-1:0];
                    read_addr = dout_b[ENTRY_WIDTH-1:GEN_BITS];

                    // If current generation, use stored parent; else addr is its own root
                    if (read_gen == curr_generation) begin
                        parent_ptr = read_addr;
                    end else begin
                        parent_ptr = addr_b;
                    end

                    if (parent_ptr == addr_b || parent_ptr == BG_MARKER) begin
                        // Root found for A (or hit background marker)
                        root_a <= addr_b;
                        addr_b <= root_b;
                        state <= RESOLVE_FIND_B;
                    end else begin
                        // Continue chasing
                        addr_b <= parent_ptr;
                        state <= RESOLVE_FIND_A;
                    end
                end

                // ============================================================
                // RESOLVE_FIND_B: First wait cycle for BRAM read
                // ============================================================
                RESOLVE_FIND_B: begin
                    state <= RESOLVE_WAIT_B;
                end

                // ============================================================
                // RESOLVE_WAIT_B: Second wait cycle (output register)
                // ============================================================
                RESOLVE_WAIT_B: begin
                    state <= RESOLVE_CHECK_B;
                end

                // ============================================================
                // RESOLVE_CHECK_B: Check if root_b is at its root
                // ============================================================
                RESOLVE_CHECK_B: begin
                    read_gen = dout_b[GEN_BITS-1:0];
                    read_addr = dout_b[ENTRY_WIDTH-1:GEN_BITS];

                    if (read_gen == curr_generation) begin
                        parent_ptr = read_addr;
                    end else begin
                        parent_ptr = addr_b;
                    end

                    if (parent_ptr == addr_b || parent_ptr == BG_MARKER) begin
                        // Root found for B (or hit background marker)
                        root_b <= addr_b;
                        state <= RESOLVE_MERGE;
                    end else begin
                        addr_b <= parent_ptr;
                        state <= RESOLVE_FIND_B;
                    end
                end

                // ============================================================
                // RESOLVE_MERGE: Union the two roots (smaller becomes parent)
                // ============================================================
                RESOLVE_MERGE: begin
                    if (root_a != root_b && root_a != BG_MARKER && root_b != BG_MARKER) begin
                        if (root_a < root_b) begin
                            // Make root_b point to root_a
                            addr_a <= root_b;
                            din_a <= {root_a, curr_generation};
                            we_a <= 1'b1;
                        end else begin
                            // Make root_a point to root_b
                            addr_a <= root_a;
                            din_a <= {root_b, curr_generation};
                            we_a <= 1'b1;
                        end
                    end
                    s_axis_ready <= 1'b0;
                    state <= P1_PROCESS;
                end

                // ============================================================
                // P2_READ: Start reading pixel's parent pointer
                // ============================================================
                P2_READ: begin
                    addr_b <= pixel_idx;
                    state <= P2_WAIT1;
                end

                // ============================================================
                // P2_WAIT1: First wait cycle for BRAM read
                // ============================================================
                P2_WAIT1: begin
                    state <= P2_WAIT2;
                end

                // ============================================================
                // P2_WAIT2: Second wait cycle (output register)
                // ============================================================
                P2_WAIT2: begin
                    state <= P2_TRAVERSE;
                end

                // ============================================================
                // P2_TRAVERSE: Chase to root
                // ============================================================
                P2_TRAVERSE: begin
                    read_gen = dout_b[GEN_BITS-1:0];
                    read_addr = dout_b[ENTRY_WIDTH-1:GEN_BITS];

                    if (read_gen == curr_generation) begin
                        parent_ptr = read_addr;
                    end else begin
                        parent_ptr = addr_b;
                    end

                    if (parent_ptr == addr_b || parent_ptr == BG_MARKER) begin
                        // Root found (self-pointer) or background (BG_MARKER)
                        p2_root_addr <= parent_ptr;
                        state <= P2_LOOKUP;
                    end else begin
                        // Continue chasing
                        addr_b <= parent_ptr;
                        state <= P2_WAIT1;
                    end
                end

                // ============================================================
                // P2_LOOKUP: Map root address to compact label
                // ============================================================
                P2_LOOKUP: begin
                    if (p2_root_addr == BG_MARKER) begin
                        // Background pixel
                        m_axis_label <= '0;
                    end else begin
                        // Search for existing mapping
                        found_in_map = 1'b0;
                        compact_label = '0;
                        for (i = 0; i < MAX_COMPONENTS; i = i + 1) begin
                            if (i < num_roots && root_map_addr[i] == p2_root_addr) begin
                                found_in_map = 1'b1;
                                compact_label = root_map_label[i];
                            end
                        end

                        if (found_in_map) begin
                            m_axis_label <= compact_label;
                        end else begin
                            // New root: assign next compact label
                            if (num_roots < MAX_COMPONENTS) begin
                                root_map_addr[num_roots] <= p2_root_addr;
                                root_map_label[num_roots] <= next_compact_label;
                                m_axis_label <= next_compact_label;
                                num_roots <= num_roots + 1;
                                next_compact_label <= next_compact_label + 1;
                            end else begin
                                // Overflow: reuse last label
                                m_axis_label <= next_compact_label;
                            end
                        end
                    end

                    m_axis_valid <= 1'b1;
                        m_axis_x <= curr_x;
                        m_axis_y <= curr_y;
                    
                    if (curr_x == WIDTH - 1 && curr_y == HEIGHT - 1) begin
                        m_axis_last <= 1'b1;
                        last_pixel_flag <= 1'b1;
                    end else begin
                        m_axis_last <= 1'b0;
                        last_pixel_flag <= 1'b0;
                    end
                    
                    state <= P2_OUTPUT;
                end

                // ============================================================
                // P2_OUTPUT: Wait for output to be accepted
                // ============================================================
                P2_OUTPUT: begin
                    if (m_axis_ready) begin
                        if (last_pixel_flag) begin
                            last_pixel_flag <= 1'b0;
                            curr_generation <= curr_generation + 1'b1;
                            state <= IDLE;
                        end else begin
                            pixel_idx <= pixel_idx + 1;
                            if (curr_x == WIDTH - 1) begin
                                curr_x <= '0;
                                curr_y <= curr_y + 1;
                            end else begin
                                curr_x <= curr_x + 1;
                            end
                            state <= P2_READ;
                        end
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
