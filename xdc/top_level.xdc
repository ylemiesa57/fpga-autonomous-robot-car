# Master clock from 100 MHz oscillator on Urbana Board
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33} [get_ports {clk_100mhz}]
create_clock -add -name gclk -period 10.000 -waveform {0 4} [get_ports {clk_100mhz}]

# Set Bank 0 voltage
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

##############################################################################
# CAMERA INTERFACE (PMOD-A connector)
##############################################################################

# Camera data bus (8 bits)
# pmoda[0]
set_property -dict {PACKAGE_PIN F14 IOSTANDARD LVCMOS33}  [get_ports {camera_d[1]}]
# pmoda[1]
set_property -dict {PACKAGE_PIN F15 IOSTANDARD LVCMOS33}  [get_ports {camera_d[3]}]
# pmoda[2]
set_property -dict {PACKAGE_PIN H13 IOSTANDARD LVCMOS33}  [get_ports {camera_d[5]}]
# pmoda[3]
set_property -dict {PACKAGE_PIN H14 IOSTANDARD LVCMOS33}  [get_ports {camera_d[7]}]
# pmoda[4]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33}  [get_ports {camera_d[0]}]
# pmoda[5]
set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS33}  [get_ports {camera_d[2]}]
# pmoda[6]
set_property -dict {PACKAGE_PIN E14 IOSTANDARD LVCMOS33}  [get_ports {camera_d[4]}]
# pmoda[7]
set_property -dict {PACKAGE_PIN E15 IOSTANDARD LVCMOS33}  [get_ports {camera_d[6]}]

##############################################################################
# CAMERA CONTROL SIGNALS (JAB connector)
##############################################################################

# jab[0] - Camera clock output (high drive for camera input)
set_property -dict {PACKAGE_PIN D11 IOSTANDARD LVCMOS33 DRIVE 16} [get_ports {cam_xclk}]
# jab[1] - Horizontal sync
set_property -dict {PACKAGE_PIN C12 IOSTANDARD LVCMOS33} [get_ports {cam_h_sync}]
# jab[2] - I2C SDA (with pull-up)
set_property -dict {PACKAGE_PIN E16 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports {i2c_sda}]
# jab[3] - Camera pixel clock
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33} [get_ports {cam_pclk}]
# jab[4] - Vertical sync
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33} [get_ports {cam_v_sync}]
# jab[5] - I2C SCL (with pull-up)
set_property -dict {PACKAGE_PIN G16 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports {i2c_scl}]

##############################################################################
# PMOD-B MOTOR DRIVER (PH/EN)
##############################################################################

# # JB1 - PH (direction)  NOTE: verify pin vs. board PMOD-B header
# set_property -dict {PACKAGE_PIN  IOSTANDARD LVCMOS33 DRIVE 8 SLEW FAST} [get_ports {motor_ph}]
# # JB2 - EN (PWM)
# set_property -dict {PACKAGE_PIN  IOSTANDARD LVCMOS33 DRIVE 8 SLEW FAST} [get_ports {motor_en}]

# PMOD B Signals
##fixed K14 and J15 which were a copy-paste and wrong.
# pmod 0 is motor_ph, pmod 1 is motor_en, lab 1 for reference
set_property -dict {PACKAGE_PIN H18 IOSTANDARD LVCMOS33}  [ get_ports {left_motor_ph} ] 
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33}  [ get_ports {left_motor_en} ] 
set_property -dict {PACKAGE_PIN K14 IOSTANDARD LVCMOS33}  [ get_ports {right_motor_ph} ]
set_property -dict {PACKAGE_PIN J15 IOSTANDARD LVCMOS33}  [ get_ports {right_motor_en} ]
#set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33}  [ get_ports "pmodb[4]" ]
#set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33}  [ get_ports "pmodb[5]" ]
#set_property -dict {PACKAGE_PIN K16 IOSTANDARD LVCMOS33}  [ get_ports "pmodb[6]" ]
#set_property -dict {PACKAGE_PIN J16 IOSTANDARD LVCMOS33}  [ get_ports "pmodb[7]" ]

##############################################################################
# TIMING CONSTRAINTS FOR CLOCK DOMAIN CROSSING
##############################################################################

