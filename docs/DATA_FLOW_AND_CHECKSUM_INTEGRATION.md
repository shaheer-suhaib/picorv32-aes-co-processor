# PicoRV32 AES Co-Processor - Complete Data Flow & SHA-256 Checksum Integration Guide

## Current System Data Flow (Without Checksum)

### Overview Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                         PicoRV32 CPU Core                           │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Instruction Execution Pipeline                              │   │
│  │  • Fetch → Decode → Execute → Memory → Writeback            │   │
│  └────────────────┬─────────────────────┬───────────────────────┘   │
│                   │                     │                           │
│         ┌─────────▼─────────┐  ┌────────▼────────┐                 │
│         │  Register File    │  │  PCPI Interface │                 │
│         │  x0-x31 (32-bit)  │  │  (Co-processor) │                 │
│         └───────────────────┘  └────────┬────────┘                 │
└────────────────────────────────────────┼──────────────────────────┘
                                         │
                    ┌────────────────────┼────────────────────┐
                    │                    │                    │
            ┌───────▼────────┐  ┌────────▼─────────┐  ┌──────▼──────┐
            │   MUL/DIV      │  │  AES Encryption  │  │ AES Decrypt │
            │  (if enabled)  │  │  Co-processor    │  │ (if enabled)│
            └────────────────┘  └────────┬─────────┘  └─────────────┘
                                         │
                                         │
                    ┌────────────────────▼────────────────────┐
                    │      AES Co-Processor (pcpi_aes)        │
                    │  ┌────────────────────────────────────┐ │
                    │  │  State Machine (FSM)               │ │
                    │  │  • IDLE → LOAD_PT → LOAD_KEY      │ │
                    │  │  • ENCRYPT → DONE                  │ │
                    │  └────────┬───────────────────────────┘ │
                    │           │                             │
                    │  ┌────────▼───────────────────────────┐ │
                    │  │  AES-128 Encryption Engine         │ │
                    │  │  ┌──────────────────────────────┐  │ │
                    │  │  │  Datapath_Encryption.v       │  │ │
                    │  │  │  • Reg_plain_text (128 bit)  │  │ │
                    │  │  │  • Reg_key (128 bit)         │  │ │
                    │  │  │  • Reg_round_key (NEW!)      │  │ │
                    │  │  │  • Sub_Bytes → shift_rows    │  │ │
                    │  │  │  • mix_cols → Round_Key_XOR  │  │ │
                    │  │  │  • 10 rounds + final round   │  │ │
                    │  │  └──────────┬───────────────────┘  │ │
                    │  │             │                       │ │
                    │  │  ┌──────────▼───────────────────┐  │ │
                    │  │  │  Reg_Dout (128-bit result)   │  │ │
                    │  │  └──────────┬───────────────────┘  │ │
                    │  └─────────────┼──────────────────────┘ │
                    │                │                        │
                    │  ┌─────────────▼──────────────────────┐ │
                    │  │  8-Lane Parallel SPI Controller    │ │
                    │  │  • Triggered by aes_done           │ │
                    │  │  • Transmits 16 bytes (128 bits)   │ │
                    │  │  • 8 bits per clock pulse          │ │
                    │  │  • Little-endian (LSB first)       │ │
                    │  └────────────────┬───────────────────┘ │
                    └───────────────────┼─────────────────────┘
                                        │
                    ┌───────────────────▼───────────────────┐
                    │  SPI Output Signals (8-lane parallel) │
                    │  • aes_spi_data[7:0]  - 8 data lanes  │
                    │  • aes_spi_clk        - Clock strobe  │
                    │  • aes_spi_cs_n       - Chip select   │
                    │  • aes_spi_active     - Transfer flag │
                    └───────────────────────────────────────┘
