# FPGA Implementation Guide for PicoRV32 with AES Co-Processor

This directory contains all files needed to synthesize and implement PicoRV32 with AES encryption/decryption on an FPGA using Vivado.

## Files in this Directory

-   `fpga_top_encryption.v` - Top-level module for AES encryption
-   `fpga_top_decryption.v` - Top-level module for AES decryption
-   `fpga_top_encryption.xdc` - Constraints file for encryption design
-   `fpga_top_decryption.xdc` - Constraints file for decryption design
-   `README.md` - This file

## Prerequisites

1.  **Python 3** - For generating hex files
2.  **Vivado** - Xilinx Vivado (any recent version)
3.  **FPGA Board** - Any Xilinx FPGA board (Basys3, Nexys A7, Zybo, etc.)

## Step-by-Step Instructions

### Step 1: Generate Hex Files

Run the Python script to convert testbench memory assignments to hex files:

```bash
# From the project root directorypython testbench_to_hex.py testbench_aes_pico.v aes_encryption.hexpython testbench_to_hex.py testbench_aes_decryption_pico.v aes_decryption.hex
```

This will create:

-   `aes_encryption.hex` - Program for encryption test
-   `aes_decryption.hex` - Program for decryption test

### Step 2: Create Vivado Project

1.  Open Vivado
2.  Create a new project
3.  Choose your FPGA part (e.g., `xc7a35tcpg236-1` for Basys3)
4.  Add source files:

#### For Encryption:

-   `../picorv32.v` (main CPU file)
-   `fpga_top_encryption.v` (top-level module)
-   `../aes_encryption.hex` (program hex file)
-   All AES encryption files from `../encryption_files.txt`:
    -   `../Aes-Code/ASMD_Encryption.v`
    -   `../Aes-Code/ControlUnit_Enryption.v`
    -   `../Aes-Code/Datapath_Encryption.v`
    -   `../Aes-Code/Counter.v`
    -   `../Aes-Code/function_g.v`
    -   `../Aes-Code/Key_expansion.v`
    -   `../Aes-Code/mix_cols.v`
    -   `../Aes-Code/Register.v`
    -   `../Aes-Code/S_BOX.v`
    -   `../Aes-Code/shift_rows.v`
    -   `../Aes-Code/Sub_Bytes.v`

#### For Decryption:

-   `../picorv32.v` (main CPU file)
-   `fpga_top_decryption.v` (top-level module)
-   `../aes_decryption.hex` (program hex file)
-   All AES decryption files from `../decryption_files.txt`:
    -   `../Aes-Code/Aes-Decryption/ASMD_Decryption.v`
    -   `../Aes-Code/Aes-Decryption/ControlUnit_Decryption.v`
    -   `../Aes-Code/Aes-Decryption/Counter.v`
    -   `../Aes-Code/Aes-Decryption/Datapath_Decryption.v`
    -   `../Aes-Code/Aes-Decryption/function_g.v`
    -   `../Aes-Code/Aes-Decryption/Inv_mix_cols.v`
    -   `../Aes-Code/Aes-Decryption/inv_S_box.v`
    -   `../Aes-Code/Aes-Decryption/Inv_shift_rows.v`
    -   `../Aes-Code/Aes-Decryption/Inv_Sub_Bytes.v`
    -   `../Aes-Code/Aes-Decryption/Key_expansion.v`
    -   `../Aes-Code/Aes-Decryption/Register.v`
    -   `../Aes-Code/Aes-Decryption/S_BOX.v`

5.  Add constraints file:
    
    -   `fpga_top_encryption.xdc` (for encryption)
    -   OR `fpga_top_decryption.xdc` (for decryption)
6.  Set top module:
    
    -   Right-click on `fpga_top_encryption.v` → Set as Top
    -   OR Right-click on `fpga_top_decryption.v` → Set as Top

### Step 3: Configure Constraints File

1.  Open the appropriate `.xdc` file
2.  Uncomment and modify pin assignments for your FPGA board
3.  Adjust clock frequency if needed
4.  Save the file

**Common FPGA Board Pin Assignments:**

Board

Clock Pin

Reset Pin

LED Pin

Basys3

W5

U18

U16

Nexys A7

E3

C12

T14

Zybo

K17

R19

M14

### Step 4: Run Synthesis and Implementation

1.  Click **Run Synthesis** (or press Ctrl+Shift+S)
2.  Wait for synthesis to complete
3.  Click **Run Implementation** (or press Ctrl+Shift+I)
4.  Wait for implementation to complete
5.  Click **Generate Bitstream** (or press Ctrl+Shift+B)

### Step 5: Program FPGA

1.  Connect your FPGA board via USB
2.  Open Hardware Manager
3.  Click **Open Target** → **Auto Connect**
4.  Right-click on your device → **Program Device**
5.  Select the generated `.bit` file
6.  Click **Program**

## Verification

After programming:

-   The CPU will start executing from address 0x00
-   The AES operation will run automatically
-   Results will be stored in memory at address 0x120
-   You can use an ILA (Integrated Logic Analyzer) to monitor internal signals

## Troubleshooting

### Synthesis Errors

1.  **Missing hex file**: Make sure `aes_encryption.hex` or `aes_decryption.hex` is in the project root directory (same level as `picorv32.v`)
    
2.  **Missing AES files**: Check that all files from `encryption_files.txt` or `decryption_files.txt` are added to the project
    
3.  **Path issues**: Ensure hex file path in `$readmemh()` matches the file location
    

### Timing Issues

-   If timing fails, try reducing clock frequency in the constraints file
-   Check that clock period matches your board's actual clock

### Memory Issues

-   If you need more memory, increase `MEM_SIZE` parameter in the top-level module
-   Note: Larger memory uses more FPGA resources

## Notes

-   The hex files must be in the same directory as `picorv32.v` (project root)
-   Memory is implemented as Block RAM (BRAM) in the FPGA
-   The design uses ~1000-2000 LUTs and ~500-1000 FFs depending on FPGA
-   AES co-processor adds additional resources

## Support

For issues or questions, refer to:

-   PicoRV32 README: `../README.md`
-   Testbench files: `../testbench_aes_pico.v` and `../testbench_aes_decryption_pico.v`