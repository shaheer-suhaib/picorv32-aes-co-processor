# PicoRV32 with AES Co-Processor Extension

## High-Level Architecture & Data Flow

This is an extended version of PicoRV32 with integrated AES-128 encryption/decryption co-processors and 8-lane parallel SPI output.

---

## System Overview

```
┌────────────────────────────────────────────────────────────────────────────────────────────┐
│                                    FPGA TOP LEVEL                                          │
│                                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────────────────────┐ │
│  │                            PicoRV32 CPU Core (RV32IMC)                               │ │
│  │  ┌─────────────────┐  ┌────────────────┐  ┌────────────────┐  ┌──────────────────┐  │ │
│  │  │ Instruction     │  │  Register File │  │   ALU Pipeline │  │  Memory Interface│  │ │
│  │  │ Fetch/Decode    │─▶│   x0 - x31     │─▶│   (MUL/DIV)    │─▶│  (Native/AXI)    │  │ │
│  │  └─────────────────┘  └────────────────┘  └────────────────┘  └──────────────────┘  │ │
│  │           │                   │                    │                                  │ │
│  │           │                   ▼ 32-bit             │                                  │ │
│  │           │         ┌──────────────────────┐       │                                  │ │
│  │           │         │  PCPI Interface      │       │                                  │ │
│  │           │         │  (Co-Processor Bus)  │       │                                  │ │
│  │           │         │  • pcpi_valid        │       │                                  │ │
│  │           │         │  • pcpi_insn [31:0]  │       │                                  │ │
│  │           │         │  • pcpi_rs1  [31:0] ─┼───────┤  From Register File              │ │
│  │           │         │  • pcpi_rs2  [31:0] ─┼───────┘  (operands)                      │ │
│  │           │         │  • pcpi_rd   [31:0] ◀┼───────┐  To Register File                │ │
│  │           │         │  • pcpi_ready        │       │  (result)                        │ │
│  │           │         │  • pcpi_wait         │       │                                  │ │
│  │           │         └─────────┬────────────┘       │                                  │ │
│  └───────────────────────────────┼────────────────────┼──────────────────────────────────┘ │
│                                  │                    │                                    │
│                                  ▼                    │                                    │
│  ┌────────────────────────────────────────────────────────────────────────────────────┐   │
│  │                       PCPI Multiplexer / Arbiter                                   │   │
│  │  (Routes custom instructions to appropriate co-processor)                          │   │
│  └───┬──────────────────────────┬─────────────────────────┬───────────────────────────┘   │
│      │                          │                         │                               │
│      │ MUL/DIV                  │ AES Encryption          │ AES Decryption                │
│      │ (if enabled)             │ (ENABLE_AES=1)          │ (ENABLE_AES_DEC=1)            │
│      │                          │                         │                               │
│  ┌───▼────────────┐  ┌──────────▼──────────────────┐  ┌──▼─────────────────────────┐     │
│  │ pcpi_mul/div   │  │     pcpi_aes               │  │   pcpi_aes_dec             │     │
│  │ (RV32M)        │  │  AES-128 Encryption        │  │   AES-128 Decryption       │     │
│  └────────────────┘  │  Co-Processor              │  │   Co-Processor             │     │
│                      │                            │  │                            │     │
│                      │  ┌──────────────────────┐  │  │  ┌──────────────────────┐  │     │
│                      │  │  DATA BUFFER         │  │  │  │  DATA BUFFER         │  │     │
│                      │  │  (Plaintext Reg)     │  │  │  │  (Ciphertext Reg)    │  │     │
│                      │  │  [127:0]             │  │  │  │  [127:0]             │  │     │
│                      │  └──────────────────────┘  │  │  └──────────────────────┘  │     │
│                      │           │                │  │           │                │     │
│                      │  ┌────────▼──────────────┐ │  │  ┌────────▼──────────────┐ │     │
│                      │  │  KEY BUFFER          │ │  │  │  KEY BUFFER          │ │     │
│                      │  │  (Original Key)      │ │  │  │  (Original Key)      │ │     │
│                      │  │  [127:0]             │ │  │  │  [127:0]             │ │     │
│                      │  └──────────────────────┘ │  │  └──────────────────────┘ │     │
│                      │           │                │  │           │                │     │
│                      │  ┌────────▼──────────────┐ │  │  ┌────────▼──────────────┐ │     │
│                      │  │  AES ENCRYPTION      │ │  │  │  AES DECRYPTION      │ │     │
│                      │  │  CORE (10 Rounds)    │ │  │  │  CORE (10 Rounds)    │ │     │
│                      │  │  • On-the-fly Keys   │ │  │  │  • On-the-fly Keys   │ │     │
│                      │  │  • SubBytes          │ │  │  │  • InvSubBytes       │ │     │
│                      │  │  • ShiftRows         │ │  │  │  • InvShiftRows      │ │     │
│                      │  │  • MixColumns        │ │  │  │  • InvMixColumns     │ │     │
│                      │  │  ~45 cycles          │ │  │  │  ~45 cycles          │ │     │
│                      │  └──────────┬───────────┘ │  │  └──────────┬───────────┘ │     │
│                      │             │ 128         │  │             │ 128         │     │
│                      │  ┌──────────▼───────────┐ │  │  ┌──────────▼───────────┐ │     │
│                      │  │ OUTPUT REGISTER     │ │  │  │ OUTPUT REGISTER     │ │     │
│                      │  │ (Ciphertext)        │ │  │  │ (Plaintext)         │ │     │
│                      │  │ [127:0]             │ │  │  │ [127:0]             │ │     │
│                      │  └──────────┬───────────┘ │  │  └──────────┬───────────┘ │     │
│                      │             │             │  │             │             │     │
│                      │             │             │  │             │             │     │
│                      │  ┌──────────▼───────────┐ │  │  (No SPI for decryption) │     │
│                      │  │ 8-Lane Parallel SPI │ │  │                            │     │
│                      │  │ Controller          │ │  │                            │     │
│                      │  │ • Auto-triggered    │ │  │                            │     │
│                      │  │ • 16 bytes in 16    │ │  │                            │     │
│                      │  │   clock pulses      │ │  │                            │     │
│                      │  └──────────┬───────────┘ │  │                            │     │
│                      │             │             │  │                            │     │
│                      │     ┌───────┼───────┐     │  │                            │     │
│                      │     │       │       │     │  │                            │     │
│                      └─────┼───────┼───────┼─────┘  └────────────────────────────┘     │
│                            │       │       │                                            │
│  ┌─────────────────────────▼───────▼───────▼──────────────────────┐                    │
│  │               8-Lane Parallel SPI Output Pins                  │                    │
│  │  • aes_spi_data[7:0]  - 8 parallel data lanes (GPIO pins)      │                    │
│  │  • aes_spi_clk        - Clock strobe (1 pulse per byte)        │                    │
│  │  • aes_spi_cs_n       - Chip select (active low)               │                    │
│  │  • aes_spi_active     - Transfer status (LED indicator)        │                    │
│  └─────────────────────────────────────────────────────────────────┘                    │
│                                                                                            │
│  Performance @ 100 MHz:                                                                   │
│  • AES Encryption: ~45 cycles = 450 ns                                                    │
│  • SPI Transmission: 16 cycles = 160 ns (8 bits per cycle!)                              │
│  • Total: ~610 ns per 128-bit block                                                       │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## AES Encryption Datapath (Detailed)

```
┌───────────────────────────────────────────────────────────────────────────────────────────────┐
│                         AES-128 Encryption Core (Datapath_Encryption.v)                       │
│                         ASMD Architecture with On-the-Fly Key Expansion                       │
│                                                                                               │
│  ┌──────────────────┐                     ┌──────────────────┐                               │
│  │  Plain Text Reg  │                     │  Original Key    │                               │
│  │  [127:0]         │                     │  Reg_key [127:0] │                               │
│  │  ┌──┬──┬──┬──┐   │                     │  ┌──┬──┬──┬──┐   │                               │
│  │  │PT│PT│PT│PT│   │                     │  │K │K │K │K │   │                               │
│  │  │[3]│[2]│[1]│[0]│   │                     │  │[3]│[2]│[1]│[0]│   │                               │
│  │  └──┴──┴──┴──┘   │                     │  └──┴──┴──┴──┘   │                               │
│  │  4×32-bit words  │                     │  4×32-bit words  │                               │
│  └────────┬─────────┘                     └─────────┬────────┘                               │
│           │ 128                                     │ 128                                     │
│           │                      ┌──────────────────▼─────────────────────┐                  │
│           │                      │  Round Key Register (NEW!)             │                  │
│           │                      │  Reg_round_key [127:0]                 │                  │
│           │                      │  • Stores current round key            │                  │
│           │                      │  • Updates on init | inc_count         │                  │
│           │                      │  • Eliminates 11:1 mux (timing fix!)   │                  │
│           │                      └────────┬───────────────┬────────────────┘                  │
│           │                               │ 128           │                                   │
│           │                               │            ┌──▼────────────────────────────┐      │
│           │                               │            │ Round_Key_Update.v            │      │
│           │                               │            │ (On-the-fly expansion)        │      │
│           │                               │            │                               │      │
│           │                               │            │  ┌──────────────────────┐     │      │
│           │                               │            │  │  function_g          │     │      │
│           │                               │            │  │  • RotWord           │     │      │
│           │                               │            │  │  • 4× S-boxes [7:0]  │     │      │
│           │                               │            │  │  • Rcon XOR          │     │      │
│           │                               │            │  └──────────┬───────────┘     │      │
│           │                               │            │       ┌─────▼─────┐           │      │
│           │ ┌─────────────────────────┐   │            │       │ XOR tree  │           │      │
│           └─►     Initial XOR        │   │            │       │ (w4-w7)   │           │      │
│           init│  (Round 0 AddRoundKey) │   │            │       └─────┬─────┘           │      │
│             └──────────┬──────────────┘   │            │             │ 128             │      │
│                        │ 128              │            │   next_round_key (key_r[N+1]) │      │
│           ┌────────────▼──────────────┐   │            └──────────┬────────────────────┘      │
│           │  Round Register           │   │                       │                           │
│           │  Reg_round_out [127:0]    │   │                       │ Updates when              │
│           │  (State array)            │   │                       │ inc_count=1               │
│           └────────┬──────────────────┘   │◄──────────────────────┘                           │
│                    │ 128                  │                                                   │
│                    │                      │                                                   │
│     ┌──────────────▼──────────────────────▼──────────┐                                        │
│     │              Round Processing Loop             │                                        │
│     │           (States S2, S3, S4, S5)              │                                        │
│     │                                                │                                        │
│     │  ┌─────────────────────────────────────────┐   │                                        │
│     │  │   State S2: SubBytes                    │   │     Counter: 0 → 1 → 2 → ... → 10     │
│     │  │   ┌──────────────────────────────────┐  │   │     Round#:  R0  R1  R2       R9      │
│     │  │   │  Sub_Bytes.v                     │  │   │                                        │
│     │  │   │  • 16× S-boxes in parallel       │  │   │                                        │
│     │  │   │  • Each S-box: 8-bit → 8-bit     │  │   │                                        │
│     │  │   │  • Lookup table (LUT-based)      │  │   │                                        │
│     │  │   │    Input:  round_out [127:0]     │  │   │                                        │
│     │  │   │    Output: sub_out   [127:0]     │  │   │                                        │
│     │  │   └──────────────┬───────────────────┘  │   │                                        │
│     │  └──────────────────┼──────────────────────┘   │                                        │
│     │                     │ 128                      │                                        │
│     │  ┌──────────────────▼──────────────────────┐   │                                        │
│     │  │   State S3: ShiftRows                   │   │                                        │
│     │  │   ┌──────────────────────────────────┐  │   │                                        │
│     │  │   │  shift_rows.v                    │  │   │                                        │
│     │  │   │  • Row 0: No shift               │  │   │                                        │
│     │  │   │  • Row 1: Left shift 1 byte      │  │   │                                        │
│     │  │   │  • Row 2: Left shift 2 bytes     │  │   │                                        │
│     │  │   │  • Row 3: Left shift 3 bytes     │  │   │                                        │
│     │  │   │    Input:  sub_out  [127:0]      │  │   │                                        │
│     │  │   │    Output: row_out  [127:0]      │  │   │                                        │
│     │  │   └──────────────┬───────────────────┘  │   │                                        │
│     │  └──────────────────┼──────────────────────┘   │                                        │
│     │                     │ 128                      │                                        │
│     │  ┌──────────────────▼──────────────────────┐   │                                        │
│     │  │   State S4: MixColumns                  │   │                                        │
│     │  │   ┌──────────────────────────────────┐  │   │                                        │
│     │  │   │  mix_cols.v                      │  │   │                                        │
│     │  │   │  • Galois Field multiplication   │  │   │                                        │
│     │  │   │  • 4 columns in parallel         │  │   │                                        │
│     │  │   │  • Skipped on final round        │  │   │                                        │
│     │  │   │    (count == 10)                 │  │   │                                        │
│     │  │   │    Input:  row_out  [127:0]      │  │   │                                        │
│     │  │   │    Output: col_out  [127:0]      │  │   │                                        │
│     │  │   └──────────────┬───────────────────┘  │   │                                        │
│     │  └──────────────────┼──────────────────────┘   │                                        │
│     │                     │ 128                      │                                        │
│     │  ┌──────────────────▼──────────────────────┐   │                                        │
│     │  │   State S5: AddRoundKey                 │   │                                        │
│     │  │   ┌──────────────────────────────────┐  │   │                                        │
│     │  │   │  XOR with current_round_key      │  │   │                                        │
│     │  │   │    col_out [127:0]               │  │   │                                        │
│     │  │   │      ⊕                           │  │   │                                        │
│     │  │   │    current_round_key [127:0]     │  │   │                                        │
│     │  │   │      ↓                           │  │   │                                        │
│     │  │   │    round_in [127:0]              │  │   │                                        │
│     │  │   │                                  │  │   │                                        │
│     │  │   │  if count < 10:                  │  │   │                                        │
│     │  │   │    inc_count (triggers key       │  │   │                                        │
│     │  │   │    update for next round)        │  │   │                                        │
│     │  │   │    Loop to S2                    │  │   │                                        │
│     │  │   │  else:                           │  │   │                                        │
│     │  │   │    Final round complete          │  │   │                                        │
│     │  │   │    done = 1                      │  │   │                                        │
│     │  │   └──────────────┬───────────────────┘  │   │                                        │
│     │  └──────────────────┼──────────────────────┘   │                                        │
│     └─────────────────────┼──────────────────────────┘                                        │
│                           │ 128                                                               │
│              ┌────────────▼──────────────┐                                                    │
│              │  Final AddRoundKey        │                                                    │
│              │  (After round 10)         │                                                    │
│              │  row_out ⊕ key_r[10]      │                                                    │
│              └────────────┬──────────────┘                                                    │
│                           │ 128                                                               │
│              ┌────────────▼──────────────┐                                                    │
│              │  Output Register          │                                                    │
│              │  Reg_Dout [127:0]         │                                                    │
│              │  (Final Ciphertext)       │                                                    │
│              └────────────┬──────────────┘                                                    │
│                           │                                                                   │
│                           │ Automatically triggers SPI transmission                           │
│                           ▼                                                                   │
│              ┌─────────────────────────────────────────┐                                      │
│              │    8-Lane Parallel SPI Controller      │                                      │
│              │    • Transmits LSB first                │                                      │
│              │    • 8 bits per clock pulse             │                                      │
│              │    • 16 pulses for 128 bits             │                                      │
│              └──────────────┬──────────────────────────┘                                      │
│                             │                                                                 │
│                             ▼ [7:0]                                                           │
│                      aes_spi_data, aes_spi_clk, aes_spi_cs_n                                 │
│                                                                                               │
│  Timing @ 100 MHz (10 ns period):                                                            │
│  • Round 0 (Init + SubBytes + ShiftRows + MixColumns): 5 cycles                              │
│  • Rounds 1-9 (9× loops):                              36 cycles (4 cycles each)             │
│  • Round 10 (Final, no MixColumns):                    4 cycles                              │
│  • SPI Transmission:                                   16 cycles                             │
│  • TOTAL:                                              ~61 cycles = 610 ns                   │
└───────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Control Unit FSM (ControlUnit_Encryption.v)

