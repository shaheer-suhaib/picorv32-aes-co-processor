# Full Pipeline: AES Encryption → SHA-256 → SPI Transmission → Decryption → Verification

## Overview

This document describes the integrated security pipeline where AES-128 encryption, SHA-256 hashing, and 8-lane parallel SPI transmission work together as a unified hardware pipeline. After encryption, the ciphertext is automatically hashed by an internal SHA-256 core, and both the ciphertext (16 bytes) and its hash (32 bytes) are transmitted via SPI — all without software intervention. Software independently verifies the results.

---

## What Was Done

### Problem
Previously, the three co-processors (AES encryption, AES decryption, SHA-256) operated independently. The SPI only transmitted the 16-byte ciphertext after encryption. SHA-256 hashed a separate test message ("abc") with no connection to the encryption output.

### Solution
The `pcpi_aes` encryption co-processor was modified to include an **internal SHA-256 core** that automatically hashes the ciphertext immediately after encryption completes. The SPI transmission was extended from 16 bytes to 48 bytes to send both the ciphertext and its SHA-256 hash in a single transfer. A new custom instruction (`AES_READ_HASH`) was added so software can also read the hash. The software SHA-256 co-processor (`pcpi_sha256`) now independently hashes the same ciphertext for verification.

---

## Architecture & Data Flow

```
                         HARDWARE (inside pcpi_aes module)
    ┌──────────────────────────────────────────────────────────────────┐
    │                                                                  │
    │  ┌─────────────┐     ┌──────────────┐     ┌──────────────────┐  │
    │  │   AES-128   │     │   SHA-256     │     │  8-Lane SPI      │  │
    │  │  Encryption │────►│  Hash Core    │────►│  Transmitter     │  │
    │  │             │     │  (internal)   │     │  (48 bytes)      │  │
    │  │  PT + KEY   │     │              │     │                  │──────► SPI Out
    │  │  → CT       │     │  CT → Digest  │     │  Bytes 0-15: CT  │  │
    │  └─────────────┘     └──────────────┘     │  Bytes 16-47:    │  │
    │       │                    │               │    SHA-256 Hash  │  │
    │       ▼                    ▼               └──────────────────┘  │
    │    RESULT reg          DIGEST reg                                │
    │    (128 bits)          (256 bits)                                │
    │       │                    │                                     │
    └───────┼────────────────────┼─────────────────────────────────────┘
            │                    │
            ▼                    ▼
    ┌───────────────┐    ┌───────────────┐
    │  AES_READ     │    │ AES_READ_HASH │
    │  (funct7=0x23)│    │ (funct7=0x25) │
    │  Read CT word │    │ Read hash word│
    └───────┬───────┘    └───────┬───────┘
            │                    │
            ▼                    ▼
         SOFTWARE (RISC-V program on PicoRV32)
    ┌──────────────────────────────────────────┐
    │                                          │
    │  1. Read CT from pcpi_aes (x8-x11)       │
    │  2. Store CT to memory                   │
    │  3. Load CT into pcpi_aes_dec            │
    │  4. Decrypt → verify plaintext matches   │
    │  5. Load CT into pcpi_sha256             │
    │  6. Hash → verify digest matches         │
    │                                          │
    └──────────────────────────────────────────┘
```

### Step-by-Step Pipeline Execution

| Step | Component | Action | Cycles |
|------|-----------|--------|--------|
| 1 | Software | Load plaintext + key into pcpi_aes | ~40 |
| 2 | Software | Issue AES_START instruction | 1 |
| 3 | **pcpi_aes** | AES-128 encryption (10 rounds) | ~22 |
| 4 | **pcpi_aes** | SHA-256 hashing of ciphertext (64 rounds) | ~68 |
| 5 | **pcpi_aes** | SPI transmits 48 bytes (CT + hash) | ~96 |
| 6 | Software | Read ciphertext, start decryption | ~40 |
| 7 | **pcpi_aes_dec** | AES-128 decryption | ~40 |
| 8 | Software | Verify decrypted plaintext matches original | ~20 |
| 9 | Software | Load ciphertext into pcpi_sha256 | ~60 |
| 10 | **pcpi_sha256** | SHA-256 hash (independent verification) | ~68 |
| 11 | Software | Compare digest with expected value | ~10 |

**Total pipeline: ~465 cycles (~4.65 µs at 100 MHz)**

---

## FSM State Machine (pcpi_aes)

The encryption co-processor FSM was extended from 8 states (3-bit) to 12 states (4-bit):

