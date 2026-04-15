# Gemini — Project Reference for PicoRV32 AES Co-Processor (SD-to-SD SPI Transfer)

> **Last updated:** 2026-04-14
> **Scope:** `fpga/aes_soc_top_sd2sd_spi.v`, `fpga/nexys_a7_sd2sd_spi.xdc`, `fpga/nexys4ddr_sd2sd_spi.xdc`

---

## 1. Overview

This design implements a **two-FPGA SD-to-SD image transfer** over an 8-lane parallel SPI link.
A single bitstream (`aes_soc_top_sd2sd_spi`) is programmed onto **both** Nexys boards.
The role (TX vs RX) is determined at runtime by pressing BTNC on the transmitter board.

### High-Level Data Path

```
 TX FPGA                                         RX FPGA
┌──────────────────────┐                ┌──────────────────────┐
│  SD Card ──► PicoRV32 ──► AES SPI ──►│──► spi_slave_8lane   │
│              (firmware)    master     │      ──► spi_rx_buffer│
│                                      │          ──► PicoRV32 │
│                                      │              ──► SD   │
└──────────────────────────────────────┘└──────────────────────┘
        8-bit data + CLK + CS_N  ──────►
```

### Wiring Between Boards

| TX Board (outputs) | → | RX Board (inputs) |
|---|---|---|
| `SPI_DATA[7:0]` (JA + JB) | → | `SPI_DATA_IN[7:0]` (JC + JD) |
| `SPI_CLK` (JB7) | → | `SPI_CLK_IN` (JD7) |
| `SPI_CS_N` (JB8) | → | `SPI_CS_N_IN` (JD8) |
| **GND** (any Pmod GND) | → | **GND** (any Pmod GND) |

> **Important:** RX board's SPI *output* pins are left unconnected — they drive nothing.

---

## 2. File: `fpga/aes_soc_top_sd2sd_spi.v`

**Top-level Verilog module** for the SD-to-SD SPI transfer design.

### 2.1 Port Summary

| Port | Dir | Width | Description |
|---|---|---|---|
| `CLK100MHZ` | in | 1 | 100 MHz system clock |
| `BTNC` | in | 1 | Start button (TX: begin transfer) |
| `BTND` | in | 1 | Reset button (active-high, inverted internally to `resetn`) |
| `SPI_CLK` | out | 1 | SPI master clock (TX direction) |
| `SPI_CS_N` | out | 1 | SPI chip-select, active-low (TX direction) |
| `SPI_DATA[7:0]` | out | 8 | 8-lane SPI data bus (TX direction) |
| `SPI_CLK_IN` | in | 1 | SPI clock received (RX direction) |
| `SPI_CS_N_IN` | in | 1 | SPI chip-select received (RX direction) |
| `SPI_DATA_IN[7:0]` | in | 8 | 8-lane SPI data received (RX direction) |
| `SD_RESET` | out | 1 | SD card power/reset |
| `SD_SCK` | out | 1 | SD SPI clock |
| `SD_CMD` | out | 1 | SD SPI MOSI |
| `SD_DAT0` | in | 1 | SD SPI MISO |
| `SD_DAT3` | out | 1 | SD SPI CS |
| `LED[15:0]` | out | 16 | Status LEDs |
| `AN[7:0]` | out | 8 | 7-segment anode enables |
| `SEG[6:0]` | out | 7 | 7-segment cathode segments |

### 2.2 Key Parameters / Localparams

| Name | Value | Purpose |
|---|---|---|
| `ENABLE_MANUAL_SPI_TEST` | `1'b0` | Set to `1'b1` to enable the manual SPI test generator (bypasses CPU) |
| `MEM_SIZE_WORDS` | `4096` | BRAM size = 4096 × 32-bit = 16 KB |
| `SD_BASE` | `0x0200_0000` | Start of SD MMIO address range |
| `SD_END` | `0x0200_0400` | End of SD MMIO address range (1 KB window) |
| `RXBUF_BASE` | `0x3000_0000` | Start of SPI RX buffer MMIO address range |
| `RXBUF_END` | `0x3000_0020` | End of SPI RX buffer MMIO address range (32-byte window) |

