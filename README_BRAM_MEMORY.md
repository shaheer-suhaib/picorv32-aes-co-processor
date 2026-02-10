# BRAM-Based Memory for PicoRV32 AES Co-Processor

## 📖 Overview

This guide shows how to use **synthesizable BRAM-based memory** instead of testbench simulation memory. This is essential for FPGA implementation where you need actual memory blocks that can be synthesized.

## 🎯 Key Files

| File | Purpose |
|------|---------|
| **[bram_memory.v](bram_memory.v)** | BRAM memory module (synthesizable) |
| **[generate_program_hex.py](generate_program_hex.py)** | Python script to generate program.hex |
| **[tb_picorv32_aes_bram.v](tb_picorv32_aes_bram.v)** | Testbench using BRAM memory |
| **[aes_soc_top_bram.v](aes_soc_top_bram.v)** | FPGA top-level with BRAM (ready for synthesis) |
| **program.hex** | Generated memory initialization file |

---

## 🚀 Quick Start

### Step 1: Generate Memory Initialization File

```bash
python3 generate_program_hex.py
```

**Output:**
```
✅ Generated program.hex
   Memory size: 2048 words (8192 bytes)
   Program size: 27 instructions
   Test Vector:
     Plaintext:  0x00112233445566778899aabbccddeeff
     Key:        0x000102030405060708090a0b0c0d0e0f
     Expected:   0x69c4e0d86a7b0430d8cdb78070b4c55a
```

### Step 2: Run Simulation with BRAM

```bash
make test_aes_bram
```

**Expected Output:**
```
================================================================
  PicoRV32 AES with BRAM Memory Test
================================================================
[BRAM] Initializing memory from program.hex
[Cycle 0] Reset released - CPU starting
[Cycle 234] SPI Transfer Started
  SPI Byte[ 0] = 0xff
  SPI Byte[ 1] = 0xee
  ...
  SPI Byte[15] = 0x69
[Cycle 266] SPI Transfer Complete (16 bytes)

Received Ciphertext: 0x69c4e0d86a7b0430d8cdb78070b4c55a
Expected Ciphertext: 0x69c4e0d86a7b0430d8cdb78070b4c55a

================================================================
  *** TEST PASSED ***
================================================================
```

### Step 3: Synthesize for FPGA

```tcl
# In Vivado TCL console
read_verilog aes_soc_top_bram.v
read_verilog bram_memory.v
read_verilog picorv32.v
read_verilog Aes-Code/*.v

# Set program.hex path
set_property INIT_FILE "path/to/program.hex" [get_cells memory/memory_reg*]

synth_design -top aes_soc_top_bram -part xc7a35tcpg236-1
opt_design
place_design
route_design

report_utilization
report_timing_summary
```

---

## 📋 How It Works

### 1. **Memory Architecture**

```
┌─────────────────────────────────────────────────┐
│         BRAM Memory (8 KB total)                │
├─────────────────────────────────────────────────┤
│  0x00000000 - 0x00000FFF : Instructions (4KB)   │
│  0x00001000 - 0x00001FFF : Data Memory (4KB)    │
└─────────────────────────────────────────────────┘
         ▲                    ▲
         │                    │
    ┌────┴────────────────────┴────┐
    │   mem_addr, mem_wdata, etc.  │
    │   (PicoRV32 Memory Bus)      │
    └──────────────────────────────┘
```

### 2. **BRAM Inference**

The `bram_memory.v` module uses Vivado BRAM inference:

```verilog
(* ram_style = "block" *) reg [31:0] memory [0:MEM_SIZE_WORDS-1];

always @(posedge clk) begin
    // Byte-wise write
    if (mem_wstrb[0]) memory[word_addr][ 7: 0] <= mem_wdata[ 7: 0];
    // ...

    // Registered read (required for BRAM inference)
    mem_rdata <= memory[word_addr];
end
```

**Key points:**
- `(* ram_style = "block" *)` forces BRAM usage
- Registered output (`mem_rdata <=`) enables BRAM inference
- Byte-write enable using `mem_wstrb`

### 3. **Memory Initialization**

**Option A: From Python Script (Recommended)**
```bash
python3 generate_program_hex.py  # Creates program.hex
```

**Option B: Manual Hex File**
```
// program.hex format (one 32-bit word per line)
00000093  // addi x1, x0, 0
00000113  // addi x2, x0, 0
...
```

**Option C: Inline Initialization**
```verilog
initial begin
    memory[0] = 32'h00000093;  // addi x1, x0, 0
    memory[1] = 32'h00000113;  // addi x2, x0, 0
    // ...
end
```

---

## 🔧 Customizing the Memory

### Change Memory Size

In `bram_memory.v`:
```verilog
module bram_memory #(
    parameter MEM_SIZE_WORDS = 4096,  // Change to 16 KB (4K words)
    // ...
)
```

### Load Different Program

**Method 1: Generate new hex file**
```python
# Edit generate_program_hex.py
PLAINTEXT = 0x11223344556677889900AABBCCDDEEFF  # New plaintext
KEY       = 0x0F0E0D0C0B0A09080706050403020100  # New key
```