```
                    ┌──────┐
                    │ IDLE │◄──────────────────────────────┐
                    └──┬───┘                               │
                       │ pcpi_valid && instr_any            │
                       ▼                                   │
                  ┌─────────┐                              │
                  │ EXECUTE │──── load_pt/key/read/status ─┘
                  └────┬────┘     (immediate return)
                       │ instr_start
                       ▼
                 ┌───────────┐
                 │ START_AES │  assert aes_encrypt
                 └─────┬─────┘
                       ▼
                 ┌───────────┐
                 │ WAIT_AES  │  wait for aes_done
                 └─────┬─────┘  capture RESULT <= Dout
                       ▼
              ┌────────────┐
              │  SHA_INIT  │  pulse sha_init (initialize H values)
              └──────┬─────┘
                     ▼
              ┌────────────┐
              │  SHA_NEXT  │  pulse sha_next (start block processing)
              └──────┬─────┘
                     ▼
              ┌────────────┐
              │ SHA_DELAY  │  1-cycle delay for core startup
              └──────┬─────┘
                     ▼
              ┌────────────┐
              │  WAIT_SHA  │  wait for sha_digest_valid
              └──────┬─────┘  capture DIGEST <= sha_digest
                     ▼
            ┌──────────────┐
            │ SPI_CS_SETUP │  assert CS_n low, output byte[0]
            └──────┬───────┘
                   ▼
             ┌──────────┐
          ┌─►│ SPI_SEND │  output byte[n], clock high
          │  └─────┬────┘
          │        ▼
          │  ┌───────────┐
          │  │SPI_CLK_LOW│  clock low, increment index
          │  └─────┬─────┘
          │        │
          │   index < 47?
          │   yes │    no
          └───────┘    │
                       ▼
                 ┌──────────┐
                 │ COMPLETE │  pcpi_ready, return to IDLE
                 └──────────┘
```

---

## Important Signals

### SPI Output Interface (active during transmission)

| Signal | Width | Direction | Description |
|--------|-------|-----------|-------------|
| `aes_spi_data[7:0]` | 8 | Output | 8 parallel data lanes (1 byte per strobe) |
| `aes_spi_clk` | 1 | Output | Byte strobe clock (pulses high for 1 cycle per byte) |
| `aes_spi_cs_n` | 1 | Output | Chip select, active low during entire 48-byte transfer |
| `aes_spi_active` | 1 | Output | High while SPI transfer is in progress |

### SPI Data Layout (48 bytes per transfer)

```
Byte Index    Source Register    Content
─────────────────────────────────────────────────────
 0            RESULT[7:0]        Ciphertext byte 0 (LSB)
 1            RESULT[15:8]       Ciphertext byte 1
 ...          ...                ...
15            RESULT[127:120]    Ciphertext byte 15 (MSB)
─────────────────────────────────────────────────────
16            DIGEST[255:248]    SHA-256 H[0] MSB
17            DIGEST[247:240]    SHA-256 H[0] byte 1
18            DIGEST[239:232]    SHA-256 H[0] byte 2
19            DIGEST[231:224]    SHA-256 H[0] LSB
20            DIGEST[223:216]    SHA-256 H[1] MSB
 ...          ...                ...
44            DIGEST[31:24]      SHA-256 H[7] MSB
45            DIGEST[23:16]      SHA-256 H[7] byte 1
46            DIGEST[15:8]       SHA-256 H[7] byte 2
47            DIGEST[7:0]        SHA-256 H[7] LSB
─────────────────────────────────────────────────────
```

- **Ciphertext (bytes 0-15)**: Little-endian byte order from RESULT register
- **SHA-256 hash (bytes 16-47)**: Big-endian byte order from DIGEST register
- **Receiver** should sample `aes_spi_data` on rising edge of `aes_spi_clk`

### Internal SHA-256 Signals (inside pcpi_aes)

| Signal | Width | Description |
|--------|-------|-------------|
| `sha_block[511:0]` | 512 | Padded ciphertext block (combinational wire) |
| `sha_init` | 1 | Initialize SHA-256 core (1-cycle pulse) |
| `sha_next` | 1 | Start SHA-256 processing (1-cycle pulse) |
| `sha_digest[255:0]` | 256 | SHA-256 output from core |
| `sha_digest_valid` | 1 | High when digest is ready |
| `DIGEST[255:0]` | 256 | Captured SHA-256 hash (registered) |

### SHA-256 Message Block Construction (hardware)

The 128-bit ciphertext is automatically padded to a 512-bit SHA-256 message block:

```
sha_block = {RESULT, 32'h80000000, 320'd0, 32'h00000080}

Bit Position    Content              Value (for FIPS-197 test vector)
────────────────────────────────────────────────────────────────
[511:480]       W[0]  = CT[127:96]   0x69c4e0d8
[479:448]       W[1]  = CT[95:64]    0x6a7b0430
[447:416]       W[2]  = CT[63:32]    0xd8cdb780
[415:384]       W[3]  = CT[31:0]     0x70b4c55a
[383:352]       W[4]  = padding      0x80000000
[351:64]        W[5]-W[14] = zeros   0x00000000 (x10)
[63:32]         W[14] = zero         0x00000000
[31:0]          W[15] = msg length   0x00000080 (128 bits)
────────────────────────────────────────────────────────────────
```

### Custom Instructions (complete table)

