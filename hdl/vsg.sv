module video_sig_gen
#(
  parameter ACTIVE_H_PIXELS = 1280,
  parameter H_FRONT_PORCH = 110,
  parameter H_SYNC_WIDTH = 40,
  parameter H_BACK_PORCH = 220,
  parameter ACTIVE_LINES = 720,
  parameter V_FRONT_PORCH = 5,
  parameter V_SYNC_WIDTH = 5,
  parameter V_BACK_PORCH = 20,
  parameter FPS = 60)
(
  input wire pixel_clk,
  input wire rst,
  output logic [$clog2(TOTAL_PIXELS)-1:0] h_count,
  output logic [$clog2(TOTAL_LINES)-1:0] v_count,
  output logic v_sync, //vertical sync out
  output logic h_sync, //horizontal sync out
  output logic active_draw,
  output logic new_frame, //single cycle enable signal
  output logic [5:0] frame_count); //frame

  localparam TOTAL_PIXELS = ACTIVE_H_PIXELS + H_FRONT_PORCH + H_SYNC_WIDTH + H_BACK_PORCH; //figure this out
  localparam TOTAL_LINES = ACTIVE_LINES + V_FRONT_PORCH + V_SYNC_WIDTH + V_BACK_PORCH; //figure this out


  //your code here
  always_ff @(posedge pixel_clk) begin
    if (rst) begin
      h_count <= 0;
      v_count <= 0;
      frame_count <= 0;
    end else begin
      // in active_draw
      if (h_count < ACTIVE_H_PIXELS && v_count < ACTIVE_LINES) begin
        h_count <= h_count + 1;
      // outside below
      end else if (h_count < ACTIVE_H_PIXELS) begin
        h_count <= h_count + 1;
      // outside right
      end else if (v_count < ACTIVE_LINES) begin
        // frame increment
        if (h_count == ACTIVE_H_PIXELS && v_count == (ACTIVE_LINES - 1)) begin
          if (frame_count < (FPS - 1)) begin
            frame_count <= frame_count + 1;
          end else begin
            frame_count <= 0;
          end
        end
        // if right edge
        if (h_count >= (TOTAL_PIXELS - 1)) begin
          h_count <= 0;
          v_count <= v_count + 1;
        end else begin
          h_count <= h_count + 1;
        end
      // outside below and right
      end else begin
        // if right edge
        if (h_count >= (TOTAL_PIXELS - 1)) begin
          h_count <= 0;
          // if bottom right
          if (v_count == (TOTAL_LINES - 1)) begin
            v_count <= 0;
          end else begin
            v_count <= v_count + 1;
          end
        end else begin
          h_count <= h_count + 1;
        end
      end
    end
  end

  always_comb begin
    // h_sync
    if (h_count >= (ACTIVE_H_PIXELS + H_FRONT_PORCH) && h_count < (ACTIVE_H_PIXELS + H_FRONT_PORCH + H_SYNC_WIDTH)) begin
      h_sync = 1'b1;
    end else begin
      h_sync = 1'b0;
    end
    // v_sync
    if (v_count >= (ACTIVE_LINES + V_FRONT_PORCH) && v_count < (ACTIVE_LINES + V_FRONT_PORCH + V_SYNC_WIDTH)) begin
      v_sync = 1'b1;
    end else begin
      v_sync = 1'b0;
    end
    // check for new frame
    if (h_count == ACTIVE_H_PIXELS && v_count == (ACTIVE_LINES - 1)) begin
      new_frame = 1'b1;
    end else begin
      new_frame = 1'b0;
    end
    // active draw
    if (h_count < ACTIVE_H_PIXELS && v_count < ACTIVE_LINES) begin
      active_draw = 1;
    end else begin
      active_draw = 0;
    end
    if (rst) begin
      h_sync = 1'b0;
      v_sync = 1'b0;
      new_frame = 1'b0;
      active_draw = 0;
    end
  end

endmodule