### 2.3 Memory Map

```
0x0000_0000 – 0x0000_3FFF  →  BRAM (code + data, 16 KB)
0x0200_0000 – 0x0200_03FF  →  SD card MMIO (sd_phase1_mmio)
0x3000_0000 – 0x3000_001F  →  SPI RX buffer MMIO (spi_rx_buffer)
anything else               →  returns 0xDEAD_BEEF, ready=1
```

### 2.4 Address Decode Logic

```verilog
bram_sel  = mem_addr < 0x0000_4000
sd_sel    = mem_addr >= SD_BASE && mem_addr < SD_END
rxbuf_sel = mem_addr >= RXBUF_BASE && mem_addr < RXBUF_END
```

`mem_ready` and `mem_rdata` are muxed based on these selects. Un-selected addresses return `0xDEAD_BEEF` with immediate ready.

---

## 3. Module Notes (Instantiated in `aes_soc_top_sd2sd_spi`)

### 3.1 `debounce` — Button Debouncer

- **File:** `debounce.v`
- **Instances:** `db_start` (BTNC), `db_reset` (BTND)
- **Purpose:** Removes mechanical bounce from push-buttons. Provides a stable level output (`btn_out`) and a single-cycle pulse (`btn_pulse`, unused here).
- **Notes:**
  - `btn_reset_level` is inverted to produce `resetn` (active-low system reset).
  - `btn_start_level` is fed to `sd_phase1_mmio` and also used to trigger the manual SPI test generator.

### 3.2 `picorv32` — RISC-V CPU Core

- **File:** `picorv32.v`
- **Instance:** `cpu_i`
- **Purpose:** The main soft-processor running firmware that orchestrates SD read, AES encrypt/decrypt, and SPI transfer.
- **Key Configuration:**
  - `ENABLE_PCPI = 0` — PCPI co-processor interface is **disabled** in this build.
  - `ENABLE_AES = 1`, `ENABLE_AES_DEC = 1` — Custom AES encrypt + decrypt instructions are enabled.
  - `ENABLE_MUL = 1`, `ENABLE_FAST_MUL = 1`, `ENABLE_DIV = 1` — Hardware multiply & divide.
  - `COMPRESSED_ISA = 1` — RV32IC (compressed instructions supported).
  - `CATCH_MISALIGN = 1`, `CATCH_ILLINSN = 1` — Traps on bad instructions/alignment.
  - `ENABLE_IRQ = 0` — Interrupts are disabled.
  - `STACKADDR = 0x0000_4000` — Stack starts at top of BRAM.
  - `PROGADDR_RESET = 0x0000_0000` — Execution begins at BRAM base.
- **AES SPI Outputs:** `aes_spi_data[7:0]`, `aes_spi_clk`, `aes_spi_cs_n`, `aes_spi_active` — these are the CPU-driven SPI signals routed through the AES custom instruction module inside picorv32.
- **Notes:**
  - The `trap` output goes high if the CPU encounters an illegal instruction, misaligned access, or other fatal condition. It is shown on `LED[8]`.

### 3.3 `bram_memory` — Block RAM

- **File:** `bram_memory.v`
- **Instance:** `bram_i`
- **Purpose:** 16 KB synchronous BRAM holding firmware code and data.
- **Key Configuration:**
  - `MEM_SIZE_WORDS = 4096` (16 KB)
  - `MEM_INIT_FILE = ".../program_sd2sd.hex"` — The hex file loaded at synthesis.
- **Notes:**
  - Address range: `0x0000_0000` to `0x0000_3FFF`.
  - The init file path is currently **hardcoded as an absolute Windows path** — must be updated per-machine:
    ```
    C:/AllData/FYPnew/cmacaddedFYP/picorv32-aes-co-processor/fpga/program_sd2sd.hex
    ```
  - `mem_valid` is gated with `bram_sel` before reaching the BRAM.

### 3.4 `sd_phase1_mmio` — SD Card MMIO Controller

