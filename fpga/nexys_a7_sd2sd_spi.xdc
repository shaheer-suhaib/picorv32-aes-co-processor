## Nexys A7-50T (Artix-7) constraints for SD-to-SD SPI transfer top
## Based on Digilent Nexys-A7-50T-Master.xdc pinout
## Target top: aes_soc_top_sd2sd_spi

## Clock
set_property -dict { PACKAGE_PIN E3  IOSTANDARD LVCMOS33 } [get_ports { CLK100MHZ }]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports { CLK100MHZ }]

## Buttons
set_property -dict { PACKAGE_PIN N17 IOSTANDARD LVCMOS33 } [get_ports { BTNC }]
set_property -dict { PACKAGE_PIN P18 IOSTANDARD LVCMOS33 } [get_ports { BTND }]

## microSD
set_property -dict { PACKAGE_PIN E2 IOSTANDARD LVCMOS33 } [get_ports { SD_RESET }]
set_property -dict { PACKAGE_PIN B1 IOSTANDARD LVCMOS33 } [get_ports { SD_SCK }]
set_property -dict { PACKAGE_PIN C1 IOSTANDARD LVCMOS33 } [get_ports { SD_CMD }]
set_property -dict { PACKAGE_PIN C2 IOSTANDARD LVCMOS33 } [get_ports { SD_DAT0 }]
set_property -dict { PACKAGE_PIN D2 IOSTANDARD LVCMOS33 } [get_ports { SD_DAT3 }]

## 7-Segment (SEG[0]=CA .. SEG[6]=CG)
set_property -dict { PACKAGE_PIN T10 IOSTANDARD LVCMOS33 } [get_ports { SEG[0] }]
set_property -dict { PACKAGE_PIN R10 IOSTANDARD LVCMOS33 } [get_ports { SEG[1] }]
set_property -dict { PACKAGE_PIN K16 IOSTANDARD LVCMOS33 } [get_ports { SEG[2] }]
set_property -dict { PACKAGE_PIN K13 IOSTANDARD LVCMOS33 } [get_ports { SEG[3] }]
set_property -dict { PACKAGE_PIN P15 IOSTANDARD LVCMOS33 } [get_ports { SEG[4] }]
set_property -dict { PACKAGE_PIN T11 IOSTANDARD LVCMOS33 } [get_ports { SEG[5] }]
set_property -dict { PACKAGE_PIN L18 IOSTANDARD LVCMOS33 } [get_ports { SEG[6] }]

## 7-Segment enables
set_property -dict { PACKAGE_PIN J17 IOSTANDARD LVCMOS33 } [get_ports { AN[0] }]
set_property -dict { PACKAGE_PIN J18 IOSTANDARD LVCMOS33 } [get_ports { AN[1] }]
set_property -dict { PACKAGE_PIN T9  IOSTANDARD LVCMOS33 } [get_ports { AN[2] }]
set_property -dict { PACKAGE_PIN J14 IOSTANDARD LVCMOS33 } [get_ports { AN[3] }]
set_property -dict { PACKAGE_PIN P14 IOSTANDARD LVCMOS33 } [get_ports { AN[4] }]
set_property -dict { PACKAGE_PIN T14 IOSTANDARD LVCMOS33 } [get_ports { AN[5] }]
set_property -dict { PACKAGE_PIN K2  IOSTANDARD LVCMOS33 } [get_ports { AN[6] }]
set_property -dict { PACKAGE_PIN U13 IOSTANDARD LVCMOS33 } [get_ports { AN[7] }]

## LEDs
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS33 } [get_ports { LED[0] }]
set_property -dict { PACKAGE_PIN K15 IOSTANDARD LVCMOS33 } [get_ports { LED[1] }]
set_property -dict { PACKAGE_PIN J13 IOSTANDARD LVCMOS33 } [get_ports { LED[2] }]
set_property -dict { PACKAGE_PIN N14 IOSTANDARD LVCMOS33 } [get_ports { LED[3] }]
set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS33 } [get_ports { LED[4] }]
set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports { LED[5] }]
set_property -dict { PACKAGE_PIN U17 IOSTANDARD LVCMOS33 } [get_ports { LED[6] }]
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports { LED[7] }]
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports { LED[8] }]
set_property -dict { PACKAGE_PIN T15 IOSTANDARD LVCMOS33 } [get_ports { LED[9] }]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports { LED[10] }]
set_property -dict { PACKAGE_PIN T16 IOSTANDARD LVCMOS33 } [get_ports { LED[11] }]
set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports { LED[12] }]
set_property -dict { PACKAGE_PIN V14 IOSTANDARD LVCMOS33 } [get_ports { LED[13] }]
set_property -dict { PACKAGE_PIN V12 IOSTANDARD LVCMOS33 } [get_ports { LED[14] }]
set_property -dict { PACKAGE_PIN V11 IOSTANDARD LVCMOS33 } [get_ports { LED[15] }]

## SPI TX outputs (Pmod JA + JB)
set_property -dict { PACKAGE_PIN C17 IOSTANDARD LVCMOS33 } [get_ports { SPI_DATA[0] }]  ;# JA1
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports { SPI_DATA[1] }]  ;# JA2
set_property -dict { PACKAGE_PIN E18 IOSTANDARD LVCMOS33 } [get_ports { SPI_DATA[2] }]  ;# JA3
set_property -dict { PACKAGE_PIN G17 IOSTANDARD LVCMOS33 } [get_ports { SPI_DATA[3] }]  ;# JA4

set_property -dict { PACKAGE_PIN D14 IOSTANDARD LVCMOS33 } [get_ports { SPI_DATA[4] }]  ;# JB1
set_property -dict { PACKAGE_PIN F16 IOSTANDARD LVCMOS33 } [get_ports { SPI_DATA[5] }]  ;# JB2
set_property -dict { PACKAGE_PIN G16 IOSTANDARD LVCMOS33 } [get_ports { SPI_DATA[6] }]  ;# JB3
set_property -dict { PACKAGE_PIN H14 IOSTANDARD LVCMOS33 } [get_ports { SPI_DATA[7] }]  ;# JB4
set_property -dict { PACKAGE_PIN E16 IOSTANDARD LVCMOS33 } [get_ports { SPI_CLK }]      ;# JB7
set_property -dict { PACKAGE_PIN F13 IOSTANDARD LVCMOS33 } [get_ports { SPI_CS_N }]     ;# JB8

## SPI RX inputs (Pmod JC + JD)
set_property -dict { PACKAGE_PIN K1 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { SPI_DATA_IN[0] }] ;# JC1
set_property -dict { PACKAGE_PIN F6 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { SPI_DATA_IN[1] }] ;# JC2
set_property -dict { PACKAGE_PIN J2 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { SPI_DATA_IN[2] }] ;# JC3
set_property -dict { PACKAGE_PIN G6 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { SPI_DATA_IN[3] }] ;# JC4

set_property -dict { PACKAGE_PIN H4 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { SPI_DATA_IN[4] }] ;# JD1
set_property -dict { PACKAGE_PIN H1 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { SPI_DATA_IN[5] }] ;# JD2
set_property -dict { PACKAGE_PIN G1 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { SPI_DATA_IN[6] }] ;# JD3
set_property -dict { PACKAGE_PIN G3 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { SPI_DATA_IN[7] }] ;# JD4
set_property -dict { PACKAGE_PIN H2 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { SPI_CLK_IN }]     ;# JD7
set_property -dict { PACKAGE_PIN G4 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { SPI_CS_N_IN }]    ;# JD8
