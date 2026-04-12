# 8-Lane Bidirectional SPI Transfer — FPGA to FPGA

**No CPU. No SD Card. Pure hardware RTL.**

Both FPGAs load the **same bitstream**. Either board can send, either can receive.

---

## What is a Pmod?

A **Pmod** (Peripheral Module) is the small 12-pin expansion connector on Digilent FPGA boards.
Each Pmod has 6 signal pins + VCC + GND. The Nexys boards have 4 of them: **JA, JB, JC, JD**.

You connect the two boards together by plugging **male-to-male jumper wires** between the Pmod pins.

---

## Folder Structure

```
fpga_spi_8lane/
├── rtl/
│   ├── top_8lane_bidir.v      ← TOP MODULE (use this as design top in Vivado)
│   ├── spi_master_8lane.v     ← SPI master FSM (TX side)
│   ├── spi_slave_8lane.v      ← SPI slave receiver (RX side, always listening)
│   ├── debounce.v             ← Button debouncer
│   └── status_display.v      ← 7-segment display controller
└── xdc/
    ├── nexys_a7_50t.xdc       ← Constraints for Nexys A7-50T
    └── nexys4ddr.xdc          ← Constraints for Nexys 4 DDR
```

---

## How to Synthesize in Vivado

### Step 1 — Create a new Vivado project
1. Choose **board**: Nexys A7-50T **or** Nexys 4 DDR (create one project per board, same RTL)
2. Add all 5 `.v` files from `rtl/` as design sources
3. Add the appropriate `.xdc` file from `xdc/` as a constraint

### Step 2 — Set the top module
- Right-click `top_8lane_bidir` in the hierarchy → **Set as Top**

### Step 3 — Generate bitstream
- Run Synthesis → Implementation → Generate Bitstream

### Step 4 — Flash **both** boards with their respective bitstreams

---

## Physical Wiring Between the Two FPGAs

Connect jumper wires **cross-style** (A's TX → B's RX *and* B's TX → A's RX):

| Board A Pmod | Signal | Board B Pmod |
|---|---|---|
| **JA1** | SPI_DATA[0] ↔ SPI_DATA_IN[0] | **JC1** |
| **JA2** | SPI_DATA[1] ↔ SPI_DATA_IN[1] | **JC2** |
| **JA3** | SPI_DATA[2] ↔ SPI_DATA_IN[2] | **JC3** |
| **JA4** | SPI_DATA[3] ↔ SPI_DATA_IN[3] | **JC4** |
| **JB1** | SPI_DATA[4] ↔ SPI_DATA_IN[4] | **JD1** |
| **JB2** | SPI_DATA[5] ↔ SPI_DATA_IN[5] | **JD2** |
| **JB3** | SPI_DATA[6] ↔ SPI_DATA_IN[6] | **JD3** |
| **JB4** | SPI_DATA[7] ↔ SPI_DATA_IN[7] | **JD4** |
| **JB7** | SPI_CLK    ↔ SPI_CLK_IN      | **JD7** |
| **JB8** | SPI_CS_N   ↔ SPI_CS_N_IN     | **JD8** |
| **GND** | Common ground                 | **GND** |

> ⚠️ **Always connect GND between the two boards** (any Pmod GND pin).
> ⚠️ Both boards must be powered from USB.

---

## How to Use

1. Set **SW[7:0]** to the byte value you want to send.
   - e.g., SW = `10101010` (binary) = `0xAA` → sends 16 copies of `0xAA`
2. Press **BTNC** to transmit.
   - Your board sends the 16-byte packet over the 8 SPI data lines.
   - The other board receives it automatically.
3. Press **BTND** to reset either board.

---

## LED Status

| LED | Meaning |
|-----|---------|
| **LED[0]** | I am transmitting (TX master busy) |
| **LED[1]** | I am receiving (RX slave busy) |
| **LED[2]** | TX done (latched until next send) |
| **LED[3]** | Data received (latched until next send) |
| **LED[4]** | My SPI_CLK output (blinks fast during TX) |
| **LED[5]** | Incoming SPI_CLK_IN (blinks fast during RX) |
| **LED[6]** | = 1 when I am actively sending (CS asserted) |
| **LED[7]** | = 1 when other board is sending to me |
| **LED[15:8]** | Last received byte [7:0] (stays latched) |

---

## 7-Segment Display

| Shown | Meaning |
|-------|---------|
| `SEND` | Currently transmitting |
| `rECU` | Currently receiving |
| `--XX` | Idle, showing last received byte in HEX (e.g., `--AB`) |

---

## Protocol Details

- **8 parallel SPI data lines** — sends 1 full byte per SPI clock cycle
- **Packet = 16 bytes** (128 bits) — same byte repeated 16 times
- **SPI Mode 0** — clock idle low, data sampled on rising edge
- **SPI clock ≈ 390 kHz** (100 MHz ÷ 256) — safe for jumper wire lengths
- **No arbitration** — if both boards press BTNC simultaneously, both transmit
  and both receive (garbage). Use one at a time.

---

## Quick Test Procedure

1. Set board A: `SW = 10101010` (0xAA)
2. Set board B: `SW = 01010101` (0x55)
3. Press BTNC on board A → check board B's `LED[15:8]` shows `10101010` and 7-seg shows `--AA`
4. Press BTNC on board B → check board A's `LED[15:8]` shows `01010101` and 7-seg shows `--55`