**Method 2: Use different hex file**
```verilog
bram_memory #(
    .MEM_INIT_FILE("my_program.hex")  // Custom file
) mem (
    // ...
);
```

### Add More Data

Edit `generate_program_hex.py`:
```python
def generate_data():
    data = {}

    # Add custom data at address 0x400
    data[0x100] = 0x12345678  # Address 0x400 (word 256)
    data[0x101] = 0xDEADBEEF

    return data
```

---

## 📊 Resource Utilization

### BRAM Usage

| Memory Size | BRAM18K Used | BRAM36K Used |
|-------------|--------------|--------------|
| **2 KB** | 1 | 0 |
| **4 KB** | 2 | 0 |
| **8 KB** (default) | 4 | 0 |
| **16 KB** | 8 | 0 |
| **32 KB** | 0 | 8 |

**XC7A35T has:**
- 100 BRAM18K blocks (50 BRAM36K)
- Using 8KB = 4 BRAM18K = **4% utilization**

### Complete SoC Utilization

```
Post-Synthesis Resource Usage:
├─ LUTs:       3,800 / 20,800  (18%)
├─ FFs:        1,400 / 41,600  (3%)
├─ BRAM18K:    4 / 100         (4%)   ← BRAM memory
├─ DSPs:       3 / 90          (3%)
└─ Timing:     +6.5 ns slack @ 100 MHz ✅
```

---

## 🐛 Troubleshooting

### Issue: "BRAM not inferred, using distributed RAM"

**Solution 1:** Force BRAM with attribute
```verilog
(* ram_style = "block" *) reg [31:0] memory [0:MEM_SIZE_WORDS-1];
```

**Solution 2:** Check registered output
```verilog
// ✅ CORRECT - registered read
always @(posedge clk)
    mem_rdata <= memory[word_addr];

// ❌ WRONG - combinational read
assign mem_rdata = memory[word_addr];  // Won't infer BRAM!
```

### Issue: "program.hex not found"

```bash
# Generate the file first
python3 generate_program_hex.py

# Or run make (does it automatically)
make test_aes_bram
```

### Issue: "Simulation hangs / timeout"

**Check:**
1. `program.hex` is correctly formatted (8 hex digits per line)
2. BRAM read latency is handled (1 cycle delay)
3. Reset is properly released (`resetn <= 1`)

**Debug:**
```bash
# View waveform
gtkwave tb_picorv32_aes_bram.vcd
```

---

## 🔄 Differences from Testbench Memory

| Aspect | Testbench Memory | BRAM Memory |
|--------|------------------|-------------|
| **Synthesis** | ❌ Simulation only | ✅ Synthesizable |
| **Read Latency** | 0 cycles (instant) | 1 cycle (registered) |
| **Write Latency** | 0 cycles | 1 cycle |
| **Initialization** | Direct array writes | Hex file / `$readmemh` |
| **Area** | N/A (simulation) | 4 BRAM18K (8KB) |
| **Use Case** | Testbench only | FPGA deployment |

---

## 📝 Example: Custom Program

### 1. Create Custom Assembly

```assembly
# custom_program.S
.global _start
_start:
    li   x5, 0xAABBCCDD
    li   x1, 0
    # AES_LOAD_PT x1, x5
    .word 0x00508027  # Custom encoding

loop:
    j loop
```

### 2. Compile to Hex

```bash
riscv32-unknown-elf-as custom_program.S -o custom_program.o
riscv32-unknown-elf-objcopy -O verilog custom_program.o custom_program.hex
```

### 3. Load in BRAM

```verilog
bram_memory #(
    .MEM_INIT_FILE("custom_program.hex")
) mem (
    // ...
);
```

---

## 🎓 Understanding BRAM Read Latency

### Traditional Testbench (0-cycle read)
```
Cycle 0: CPU sends address 0x100
Cycle 0: Memory returns data immediately
```

### BRAM Memory (1-cycle read)
```
Cycle 0: CPU sends address 0x100, mem_valid=1
Cycle 1: BRAM reads, mem_ready=0 (reading)
Cycle 2: BRAM outputs data, mem_ready=1 (data available)
```

The `bram_memory.v` module handles this latency internally with:
```verilog
reg mem_valid_q;
always @(posedge clk) begin
    mem_valid_q <= mem_valid && !mem_ready;  // Delay ready by 1 cycle
    mem_ready <= mem_valid_q;                // to match BRAM latency
end
```

---

## 🚀 Next Steps

1. ✅ **Simulation:** `make test_aes_bram`
2. ✅ **Synthesis:** Open Vivado, synthesize `aes_soc_top_bram.v`
3. ✅ **FPGA:** Generate bitstream, program FPGA
4. ✅ **Test:** Connect SPI receiver, verify ciphertext

For SHA-256 integration, you can expand the memory and add SHA module following the same pattern!

---

## 📚 Related Documentation

- [Timing Fix Documentation](docs/TIMING_FIX_README.md)
- [Data Flow & Checksum Integration](docs/DATA_FLOW_AND_CHECKSUM_INTEGRATION.md)
- [Complete Architecture](README_AES_EXTENSION.md)
- [Build Guide](CLAUDE.md)