```

---

## Detailed Step-by-Step Flow

### Phase 1: Initialization (CPU Software)

```
Cycle 0-5: Load Constants
├─ x1  = 1              (index constant)
├─ x2  = 2              (index constant)
├─ x3  = 3              (index constant)
├─ x4  = 0x200          (key base address)
├─ x6  = 0x100          (plaintext base address)
└─ x12 = 0x300          (result storage address)
```

### Phase 2: Load Plaintext (4 words × 32 bits = 128 bits)

```
┌──────────────────────────────────────────────────────────┐
│ CPU: Load word from memory                               │
│      lw x5, 0(x6)  → x5 = memory[0x100] (PT[31:0])      │
│                                                          │
│ CPU: Execute AES_LOAD_PT custom instruction              │
│      AES_LOAD_PT idx=0, data=x5                         │
│                                                          │
│      ┌──────────────────────────────────────┐           │
│      │ PCPI Interface Signals               │           │
│      │  pcpi_valid = 1                      │           │
│      │  pcpi_insn  = 0x00028073 (example)   │           │
│      │  pcpi_rs1   = 0 (index)              │           │
│      │  pcpi_rs2   = x5 (data)              │           │
│      └────────────┬─────────────────────────┘           │
│                   │                                     │
│      ┌────────────▼─────────────────────────┐           │
│      │ pcpi_aes Module                      │           │
│      │  Decodes instruction                 │           │
│      │  Recognizes: LOAD_PT, idx=0          │           │
│      │  Stores data in internal register:   │           │
│      │    plaintext_reg[31:0] = pcpi_rs2    │           │
│      │                                      │           │
│      │  Returns: pcpi_ready = 1             │           │
│      └──────────────────────────────────────┘           │
└──────────────────────────────────────────────────────────┘

Repeat for PT[63:32], PT[95:64], PT[127:96]
```

### Phase 3: Load Key (4 words × 32 bits = 128 bits)

```
Same flow as Phase 2, but:
  Instruction: AES_LOAD_KEY idx=0..3
  Storage:     key_reg[127:0] in pcpi_aes
