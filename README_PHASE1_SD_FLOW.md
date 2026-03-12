# PicoRV32 SD Image AES Phase 1

This document explains the current Phase 1 flow that runs on a single Nexys4 DDR FPGA.

## Goal

Phase 1 combines:

- PicoRV32 processor
- AES encrypt and decrypt custom instructions
- BRAM boot image containing firmware and one fixed demo image
- SD-card controller

The purpose is to:

1. boot PicoRV32 from BRAM
2. wait in idle
3. start the image pipeline when `BTNC` is pressed
4. write the image to the SD card
5. encrypt it block by block
6. read ciphertext back and verify it
7. decrypt it block by block
8. write decrypted data back to the SD card
9. show pass/fail on LEDs and 7-segment

Phase 1 uses only one FPGA. The external FPGA-to-FPGA SPI transfer is not used here.

## Main Idea

The older standalone SD project had a top-level hardware FSM that controlled the whole pipeline directly.

This Phase 1 design is different:

- the SD controller is still hardware
- the AES engines are still hardware
- but the overall pipeline is now owned by PicoRV32

So the processor is responsible for:

- waiting for the button press
- filling the SD sector buffer through MMIO
- starting SD reads and writes through MMIO
- calling AES custom instructions
- checking ciphertext readback and decrypted data
- updating the board status outputs

## Important Files

### FPGA top

- [fpga/aes_soc_top_nexys4_sd.v](/A:/mySemData/FYP/picorv32-aes-co-processor/fpga/aes_soc_top_nexys4_sd.v)

This is the Nexys4 DDR top for Phase 1.

It connects:

- `picorv32`
- `bram_memory`
- `sd_phase1_mmio`
- `sd_spi`
- buttons
- LEDs
- 7-segment display

### SD MMIO block

- [sd_phase1_mmio.v](/A:/mySemData/FYP/picorv32-aes-co-processor/sd_phase1_mmio.v)

This is the bridge between PicoRV32 memory accesses and the SD controller.

It provides:

- SD control registers
- SD status registers
- sector address register
- GPIO status/output registers
- 512-byte SD sector buffer window

### BRAM program generator

- [generate_program_sd_hex.py](/A:/mySemData/FYP/picorv32-aes-co-processor/generate_program_sd_hex.py)

This script generates:

- [program_sd.hex](/A:/mySemData/FYP/picorv32-aes-co-processor/program_sd.hex)

It embeds:

- the PicoRV32 firmware instructions
- the fixed image blocks from `image_input.hex`
- the fixed AES key

### Verification

- [verify_sd.py](/A:/mySemData/FYP/picorv32-aes-co-processor/verify_sd.py)

This script reads the SD card after the FPGA run and reconstructs:

- original image
- encrypted image view
- decrypted image

## What Is Stored In BRAM

The BRAM is initialized from [program_sd.hex](/A:/mySemData/FYP/picorv32-aes-co-processor/program_sd.hex).

Inside that BRAM image:

- firmware code is stored at the beginning of memory
- image blocks are embedded starting at byte address `0x1000`
- fixed AES key is embedded at byte address `0x1C60`

So for this design:

- Vivado only needs `program_sd.hex`
- Vivado does not need `image_input.hex`

`image_input.hex` is only an input to the Python generator.

## Memory / MMIO Map

The PicoRV32 program uses normal BRAM for code/data and uses MMIO for SD access.

### BRAM

- `0x0000_0000 .. 0x0000_3FFF`

This is the 16 KB boot BRAM used by `bram_memory`.

### SD / GPIO MMIO

Base address:

- `0x0200_0000`

Registers:

- `0x0200_0000` `SD_CTRL`
  - bit `0`: start sector read
  - bit `1`: start sector write
  - bit `2`: clear `rd_done`
  - bit `3`: clear `wr_done`
- `0x0200_0004` `SD_STATUS`
  - bit `0`: `init_done`
  - bit `1`: `init_err`
  - bit `2`: `busy`
  - bit `3`: `rd_done`
  - bit `4`: `wr_done`
  - bits `12:8`: `debug_state`
  - bits `20:16`: `debug_last`
- `0x0200_0008` `SD_SECTOR_ADDR`
- `0x0200_0100` `GPIO_STATUS`
  - bit `0`: debounced `BTNC`
- `0x0200_0104` `GPIO_OUT`
  - firmware-owned display and status flags
- `0x0200_0200 .. 0x0200_03FF`
  - 512-byte SD sector buffer

## SD Card Layout

