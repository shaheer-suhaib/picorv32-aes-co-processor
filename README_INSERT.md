# PicoRV32 with AES-128 Co-Processor Extension

> **⚡ Extended Version** with hardware AES-128 encryption/decryption and 8-lane parallel SPI output

---

## 🎯 Key Features of This Extension

- ✅ **AES-128 Encryption/Decryption Co-Processors** via PCPI interface
- ✅ **8-Lane Parallel SPI** - 8× faster than serial (128 bits in 16 cycles)
- ✅ **Timing Optimized** - On-the-fly key expansion meets 100 MHz @ FPGA
- ✅ **Low Latency** - Complete encryption + transmission in ~610 ns
- ✅ **FIPS-197 Compliant** - Passes all standard test vectors

## 📊 Quick Stats

| Metric | Value |
|--------|-------|
| **AES Throughput** | 210 Mbps @ 100 MHz |
| **Latency** | ~45 cycles encryption + 16 cycles SPI |
| **Speed-up vs SW** | 164× faster than software AES |
| **FPGA Resource** | ~3800 LUTs, ~1330 FFs (18% of XC7A35T) |
| **Timing @ 100MHz** | +6.5 ns positive slack (timing closure achieved) |

## 📖 Documentation

### 🚀 **[Complete Architecture & Flow Diagrams →](README_AES_EXTENSION.md)**

**What's inside:**
- System overview with all components and bit widths
- Detailed AES encryption datapath (with on-the-fly key expansion)
- AES decryption datapath
- 8-lane parallel SPI controller timing diagrams
- Control FSM state machine
- Custom instruction encoding and examples
- Performance metrics and resource utilization
- FIPS-197 test vectors

### 📋 Additional Resources

- **[Timing Fix Documentation](docs/TIMING_FIX_README.md)** - How we achieved 100 MHz timing closure
  - Before: -16.7 ns slack (FAILED) ❌
  - After: +6.5 ns slack (PASSED) ✅
  - 7.6× critical path reduction through on-the-fly key expansion

- **[Build & Test Guide](CLAUDE.md)** - Quick start instructions
  - Prerequisites and toolchain setup
  - Compilation commands
  - Testbench execution
  - FPGA synthesis workflow

- **[Data Flow & Checksum Integration](docs/DATA_FLOW_AND_CHECKSUM_INTEGRATION.md)** - Adding SHA-256
  - Current system data flow
  - 3 SHA-256 integration options
  - Implementation steps

## 🏗️ System Architecture (High-Level)

```
┌──────────────────────────────────────────────────────────────┐
│                    PicoRV32 CPU (RV32IMC)                    │
│  ┌────────────┐  ┌────────────┐  ┌─────────────────────┐    │
│  │ Fetch/     │─▶│  Register  │─▶│  ALU + MUL/DIV      │    │
│  │ Decode     │  │  File      │  │                     │    │
│  └────────────┘  │  (x0-x31)  │  └─────────────────────┘    │
│                  └──────┬─────┘                              │
│                         │ 32-bit                             │
│                  ┌──────▼──────────────────┐                 │
│                  │   PCPI Interface        │                 │
│                  │   (Co-Processor Bus)    │                 │
│                  └───┬──────────────┬──────┘                 │
└──────────────────────┼──────────────┼────────────────────────┘
                       │              │
           ┌───────────▼────┐    ┌────▼──────────────┐
           │  AES Encrypt   │    │  AES Decrypt      │
           │  Co-Processor  │    │  Co-Processor     │
           │  • 128-bit I/O │    │  • 128-bit I/O    │
           │  • 10 rounds   │    │  • 10 rounds      │
           │  • ~45 cycles  │    │  • ~45 cycles     │
           └───────┬────────┘    └───────────────────┘
                   │ 128-bit ciphertext
           ┌───────▼─────────────────────┐
           │  8-Lane Parallel SPI        │
           │  • 8 bits per clock pulse   │
           │  • 16 cycles for 128 bits   │
           │  • Auto-triggered           │
           └─────────────────────────────┘
                   │
                   ▼ [7:0] data + clk + cs_n
              (To External Receiver)
```

## 🚀 Quick Start

```bash
# Clone repository
git clone <your-repo-url>
cd picorv32-aes-co-processor

# Run testbench (requires Icarus Verilog)
make test_aes_pico

# Expected output:
#   OVERALL TEST RESULT: *** PASS ***
#   [OK] AES-128 encryption correct (FIPS-197)
#   [OK] 8-Lane SPI successful (16 bytes in 16 clocks)

# Synthesize for FPGA (Vivado)
cd fpga
vivado -mode batch -source ../scripts/synth.tcl

# Or manually:
synth_design -top aes_soc_top -part xc7a35tcpg236-1
report_timing_summary
# Expected: WNS = +6.5 ns (timing met!)
```

## 📝 Custom Instructions Example

```assembly
# Load plaintext (128 bits = 4×32-bit words)
li   x5, 0xCCDDEEFF        # PT[31:0]
li   x1, 0                 # Index 0
AES_LOAD_PT x1, x5

# Load key (128 bits = 4×32-bit words)
li   x5, 0x0C0D0E0F        # KEY[31:0]
li   x1, 0                 # Index 0
AES_LOAD_KEY x1, x5

# Start encryption
AES_START

# Poll for completion
poll_loop:
    AES_STATUS x7          # Check if done
    beqz x7, poll_loop     # Loop if not done

# Read ciphertext
li   x1, 0                 # Index 0
AES_READ x8, x1            # Result in x8

# Ciphertext is also automatically transmitted via 8-lane SPI!
```

## ⏱️ Performance Comparison

| Implementation | Cycles | Time @ 100MHz | Throughput |
|----------------|--------|---------------|------------|
| **Hardware AES (this)** | 61 | 610 ns | 210 Mbps |
| Software AES (PicoRV32) | 10,000 | 100 μs | 1.28 Mbps |
| **Speed-up** | **164×** | **164×** | **164×** |

---

# PicoRV32 - Original Documentation

> **Note:** This is an extended version of PicoRV32 with additional AES co-processor functionality.
> The original PicoRV32 documentation follows below.

---
