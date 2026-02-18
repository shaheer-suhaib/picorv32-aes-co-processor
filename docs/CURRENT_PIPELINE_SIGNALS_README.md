# Current Secure Pipeline (With Signal-Level Details)

This document describes the **current working pipeline** in this project, using the exact module and signal names from RTL.

---

## 1) End-to-End Flow

Pipeline:

1. CPU loads `PT` and `KEY` into `pcpi_aes`
2. AES encrypts: `RESULT = AES128(PT, KEY)`
3. `pcpi_aes` computes `DIGEST = SHA256(CT || KEY)`
4. `pcpi_aes` transmits over SPI:
   - bytes `[0..15]` = ciphertext (`CT`)
   - bytes `[16..23]` = auth tag (`DIGEST[255:192]`)
5. Receiver captures SPI packet (24 bytes)
6. Receiver computes `SHA256(RX_CT || KEY)` and compares leftmost 64-bit tag
7. Only if tag matches, decrypt and store plaintext

---

## 2) Main RTL Blocks

- `picorv32.v`
  - `module pcpi_aes`
  - `module pcpi_aes_dec`
  - `module pcpi_sha256`
- `spi_slave_8lane.v`
- `spi_rx_buffer.v`
- `aes_soc_device.v`
- `tb_picorv32_aes_bram.v` (verification flow)

---

## 3) Transmitter Path (pcpi_aes)

### 3.1 Inputs/Outputs

`pcpi_aes` key interface signals:

- PCPI side:
  - `pcpi_valid`, `pcpi_insn`, `pcpi_rs1`, `pcpi_rs2`
  - `pcpi_wr`, `pcpi_rd`, `pcpi_wait`, `pcpi_ready`
- SPI side:
  - `aes_spi_data[7:0]`
  - `aes_spi_clk`
  - `aes_spi_cs_n`
  - `aes_spi_active`

### 3.2 Internal Registers

- `PT[127:0]`
- `KEY[127:0]`
- `RESULT[127:0]`
- `DIGEST[255:0]`
- `tag64 = DIGEST[255:192]`

### 3.3 SHA Input Block (Current)

`sha_block` is built as:

```verilog
{
  RESULT[31:0], RESULT[63:32], RESULT[95:64], RESULT[127:96],
  KEY[31:0],    KEY[63:32],    KEY[95:64],    KEY[127:96],
  32'h80000000, 192'd0, 32'h00000100
}
```

This is SHA-256 of `(CT || KEY)` with message length = 256 bits.

### 3.4 SPI Packet Format (Current)

- Total = **24 bytes**
- Byte counter in `pcpi_aes`: `spi_byte_index[4:0]`
- Mapping:
  - `0..15`: `RESULT[(spi_byte_index*8)+:8]` (ciphertext bytes)
  - `16..23`: `tag64[((23-spi_byte_index)*8)+:8]` (tag bytes)

---

## 4) Receiver Input Path (SPI + RX Buffer)

### 4.1 `spi_slave_8lane`

- Parameter: `RX_NUM_BYTES = 24`
- Output payload:
  - `rx_data[191:0]`
  - `rx_valid`

### 4.2 `spi_rx_buffer`

On `spi_rx_valid`:

- `rx_data_buffer <= spi_rx_data[127:0]` (ciphertext)
- `rx_tag_buffer  <= spi_rx_data[191:128]` (auth tag)

MMIO registers:

- `ADDR_RX_STATUS  = BASE + 0x00`
- `ADDR_RX_DATA_0  = BASE + 0x04`
- `ADDR_RX_DATA_1  = BASE + 0x08`
- `ADDR_RX_DATA_2  = BASE + 0x0C`
- `ADDR_RX_DATA_3  = BASE + 0x10`
- `ADDR_RX_CLEAR   = BASE + 0x14`
- `ADDR_IRQ_ENABLE = BASE + 0x18`
- `ADDR_RX_TAG_0   = BASE + 0x1C`
- `ADDR_RX_TAG_1   = BASE + 0x20`

---

## 5) Receiver Auth + Decrypt Path (pcpi_aes_dec)

### 5.1 Supported Custom Instructions (funct7)

- `0101000` : `AES_DEC_LOAD_CT`
- `0101001` : `AES_DEC_LOAD_KEY`
- `0101010` : `AES_DEC_START`
- `0101011` : `AES_DEC_READ`
- `0101100` : `AES_DEC_STATUS`
- `0101101` : `AES_DEC_LOAD_TAG`
- `0101110` : `AES_DEC_AUTH_STATUS`

### 5.2 Internal Auth Signals

- `CT[127:0]`
- `KEY[127:0]`
- `RX_TAG[63:0]`
- `sha_digest[255:0]`
- `CALC_TAG[63:0] = sha_digest[255:192]`
- `auth_code[1:0]`
  - `2'b00` busy
  - `2'b01` pass
  - `2'b10` fail

### 5.3 Auth Logic

1. On `AES_DEC_START`, FSM enters auth phase
2. Compute `sha_digest = SHA256(CT || KEY)`
3. Compare `sha_digest[255:192]` with `RX_TAG`
4. If match:
   - start `ASMD_Decryption`
   - set `auth_code = 2'b01` on completion
5. If mismatch:
   - do **not** decrypt
   - set `auth_code = 2'b10`

### 5.4 Tag Word Load Order

`AES_DEC_LOAD_TAG` is mapped as:

- `rs1[0] = 0` -> `RX_TAG[63:32]`
- `rs1[0] = 1` -> `RX_TAG[31:0]`

This order must stay consistent with sender tag word ordering.

---

## 6) Software/Memory Result Signals

Main software-observed status writes:

- `MATCH_ADDR = 0x330`
  - `1` = decrypt/auth pass
  - `2` = fail
- `DEC_RESULT_ADDR = 0x340..0x34C` (decrypted plaintext words)
- `SHA_DIGEST_ADDR = 0x440..0x45C`
- `SHA_MATCH_ADDR = 0x460`

---

## 7) Top-Level Physical SPI Signals

From `picorv32` / top module:

- `aes_spi_data[7:0]` : byte payload
- `aes_spi_clk` : byte strobe
- `aes_spi_cs_n` : transfer framing
- `aes_spi_active` : active transfer indicator

---

## 8) Verification Expectation (Current Test Vector)

Expected values in testbench:

- Ciphertext: `0x69c4e0d86a7b0430d8cdb78070b4c55a`
- Tag64: `0xef9935f981202cd6`

Testbench path:

- `tb_picorv32_aes_bram.v` prints:
  - `SPI CT Byte[0..15]`
  - `SPI TAG Byte[16..23]`

---

## 9) Related Diagrams

- Full flow diagram:
  - `docs/current_pipeline_dataflow.svg`
- Receiver MACTAG match logic diagram:
  - `docs/rx_mactag_match_logic.svg`