```

### Phase 4: Start Encryption

```
┌──────────────────────────────────────────────────────────┐
│ CPU: Execute AES_START                                   │
│      AES_START (no operands)                            │
│                                                          │
│      ┌──────────────────────────────────────┐           │
│      │ pcpi_aes FSM: IDLE → ENCRYPT         │           │
│      │                                      │           │
│      │  Asserts: encrypt_start = 1          │           │
│      └────────────┬─────────────────────────┘           │
│                   │                                     │
│      ┌────────────▼─────────────────────────────────┐   │
│      │ ASMD_Encryption (AES Core)                   │   │
│      │                                              │   │
│      │  Datapath_Encryption.v:                      │   │
│      │  ┌──────────────────────────────────────┐    │   │
│      │  │ State S0: IDLE                       │    │   │
│      │  │  - Wait for encrypt=1                │    │   │
│      │  └────────┬─────────────────────────────┘    │   │
│      │           │ encrypt=1                        │   │
│      │  ┌────────▼─────────────────────────────┐    │   │
│      │  │ State S1: Initialize (Round 0 Load)  │    │   │
│      │  │  - init=1 (reset counter to 0)       │    │   │
│      │  │  - Reg_round_key ← key (original)    │    │   │
│      │  │  - round_in ← PT ⊕ key_r[0]          │    │   │
│      │  │  - inc_count (counter: 0→1)          │    │   │
│      │  │  - Reg_round_key ← key_r[1] (next)   │    │   │
│      │  └────────┬─────────────────────────────┘    │   │
│      │           │                                  │   │
│      │  ┌────────▼─────────────────────────────┐    │   │
│      │  │ States S2-S5: Round Processing       │    │   │
│      │  │  (Repeated 10 times for rounds 0-9)  │    │   │
│      │  │                                      │    │   │
│      │  │  S2: Sub_Bytes                       │    │   │
│      │  │      round_out → sub_out (16 S-boxes)│    │   │
│      │  │                                      │    │   │
│      │  │  S3: shift_rows                      │    │   │
│      │  │      sub_out → row_out               │    │   │
│      │  │                                      │    │   │
│      │  │  S4: mix_cols (skip on final round)  │    │   │
│      │  │      row_out → col_out               │    │   │
│      │  │                                      │    │   │
│      │  │  S5: Add Round Key & Check           │    │   │
│      │  │      if count < 10:                  │    │   │
│      │  │        round_in ← col_out ⊕ key_r[N] │    │   │
│      │  │        inc_count (counter: N→N+1)    │    │   │
│      │  │        Reg_round_key ← key_r[N+1]    │    │   │
│      │  │        loop to S2                    │    │   │
│      │  │      else:                           │    │   │
│      │  │        Dout ← row_out ⊕ key_r[10]    │    │   │
│      │  │        done = 1                      │    │   │
│      │  └──────────────────────────────────────┘    │   │
│      │                                              │   │
│      │  Total: ~45-50 clock cycles for full encrypt│   │
│      └──────────────────┬───────────────────────────┘   │
│                         │ done=1, Dout=ciphertext       │
│      ┌──────────────────▼───────────────────────────┐   │
│      │ pcpi_aes FSM: ENCRYPT → SPI_TRANSMIT        │   │
│      │  - Captures Dout → RESULT[127:0]            │   │
│      │  - Triggers SPI controller                  │   │
│      └─────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
```

### Phase 5: Automatic SPI Transmission (8-Lane Parallel)

```
┌─────────────────────────────────────────────────────────────┐
│ 8-Lane Parallel SPI Controller (Inside pcpi_aes)           │
│                                                             │
│  Triggered automatically when aes_done = 1                  │
│                                                             │
│  Transmits: 128 bits = 16 bytes in LITTLE-ENDIAN order     │
│             (LSB first: RESULT[7:0], RESULT[15:8], ...)    │
│                                                             │
│  Timeline (100 MHz, 10 ns per cycle):                       │
│  ┌────────────────────────────────────────────────────┐    │
│  │ Cycle 0:  aes_spi_cs_n = 0 (assert chip select)   │    │
│  │           aes_spi_active = 1                       │    │
│  │                                                    │    │
│  │ Cycle 1:  aes_spi_clk = 1 (pulse)                 │    │
│  │           aes_spi_data[7:0] = RESULT[7:0]         │    │
│  │           (Byte 0 - LSB)                          │    │
│  │                                                    │    │
│  │ Cycle 2:  aes_spi_clk = 0 → 1                     │    │
│  │           aes_spi_data[7:0] = RESULT[15:8]        │    │
│  │           (Byte 1)                                │    │
│  │                                                    │    │
│  │ ... (continues for bytes 2-14)                     │    │
│  │                                                    │    │
│  │ Cycle 16: aes_spi_clk = 0 → 1                     │    │
│  │           aes_spi_data[7:0] = RESULT[127:120]     │    │
│  │           (Byte 15 - MSB)                         │    │
│  │                                                    │    │
│  │ Cycle 17: aes_spi_cs_n = 1 (deassert)             │    │
│  │           aes_spi_active = 0                       │    │
│  │           Transfer complete!                       │    │
│  └────────────────────────────────────────────────────┘    │
│                                                             │
│  Total time: 17 cycles × 10 ns = 170 ns                    │
│  (8x faster than serial SPI: 128 cycles)                   │
└─────────────────────────────────────────────────────────────┘

Output Pins:
  aes_spi_data[7:0]  → Connect to 8 GPIO pins (e.g., Pmod connector)
  aes_spi_clk        → Clock strobe (receiver samples on rising edge)
  aes_spi_cs_n       → Chip select (active low)
  aes_spi_active     → Status LED / monitoring
