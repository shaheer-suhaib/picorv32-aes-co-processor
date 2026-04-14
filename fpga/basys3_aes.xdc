## Constraints for Basys3 Board - PicoRV32 + AES + 8-Lane SPI
## Digilent Basys3 (Xilinx Artix-7 XC7A35T)

## Clock (100 MHz)
set_property PACKAGE_PIN W5 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 10.000 -name sys_clk [get_ports clk]

## Reset Button (active-low, directly usable)
set_property PACKAGE_PIN U18 [get_ports resetn_btn]
set_property IOSTANDARD LVCMOS33 [get_ports resetn_btn]

##############################################
## 8-Lane Parallel SPI on Pmod Header JA
##
## Physical Connection:
##   JA1 (pin 1)  = spi_data[0]
##   JA2 (pin 2)  = spi_data[1]
##   JA3 (pin 3)  = spi_data[2]
##   JA4 (pin 4)  = spi_data[3]
##   JA7 (pin 7)  = spi_data[4]
##   JA8 (pin 8)  = spi_data[5]
##   JA9 (pin 9)  = spi_data[6]
##   JA10 (pin 10) = spi_data[7]
##############################################

## Pmod JA - Top Row (pins 1-4)
set_property PACKAGE_PIN J1 [get_ports {spi_data[0]}]
set_property PACKAGE_PIN L2 [get_ports {spi_data[1]}]
set_property PACKAGE_PIN J2 [get_ports {spi_data[2]}]
set_property PACKAGE_PIN G2 [get_ports {spi_data[3]}]

## Pmod JA - Bottom Row (pins 7-10)
set_property PACKAGE_PIN H1 [get_ports {spi_data[4]}]
set_property PACKAGE_PIN K2 [get_ports {spi_data[5]}]
set_property PACKAGE_PIN H2 [get_ports {spi_data[6]}]
set_property PACKAGE_PIN G3 [get_ports {spi_data[7]}]

set_property IOSTANDARD LVCMOS33 [get_ports {spi_data[*]}]

##############################################
## SPI Control Signals on Pmod Header JB
##############################################

## JB1 = spi_clk
set_property PACKAGE_PIN A14 [get_ports spi_clk]
set_property IOSTANDARD LVCMOS33 [get_ports spi_clk]

## JB2 = spi_cs_n
set_property PACKAGE_PIN A16 [get_ports spi_cs_n]
set_property IOSTANDARD LVCMOS33 [get_ports spi_cs_n]

## JB3 = spi_active (optional, useful for debugging)
set_property PACKAGE_PIN B15 [get_ports spi_active]
set_property IOSTANDARD LVCMOS33 [get_ports spi_active]

##############################################
## Status LEDs
##############################################

## LED 0 = Trap indicator (error)
set_property PACKAGE_PIN U16 [get_ports led_trap]
set_property IOSTANDARD LVCMOS33 [get_ports led_trap]

## LED 15 = Heartbeat (running indicator)
set_property PACKAGE_PIN L1 [get_ports led_running]
set_property IOSTANDARD LVCMOS33 [get_ports led_running]

##############################################
## Configuration
##############################################
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