# Explicitly declare the camera, pixel/HDMI, and controller/DDR domains asynchronous
# so CDC synchronizers (e.g., inside xpm_fifo_async) are not timed.
set_clock_groups -asynchronous \
    -group [get_clocks {clk_camera*}] \
    -group [get_clocks {clk_pixel* clk_5x*}] \
    -group [get_clocks {clk_controller* clk_ddr3*}]

# Legacy max_delay guards (kept commented); uncomment only if you later want
# loose synchronous budgeting instead of async grouping.
# set_max_delay -datapath_only 6 -from [get_clocks clk_controller_clk_wiz_0] -to [get_clocks clk_pixel_cw_hdmi]
# set_max_delay -datapath_only 6 -from [get_clocks clk_pixel_cw_hdmi] -to [get_clocks clk_controller_clk_wiz_0]
# set_max_delay -datapath_only 6 -from [get_clocks clk_controller_clk_wiz_0] -to [get_clocks clk_camera_clk_wiz_0]
# set_max_delay -datapath_only 6 -from [get_clocks clk_camera_clk_wiz_0] -to [get_clocks clk_controller_clk_wiz_0]

##############################################################################
# USER INTERFACE - LED OUTPUTS
##############################################################################

set_property -dict {PACKAGE_PIN C13 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN C14 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN D14 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN D15 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN D16 IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN F18 IOSTANDARD LVCMOS33} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN E17 IOSTANDARD LVCMOS33} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN D17 IOSTANDARD LVCMOS33} [get_ports {led[7]}]
set_property -dict {PACKAGE_PIN C17 IOSTANDARD LVCMOS33} [get_ports {led[8]}]
set_property -dict {PACKAGE_PIN B18 IOSTANDARD LVCMOS33} [get_ports {led[9]}]
set_property -dict {PACKAGE_PIN A17 IOSTANDARD LVCMOS33} [get_ports {led[10]}]
set_property -dict {PACKAGE_PIN B17 IOSTANDARD LVCMOS33} [get_ports {led[11]}]
set_property -dict {PACKAGE_PIN C18 IOSTANDARD LVCMOS33} [get_ports {led[12]}]
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports {led[13]}]
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports {led[14]}]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports {led[15]}]

##############################################################################
# USER INTERFACE - RGB LEDs
##############################################################################

# RGB0 (lower tri-color LED)
set_property -dict {PACKAGE_PIN C9 IOSTANDARD LVCMOS33} [get_ports {rgb0[0]}]
set_property -dict {PACKAGE_PIN A9 IOSTANDARD LVCMOS33} [get_ports {rgb0[1]}]
set_property -dict {PACKAGE_PIN A10 IOSTANDARD LVCMOS33} [get_ports {rgb0[2]}]

# RGB1 (upper tri-color LED)
set_property -dict {PACKAGE_PIN A11 IOSTANDARD LVCMOS33} [get_ports {rgb1[0]}]
set_property -dict {PACKAGE_PIN C10 IOSTANDARD LVCMOS33} [get_ports {rgb1[1]}]
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33} [get_ports {rgb1[2]}]

##############################################################################
# USER INTERFACE - PUSH BUTTONS
##############################################################################

set_property -dict {PACKAGE_PIN J2 IOSTANDARD LVCMOS33} [get_ports {btn[0]}]
set_property -dict {PACKAGE_PIN J1 IOSTANDARD LVCMOS33} [get_ports {btn[1]}]
set_property -dict {PACKAGE_PIN G2 IOSTANDARD LVCMOS33} [get_ports {btn[2]}]
set_property -dict {PACKAGE_PIN H2 IOSTANDARD LVCMOS33} [get_ports {btn[3]}]

##############################################################################
# USER INTERFACE - SLIDE SWITCHES
##############################################################################

