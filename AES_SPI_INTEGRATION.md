# AES Co-Processor with SPI Output Integration

## Overview
This document describes the integration of SPI output functionality with the AES co-processor in PicoRV32. When AES encryption completes, the encrypted ciphertext is automatically transmitted via SPI.

## Changes Made

### 1. Modified `picorv32.v`

#### Added SPI Ports to picorv32 Module
- `aes_spi_mosi` - SPI Master Out Slave In (data output)
- `aes_spi_clk` - SPI clock signal
- `aes_spi_cs_n` - SPI chip select (active low)
- `aes_spi_active` - SPI transfer active indicator
- `aes_spi_miso` - SPI Master In Slave Out (data input, currently unused)

#### Connected SPI Signals to pcpi_aes Instance
The SPI signals are now properly connected when `ENABLE_AES` is set. When AES encryption completes, the encrypted data is automatically loaded into the SPI buffer and transmitted.

#### Fixed SPI Transfer Trigger
In the `WAIT_AES` state of `pcpi_aes`, when `aes_done` is asserted:
- The encrypted result (`Dout`) is captured into `RESULT`
- The encrypted data is loaded into `spi_data_buf` for SPI transmission
- `spi_send_pending` is set to trigger the SPI transfer

### 2. Created `testbench_aes_spi.v`

A comprehensive testbench that:
- Tests AES encryption with known test vectors
- Monitors SPI signals and captures transmitted bytes
- Verifies that encrypted data is correctly sent via SPI
- Displays received SPI data and compares with expected ciphertext

## SPI Configuration

### SPI Mode
- **Mode 0**: CPOL=0, CPHA=0
  - Clock idle low
  - Data sampled on rising edge of clock
  - Data changed on falling edge of clock

### SPI Parameters (in pcpi_aes)
- `AES_SPI_CLKS_PER_HALF_BIT`: 2 (default)
- `AES_SPI_NUM_BYTES`: 16 (128-bit ciphertext = 16 bytes)
- `AES_SPI_CS_INACTIVE_CLKS`: 1 (default)

### Byte Order
The SPI transmission sends bytes in **little-endian** order (LSB first):
- Byte 0: Ciphertext bits [7:0]
- Byte 1: Ciphertext bits [15:8]
- ...
- Byte 15: Ciphertext bits [127:120]

## Usage

### Running the Testbench

```bash
# Compile with SPI Master module
iverilog -o tb_aes_spi testbench_aes_spi.v picorv32.v SPI/spi.v SPI/SPI_Master.v

# Run simulation
vvp tb_aes_spi

# With VCD dump for waveform viewing
iverilog -o tb_aes_spi testbench_aes_spi.v picorv32.v SPI/spi.v SPI/SPI_Master.v
vvp tb_aes_spi +vcd
gtkwave tb_picorv32_aes_spi.vcd
```

### Expected Output

The testbench will:
1. Load plaintext and key into AES co-processor
2. Start encryption
3. Wait for completion
4. Automatically transmit encrypted data via SPI
5. Capture and display SPI bytes
6. Verify the transmission

### Test Vector

- **Plaintext**: `0x00112233445566778899aabbccddeeff`
- **Key**: `0x000102030405060708090a0b0c0d0e0f`
- **Expected Ciphertext**: `0x69c4e0d86a7b0430d8cdb78070b4c55a`

### SPI Output Format

The ciphertext will be transmitted as 16 bytes over SPI in little-endian order:
- SPI Byte 0: `0x5a` (CT[7:0])
- SPI Byte 1: `0xc5` (CT[15:8])
- SPI Byte 2: `0xb4` (CT[23:16])
- SPI Byte 3: `0x70` (CT[31:24])
- ... and so on

## Integration Notes

### Connecting to External SPI Devices

When connecting to external SPI slave devices:
1. Connect `aes_spi_mosi` to the slave's MOSI/DIN pin
2. Connect `aes_spi_clk` to the slave's SCLK pin
3. Connect `aes_spi_cs_n` to the slave's CS/SS pin (active low)
4. Connect `aes_spi_miso` from the slave's MISO/DOUT pin (if bidirectional communication is needed)
5. Monitor `aes_spi_active` to know when a transfer is in progress

### Timing Considerations

- The SPI clock frequency is derived from the system clock
- With `CLKS_PER_HALF_BIT = 2` and 100 MHz system clock:
  - SPI clock frequency = 100 MHz / (2 * 2) = 25 MHz
- Adjust `AES_SPI_CLKS_PER_HALF_BIT` parameter to change SPI speed

## Files Modified

1. `picorv32.v` - Added SPI ports and connections
2. `testbench_aes_spi.v` - New testbench for SPI testing

## Files Required

- `picorv32.v` - Main processor with AES co-processor
- `SPI/spi.v` - SPI Master with CS wrapper
- `SPI/SPI_Master.v` - Core SPI Master module
- AES encryption core module (ASMD_Encryption)

## Future Enhancements

Possible improvements:
1. Add SPI receive capability for decryption
2. Support configurable SPI modes (0-3)
3. Add SPI interrupt on transfer complete
4. Support variable-length SPI transfers
5. Add SPI FIFO for buffering

