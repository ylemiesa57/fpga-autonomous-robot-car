`timescale 1ns / 1ps
`default_nettype none

module kernels #(
  parameter K_SELECT=0)(
  input wire rst,
  output logic signed [2:0][2:0][7:0] coeffs,
  output logic signed [7:0] shift);

  logic signed [7:0]coeffs_i[2:0][2:0];

  assign coeffs = { coeffs_i[2][2],
                    coeffs_i[2][1],
                    coeffs_i[2][0],
                    coeffs_i[1][2],
                    coeffs_i[1][1],
                    coeffs_i[1][0],
                    coeffs_i[0][2],
                    coeffs_i[0][1],
                    coeffs_i[0][0]};

  always_comb begin
    case (K_SELECT)
      0: begin // Identity
        coeffs_i[0][0] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[0][1] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[0][2] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[1][0] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[1][1] = rst ? 8'sd0 : 8'sd1;
        coeffs_i[1][2] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[2][0] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[2][1] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[2][2] = rst ? 8'sd0 : 8'sd0;
        shift = rst ? 8'sd0 : 8'sd0;
      end

      1: begin // Gaussian Blur
        coeffs_i[0][0] = rst ? 8'sd0 : 8'sd1;
        coeffs_i[0][1] = rst ? 8'sd0 : 8'sd2;
        coeffs_i[0][2] = rst ? 8'sd0 : 8'sd1;
        coeffs_i[1][0] = rst ? 8'sd0 : 8'sd2;
        coeffs_i[1][1] = rst ? 8'sd0 : 8'sd4;
        coeffs_i[1][2] = rst ? 8'sd0 : 8'sd2;
        coeffs_i[2][0] = rst ? 8'sd0 : 8'sd1;
        coeffs_i[2][1] = rst ? 8'sd0 : 8'sd2;
        coeffs_i[2][2] = rst ? 8'sd0 : 8'sd1;
        shift = rst ? 8'sd0 : 8'sd4;
      end

      2: begin // Sharpen
        coeffs_i[0][0] = rst ? 8'sd0 :  8'sd0;
        coeffs_i[0][1] = rst ? 8'sd0 : -8'sd1;
        coeffs_i[0][2] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[1][0] = rst ? 8'sd0 : -8'sd1;
        coeffs_i[1][1] = rst ? 8'sd0 :  8'sd5;
        coeffs_i[1][2] = rst ? 8'sd0 : -8'sd1;
        coeffs_i[2][0] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[2][1] = rst ? 8'sd0 : -8'sd1;
        coeffs_i[2][2] = rst ? 8'sd0 : 8'sd0;
        shift = rst ? 8'sd0 : 8'sd0;
      end

      3: begin // Ridge Detection
        coeffs_i[0][0] = rst ? 8'sd0 : -8'sd1;
        coeffs_i[0][1] = rst ? 8'sd0 : -8'sd1;
        coeffs_i[0][2] = rst ? 8'sd0 : -8'sd1;
        coeffs_i[1][0] = rst ? 8'sd0 : -8'sd1;
        coeffs_i[1][1] = rst ? 8'sd0 :  8'sd8;
        coeffs_i[1][2] = rst ? 8'sd0 : -8'sd1;
        coeffs_i[2][0] = rst ? 8'sd0 : -8'sd1;
        coeffs_i[2][1] = rst ? 8'sd0 : -8'sd1;
        coeffs_i[2][2] = rst ? 8'sd0 : -8'sd1;
        shift = rst ? 8'sd0 : 8'sd0;
      end

      4: begin // Sobel X Edge Detection
        coeffs_i[0][0] = rst ? 8'sd0 : 8'sd1;
        coeffs_i[0][1] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[0][2] = rst ? 8'sd0 : -8'sd1;
        coeffs_i[1][0] = rst ? 8'sd0 : 8'sd2;
        coeffs_i[1][1] = rst ? 8'sd0 :  8'sd0;
        coeffs_i[1][2] = rst ? 8'sd0 : -8'sd2;
        coeffs_i[2][0] = rst ? 8'sd0 : 8'sd1;
        coeffs_i[2][1] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[2][2] = rst ? 8'sd0 : -8'sd1;
        shift = rst ? 8'sd0 : 8'sd0;
      end

      5: begin // Sobel Y Edge Detection
        coeffs_i[0][0] = rst ? 8'sd0 : -8'sd1;
        coeffs_i[0][1] = rst ? 8'sd0 : -8'sd2;
        coeffs_i[0][2] = rst ? 8'sd0 : -8'sd1;
        coeffs_i[1][0] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[1][1] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[1][2] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[2][0] = rst ? 8'sd0 : 8'sd1;
        coeffs_i[2][1] = rst ? 8'sd0 : 8'sd2;
        coeffs_i[2][2] = rst ? 8'sd0 : 8'sd1;
        shift = rst ? 8'sd0 : 8'sd0;
      end
      default: begin //Identity kernel
        coeffs_i[0][0] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[0][1] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[0][2] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[1][0] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[1][1] = rst ? 8'sd0 : 8'sd1;
        coeffs_i[1][2] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[2][0] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[2][1] = rst ? 8'sd0 : 8'sd0;
        coeffs_i[2][2] = rst ? 8'sd0 : 8'sd0;
        shift = rst ? 8'sd0 : 8'sd0;
      end
    endcase
  end
endmodule

`default_nettype wire