```

### Phase 6: CPU Read Back (Optional - via AES_READ)

```
┌──────────────────────────────────────────────────────────┐
│ CPU: Read ciphertext back to registers                   │
│                                                          │
│      AES_READ idx=0 → x8                                │
│      AES_READ idx=1 → x9                                │
│      AES_READ idx=2 → x10                               │
│      AES_READ idx=3 → x11                               │
│                                                          │
│  pcpi_aes returns: RESULT[(idx*32)+31 : idx*32]         │
│                                                          │
│  Store to memory (optional):                             │
│      sw x8,  0(x12)  → memory[0x300] = CT[31:0]         │
│      sw x9,  4(x12)  → memory[0x304] = CT[63:32]        │
│      sw x10, 8(x12)  → memory[0x308] = CT[95:64]        │
│      sw x11,12(x12)  → memory[0x30C] = CT[127:96]       │
└──────────────────────────────────────────────────────────┘
```

---

## SHA-256 Checksum Integration Options

You have **3 main options** for integrating SHA-256:

### Option 1: Checksum of Plaintext (Before Encryption)

**Use Case:** Verify data integrity before encryption

```
┌─────────────────────────────────────────────────────────────┐
│  Flow:  Plaintext → SHA-256 → Hash                          │
│             ↓                                                │
│         Plaintext → AES → Ciphertext                         │
│                             ↓                                │
│         SPI Output: [Ciphertext (16 bytes) | Hash (32 bytes)]│
└─────────────────────────────────────────────────────────────┘

Implementation:
  1. Add SHA-256 co-processor to PCPI interface
  2. Custom instructions: SHA_LOAD, SHA_START, SHA_READ
  3. After loading plaintext, also load to SHA
  4. Start both AES and SHA in parallel
  5. Extend SPI to transmit 48 bytes total
```

### Option 2: Checksum of Ciphertext (After Encryption)

**Use Case:** Verify ciphertext integrity during transmission

```
┌─────────────────────────────────────────────────────────────┐
│  Flow:  Plaintext → AES → Ciphertext → SHA-256 → Hash      │
│                                           ↓                  │
│         SPI Output: [Ciphertext (16 bytes) | Hash (32 bytes)]│
└─────────────────────────────────────────────────────────────┘

Implementation:
  1. Add SHA-256 co-processor to PCPI interface
  2. After AES completes, automatically feed ciphertext to SHA
  3. Wait for SHA completion
  4. Transmit both via SPI (48 bytes total)
```

### Option 3: HMAC (Keyed Hash for Authentication)

**Use Case:** Authenticated encryption (prevents tampering)

```
┌─────────────────────────────────────────────────────────────┐
│  Flow:  Plaintext → AES → Ciphertext                        │
│                             ↓                                │
│         HMAC-SHA256(Key, Ciphertext) → MAC                   │
│                                           ↓                  │
│         SPI Output: [Ciphertext (16 bytes) | MAC (32 bytes)] │
└─────────────────────────────────────────────────────────────┘

Implementation:
  1. Implement HMAC using SHA-256 core
  2. Requires 2 SHA-256 hashes per message
  3. More secure than plain checksum
```

---

## Recommended: Option 2 (Ciphertext Checksum)

This is the most common approach for secure communication.

### Architecture Diagram

```
                    ┌─────────────────────────────────────┐
                    │      PicoRV32 CPU Core              │
                    └──────────────┬──────────────────────┘
                                   │
                           ┌───────┼───────┐
                           │ PCPI Interface │
                           └───┬───────┬────┘
                               │       │
                    ┌──────────▼──┐ ┌─▼────────────┐
                    │  AES Core   │ │  SHA-256 Core│
                    │  (128-bit)  │ │  (512-bit)   │
                    └──────┬──────┘ └──┬───────────┘
                           │           │
                    ┌──────▼───────────▼───────────┐
                    │  Transmission Controller     │
                    │  • Wait for AES done         │
                    │  • Feed ciphertext to SHA    │
                    │  • Wait for SHA done         │
                    │  • Trigger SPI with both     │
                    └──────────┬───────────────────┘
                               │
                    ┌──────────▼───────────────────┐
                    │  Enhanced SPI Controller     │
                    │  • 48 bytes total:           │
                    │    - 16 bytes ciphertext     │
                    │    - 32 bytes SHA-256 hash   │
                    │  • Still 8-lane parallel     │
                    │  • 48 clock pulses           │
                    └──────────────────────────────┘
```

### Modified Data Flow (With SHA-256)

```
Phase 1-4: Same as before (Load PT, Load Key, Encrypt)