```
┌─────────────────────────────────────────────────────────────────────┐
│                    AES Encryption FSM States                        │
│                                                                     │
│                          ┌─────────┐                                │
│                          │   S0:   │                                │
│                          │  IDLE   │                                │
│                          └────┬────┘                                │
│                               │ encrypt=1                           │
│                          ┌────▼────┐                                │
│                          │   S1:   │                                │
│                          │  INIT   │                                │
│                          │  • init=1                                │
│                          │  • isRound0=1                            │
│                          │  • en_round_out=1                        │
│                          │  • inc_count (0→1)                       │
│                          │  • Reg_round_key←key                     │
│                          └────┬────┘                                │
│                               │                                     │
│               ┌───────────────┴───────────────┐                     │
│               │   Round Processing Loop       │                     │
│               │   (Repeats 10 times)          │                     │
│               │                               │                     │
│          ┌────▼────┐    ┌────────┐    ┌────────┐    ┌────────┐    │
│          │   S2:   │───▶│   S3:  │───▶│   S4:  │───▶│   S5:  │    │
│          │ SubBytes│    │ShiftRow│    │MixCols │    │AddRKey │    │
│          └─────────┘    └────────┘    └────────┘    └───┬────┘    │
│               │                                          │         │
│               │◄─────────────────────────────────────────┘         │
│               │             if count < 10:                         │
│               │             • inc_count (N→N+1)                    │
│               │             • en_round_out=1                       │
│               │             • Loop to S2                           │
│               │                                                    │
│          ┌────▼────┐                                               │
│          │   S6:   │      if count == 10:                          │
│          │  DONE   │      • en_Dout=1                              │
│          │  done=1 │      • done=1                                 │
│          └─────────┘      • Go to S6                               │
│                                                                     │
│  Control Signals:                                                  │
│  • init          - Initialize counters and registers               │
│  • isRound0      - First round flag (XOR with plaintext)           │
│  • en_round_out  - Enable round register                           │
│  • inc_count     - Increment round counter (also updates round key)│
│  • en_reg_sub_out- Enable SubBytes output register                 │
│  • en_reg_row_out- Enable ShiftRows output register                │
│  • en_reg_col_out- Enable MixColumns output register               │
│  • en_Dout       - Enable final output register                    │
│  • done          - Encryption complete flag (triggers SPI)         │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 8-Lane Parallel SPI Transmission

```
┌─────────────────────────────────────────────────────────────────────────────┐
│               8-Lane Parallel SPI Controller (in pcpi_aes.v)                │
│                                                                             │
│  Triggered automatically when: aes_done = 1                                 │
│                                                                             │
│  ┌─────────────────────┐                                                    │
│  │  Ciphertext Buffer  │                                                    │
│  │  RESULT [127:0]     │                                                    │
│  │  ┌───┬───┬───┬───┐  │                                                    │
│  │  │[15│[14│...│ [0│  │  16 bytes (Little-Endian)                          │
│  │  │] │] │   │]  │  │  Transmitted LSB first                             │
│  │  └─┬─┴─┬─┴───┴─┬─┘  │                                                    │
│  └────┼───┼───────┼────┘                                                    │
│       │   │       │                                                         │
│  ┌────▼───▼───────▼────────────────────────────────────────┐               │
│  │  Byte Counter: spi_byte_index [3:0]                     │               │
│  │  0 → 1 → 2 → ... → 15                                   │               │
│  └────────────┬─────────────────────────────────────────────┘               │
│               │                                                             │
│  ┌────────────▼─────────────────────────────────────────────┐              │
│  │  SPI State Machine                                       │              │
│  │                                                          │              │
│  │  IDLE ──aes_done──▶ TRANSMIT ──(16 bytes)──▶ DONE       │              │
│  │                          │                      │        │              │
│  │                          │                      │        │              │
│  │  Each cycle:             │                      └────────┘              │
│  │  1. aes_spi_clk = 1      │      (pulse for 1 cycle)                     │
│  │  2. aes_spi_data[7:0] = RESULT[(index*8)+:8]                            │
│  │  3. index++              │                                               │
│  └──────────────────────────┴──────────────────────────────┘               │
│                             │                                               │
│  ┌──────────────────────────▼──────────────────────────────┐               │
│  │              Output Signals                             │               │
│  │  ┌──────────────────────────────────────────────────┐   │               │
│  │  │  aes_spi_cs_n     [Active Low]                   │   │               │
│  │  │    ‾‾\_______________________________/‾‾          │   │               │
│  │  │                                                   │   │               │
│  │  │  aes_spi_clk      [Pulse per byte]               │   │               │
│  │  │      _   _   _   _       _   _   _               │   │               │
│  │  │  ___| |_| |_| |_| |_..._| |_| |_| |___           │   │               │
│  │  │     B0  B1  B2  B3      B13 B14 B15              │   │               │
│  │  │                                                   │   │               │
│  │  │  aes_spi_data[7:0]  [8 bits per clock]           │   │               │
│  │  │     ┌──┬──┬──┬──┬─   ─┬──┬──┬──┐                │   │               │
│  │  │  ───┤D0│D1│D2│D3│ ... │DC│DD│DE│───             │   │               │
│  │  │     └──┴──┴──┴──┴─   ─┴──┴──┴──┘                │   │               │
│  │  │                                                   │   │               │
│  │  │  aes_spi_active   [Status indicator]             │   │               │
│  │  │    __/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\__          │   │               │
│  │  └──────────────────────────────────────────────────┘   │               │
│  └───────────────────────────────────────────────────────┘               │
│                                                                             │
│  Byte Transmission Order (Little-Endian):                                  │
│  ┌─────┬──────────────────────────────────────────────────────┐            │
│  │ Byte│ Content                    │ Clock Pulse │ Time (ns) │            │
│  ├─────┼──────────────────────────────────────────────────────┤            │
│  │  0  │ Ciphertext[7:0]   (LSB)    │     1       │    10     │            │
│  │  1  │ Ciphertext[15:8]           │     2       │    20     │            │
│  │  2  │ Ciphertext[23:16]          │     3       │    30     │            │
│  │  3  │ Ciphertext[31:24]          │     4       │    40     │            │
│  │  4  │ Ciphertext[39:32]          │     5       │    50     │            │
│  │  ... │        ...                 │    ...      │   ...     │            │
│  │  15 │ Ciphertext[127:120] (MSB)  │    16       │   160     │            │
│  └─────┴──────────────────────────────────────────────────────┘            │
│                                                                             │
│  Performance:                                                               │
│  • Traditional Serial SPI: 128 clock cycles (1 bit per cycle)              │
│  • 8-Lane Parallel SPI:     16 clock cycles (8 bits per cycle)             │
│  • Speed Improvement:        8× faster!                                    │
│  • Total time @ 100 MHz:    160 ns for 128-bit transmission                │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Custom AES Instructions