set_property -dict {PACKAGE_PIN G1 IOSTANDARD LVCMOS33} [get_ports {sw[0]}]
set_property -dict {PACKAGE_PIN F2 IOSTANDARD LVCMOS33} [get_ports {sw[1]}]
set_property -dict {PACKAGE_PIN F1 IOSTANDARD LVCMOS33} [get_ports {sw[2]}]
set_property -dict {PACKAGE_PIN E2 IOSTANDARD LVCMOS33} [get_ports {sw[3]}]
set_property -dict {PACKAGE_PIN E1 IOSTANDARD LVCMOS33} [get_ports {sw[4]}]
set_property -dict {PACKAGE_PIN D2 IOSTANDARD LVCMOS33} [get_ports {sw[5]}]
# set_property -dict {PACKAGE_PIN D1 IOSTANDARD LVCMOS33} [get_ports {sw[6]}]
# set_property -dict {PACKAGE_PIN C2 IOSTANDARD LVCMOS33} [get_ports {sw[7]}]
# set_property -dict {PACKAGE_PIN B2 IOSTANDARD LVCMOS33} [get_ports {sw[8]}]
# set_property -dict {PACKAGE_PIN A4 IOSTANDARD LVCMOS33} [get_ports {sw[9]}]
# set_property -dict {PACKAGE_PIN A5 IOSTANDARD LVCMOS33} [get_ports {sw[10]}]
# set_property -dict {PACKAGE_PIN A6 IOSTANDARD LVCMOS33} [get_ports {sw[11]}]
# set_property -dict {PACKAGE_PIN C7 IOSTANDARD LVCMOS33} [get_ports {sw[12]}]
# set_property -dict {PACKAGE_PIN A7 IOSTANDARD LVCMOS33} [get_ports {sw[13]}]
# set_property -dict {PACKAGE_PIN B7 IOSTANDARD LVCMOS33} [get_ports {sw[14]}]
# set_property -dict {PACKAGE_PIN A8 IOSTANDARD LVCMOS33} [get_ports {sw[15]}]

##############################################################################
# USER INTERFACE - SEVEN SEGMENT DISPLAY (Anode Control - Active Low)
##############################################################################

# # Upper 4-digit display anode control
# set_property -dict {PACKAGE_PIN B3 IOSTANDARD LVCMOS33} [get_ports {ss0_an[0]}]
# set_property -dict {PACKAGE_PIN C3 IOSTANDARD LVCMOS33} [get_ports {ss0_an[1]}]
# set_property -dict {PACKAGE_PIN H6 IOSTANDARD LVCMOS33} [get_ports {ss0_an[2]}]
# set_property -dict {PACKAGE_PIN G6 IOSTANDARD LVCMOS33} [get_ports {ss0_an[3]}]

# # Lower 4-digit display anode control
# set_property -dict {PACKAGE_PIN H5 IOSTANDARD LVCMOS33} [get_ports {ss1_an[0]}]
# set_property -dict {PACKAGE_PIN F5 IOSTANDARD LVCMOS33} [get_ports {ss1_an[1]}]
# set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports {ss1_an[2]}]
# set_property -dict {PACKAGE_PIN E4 IOSTANDARD LVCMOS33} [get_ports {ss1_an[3]}]

##############################################################################
# USER INTERFACE - SEVEN SEGMENT DISPLAY (Cathode Control - Active Low)
##############################################################################

# # Upper 4-digit display cathode control
# set_property -dict {PACKAGE_PIN E6 IOSTANDARD LVCMOS33} [get_ports {ss0_c[0]}]
# set_property -dict {PACKAGE_PIN B4 IOSTANDARD LVCMOS33} [get_ports {ss0_c[1]}]
# set_property -dict {PACKAGE_PIN D5 IOSTANDARD LVCMOS33} [get_ports {ss0_c[2]}]
# set_property -dict {PACKAGE_PIN C5 IOSTANDARD LVCMOS33} [get_ports {ss0_c[3]}]
# set_property -dict {PACKAGE_PIN D7 IOSTANDARD LVCMOS33} [get_ports {ss0_c[4]}]
# set_property -dict {PACKAGE_PIN D6 IOSTANDARD LVCMOS33} [get_ports {ss0_c[5]}]
# set_property -dict {PACKAGE_PIN C4 IOSTANDARD LVCMOS33} [get_ports {ss0_c[6]}]

