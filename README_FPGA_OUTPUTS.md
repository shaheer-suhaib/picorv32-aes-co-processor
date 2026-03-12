# PicoRV32 SD Image AES Phase 1: FPGA Output Guide

This file explains how to read the Nexys4 DDR outputs for the Phase 1 design using:

- [aes_soc_top_nexys4_sd.v](/A:/mySemData/FYP/picorv32-aes-co-processor/fpga/aes_soc_top_nexys4_sd.v)
- [sd_phase1_mmio.v](/A:/mySemData/FYP/picorv32-aes-co-processor/sd_phase1_mmio.v)
- [phase1_sd_image_demo.c](/A:/mySemData/FYP/picorv32-aes-co-processor/firmware_sd/phase1_sd_image_demo.c)
- [sd_spi.v](/A:/mySemData/FYP/picorv32-aes-co-processor/sd_spi.v)

## Buttons

- `BTND`: reset the whole design
- `BTNC`: start the CPU-owned SD image pipeline once the board is idle

## LEDs

The LED mapping is defined in [aes_soc_top_nexys4_sd.v](/A:/mySemData/FYP/picorv32-aes-co-processor/fpga/aes_soc_top_nexys4_sd.v#L169).

- `LED[0]`: SD card initialization done
- `LED[1]`: preload to SD completed
- `LED[2]`: ciphertext write/readback checks passed so far
- `LED[3]`: decrypted data matches original so far
- `LED[4]`: run completed
- `LED[5]`: overall pass flag from firmware
- `LED[6]`: SD controller busy
- `LED[7]`: debounced `BTNC` level
- `LED[8]`: PicoRV32 trap
- `LED[9]`: unused
- `LED[14:10]`: SD controller debug state
- `LED[15]`: error flag

## How To Read `LED[14:10]`

These five LEDs come from the SD controller debug bus.

- While `LED[6] = 1`, `LED[14:10]` shows the current SD FSM state
- While `LED[6] = 0`, `LED[14:10]` shows the last SD FSM state reached before the controller became idle or failed

Common init states from [sd_spi.v](/A:/mySemData/FYP/picorv32-aes-co-processor/sd_spi.v):

- `0`: `ST_PWRUP`
- `1`: `ST_PWRDLY`
- `2`: `ST_DUMMY`
- `3`: `ST_CMD0`
- `4`: `ST_CMD0_RESP`
- `5`: `ST_CMD8`
- `6`: `ST_CMD8_RESP`
- `7`: `ST_CMD55`
- `8`: `ST_CMD55_RESP`
- `9`: `ST_ACMD41`
- `10` (`A`): `ST_ACMD41_RESP`
- `11` (`B`): `ST_READY`
- `26`: `ST_ERROR`

Important interpretation:

- `LED15 = 1` and `LED[14:10] = 4` means SD init failed waiting for `CMD0` response
- `LED15 = 1` and `LED[14:10] = 26` means the SD controller entered its generic error state

## 7-Segment Display

The rightmost digit is the main status digit.

- Before SD init finishes:
  - rightmost digit shows `sd_debug_state[3:0]`
  - use this together with `LED[14:10]` for SD bring-up debugging
- After SD init finishes:
  - rightmost digit shows the firmware stage code from `GPIO_OUT[3:0]`

The other digits are mostly placeholders in the current [sevenSeg.v](/A:/mySemData/FYP/picorv32-aes-co-processor/sevenSeg.v). For practical debugging, rely on:

- rightmost 7-seg digit
- `LED[0..8]`
- `LED[14:10]`
- `LED[15]`

## Firmware Stage Codes

Stage values are defined in [phase1_sd_image_demo.c](/A:/mySemData/FYP/picorv32-aes-co-processor/firmware_sd/phase1_sd_image_demo.c#L32).

- `0`: idle, waiting for `BTNC`
- `1`: preload metadata, key, and original image blocks to SD
- `2`: read original block from SD
- `3`: encrypt block with PicoRV32 AES custom instructions
- `4`: write ciphertext block to SD
- `5`: read ciphertext block back from SD
- `6`: decrypt ciphertext block
- `7`: write decrypted block to SD
- `9`: pass
- `A` (`10`): fail
- `E` (`14`): error

## Expected Board Behavior

### After programming, before pressing `BTNC`

- `LED[0]` should eventually turn on
- rightmost 7-seg should settle to `0`
- `LED[6]` should go low once SD init is complete

### When `BTNC` is pressed

You should see the stage digit move roughly through:

- `1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7`

This repeats for all image blocks.

During this time:

- `LED[6]` will pulse/high while the SD controller is active
- `LED[1]` turns on after preload completes

### Successful run

At the end:

- rightmost 7-seg shows `9`
- `LED[1] = 1`
- `LED[2] = 1`
- `LED[3] = 1`
- `LED[4] = 1`
- `LED[5] = 1`
- `LED[15] = 0`

Meaning:

- preload completed
- ciphertext readback matched what firmware produced
- decrypted data matched the original image block-by-block
- run completed
- overall pass asserted

### Failed run

At the end:

- rightmost 7-seg shows `A` or `E`
- `LED[15]` may be high
- `LED[14:10]` tells you the SD state involved if the problem is in the SD controller

Use the meaning of `LED[2]` and `LED[3]` to narrow the issue:

- `LED[2] = 0`: ciphertext write/readback mismatch happened
- `LED[3] = 0`: decryption mismatch happened

## Quick Debug Checklist

If nothing happens correctly:

1. Check `LED[0]`
   - if `0`, SD init never finished
2. Check `LED[15]`
   - if `1`, look at `LED[14:10]`
3. Check rightmost 7-seg digit
   - before init: SD debug state
   - after init: firmware stage
4. If the run ends in `9`, verify the SD card with:

```powershell
python verify_sd.py \\.\PhysicalDrive1
```

## Sector Layout Written By Phase 1

The firmware uses the same SD layout as the standalone SD image design:

- sector `20`: metadata block
- sector `21`: AES key block
- sectors `22..217`: original image blocks
- sectors `218..413`: encrypted image blocks
- sectors `414..609`: decrypted image blocks

Each sector stores one 16-byte AES payload in bytes `0..15`. Bytes `16..511` are expected to remain zero.