- **File:** `sd_phase1_mmio.v`
- **Instance:** `sd_mmio_i`
- **Purpose:** Provides a memory-mapped register interface for the firmware to control the SD card (init, read sectors, write sectors).
- **Connections:**
  - CPU bus signals gated by `sd_sel`.
  - SD card physical pins: `SD_RESET`, `SD_SCK`, `SD_CMD`, `SD_DAT0`, `SD_DAT3`.
  - `btnc_level` — the debounced BTNC input, used by firmware to detect the "start" command.
  - `gpio_out_reg[31:0]` — general-purpose output register written by firmware, drives LEDs and 7-seg display.
- **Status Outputs:**
  - `init_done` — SD card initialization complete.
  - `init_err` — SD card initialization failed.
  - `busy` — SD controller is mid-operation.
  - `debug_state[4:0]`, `debug_last[4:0]` — FSM state for debugging.

### 3.5 `spi_slave_8lane` — 8-Lane SPI Slave Receiver

- **File:** `spi_slave_8lane.v`
- **Instance:** `spi_rx_i`
- **Purpose:** Receives 8-bit-wide parallel SPI data from the TX board and assembles it into 128-bit blocks (16 bytes per block).
- **Key Configuration:**
  - `SAME_CLK_DOMAIN = 1'b0` — TX and RX FPGAs have independent clocks, so CDC (clock-domain crossing) synchronizers are enabled internally.
- **Outputs:**
  - `rx_data[127:0]` — the assembled 128-bit (16-byte) block.
  - `rx_valid` — pulsed when a full block has been received.
  - `rx_busy` — high while receiving.
  - `irq_rx` — interrupt request (unused, left unconnected).
- **Notes:**
  - The 128-bit block size matches the AES block size, which is intentional.
  - `PULLDOWN true` is set on all RX input pins in the XDC to prevent floating when TX is not connected.

### 3.6 `spi_rx_buffer` — SPI Receive Buffer (MMIO)

- **File:** `spi_rx_buffer.v`
- **Instance:** `rxbuf_i`
- **Purpose:** Latches the 128-bit block from `spi_slave_8lane` and makes it accessible to the CPU via memory-mapped reads.
- **Key Configuration:**
  - `BASE_ADDR = RXBUF_BASE` (`0x3000_0000`)
- **Connections:**
  - CPU bus signals gated by `rxbuf_sel`.
  - `spi_rx_data[127:0]` and `spi_rx_valid` from the SPI slave.
- **Notes:**
  - The CPU reads the 128-bit block as four 32-bit word reads at offsets `0x00`, `0x04`, `0x08`, `0x0C` from the base address.
  - Additional status/control registers may occupy the remaining addresses up to `RXBUF_END`.

### 3.7 `seven_seg` — 7-Segment Display Driver

- **File:** `sevenSeg.v`
- **Instance:** `seg_i`
- **Purpose:** Drives the 8-digit 7-segment display with multiplexed output.
- **Inputs:**
  - `digit[3:0]` — the hex digit to display. Source depends on state:
    - **Before SD init:** shows `sd_debug_state[3:0]` (SD FSM state).
    - **After SD init:** shows `gpio_out_reg[3:0]` (firmware-controlled value).
  - `show_digit` — always `1'b1`.
  - `init_ok` — `sd_init_done`, used to switch display mode.
  - `error_flag` — OR of `sd_init_err`, `trap`, and `gpio_out_reg[9]`.

### 3.8 Manual SPI Test Generator (Inline Logic)

- **Lines:** 254–314
- **Purpose:** A debug-only feature for verifying SPI wiring between TX and RX boards without relying on SD card or firmware.
- **How it works:**
  - Controlled by `ENABLE_MANUAL_SPI_TEST` localparam (default: **disabled**, `1'b0`).
  - When enabled, pressing BTNC triggers a 16-byte ascending-pattern transfer on the SPI outputs.
  - Generates a slow SPI clock (~390 kHz) by dividing 100 MHz by 256.
  - Data pattern: bytes `0x00, 0x01, 0x02, ... 0x0F`.
  - After 16 bytes, CS is de-asserted and the generator goes idle.
