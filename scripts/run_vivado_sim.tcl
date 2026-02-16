#!/usr/bin/env tclsh
# Vivado Tcl script to compile and run the PicoRV32 AES BRAM simulation
# Usage: open Vivado TCL console and run: source scripts/run_vivado_sim.tcl

puts "Starting PicoRV32-AES simulation script"

# Check for program.hex
if {![file exists "program.hex"]} {
    puts "WARNING: program.hex not found in working directory. Generate it with generate_program_hex.py and copy it here."
} else {
    puts "Found program.hex"
}

# Files to compile (order groups: AES core, CPU, BRAM, testbench)
set files {
    "Aes-Code/ASMD_Encryption.v"
    "Aes-Code/ControlUnit_Enryption.v"
    "Aes-Code/Datapath_Encryption.v"
    "Aes-Code/Round_Key_Update.v"
    "Aes-Code/function_g.v"
    "Aes-Code/S_BOX.v"
    "Aes-Code/mix_cols.v"
    "Aes-Code/shift_rows.v"
    "Aes-Code/Sub_Bytes.v"
    "Aes-Code/Register.v"
    "Aes-Code/Counter.v"
    "picorv32.v"
    "bram_memory.v"
    "tb_picorv32_aes_bram.v"
}

puts "Files to compile:"
foreach f $files { puts "  $f" }

# Use xvlog/xelab/xsim (XSIM) to compile and run simulation
puts "Running xvlog..."
eval xvlog $files

puts "Elaborating design with xelab..."
xelab tb_picorv32_aes_bram -s tb_picorv32_sim

puts "Launching xsim (GUI). To run headless use '-runall' instead of opening GUI."
xsim tb_picorv32_sim -gui

puts "Script finished."
