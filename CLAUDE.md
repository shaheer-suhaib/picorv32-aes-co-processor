# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a PicoRV32 RISC-V processor (RV32IMC) extended with an AES-128 encryption/decryption co-processor and SPI master interface. The AES co-processor uses the PCPI (Pico Co-Processor Interface) and automatically transmits ciphertext via SPI upon encryption completion.

## Build and Test Commands

### Prerequisites
- Icarus Verilog (`iverilog`, `vvp`)
- RISC-V toolchain at `/opt/riscv32i/bin/riscv32-unknown-elf-*`
- Python 3 for hex file generation

### Common Commands

```bash
# Run AES encryption testbench (primary test)
make test_aes_pico

# Run AES decryption testbench
make test_aes_decryption_pico

# Standard PicoRV32 test with firmware
make test

# Simple test without firmware (no toolchain required)
make test_ez

# Generate VCD waveform for debugging
make test_vcd

# Formal verification with SMT solver
make check
```

### Manual Compilation (AES + 8-lane Parallel SPI testbench)

```bash
iverilog -g2012 -o tb_aes_coprocessor.vvp picorv32.v \
    Aes-Code/ASMD_Encryption.v Aes-Code/ControlUnit_Enryption.v \
    Aes-Code/Datapath_Encryption.v Aes-Code/Key_expansion.v \
    Aes-Code/S_BOX.v Aes-Code/mix_cols.v Aes-Code/shift_rows.v \
    Aes-Code/Sub_Bytes.v Aes-Code/Counter.v Aes-Code/Register.v \
    Aes-Code/function_g.v tb_picorv32_aes_coprocessor.v
vvp tb_aes_coprocessor.vvp
gtkwave tb_picorv32_aes_coprocessor.vcd
```

### Toolchain Installation

```bash
make download-tools                  # Download sources
make -j$(nproc) build-riscv32i-tools # Build RV32I toolchain to /opt/riscv32i/
```

## Architecture

### Core Components

- **picorv32.v** - Main CPU with integrated PCPI interface, AES co-processor (`pcpi_aes`), and SPI master
- **Aes-Code/** - AES-128 encryption modules (ASMD state machine architecture)
- **Aes-Code/Aes-Decryption/** - AES-128 decryption modules (inverse operations)
- **SPI/** - SPI Master with chip-select wrapper

### AES Co-Processor Integration

The AES co-processor is enabled via module parameters:
- `ENABLE_AES=1` for encryption
- `ENABLE_AES_DEC=1` for decryption

Custom instructions use opcode `0x0B` (custom-0) with funct3=`0x0`:

| Instruction | funct7 | Description |
|-------------|--------|-------------|
| AES_LOAD_PT | 0100000 | Load plaintext word (rs1[1:0]=index, rs2=data) |
| AES_LOAD_KEY | 0100001 | Load key word |
| AES_START | 0100010 | Start encryption |
| AES_READ | 0100011 | Read ciphertext word |
| AES_STATUS | 0100100 | Check completion (returns 1 when done) |

### 8-Lane Parallel SPI Transmission

Upon AES completion, ciphertext is automatically transmitted via 8-lane parallel SPI:
- **8 bits per clock pulse** (vs 1 bit for traditional SPI)
- 128-bit ciphertext transmitted in **16 clock pulses / 32 system cycles** (8x faster than serial)
- 16 bytes in little-endian order (LSB first)
- Signals:
  - `aes_spi_data[7:0]` - 8 parallel data lanes (directly inline, no external SPI module)
  - `aes_spi_clk` - Clock strobe (pulses high for 1 cycle per byte)
  - `aes_spi_cs_n` - Chip select (active low during transfer)
  - `aes_spi_active` - Transfer in progress indicator
- Receiver should sample `aes_spi_data` on rising edge of `aes_spi_clk`

### Test Vectors (FIPS-197)

```
Plaintext:  0x00112233445566778899aabbccddeeff
Key:        0x000102030405060708090a0b0c0d0e0f
Ciphertext: 0x69c4e0d86a7b0430d8cdb78070b4c55a
```

## Key File Locations

| Path | Purpose |
|------|---------|
| `picorv32.v` | CPU + AES + inline 8-lane parallel SPI (3500+ lines) |
| `Aes-Code/ControlUnit_Enryption.v` | AES encryption FSM |
| `Aes-Code/Datapath_Encryption.v` | AES encryption datapath |
| `tb_picorv32_aes_coprocessor.v` | Main AES + 8-lane SPI testbench |
| `firmware/custom_ops.S` | Custom instruction macros |
| `fpga/` | FPGA top-level modules and constraints |
| `SPI/` | Legacy serial SPI modules (no longer used) |

## Notes

- The Makefile expects `encryption_files.txt` and `decryption_files.txt` for file lists (currently missing)
- Current branch is `spinew` with 8-lane parallel SPI implementation
- Forked from YosysHQ/picorv32
