# Image AES Encryption/Decryption Implementation

This document details the implementation of end-to-end image encryption and decryption using the AES-128 co-processor, including the bugs discovered and fixes applied.

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Implementation Steps](#implementation-steps)
4. [Bugs Discovered and Fixes](#bugs-discovered-and-fixes)
5. [Files Created](#files-created)
6. [How to Run](#how-to-run)
7. [Lessons Learned](#lessons-learned)

---

## Overview

### Goal
Demonstrate that an image can be:
1. Loaded into memory
2. Encrypted block-by-block using AES-128
3. Decrypted block-by-block (loopback)
4. Reconstructed as an identical copy of the original

### Result
Successfully implemented and verified with a 32x32 BMP test image (3126 bytes = 196 AES blocks). The decrypted output is byte-for-byte identical to the original.

---

## Architecture

### Data Flow

```
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│ Image File  │────▶│ image_to_hex │────▶│ image_input.hex │
│ (any format)│     │   (Python)   │     │ (128-bit blocks)│
└─────────────┘     └──────────────┘     └────────┬────────┘
                                                  │
                                                  ▼
                                         ┌───────────────┐
                                         │  Testbench    │
                                         │  Memory Load  │
                                         │ ($readmemh)   │
                                         └───────┬───────┘
                                                 │
                    ┌────────────────────────────┼────────────────────────────┐
                    │                            │                            │
                    ▼                            ▼                            ▼
           ┌───────────────┐            ┌───────────────┐            ┌───────────────┐
           │ Block 1       │            │ Block 2       │            │ Block N       │
           │ Encrypt (AES) │            │ Encrypt (AES) │    ...     │ Encrypt (AES) │
           └───────┬───────┘            └───────┬───────┘            └───────┬───────┘
                   │                            │                            │
                   ▼                            ▼                            ▼
           ┌───────────────┐            ┌───────────────┐            ┌───────────────┐
           │ Block 1       │            │ Block 2       │            │ Block N       │
           │ Decrypt (AES) │            │ Decrypt (AES) │    ...     │ Decrypt (AES) │
           └───────┬───────┘            └───────┬───────┘            └───────┬───────┘
                   │                            │                            │
                   └────────────────────────────┼────────────────────────────┘
                                                │
                                                ▼
                                       ┌─────────────────┐
                                       │ Verify: Does    │
                                       │ decrypted ==    │
                                       │ original?       │
                                       └────────┬────────┘
                                                │
                                                ▼
                                      ┌──────────────────┐
                                      │ image_decrypted  │
                                      │     .hex         │
                                      └────────┬─────────┘
                                               │
                                               ▼
                                      ┌──────────────┐     ┌─────────────┐
                                      │ hex_to_image │────▶│ Recovered   │
                                      │   (Python)   │     │ Image File  │
                                      └──────────────┘     └─────────────┘
```

### AES Block Processing

AES-128 operates on 128-bit (16-byte) blocks. For an image of N bytes:
- Pad to multiple of 16 bytes (PKCS7-style)
- Process `ceil(N/16)` blocks
- First block in hex file is metadata (original file size)

---

## Implementation Steps

### Step 1: Python Conversion Scripts

Created two Python scripts to convert between image files and Verilog-compatible hex format.

**image_to_hex.py:**
- Reads any binary file (image, etc.)
- Pads to 16-byte boundary
- Writes 32 hex characters per line (128 bits)
- First line contains metadata (original file size)

**hex_to_image.py:**
- Reads hex file (handles Verilog `$writememh` comments)
- Extracts original file size from metadata
- Reconstructs original file

### Step 2: Test Image Generator

Created `create_test_image.py` to generate simple BMP test images with gradient patterns. This provides reproducible test cases without requiring external image files.

### Step 3: Verilog Testbench

Created `tb_image_aes.v` that:
1. Loads hex data into memory using `$readmemh`
2. Iterates through all blocks
3. Encrypts each block using `ASMD_Encryption` module
4. Decrypts each block using `ASMD_Decryption` module
5. Compares decrypted output with original
6. Writes results using `$writememh`

### Step 4: Debug and Fix

Created `tb_aes_single.v` for isolated single-block testing to identify bugs (see next section).

---

## Bugs Discovered and Fixes

### Bug #1: Decryption Control Unit - Missing Default Assignments

**File:** `Aes-Code/Aes-Decryption/ControlUnit_Decryption.v`

**Symptom:** Decryption would hang indefinitely, never completing.

**Root Cause:** The FSM combinatorial block was missing:
1. Default assignment for `next` state variable
2. Default assignment for `en_reg_inv_col_out` output

**Original Code:**
```verilog
always @(*) begin
    done = 0;
    isRound10 = 0;
    isRound9 = 0;
    init = 0;
    dec_count = 0;
    en_round_out = 0;
    en_reg_inv_row_out = 0;
    en_reg_inv_sub_out = 0;
    en_Dout = 0;
    // MISSING: en_reg_inv_col_out = 0;
    // MISSING: next = current;
    case (current)
        S0: begin
            if (decrypt) begin
                init = 1;
                next = S1;
            end
            // If decrypt=0, next is UNDEFINED - creates latch!
        end
        ...
    endcase
end
```

**Fixed Code:**
```verilog
always @(*) begin
    // Default values for all outputs
    done = 0;
    isRound10 = 0;
    isRound9 = 0;
    init = 0;
    dec_count = 0;
    en_round_out = 0;
    en_reg_inv_row_out = 0;
    en_reg_inv_sub_out = 0;
    en_reg_inv_col_out = 0;  // ADDED
    en_Dout = 0;

    // CRITICAL: Default value for next to prevent latch
    next = current;  // ADDED

    case (current)
        ...
    endcase
end
```

**Why This Matters:**
- Without `next = current`, the FSM would have undefined behavior when no transition was specified
- This creates an inferred latch in synthesis, which is unpredictable
- The FSM could get stuck or behave erratically

---

### Bug #2: Encryption Counter Never Resets

**File:** `Aes-Code/Datapath_Encryption.v`

**Symptom:** First encryption works correctly. Second and subsequent encryptions produce wrong/undefined output.

**Root Cause:** The round counter's `load` signal was hardcoded to `1'b0`, so the counter never reset between encryptions.

**Original Code:**
```verilog
//Counter
Counter #(4) up(count, 4'd0, 1'b0, inc_count, 1'b0, clock, reset);
//                      ^^^^  ^^^^
//                      |     load = 0 (NEVER LOADS!)
//                      loadValue = 0
```

**What Happened:**
1. First encryption: counter starts at 0, increments to 10, encryption completes
2. Second encryption: counter is STILL at 10, `count_lt_10` is false
3. FSM skips rounds, produces garbage output

**Fixed Code:**
```verilog
//Counter - load=init to reset counter when starting new encryption
Counter #(4) up(count, 4'd0, init, inc_count, 1'b0, clock, reset);
//                           ^^^^
//                           load = init (resets to 0 when starting)
```

**Why This Matters:**
- The `init` signal is asserted when starting a new encryption
- Connecting it to `load` resets the counter to 0 at the start of each encryption
- This ensures each encryption runs all 10 rounds correctly

---

### Bug #3: Testbench Timing Issue

**File:** `tb_image_aes.v` (and `tb_aes_single.v`)

**Symptom:** Even after fixing Bug #2, the second encryption produced the same ciphertext as the first (plaintext register not updating).

**Root Cause:** The testbench set `enc_start` AFTER the clock edge, so the FSM never saw the start signal.

**Original Code:**
```verilog
enc_plaintext = input_data[block_idx];  // Load new plaintext
@(posedge clk);  // Wait for clock edge
enc_start = 1;   // Set start AFTER edge - FSM misses it!
@(posedge clk);  // FSM still doesn't see enc_start=1 at THIS edge
enc_start = 0;
```

**Timeline Problem:**
```
Time 0ns:  Clock edge occurs, enc_start is still 0
Time 0ns+: enc_start becomes 1 (too late!)
Time 10ns: Clock edge, FSM finally sees enc_start=1
```

The FSM in state S6 outputs `init=1` when it sees `encrypt=1`. But `init` must be high AT the clock edge for the plaintext register to capture the new value.

**Fixed Code:**
```verilog
enc_plaintext = input_data[block_idx];  // Load new plaintext
@(posedge clk);  // Let plaintext settle

enc_start = 1;   // Set start BEFORE clock edge
@(posedge clk);  // This edge: FSM sees encrypt=1, outputs init=1, register captures
@(posedge clk);  // Let FSM continue processing
enc_start = 0;
```

**Why This Matters:**
- Verilog `@(posedge clk)` waits for the edge, then continues
- Assignments after `@(posedge clk)` happen AFTER the edge
- For the FSM to see a signal at the clock edge, it must be set BEFORE
- This is a common testbench timing mistake

---

## Files Created

| File | Purpose |
|------|---------|
| `scripts/image_to_hex.py` | Convert image/binary to hex format for `$readmemh` |
| `scripts/hex_to_image.py` | Convert hex back to original format (handles `$writememh` comments) |
| `scripts/create_test_image.py` | Generate test BMP images with gradient patterns |
| `tb_image_aes.v` | Main testbench for image encryption/decryption |
| `tb_aes_single.v` | Debug testbench for single-block AES testing |
| `run_image_test.sh` | One-command script to run the full test |
| `docs/IMAGE_AES_IMPLEMENTATION.md` | This documentation |

---

## How to Run

### Quick Test (Auto-Generated Image)

```bash
./run_image_test.sh
```

This will:
1. Create a 64x64 test image
2. Convert to hex
3. Compile and run simulation
4. Convert back to image
5. Compare original vs recovered

### Test with Custom Image

```bash
./run_image_test.sh path/to/your/image.png
```

### Manual Steps

```bash
# 1. Create test image (optional)
python3 scripts/create_test_image.py 32

# 2. Convert to hex
python3 scripts/image_to_hex.py test_image_32x32.bmp image_input.hex

# 3. Compile testbench
iverilog -g2012 -o tb_image_aes.vvp \
    tb_image_aes.v \
    Aes-Code/ASMD_Encryption.v \
    Aes-Code/ControlUnit_Enryption.v \
    Aes-Code/Datapath_Encryption.v \
    Aes-Code/Key_expansion.v \
    Aes-Code/S_BOX.v \
    Aes-Code/Sub_Bytes.v \
    Aes-Code/mix_cols.v \
    Aes-Code/shift_rows.v \
    Aes-Code/function_g.v \
    Aes-Code/Counter.v \
    Aes-Code/Register.v \
    Aes-Code/Aes-Decryption/ASMD_Decryption.v \
    Aes-Code/Aes-Decryption/ControlUnit_Decryption.v \
    Aes-Code/Aes-Decryption/Datapath_Decryption.v \
    Aes-Code/Aes-Decryption/inv_S_box.v \
    Aes-Code/Aes-Decryption/Inv_Sub_Bytes.v \
    Aes-Code/Aes-Decryption/Inv_mix_cols.v \
    Aes-Code/Aes-Decryption/Inv_shift_rows.v

# 4. Run simulation
vvp tb_image_aes.vvp

# 5. Convert decrypted hex back to image
python3 scripts/hex_to_image.py image_decrypted.hex recovered_image.bmp

# 6. Compare
cmp test_image_32x32.bmp recovered_image.bmp && echo "SUCCESS!"
```

---

## Lessons Learned

### 1. FSM Design Best Practices

**Always include default assignments in combinatorial blocks:**
```verilog
always @(*) begin
    // Default ALL outputs
    output1 = 0;
    output2 = 0;
    next = current;  // CRITICAL for FSMs!

    case (current)
        ...
    endcase
end
```

This prevents:
- Inferred latches
- Undefined behavior
- Synthesis warnings/errors

### 2. Counter/Register Initialization

**Ensure stateful elements can be re-initialized:**
- Counters need a load/reset mechanism for repeated operations
- Don't hardcode control signals to constants unless truly static
- Consider what happens on the SECOND operation, not just the first

### 3. Testbench Timing

**Signal timing relative to clock edges matters:**
```verilog
// WRONG - signal changes AFTER edge
@(posedge clk);
signal = 1;

// RIGHT - signal is stable BEFORE edge
signal = 1;
@(posedge clk);
```

For synchronous logic, inputs must be stable before the clock edge for the logic to sample them correctly.

### 4. Incremental Testing

**Debug complex systems by isolating components:**
1. First, test single-block operation
2. Then test multiple blocks
3. Use targeted debug testbenches (`tb_aes_single.v`)
4. Add `$display` statements to trace state

### 5. Simulation vs Synthesis

**$readmemh and $writememh behavior:**
- `$writememh` adds comment lines (`// 0x00000000`)
- Python scripts must handle these comments
- Memory initialization works in both simulation and synthesis (Vivado)

---

## Test Results

```
========================================
  Image AES Encryption/Decryption Test
========================================

Input: test_image_32x32.bmp (3126 bytes)
Blocks: 197 (1 metadata + 196 data)
Key: 0x000102030405060708090a0b0c0d0e0f

Encryption: 196 blocks processed
Decryption: 196 blocks processed
Verification: All 197 blocks match!

Output: recovered_image.bmp
Result: IDENTICAL to original!
```

---

## Future Improvements

1. **CBC Mode**: Currently uses ECB (each block independent). CBC would chain blocks for better security.

2. **Hardware Acceleration**: The current design processes one block at a time. Pipelining could increase throughput.

3. **DMA Integration**: For FPGA implementation, DMA could stream image data directly to/from the AES core.

4. **Key Management**: Currently uses a fixed key. A key loading mechanism would be needed for practical use.

---

*Document created: 2024*
*Last updated: After successful image encryption/decryption test*