# # Lower 4-digit display cathode control
# set_property -dict {PACKAGE_PIN F3 IOSTANDARD LVCMOS33} [get_ports {ss1_c[0]}]
# set_property -dict {PACKAGE_PIN G5 IOSTANDARD LVCMOS33} [get_ports {ss1_c[1]}]
# set_property -dict {PACKAGE_PIN J3 IOSTANDARD LVCMOS33} [get_ports {ss1_c[2]}]
# set_property -dict {PACKAGE_PIN H4 IOSTANDARD LVCMOS33} [get_ports {ss1_c[3]}]
# set_property -dict {PACKAGE_PIN F4 IOSTANDARD LVCMOS33} [get_ports {ss1_c[4]}]
# set_property -dict {PACKAGE_PIN H3 IOSTANDARD LVCMOS33} [get_ports {ss1_c[5]}]
# set_property -dict {PACKAGE_PIN E5 IOSTANDARD LVCMOS33} [get_ports {ss1_c[6]}]

##############################################################################
# HDMI OUTPUT
##############################################################################

# HDMI differential clock
set_property -dict {PACKAGE_PIN V17 IOSTANDARD TMDS_33} [get_ports {hdmi_clk_n}]
set_property -dict {PACKAGE_PIN U16 IOSTANDARD TMDS_33} [get_ports {hdmi_clk_p}]

# HDMI data channels (Blue, Green, Red)
set_property -dict {PACKAGE_PIN U18 IOSTANDARD TMDS_33} [get_ports {hdmi_tx_n[0]}]
set_property -dict {PACKAGE_PIN R17 IOSTANDARD TMDS_33} [get_ports {hdmi_tx_n[1]}]
set_property -dict {PACKAGE_PIN T14 IOSTANDARD TMDS_33} [get_ports {hdmi_tx_n[2]}]

set_property -dict {PACKAGE_PIN U17 IOSTANDARD TMDS_33} [get_ports {hdmi_tx_p[0]}]
set_property -dict {PACKAGE_PIN R16 IOSTANDARD TMDS_33} [get_ports {hdmi_tx_p[1]}]
set_property -dict {PACKAGE_PIN R14 IOSTANDARD TMDS_33} [get_ports {hdmi_tx_p[2]}]

##############################################################################
# DDR3 SDRAM DATA SIGNALS
##############################################################################

# Data bus (16 bits)
set_property SLEW FAST [get_ports {ddr3_dq[0]}]
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {ddr3_dq[0]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_dq[0]}]
set_property PACKAGE_PIN K2 [get_ports {ddr3_dq[0]}]

set_property SLEW FAST [get_ports {ddr3_dq[1]}]
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {ddr3_dq[1]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_dq[1]}]
set_property PACKAGE_PIN M4 [get_ports {ddr3_dq[1]}]

set_property SLEW FAST [get_ports {ddr3_dq[2]}]
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {ddr3_dq[2]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_dq[2]}]
set_property PACKAGE_PIN K3 [get_ports {ddr3_dq[2]}]

set_property SLEW FAST [get_ports {ddr3_dq[3]}]
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {ddr3_dq[3]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_dq[3]}]
set_property PACKAGE_PIN L5 [get_ports {ddr3_dq[3]}]

set_property SLEW FAST [get_ports {ddr3_dq[4]}]
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {ddr3_dq[4]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_dq[4]}]
set_property PACKAGE_PIN L6 [get_ports {ddr3_dq[4]}]

set_property SLEW FAST [get_ports {ddr3_dq[5]}]
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {ddr3_dq[5]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_dq[5]}]
set_property PACKAGE_PIN M6 [get_ports {ddr3_dq[5]}]

set_property SLEW FAST [get_ports {ddr3_dq[6]}]
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {ddr3_dq[6]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_dq[6]}]
set_property PACKAGE_PIN L4 [get_ports {ddr3_dq[6]}]

set_property SLEW FAST [get_ports {ddr3_dq[7]}]
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {ddr3_dq[7]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_dq[7]}]
set_property PACKAGE_PIN K6 [get_ports {ddr3_dq[7]}]

set_property SLEW FAST [get_ports {ddr3_dq[8]}]
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {ddr3_dq[8]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_dq[8]}]
set_property PACKAGE_PIN N5 [get_ports {ddr3_dq[8]}]

set_property SLEW FAST [get_ports {ddr3_dq[9]}]
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {ddr3_dq[9]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_dq[9]}]
set_property PACKAGE_PIN M1 [get_ports {ddr3_dq[9]}]

set_property SLEW FAST [get_ports {ddr3_dq[10]}]
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {ddr3_dq[10]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_dq[10]}]
set_property PACKAGE_PIN P1 [get_ports {ddr3_dq[10]}]