Phase 5 (NEW): Compute Checksum
┌─────────────────────────────────────────────────────────────┐
│ AES completes → ciphertext ready in RESULT[127:0]          │
│                                                             │
│ ┌───────────────────────────────────────────────────────┐  │
│ │ Transmission Controller FSM                           │  │
│ │                                                       │  │
│ │ State: AES_DONE                                       │  │
│ │   - Capture ciphertext → temp_buffer[127:0]          │  │
│ │   - Trigger SHA: sha_start = 1                       │  │
│ │   - Provide data: sha_block = {padding, ciphertext}  │  │
│ │   - Wait for sha_ready                               │  │
│ │                                                       │  │
│ │ State: SHA_COMPUTING                                  │  │
│ │   - SHA processes 512-bit block (~64 cycles)         │  │
│ │   - Monitor sha_digest_valid                         │  │
│ │                                                       │  │
│ │ State: SHA_DONE                                       │  │
│ │   - Read hash: sha_digest[255:0]                     │  │
│ │   - Prepare transmission:                            │  │
│ │     transmission_buffer[0:15]  = ciphertext bytes    │  │
│ │     transmission_buffer[16:47] = hash bytes          │  │
│ │   - Trigger SPI: spi_start = 1, spi_length = 48     │  │
│ └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘

Phase 6 (NEW): Extended SPI Transmission
┌─────────────────────────────────────────────────────────────┐
│ 8-Lane Parallel SPI - 48 Bytes                              │
│                                                             │
│ Cycles 1-16:  Transmit ciphertext (16 bytes)               │
│               aes_spi_data = CT[7:0], CT[15:8], ...        │
│                                                             │
│ Cycles 17-48: Transmit SHA-256 hash (32 bytes)             │
│               aes_spi_data = Hash[7:0], Hash[15:8], ...    │
│                                                             │
│ Total time: 48 cycles × 10 ns = 480 ns                     │
│             (Still very fast with 8-lane parallel!)        │
└─────────────────────────────────────────────────────────────┘
```

---

## Implementation Steps

### Step 1: Add SHA-256 to PCPI Interface

**Modify picorv32.v:**

```verilog
// Add parameter
parameter [0:0] ENABLE_SHA256 = 0,

// Add output ports (if needed for standalone SHA use)
output wire       sha_ready,
output wire[255:0] sha_digest,

// Add SHA-256 PCPI signals
wire        pcpi_sha_wait;
wire        pcpi_sha_ready;
wire [31:0] pcpi_sha_rd;

// Instantiate SHA-256 module
generate if (ENABLE_SHA256) begin
    pcpi_sha256 pcpi_sha_inst (
        .clk         (clk),
        .resetn      (resetn),
        .pcpi_valid  (pcpi_valid),
        .pcpi_insn   (pcpi_insn),
        .pcpi_rs1    (pcpi_rs1),
        .pcpi_rs2    (pcpi_rs2),
        .pcpi_wr     (pcpi_sha_wr),
        .pcpi_rd     (pcpi_sha_rd),
        .pcpi_wait   (pcpi_sha_wait),
        .pcpi_ready  (pcpi_sha_ready),
        .sha_digest  (sha_digest),
        .sha_ready   (sha_ready)
    );
end endgenerate

// Update PCPI multiplexing
assign pcpi_int_wait  = |{ENABLE_MUL && pcpi_mul_wait,
                          ENABLE_DIV && pcpi_div_wait,
                          ENABLE_AES && pcpi_aes_wait,
                          ENABLE_SHA256 && pcpi_sha_wait};  // NEW

assign pcpi_int_ready = |{ENABLE_MUL && pcpi_mul_ready,
                          ENABLE_DIV && pcpi_div_ready,
                          ENABLE_AES && pcpi_aes_ready,
                          ENABLE_SHA256 && pcpi_sha_ready}; // NEW