| Instruction | funct7 | Hex | Description |
|-------------|--------|-----|-------------|
| **AES Encryption** | | | |
| AES_LOAD_PT | 0100000 | 0x20 | Load plaintext word (rs1[1:0]=index, rs2=data) |
| AES_LOAD_KEY | 0100001 | 0x21 | Load key word |
| AES_START | 0100010 | 0x22 | Start encryption → SHA-256 → SPI (blocking) |
| AES_READ | 0100011 | 0x23 | Read ciphertext word (rs1[1:0]=index) |
| AES_STATUS | 0100100 | 0x24 | Check completion (1=done, 0=busy) |
| **AES_READ_HASH** | **0100101** | **0x25** | **Read SHA-256 hash word (rs1[2:0]=index 0-7) [NEW]** |
| **AES Decryption** | | | |
| AES_DEC_LOAD_CT | 0101000 | 0x28 | Load ciphertext word for decryption |
| AES_DEC_LOAD_KEY | 0101001 | 0x29 | Load key word for decryption |
| AES_DEC_START | 0101010 | 0x2A | Start decryption |
| AES_DEC_READ | 0101011 | 0x2B | Read decrypted plaintext word |
| AES_DEC_STATUS | 0101100 | 0x2C | Check decryption completion |
| **SHA-256** | | | |
| SHA_LOAD_MSG | 0110000 | 0x30 | Load message block word (rs1[3:0]=index) |
| SHA_START | 0110001 | 0x31 | Start SHA-256 hash |
| SHA_READ | 0110010 | 0x32 | Read digest word (rs1[2:0]=index) |
| SHA_STATUS | 0110011 | 0x33 | Check SHA-256 completion |

All instructions use opcode `0x0B` (custom-0) with funct3 = `0x0`.

---

## Test Vectors

### AES-128 (FIPS-197)
```
Plaintext:  0x00112233445566778899aabbccddeeff
Key:        0x000102030405060708090a0b0c0d0e0f
Ciphertext: 0x69c4e0d86a7b0430d8cdb78070b4c55a
```

### SHA-256 of Ciphertext
```
Message (16 bytes): 0x69c4e0d86a7b0430d8cdb78070b4c55a

SHA-256 Digest:
  H[0] = 0xfb140790
  H[1] = 0x6864ec3b
  H[2] = 0xf9823962
  H[3] = 0xfb2ff077
  H[4] = 0x53dbc877
  H[5] = 0x7da34b08
  H[6] = 0xd23019b0
  H[7] = 0xc899f339

Full: 0xfb1407906864ec3bf9823962fb2ff07753dbc8777da34b08d23019b0c899f339
```

---

## Verification Results (Simulation)

Four independent checks all pass:

| Test | Method | Result |
|------|--------|--------|
| Encryption via SPI | Compare 16 SPI bytes vs expected ciphertext | PASSED |
| SHA-256 via SPI | Compare 32 SPI bytes vs expected hash | PASSED |
| Decryption | Decrypt ciphertext, compare with original plaintext | PASSED |
| Software SHA-256 | Independent hash via pcpi_sha256, compare H[0] | PASSED |

### Timing (100 MHz simulation)
- SPI transfer starts: cycle 271
- SPI transfer complete (48 bytes): cycle 367
- Decryption verified: cycle 1046
- SHA-256 software verified: cycle 1613

---

## Resource Impact

### Hardware Added to pcpi_aes
- 1x `sha256_core` instance (shared module definition with pcpi_sha256)
- 256-bit `DIGEST` register
- 512-bit `sha_block` combinational wire (padding logic)
- FSM expanded from 3-bit (8 states) to 4-bit (12 states)
- `spi_byte_index` widened from 5-bit to 6-bit (0-47 range)

### Module Hierarchy (pcpi_aes)
```
pcpi_aes
├── ASMD_Encryption (aes_core)
│   ├── ControlUnit_Enryption
│   └── Datapath_Encryption
│       ├── Round_Key_Update
│       ├── Sub_Bytes (16x S_BOX)
│       ├── shift_rows
│       └── mix_cols
├── sha256_core (sha_pipe_inst)    ← NEW
│   ├── sha256_w_mem
│   └── sha256_k_constants
└── [SPI logic: byte mux + FSM]
```

---

## Memory Map

```
Address Range    Content
──────────────────────────────────────────
0x000 - 0x243    Program code (145 instructions)
0x244 - 0x2FF    Unused (available for expansion)
0x300 - 0x30F    Plaintext data (4 words)
0x310 - 0x31F    Key data (4 words)
0x320 - 0x32F    Encrypted result storage
0x330            Decryption match flag (1=match, 2=mismatch)
0x340 - 0x34F    Decrypted plaintext storage
0x400 - 0x43F    (Available - SHA message no longer pre-stored)
0x440 - 0x45F    SHA-256 digest output (8 words)
0x460            SHA-256 match flag (1=match, 2=mismatch)
──────────────────────────────────────────
```