set_property SLEW FAST [get_ports {ddr3_dq[11]}]
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {ddr3_dq[11]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_dq[11]}]
set_property PACKAGE_PIN N1 [get_ports {ddr3_dq[11]}]

set_property SLEW FAST [get_ports {ddr3_dq[12]}]
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {ddr3_dq[12]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_dq[12]}]
set_property PACKAGE_PIN R2 [get_ports {ddr3_dq[12]}]

set_property SLEW FAST [get_ports {ddr3_dq[13]}]
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {ddr3_dq[13]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_dq[13]}]
set_property PACKAGE_PIN N4 [get_ports {ddr3_dq[13]}]

set_property SLEW FAST [get_ports {ddr3_dq[14]}]
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {ddr3_dq[14]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_dq[14]}]
set_property PACKAGE_PIN P2 [get_ports {ddr3_dq[14]}]

set_property SLEW FAST [get_ports {ddr3_dq[15]}]
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {ddr3_dq[15]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_dq[15]}]
set_property PACKAGE_PIN M2 [get_ports {ddr3_dq[15]}]

##############################################################################
# DDR3 ADDRESS SIGNALS
##############################################################################

# Address bus (14 bits)
set_property SLEW FAST [get_ports {ddr3_addr[13]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr[13]}]
set_property PACKAGE_PIN V7 [get_ports {ddr3_addr[13]}]

set_property SLEW FAST [get_ports {ddr3_addr[12]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr[12]}]
set_property PACKAGE_PIN V6 [get_ports {ddr3_addr[12]}]

set_property SLEW FAST [get_ports {ddr3_addr[11]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr[11]}]
set_property PACKAGE_PIN P5 [get_ports {ddr3_addr[11]}]

set_property SLEW FAST [get_ports {ddr3_addr[10]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr[10]}]
set_property PACKAGE_PIN U3 [get_ports {ddr3_addr[10]}]

set_property SLEW FAST [get_ports {ddr3_addr[9]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr[9]}]
set_property PACKAGE_PIN U6 [get_ports {ddr3_addr[9]}]

set_property SLEW FAST [get_ports {ddr3_addr[8]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr[8]}]
set_property PACKAGE_PIN R7 [get_ports {ddr3_addr[8]}]

set_property SLEW FAST [get_ports {ddr3_addr[7]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr[7]}]
set_property PACKAGE_PIN U7 [get_ports {ddr3_addr[7]}]

set_property SLEW FAST [get_ports {ddr3_addr[6]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr[6]}]
set_property PACKAGE_PIN V5 [get_ports {ddr3_addr[6]}]

set_property SLEW FAST [get_ports {ddr3_addr[5]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr[5]}]
set_property PACKAGE_PIN T1 [get_ports {ddr3_addr[5]}]

set_property SLEW FAST [get_ports {ddr3_addr[4]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr[4]}]
set_property PACKAGE_PIN T6 [get_ports {ddr3_addr[4]}]

set_property SLEW FAST [get_ports {ddr3_addr[3]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr[3]}]
set_property PACKAGE_PIN T3 [get_ports {ddr3_addr[3]}]

set_property SLEW FAST [get_ports {ddr3_addr[2]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr[2]}]
set_property PACKAGE_PIN P6 [get_ports {ddr3_addr[2]}]

set_property SLEW FAST [get_ports {ddr3_addr[1]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr[1]}]
set_property PACKAGE_PIN R4 [get_ports {ddr3_addr[1]}]

set_property SLEW FAST [get_ports {ddr3_addr[0]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_addr[0]}]
set_property PACKAGE_PIN V3 [get_ports {ddr3_addr[0]}]

##############################################################################
# DDR3 BANK ADDRESS SIGNALS
##############################################################################

set_property SLEW FAST [get_ports {ddr3_ba[2]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_ba[2]}]
set_property PACKAGE_PIN R3 [get_ports {ddr3_ba[2]}]

set_property SLEW FAST [get_ports {ddr3_ba[1]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_ba[1]}]
set_property PACKAGE_PIN V4 [get_ports {ddr3_ba[1]}]

set_property SLEW FAST [get_ports {ddr3_ba[0]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_ba[0]}]
set_property PACKAGE_PIN V2 [get_ports {ddr3_ba[0]}]