```

### Step 2: Create SHA-256 PCPI Wrapper

**New file: `pcpi_sha256.v`**

```verilog
module pcpi_sha256 (
    input clk, resetn,

    // PCPI Interface
    input        pcpi_valid,
    input [31:0] pcpi_insn,
    input [31:0] pcpi_rs1,
    input [31:0] pcpi_rs2,
    output reg       pcpi_wr,
    output reg[31:0] pcpi_rd,
    output reg       pcpi_wait,
    output reg       pcpi_ready,

    // SHA-256 outputs
    output[255:0] sha_digest,
    output        sha_ready
);
    // Custom instruction opcodes (same 0x0B, different funct7)
    localparam SHA_LOAD_BLOCK  = 7'b0100101; // Load 512-bit block word-by-word
    localparam SHA_START       = 7'b0100110; // Start hashing
    localparam SHA_READ_DIGEST = 7'b0100111; // Read 32-bit digest word

    // Instantiate sha256 core (from Sha-Code/sha.v)
    reg [7:0]  sha_addr;
    reg [31:0] sha_wdata;
    reg        sha_cs, sha_we;
    wire[31:0] sha_rdata;

    sha256 sha_core (
        .clk        (clk),
        .reset_n    (resetn),
        .cs         (sha_cs),
        .we         (sha_we),
        .address    (sha_addr),
        .write_data (sha_wdata),
        .read_data  (sha_rdata)
    );

    // Decode and execute SHA instructions
    // (Implementation details: load block, start hash, read digest)
    // ...
endmodule
```

### Step 3: Create Transmission Controller

**New file: `aes_sha_transmission_controller.v`**

```verilog
module aes_sha_transmission_controller (
    input wire clk,
    input wire resetn,

    // From AES
    input wire        aes_done,
    input wire[127:0] aes_ciphertext,

    // From SHA-256
    input wire        sha_digest_valid,
    input wire[255:0] sha_digest,

    // To SHA-256
    output reg        sha_start,
    output reg[511:0] sha_block,  // Padded ciphertext

    // To SPI
    output reg        spi_start,
    output reg[5:0]   spi_byte_count,  // 48 bytes
    output reg[383:0] spi_data_buffer  // 48 bytes = 384 bits
);

    // FSM states
    localparam IDLE        = 3'd0;
    localparam SHA_TRIGGER = 3'd1;
    localparam SHA_WAIT    = 3'd2;
    localparam PREPARE_SPI = 3'd3;
    localparam SPI_TRANSMIT= 3'd4;

    reg [2:0] state;

    always @(posedge clk) begin
        if (!resetn) begin
            state <= IDLE;
            sha_start <= 0;
            spi_start <= 0;
        end else begin
            case (state)
                IDLE: begin
                    if (aes_done) begin
                        // Prepare SHA input: pad 128-bit ciphertext to 512 bits
                        sha_block <= {aes_ciphertext, 128'd0, 256'd128}; // Simplified padding
                        sha_start <= 1;
                        state <= SHA_TRIGGER;
                    end
                end

                SHA_TRIGGER: begin
                    sha_start <= 0;
                    state <= SHA_WAIT;
                end

                SHA_WAIT: begin
                    if (sha_digest_valid) begin
                        state <= PREPARE_SPI;
                    end
                end

                PREPARE_SPI: begin
                    // Concatenate ciphertext + hash
                    spi_data_buffer <= {sha_digest, aes_ciphertext}; // 256 + 128 = 384 bits
                    spi_byte_count <= 48; // 48 bytes
                    spi_start <= 1;
                    state <= SPI_TRANSMIT;
                end

                SPI_TRANSMIT: begin
                    spi_start <= 0;
                    // Wait for SPI completion, then return to IDLE
                    state <= IDLE;
                end
            endcase
        end
    end
endmodule
```

### Step 4: Modify SPI Controller for 48 Bytes

**In `pcpi_aes.v`, modify the SPI controller:**

```verilog
// Change byte counter from 4 bits (0-15) to 6 bits (0-47)
reg [5:0] spi_byte_index;  // Was: reg [3:0]

// Update loop condition
if (spi_byte_index < spi_byte_count) begin  // Dynamic count
    aes_spi_data <= transmission_buffer[(spi_byte_index*8) +: 8];
    spi_byte_index <= spi_byte_index + 1;