```
┌──────────────────────────────────────────────────────────────────────────┐
│                     Custom Instruction Encoding                          │
│                     Opcode: 0x0B (custom-0)                              │
│                     funct3: 0x0                                          │
│                                                                          │
│   31        25 24    20 19    15 14  12 11      7 6      0              │
│  ┌───────────┬────────┬─────────┬──────┬─────────┬────────┐             │
│  │  funct7   │   rs2  │   rs1   │funct3│   rd    │ opcode │             │
│  └───────────┴────────┴─────────┴──────┴─────────┴────────┘             │
│                                                                          │
│  Instructions:                                                           │
│  ┌──────────────────┬─────────┬──────────────────────────────────────┐  │
│  │ Instruction      │ funct7  │ Description                          │  │
│  ├──────────────────┼─────────┼──────────────────────────────────────┤  │
│  │ AES_LOAD_PT      │ 0100000 │ Load plaintext word                  │  │
│  │                  │ (0x20)  │ • rs1[1:0] = word index (0-3)        │  │
│  │                  │         │ • rs2 = 32-bit data                  │  │
│  │                  │         │ • plaintext[rs1] ← rs2               │  │
│  ├──────────────────┼─────────┼──────────────────────────────────────┤  │
│  │ AES_LOAD_KEY     │ 0100001 │ Load key word                        │  │
│  │                  │ (0x21)  │ • rs1[1:0] = word index (0-3)        │  │
│  │                  │         │ • rs2 = 32-bit data                  │  │
│  │                  │         │ • key[rs1] ← rs2                     │  │
│  ├──────────────────┼─────────┼──────────────────────────────────────┤  │
│  │ AES_START        │ 0100010 │ Start encryption                     │  │
│  │                  │ (0x22)  │ • No operands                        │  │
│  │                  │         │ • Triggers AES FSM                   │  │
│  │                  │         │ • ~45 cycles to complete             │  │
│  ├──────────────────┼─────────┼──────────────────────────────────────┤  │
│  │ AES_READ         │ 0100011 │ Read ciphertext word                 │  │
│  │                  │ (0x23)  │ • rs1[1:0] = word index (0-3)        │  │
│  │                  │         │ • rd ← ciphertext[rs1]               │  │
│  ├──────────────────┼─────────┼──────────────────────────────────────┤  │
│  │ AES_STATUS       │ 0100100 │ Check encryption status              │  │
│  │                  │ (0x24)  │ • rd ← done flag (1=complete)        │  │
│  └──────────────────┴─────────┴──────────────────────────────────────┘  │
│                                                                          │
│  Example Assembly (from firmware/custom_ops.S):                         │
│  ```assembly                                                             │
│  # Load plaintext (4 words)                                              │
│  li   x1, 0xCCDDEEFF      # PT[31:0]                                     │
│  li   x2, 0              # Index 0                                       │
│  AES_LOAD_PT x2, x1                                                      │
│                                                                          │
│  # Load key (4 words)                                                    │
│  li   x3, 0x0C0D0E0F      # KEY[31:0]                                    │
│  li   x2, 0              # Index 0                                       │
│  AES_LOAD_KEY x2, x3                                                     │
│                                                                          │
│  # Start encryption                                                      │
│  AES_START                                                               │
│                                                                          │
│  # Poll for completion                                                   │
│  poll_loop:                                                              │
│    AES_STATUS x4                                                         │
│    beqz x4, poll_loop                                                    │
│                                                                          │
│  # Read ciphertext                                                       │
│  li   x2, 0              # Index 0                                       │
│  AES_READ x5, x2          # Result in x5                                 │
│  ```                                                                     │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Bit Widths Summary

```
┌──────────────────────────────────────────────────────────────────┐
│                    Signal Bit Widths                             │
├────────────────────────────┬─────────────────────────────────────┤
│ Component                  │ Width       │ Description          │
├────────────────────────────┼─────────────────────────────────────┤
│ CPU Registers (x0-x31)     │ 32 bits     │ General purpose regs │
│ PCPI Data Bus              │ 32 bits     │ pcpi_rs1, pcpi_rs2   │
│ AES Plaintext Register     │ 128 bits    │ 4×32-bit words       │
│ AES Key Register           │ 128 bits    │ 4×32-bit words       │
│ AES Round Key Register     │ 128 bits    │ Current round key    │
│ AES State Array            │ 128 bits    │ 16 bytes (4×4 matrix)│
│ S-Box Input/Output         │ 8 bits      │ 256-entry LUT        │
│ Round Counter              │ 4 bits      │ Counts 0-10          │
│ AES Ciphertext Output      │ 128 bits    │ Final result         │
│ SPI Data Lanes             │ 8 bits      │ Parallel output      │
│ SPI Byte Counter           │ 4 bits      │ Counts 0-15          │
│ SPI Control Signals        │ 1 bit each  │ clk, cs_n, active    │
└────────────────────────────┴─────────────────────────────────────┘
```

---

## Performance Metrics

```
┌──────────────────────────────────────────────────────────────────────┐
│                        Performance @ 100 MHz                         │
├──────────────────────────────────────────────────────────────────────┤
│ Operation                    │ Cycles │ Time (ns) │ Throughput       │
├──────────────────────────────┼────────┼───────────┼──────────────────┤
│ AES-128 Encryption           │   ~45  │    450    │ 284 Mbps         │
│ 8-Lane SPI Transmission      │    16  │    160    │ 800 Mbps         │
│ Total (AES + SPI)            │   ~61  │    610    │ 210 Mbps         │
├──────────────────────────────┼────────┼───────────┼──────────────────┤
│ CPU Instruction Load PT/Key  │     2  │     20    │ Per word         │
│ CPU Instruction AES_START    │     1  │     10    │ Trigger only     │
│ CPU Poll AES_STATUS          │     2  │     20    │ Per poll         │
│ CPU Read Ciphertext          │     2  │     20    │ Per word         │
├──────────────────────────────┼────────┼───────────┼──────────────────┤
│ Software Overhead (typical)  │   ~30  │    300    │ 8 loads + 4 reads│
│ Total with SW                │   ~91  │    910    │ 141 Mbps         │
└──────────────────────────────┴────────┴───────────┴──────────────────┘