##############################################################################
# DDR3 CONTROL SIGNALS
##############################################################################

set_property SLEW FAST [get_ports ddr3_ras_n]
set_property IOSTANDARD SSTL135 [get_ports ddr3_ras_n]
set_property PACKAGE_PIN U2 [get_ports ddr3_ras_n]

set_property SLEW FAST [get_ports ddr3_cas_n]
set_property IOSTANDARD SSTL135 [get_ports ddr3_cas_n]
set_property PACKAGE_PIN U1 [get_ports ddr3_cas_n]

set_property SLEW FAST [get_ports ddr3_we_n]
set_property IOSTANDARD SSTL135 [get_ports ddr3_we_n]
set_property PACKAGE_PIN T2 [get_ports ddr3_we_n]

set_property SLEW FAST [get_ports ddr3_reset_n]
set_property IOSTANDARD SSTL135 [get_ports ddr3_reset_n]
set_property PACKAGE_PIN M5 [get_ports ddr3_reset_n]

set_property SLEW FAST [get_ports {ddr3_clke}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_clke}]
set_property PACKAGE_PIN T5 [get_ports {ddr3_clke}]

set_property SLEW FAST [get_ports {ddr3_odt}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_odt}]
set_property PACKAGE_PIN P7 [get_ports {ddr3_odt}]

##############################################################################
# DDR3 DATA MASK SIGNALS
##############################################################################

set_property SLEW FAST [get_ports {ddr3_dm[0]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_dm[0]}]
set_property PACKAGE_PIN K4 [get_ports {ddr3_dm[0]}]

set_property SLEW FAST [get_ports {ddr3_dm[1]}]
set_property IOSTANDARD SSTL135 [get_ports {ddr3_dm[1]}]
set_property PACKAGE_PIN M3 [get_ports {ddr3_dm[1]}]

##############################################################################
# DDR3 DQS (Data Strobe) SIGNALS - DIFFERENTIAL
##############################################################################

# Lower byte DQS
set_property SLEW FAST [get_ports {ddr3_dqs_p[0]}]
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {ddr3_dqs_p[0]}]
set_property IOSTANDARD DIFF_SSTL135 [get_ports {ddr3_dqs_p[0]}]
set_property PACKAGE_PIN K1 [get_ports {ddr3_dqs_p[0]}]

set_property SLEW FAST [get_ports {ddr3_dqs_n[0]}]
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {ddr3_dqs_n[0]}]
set_property IOSTANDARD DIFF_SSTL135 [get_ports {ddr3_dqs_n[0]}]
set_property PACKAGE_PIN L1 [get_ports {ddr3_dqs_n[0]}]

# Upper byte DQS
set_property SLEW FAST [get_ports {ddr3_dqs_p[1]}]
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {ddr3_dqs_p[1]}]
set_property IOSTANDARD DIFF_SSTL135 [get_ports {ddr3_dqs_p[1]}]
set_property PACKAGE_PIN N3 [get_ports {ddr3_dqs_p[1]}]

set_property SLEW FAST [get_ports {ddr3_dqs_n[1]}]
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {ddr3_dqs_n[1]}]
set_property IOSTANDARD DIFF_SSTL135 [get_ports {ddr3_dqs_n[1]}]
set_property PACKAGE_PIN N2 [get_ports {ddr3_dqs_n[1]}]

##############################################################################
# DDR3 CLOCK SIGNALS - DIFFERENTIAL
##############################################################################

set_property SLEW FAST [get_ports {ddr3_clk_p}]
set_property IOSTANDARD DIFF_SSTL135 [get_ports {ddr3_clk_p}]
set_property PACKAGE_PIN R5 [get_ports {ddr3_clk_p}]

set_property SLEW FAST [get_ports {ddr3_clk_n}]
set_property IOSTANDARD DIFF_SSTL135 [get_ports {ddr3_clk_n}]
set_property PACKAGE_PIN T4 [get_ports {ddr3_clk_n}]

##############################################################################
# DDR3 INTERNAL VOLTAGE REFERENCE
##############################################################################

set_property INTERNAL_VREF 0.675 [get_iobanks 34]

##############################################################################
# CONFIGURATION OPTIONS
##############################################################################

set_property BITSTREAM.CONFIG.UNUSEDPIN PULLUP [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]