end
```

---

## Custom Instructions for SHA-256

Add these to `firmware/custom_ops.S`:

```assembly
# SHA-256 Custom Instructions
.macro SHA_LOAD_BLOCK idx, data
    .insn r 0x0B, 0x0, 0x25, x0, \idx, \data
.endm

.macro SHA_START
    .insn r 0x0B, 0x0, 0x26, x0, x0, x0
.endm

.macro SHA_READ_DIGEST idx, rd
    .insn r 0x0B, 0x0, 0x27, \rd, \idx, x0
.endm
```

---

## Example Software Flow

```c
// Pseudocode in C (or assembly)

// 1. Load plaintext to AES
for (int i = 0; i < 4; i++) {
    AES_LOAD_PT(i, plaintext[i]);
}

// 2. Load key to AES
for (int i = 0; i < 4; i++) {
    AES_LOAD_KEY(i, key[i]);
}

// 3. Start AES encryption
AES_START();

// 4. Wait for completion (polling)
while (!AES_STATUS());

// 5. Hardware automatically:
//    a) Computes SHA-256 of ciphertext
//    b) Transmits 48 bytes via SPI:
//       [16 bytes CT | 32 bytes Hash]

// 6. (Optional) Read back for verification
uint32_t ciphertext[4];
for (int i = 0; i < 4; i++) {
    ciphertext[i] = AES_READ(i);
}

uint32_t hash[8];
for (int i = 0; i < 8; i++) {
    hash[i] = SHA_READ_DIGEST(i);
}
```

---

## Timing & Performance

### Without SHA-256 (Current)
- AES encryption: ~45-50 cycles
- SPI transmission: 16 cycles (16 bytes)
- **Total: ~65 cycles = 650 ns @ 100 MHz**

### With SHA-256 Checksum
- AES encryption: ~45-50 cycles
- SHA-256 hashing: ~64 cycles (one 512-bit block)
- SPI transmission: 48 cycles (48 bytes)
- **Total: ~160 cycles = 1.6 μs @ 100 MHz**

**Still very fast!** Only 2.5x slower for added security.

---

## File Structure After Integration

```
Aes-Code/
├── ASMD_Encryption.v           (unchanged)
├── ControlUnit_Enryption.v     (unchanged)
├── Datapath_Encryption.v       (unchanged - has timing fix)
├── Round_Key_Update.v          (NEW - timing fix)
└── ... (other AES modules)

Sha-Code/
├── sha.v                       (your existing SHA-256)
├── sha256_core.v               (if separate)
└── ... (SHA support modules)

pcpi_sha256.v                   (NEW - PCPI wrapper for SHA)
aes_sha_transmission_controller.v  (NEW - orchestrates AES→SHA→SPI)

picorv32.v                      (MODIFIED - add ENABLE_SHA256, pcpi_sha integration)
```

---

## Summary: Integration Points

| Module | Purpose | What to Modify |
|--------|---------|----------------|
| `picorv32.v` | Add SHA-256 parameter & PCPI routing | Add `ENABLE_SHA256`, instantiate `pcpi_sha256` |
| `pcpi_sha256.v` | PCPI wrapper for SHA-256 core | Create new file |
| `aes_sha_transmission_controller.v` | Orchestrate AES→SHA→SPI flow | Create new file |
| `pcpi_aes.v` | Update SPI for 48 bytes | Change byte counter to 6 bits, add transmission controller |
| `firmware/custom_ops.S` | Add SHA instructions | Define SHA_LOAD_BLOCK, SHA_START, SHA_READ_DIGEST macros |

---

📖 **Questions to decide:**
1. **Which option?** Plaintext hash (Option 1), Ciphertext hash (Option 2), or HMAC (Option 3)?
2. **Hardware or software?** Automatic hardware SHA (recommended) or manual software control?
3. **SPI format?** `[CT | Hash]` or `[Hash | CT]` or separate transmissions?

Let me know your choice and I can generate the complete implementation files!