Comparison to Other Implementations:
• Software AES (on PicoRV32): ~10,000 cycles = 100 μs → 1.28 Mbps
• Hardware AES (this design):      ~61 cycles = 610 ns → 210 Mbps
• Speed-up:                         164× faster than software

Note: SPI transmission happens automatically in parallel with CPU continuing
      execution, so effective throughput can be higher in pipelined operation.
```

---

## Resource Utilization (Estimated)

```
┌─────────────────────────────────────────────────────────────────┐
│            FPGA Resource Usage (Xilinx 7-Series)                │
├─────────────────────────────────────────────────────────────────┤
│ Component                  │  LUTs  │  FFs  │  BRAM  │  DSP    │
├────────────────────────────┼────────┼───────┼────────┼─────────┤
│ PicoRV32 CPU (base)        │   917  │  583  │    0   │    0    │
│ AES Encryption Core        │  ~2800 │ ~700  │    0   │    0    │
│   • S-boxes (16×256×8)     │  ~1600 │    0  │    0   │    0    │
│   • ShiftRows              │   ~50  │    0  │    0   │    0    │
│   • MixColumns             │  ~600  │    0  │    0   │    0    │
│   • Round_Key_Update       │  ~110  │    0  │    0   │    0    │
│   • Registers & Control    │  ~440  │ ~700  │    0   │    0    │
│ 8-Lane SPI Controller      │  ~100  │  ~50  │    0   │    0    │
├────────────────────────────┼────────┼───────┼────────┼─────────┤
│ TOTAL (CPU + AES + SPI)    │ ~3817  │ ~1333 │    0   │    0    │
├────────────────────────────┼────────┼───────┼────────┼─────────┤
│ Target: Artix-7 XC7A35T    │ 20800  │ 41600 │   50   │   90    │
│ Utilization                │  18%   │   3%  │   0%   │   0%    │
└────────────────────────────┴────────┴───────┴────────┴─────────┘