Phase 1 writes the same logical SD layout used in the standalone SD image design.

- sector `20`: metadata block
- sector `21`: AES key block
- sectors `22..217`: original image blocks
- sectors `218..413`: encrypted image blocks
- sectors `414..609`: decrypted image blocks

Important detail:

- each sector stores only one AES block in bytes `0..15`
- bytes `16..511` are expected to stay zero

## Run Flow On Hardware

### After programming

1. the FPGA configures
2. `program_sd.hex` initializes BRAM
3. PicoRV32 starts running immediately
4. the SD controller performs card initialization
5. the system waits in idle

Expected idle state:

- `LED[0] = 1` when SD init is done
- rightmost 7-seg shows `0`

### When `BTNC` is pressed

The processor starts one full run:

1. write metadata sector
2. write key sector
3. write original image sectors
4. for each 16-byte image block:
   - read original block
   - encrypt with PicoRV32 AES custom instructions
   - write ciphertext sector
   - read ciphertext back
   - compare readback ciphertext against generated ciphertext
   - decrypt ciphertext
   - compare decrypted plaintext against original plaintext
   - write decrypted sector
5. latch final pass or fail state
6. return to idle and wait for the next button press

## FPGA Outputs

For full board-output meaning, see:

- [README_FPGA_OUTPUTS.md](/A:/mySemData/FYP/picorv32-aes-co-processor/README_FPGA_OUTPUTS.md)

Short summary:

- `LED[0]`: SD init done
- `LED[1]`: preload to SD done
- `LED[2]`: ciphertext write/readback checks passed
- `LED[3]`: decrypted data matches original
- `LED[4]`: run completed
- `LED[5]`: overall pass
- `LED[6]`: SD controller busy
- `LED[15]`: error/fail path

7-segment:

- `0`: idle
- `1..7`: pipeline stages
- `9`: pass
- `A`: fail
- `E`: error

## How To Build The BRAM Image

If the image input changes, regenerate the BRAM image:

```powershell
cd A:\mySemData\FYP\picorv32-aes-co-processor
python generate_program_sd_hex.py
```

This regenerates:

- [program_sd.hex](/A:/mySemData/FYP/picorv32-aes-co-processor/program_sd.hex)

## What To Add In Vivado

Use these project files for Phase 1:

- [fpga/aes_soc_top_nexys4_sd.v](/A:/mySemData/FYP/picorv32-aes-co-processor/fpga/aes_soc_top_nexys4_sd.v)
- [sd_phase1_mmio.v](/A:/mySemData/FYP/picorv32-aes-co-processor/sd_phase1_mmio.v)
- [sd_spi.v](/A:/mySemData/FYP/picorv32-aes-co-processor/sd_spi.v)
- [debounce.v](/A:/mySemData/FYP/picorv32-aes-co-processor/debounce.v)
- [sevenSeg.v](/A:/mySemData/FYP/picorv32-aes-co-processor/sevenSeg.v)
- [bram_memory.v](/A:/mySemData/FYP/picorv32-aes-co-processor/bram_memory.v)
- [picorv32.v](/A:/mySemData/FYP/picorv32-aes-co-processor/picorv32.v)
- AES encrypt/decrypt RTL under `Aes-Code/`
- [fpga/nexys4ddr_sd_phase1.xdc](/A:/mySemData/FYP/picorv32-aes-co-processor/fpga/nexys4ddr_sd_phase1.xdc)
- [program_sd.hex](/A:/mySemData/FYP/picorv32-aes-co-processor/program_sd.hex) as Memory Initialization File

Top module:

- `aes_soc_top_nexys4_sd`

## How To Verify After FPGA Run

After programming the FPGA and pressing `BTNC`, verify the SD card with:

```powershell
cd A:\mySemData\FYP\picorv32-aes-co-processor
python verify_sd.py \\.\PhysicalDrive1
```

Expected good result:

- metadata sector is valid
- key sector contains the fixed AES key
- original image reconstructs correctly
- encrypted image looks different
- decrypted image matches the original
- overall result is `PASS`

The verifier also writes:

- `verify_outputs/original_from_sd.bmp`
- `verify_outputs/encrypted_view.bmp`
- `verify_outputs/decrypted_from_sd.bmp`

## Phase 1 Scope

This repository state is only for Phase 1.

Included:

- one FPGA
- PicoRV32-driven SD image pipeline
- BRAM-loaded image and code
- SD verification on PC

Not included yet:

- two-FPGA SPI transfer
- runtime image upload
- dynamic file selection

That will belong to Phase 2.
