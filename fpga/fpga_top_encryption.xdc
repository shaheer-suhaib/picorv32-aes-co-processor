################################################################################
# Constraints file for PicoRV32 AES Encryption on FPGA
# 
# IMPORTANT: Modify the pin assignments below to match your FPGA board!
# 
# Common FPGA boards:
# - Basys3: Use 100MHz clock, buttons for reset
# - Nexys A7: Use 100MHz clock, buttons for reset
# - Zybo: Use 125MHz clock, buttons for reset
# - Custom: Check your board's reference manual
################################################################################

# Clock constraint (adjust frequency to match your board)
# Example for 100MHz clock on Basys3/Nexys A7:
create_clock -period 10.000 -name clk [get_ports clk]

# Clock input pin (MODIFY THIS to match your board)
# Example for Basys3: W5 (100MHz clock)
# Example for Nexys A7: E3 (100MHz clock)
# set_property PACKAGE_PIN W5 [get_ports clk]
# set_property IOSTANDARD LVCMOS33 [get_ports clk]

# Reset button (MODIFY THIS to match your board)
# Example for Basys3: U18 (BTNC - center button)
# Example for Nexys A7: C12 (BTNC - center button)
# set_property PACKAGE_PIN U18 [get_ports resetn]
# set_property IOSTANDARD LVCMOS33 [get_ports resetn]

# Trap LED (optional - for debugging)
# Example for Basys3: U16 (LD0)
# Example for Nexys A7: T14 (LD0)
# set_property PACKAGE_PIN U16 [get_ports trap]
# set_property IOSTANDARD LVCMOS33 [get_ports trap]

# Timing constraints
set_input_delay -clock clk 2.0 [get_ports resetn]
set_output_delay -clock clk 2.0 [get_ports trap]

# False paths (if needed)
# set_false_path -from [get_ports resetn]

################################################################################
# INSTRUCTIONS:
# 1. Uncomment and modify the pin assignments above for your board
# 2. Adjust clock period if your board uses a different frequency
# 3. Save this file and add it to your Vivado project
################################################################################