- **SPI Output Mux:**
  - `SPI_DATA`, `SPI_CLK`, `SPI_CS_N` are multiplexed between the CPU/AES outputs and the manual generator based on `ENABLE_MANUAL_SPI_TEST && manual_active`.

---

## 4. LED Assignments

| LED | Signal | Meaning |
|---|---|---|
| `LED[0]` | `sd_init_done` | SD card initialized OK |
| `LED[1]` | `gpio_out_reg[4]` | Firmware-controlled (typically: TX read started) |
| `LED[2]` | `gpio_out_reg[5]` | Firmware-controlled |
| `LED[3]` | `gpio_out_reg[6]` | Firmware-controlled |
| `LED[4]` | `gpio_out_reg[7]` | Firmware-controlled |
| `LED[5]` | `gpio_out_reg[8]` | Firmware-controlled |
| `LED[6]` | `sd_busy` | SD controller is busy |
| `LED[7]` | `btn_start_level` | BTNC is pressed |
| `LED[8]` | `trap` | **CPU TRAP** — fatal error |
| `LED[9]` | `rx_block_busy` | SPI slave is receiving data |
| `LED[10]` | `cpu_spi_active \| manual_active` | SPI master is actively transmitting |
| `LED[11]` | `~SPI_CS_N_IN` | RX: SPI chip-select is asserted (receiving) |
| `LED[12]` | `(~CS_IN) & CLK_IN` | RX: SPI clock activity while selected |
| `LED[13]` | `(~CS_IN) & DATA_IN[0]` | RX: data bit 0 activity |
| `LED[14]` | `(~CS_IN) & DATA_IN[1]` | RX: data bit 1 activity |
| `LED[15]` | `display_error` | **Error flag** (SD err OR trap OR gpio[9]) |

---

## 5. File: `fpga/nexys_a7_sd2sd_spi.xdc`

**Vivado constraints for the Nexys A7-50T (Artix-7) board.**

### Pin Mapping Summary

| Group | Pmod / Location | Ports |
|---|---|---|
| Clock | E3 | `CLK100MHZ` (100 MHz, 10 ns period) |
| Buttons | N17, P18 | `BTNC`, `BTND` |
| SD Card | E2, B1, C1, C2, D2 | `SD_RESET`, `SD_SCK`, `SD_CMD`, `SD_DAT0`, `SD_DAT3` |
| 7-Seg Cathodes | T10, R10, K16, K13, P15, T11, L18 | `SEG[6:0]` (CA–CG) |
| 7-Seg Anodes | J17, J18, T9, J14, P14, T14, K2, U13 | `AN[7:0]` |
| LEDs | H17..V11 | `LED[15:0]` |
| **SPI TX Data** | **JA:** C17, D18, E18, G17 | `SPI_DATA[3:0]` |
| **SPI TX Data** | **JB:** D14, F16, G16, H14 | `SPI_DATA[7:4]` |
| **SPI TX CLK/CS** | **JB:** E16, F13 | `SPI_CLK` (JB7), `SPI_CS_N` (JB8) |
| **SPI RX Data** | **JC:** K1, F6, J2, G6 | `SPI_DATA_IN[3:0]` (PULLDOWN) |
| **SPI RX Data** | **JD:** H4, H1, G1, G3 | `SPI_DATA_IN[7:4]` (PULLDOWN) |
| **SPI RX CLK/CS** | **JD:** H2, G4 | `SPI_CLK_IN` (JD7), `SPI_CS_N_IN` (JD8) (PULLDOWN) |
| Switches | J15..V10 | `SW[15:0]` (defined but **not used** by the top module) |

### Notes

- All I/O uses **LVCMOS33** except `SW[8]` and `SW[9]` which use **LVCMOS18** (bank voltage difference).
- All SPI RX inputs have **PULLDOWN** enabled to prevent floating when no TX board is connected.
- Switches `SW[15:0]` are constrained but **not connected** in the current top module — available for future use.