Note: After timing fix (on-the-fly key expansion):
  • Removed 1100 LUTs (old Key_expansion combinational logic)
  • Added 128 FFs (Reg_round_key register)
  • Net result: Smaller and faster design
```

---

## Test Vectors (FIPS-197 Appendix B)

```
┌─────────────────────────────────────────────────────────────────┐
│                 AES-128 Test Vector                             │
├─────────────────────────────────────────────────────────────────┤
│ Plaintext:   0x00112233445566778899aabbccddeeff                 │
│              └─────────┬─────────┬─────────┬─────────┘          │
│                   PT[3]    PT[2]    PT[1]    PT[0]              │
│                                                                 │
│ Key:         0x000102030405060708090a0b0c0d0e0f                 │
│              └─────────┬─────────┬─────────┬─────────┘          │
│                   K[3]     K[2]     K[1]     K[0]               │
│                                                                 │
│ Ciphertext:  0x69c4e0d86a7b0430d8cdb78070b4c55a                 │
│              └─────────┬─────────┬─────────┬─────────┘          │
│                   CT[3]    CT[2]    CT[1]    CT[0]              │
│                                                                 │
│ SPI Output (Little-Endian, LSB first):                          │
│   Byte  0: 0x5a  (CT[0][7:0])     ─┐                            │
│   Byte  1: 0xc5  (CT[0][15:8])     │ Word 0                     │
│   Byte  2: 0xb4  (CT[0][23:16])    │                            │
│   Byte  3: 0x70  (CT[0][31:24])   ─┘                            │
│   Byte  4: 0x80  (CT[1][7:0])     ─┐                            │
│   Byte  5: 0xb7  (CT[1][15:8])     │ Word 1                     │
│   Byte  6: 0xcd  (CT[1][23:16])    │                            │
│   Byte  7: 0xd8  (CT[1][31:24])   ─┘                            │
│   Byte  8: 0x30  (CT[2][7:0])     ─┐                            │
│   Byte  9: 0x04  (CT[2][15:8])     │ Word 2                     │
│   Byte 10: 0x7b  (CT[2][23:16])    │                            │
│   Byte 11: 0x6a  (CT[2][31:24])   ─┘                            │
│   Byte 12: 0xd8  (CT[3][7:0])     ─┐                            │
│   Byte 13: 0xe0  (CT[3][15:8])     │ Word 3                     │
│   Byte 14: 0xc4  (CT[3][23:16])    │                            │
│   Byte 15: 0x69  (CT[3][31:24])   ─┘                            │
└─────────────────────────────────────────────────────────────────┘
```

---

## Key Features

1. **On-the-Fly Round Key Expansion** (Timing Optimized)
   - Computes round keys incrementally (1 per cycle)
   - Eliminates 26.5 ns critical path → 3.5 ns
   - 21% smaller (removed 1100 LUTs)
   - Still passes all FIPS-197 test vectors

2. **8-Lane Parallel SPI Output**
   - 8× faster than serial SPI (16 cycles vs 128 cycles)
   - Transmits 128 bits in just 160 ns @ 100 MHz
   - Automatic triggering on encryption completion
   - Little-endian byte order (LSB first)

3. **PCPI Integration**
   - Seamless integration with PicoRV32
   - Custom instructions via opcode 0x0B
   - Zero-overhead co-processor interface
   - Software-controlled encryption flow

4. **Low Latency**
   - Complete AES-128 encryption in ~450 ns
   - Total encryption + transmission in ~610 ns
   - 164× faster than software implementation

---

## Documentation References

- **Timing Fix Details:** [`docs/TIMING_FIX_README.md`](docs/TIMING_FIX_README.md)
- **Data Flow & SHA-256 Integration:** [`docs/DATA_FLOW_AND_CHECKSUM_INTEGRATION.md`](docs/DATA_FLOW_AND_CHECKSUM_INTEGRATION.md)
- **Build Instructions:** [`CLAUDE.md`](CLAUDE.md)
- **Testbench:** [`tb_picorv32_aes_coprocessor.v`](tb_picorv32_aes_coprocessor.v)

---

## Quick Start

```bash
# Synthesize for FPGA (Vivado)
synth_design -top aes_soc_top -part xc7a35tcpg236-1

# Run simulation
iverilog -g2012 -o sim.vvp picorv32.v Aes-Code/*.v tb_picorv32_aes_coprocessor.v
vvp sim.vvp

# Expected output:
#   OVERALL TEST RESULT: *** PASS ***
#   [OK] AES-128 encryption correct (FIPS-197)
#   [OK] 8-Lane SPI successful (16 bytes in 16 clocks)
```

---

**Status:** ✅ Timing closure achieved @ 100 MHz
**Version:** 2.0 (with on-the-fly key expansion optimization)
**Date:** February 2026