---

## 6. File: `fpga/nexys4ddr_sd2sd_spi.xdc`

**Vivado constraints for the Nexys4 DDR board.**

### Differences from Nexys A7

The Nexys4 DDR and Nexys A7 share the **same Artix-7 FPGA** and nearly identical pin maps. The key differences in these XDC files:

| Aspect | Nexys A7 | Nexys4 DDR |
|---|---|---|
| File header comment | "Nexys A7-50T" | "Nexys4 DDR" |
| Pin assignments | **Identical** for all used ports | **Identical** |
| Ordering of 7-seg constraints | SEG first, then AN | AN first, then SEG |

> **In practice, these two XDC files are functionally equivalent.** Use whichever matches the board label printed on your hardware. The pin mapping for clock, buttons, SD, LEDs, 7-seg, and all Pmod headers is the same.

### Pmod Allocation (Both Boards)

```
JA  →  SPI_DATA[3:0]         (TX output, pins 1–4)
JB  →  SPI_DATA[7:4]         (TX output, pins 1–4)
       SPI_CLK               (TX output, pin 7)
       SPI_CS_N              (TX output, pin 8)
JC  →  SPI_DATA_IN[3:0]      (RX input, pins 1–4, PULLDOWN)
JD  →  SPI_DATA_IN[7:4]      (RX input, pins 1–4, PULLDOWN)
       SPI_CLK_IN            (RX input, pin 7, PULLDOWN)
       SPI_CS_N_IN           (RX input, pin 8, PULLDOWN)
```

---

## 7. Related Files (Quick Reference)

| File | Purpose |
|---|---|
| `picorv32.v` | RISC-V CPU core with custom AES instructions |
| `bram_memory.v` | Synchronous BRAM with hex-file initialization |
| `sd_phase1_mmio.v` | SD card MMIO controller (init, read, write sectors) |
| `sd_spi.v` | Low-level SD card SPI protocol driver (used by sd_phase1_mmio) |
| `spi_slave_8lane.v` | 8-bit parallel SPI slave receiver with CDC |
| `spi_rx_buffer.v` | MMIO wrapper for SPI received data |
| `debounce.v` | Button debouncer |
| `sevenSeg.v` | 7-segment display multiplexer |
| `fpga/program_sd2sd.hex` | Firmware hex loaded into BRAM at synthesis |
| `generate_program_sd2sd_hex.py` | Python script to compile firmware → hex |
| `prepare_tx_sd.py` | Writes raw image data to the TX board's SD card |
| `read_rx_sd.py` | Reads received data from the RX board's SD card |
| `verify_sd2sd_rx_image.py` | Verifies the reconstructed image from RX SD card |

---

## 8. Known Issues / TODOs

- [ ] **Hardcoded BRAM init path** in `bram_memory` instantiation — must be updated per machine.
- [ ] **Switches `SW[15:0]`** are constrained in XDC but not used in the top module.
- [ ] **`irq_rx`** from both `spi_slave_8lane` and `spi_rx_buffer` is left unconnected — interrupts are not used (polling-based firmware).
- [ ] **`ENABLE_PCPI = 0`** — PCPI interface is disabled; AES uses the built-in custom instruction path instead.
- [ ] **`ENABLE_MANUAL_SPI_TEST`** is hardcoded to `0` — set to `1` only for debug wiring tests.

---

## 9. Build & Program Quick Reference

1. **Generate firmware hex:** `python generate_program_sd2sd_hex.py`
2. **Update BRAM init path** in `aes_soc_top_sd2sd_spi.v` line 161 to match your local filesystem.
3. **Open Vivado**, create/open project, add all `.v` sources and the appropriate `.xdc` file.
4. **Synthesize → Implement → Generate Bitstream.**
5. **Program both boards** with the same bitstream.
6. **Prepare TX SD:** `python prepare_tx_sd.py`
7. **Press BTNC** on the TX board to start the transfer.
8. **Verify RX SD:** `python verify_sd2sd_rx_image.py`
