`timescale 1ns / 1ps

/***************************************************************
 * Two-CPU Encrypted Image Transfer Testbench
 *
 *   ┌─────────────────────────┐         ┌─────────────────────────┐
 *   │   DEVICE A (Transmitter)│  8-lane │   DEVICE B (Receiver)   │
 *   │                         │   SPI   │                         │
 *   │  PicoRV32 CPU           │ ══════> │  SPI Slave + RX Buffer  │
 *   │  + AES Encrypt          │         │         ↓               │
 *   │  + SPI Master (auto)    │         │  PicoRV32 CPU           │
 *   │                         │         │  + AES Decrypt           │
 *   │  BRAM: firmware +       │         │                         │
 *   │        image data       │         │  BRAM: firmware + key + │
 *   │        + key            │         │        decrypted output │
 *   └─────────────────────────┘         └─────────────────────────┘
 *
 * Flow:
 * 1. Python script converts image → image_data.hex (16-byte chunks)
 * 2. Device A firmware encrypts each 128-bit block from memory
 * 3. Ciphertext auto-transmitted via 8-lane SPI after each encryption
 * 4. Device B SPI slave captures block into RX buffer (memory-mapped)
 * 5. Device B firmware polls RX buffer, reads ciphertext
 * 6. Device B loads ciphertext into AES decrypt coprocessor
 * 7. Device B stores decrypted plaintext to output memory
 * 8. Testbench writes decrypted output → decrypted_output.hex
 * 9. Python script reconstructs image from hex
 
 ***************************************************************/

// Number of 128-bit AES blocks in the image (set via -DIMAGE_NUM_BLOCKS=N)
`ifndef IMAGE_NUM_BLOCKS
`define IMAGE_NUM_BLOCKS 256
`endif

module tb_soc_image_transfer;

    //=========================================================
    // Parameters
    //=========================================================
    parameter CLK_PERIOD     = 10;
    parameter NUM_BLOCKS     = `IMAGE_NUM_BLOCKS;
    parameter MEM_SIZE       = (NUM_BLOCKS * 4) + 512;  // image words + firmware/key overhead
    parameter TIMEOUT_CYCLES = NUM_BLOCKS * 2000 + 50000;

    //=========================================================
    // AES Key (same on both devices)
    //=========================================================
    localparam [127:0] AES_KEY = 128'h000102030405060708090a0b0c0d0e0f;

    //=========================================================
    // Clock and Reset
    //=========================================================
    reg clk = 0;
    reg resetn = 0;

    always #(CLK_PERIOD/2) clk = ~clk;

    //=========================================================
    // Device Signals
    //=========================================================
    wire        trap_a, trap_b;

    // SPI bus: Device A TX → Device B RX
    wire [7:0]  spi_data;
    wire        spi_clk_w;
    wire        spi_cs_n;
    wire        spi_active;
    wire        spi_rx_irq;

    //=========================================================
    // Test Control
    //=========================================================
    integer cycle_count;
    integer blocks_sent;
    integer errors;
    integer fd;

    //=========================================================
    // VCD Dump (disabled by default for large images)
    //=========================================================
`ifdef DUMP_VCD
    initial begin
        $dumpfile("tb_soc_image_transfer.vcd");
        $dumpvars(0, tb_soc_image_transfer);
    end
`endif

    //=========================================================
    // Device A: Transmitter (PicoRV32 + AES Encrypt + SPI TX)
    //=========================================================
    aes_soc_device #(
        .MEM_SIZE_WORDS (MEM_SIZE),
        .PROGADDR_RESET (32'h0000_0000)
    ) device_a (
        .clk            (clk),
        .resetn         (resetn),
        .trap           (trap_a),
        // SPI TX → Device B
        .spi_tx_data    (spi_data),
        .spi_tx_clk     (spi_clk_w),
        .spi_tx_cs_n    (spi_cs_n),
        .spi_tx_active  (spi_active),
        // SPI RX unused (tie inactive)
        .spi_rx_clk_in  (1'b0),
        .spi_rx_data_in (8'b0),
        .spi_rx_cs_n_in (1'b1),
        .spi_rx_irq     ()
    );

    //=========================================================
    // Device B: Receiver (SPI Slave + RX Buffer + PicoRV32 + AES Decrypt)
    //=========================================================
    aes_soc_device #(
        .MEM_SIZE_WORDS (MEM_SIZE),
        .PROGADDR_RESET (32'h0000_0000)
    ) device_b (
        .clk            (clk),
        .resetn         (resetn),
        .trap           (trap_b),
        // SPI TX unused
        .spi_tx_data    (),
        .spi_tx_clk     (),
        .spi_tx_cs_n    (),
        .spi_tx_active  (),
        // SPI RX ← Device A
        .spi_rx_clk_in  (spi_clk_w),
        .spi_rx_data_in (spi_data),
        .spi_rx_cs_n_in (spi_cs_n),
        .spi_rx_irq     (spi_rx_irq)
    );

    //=========================================================
    // RISC-V Instruction Encoding Helpers
    //=========================================================

    // LUI rd, imm20
    function [31:0] lui;
        input [4:0] rd;
        input [19:0] imm;
        lui = {imm, rd, 7'b0110111};
    endfunction

    // ADDI rd, rs1, imm12
    function [31:0] addi;
        input [4:0] rd, rs1;
        input [11:0] imm;
        addi = {imm, rs1, 3'b000, rd, 7'b0010011};
    endfunction

    // LW rd, imm12(rs1)
    function [31:0] lw;
        input [4:0] rd, rs1;
        input [11:0] imm;
        lw = {imm, rs1, 3'b010, rd, 7'b0000011};
    endfunction

    // SW rs2, imm12(rs1)
    function [31:0] sw;
        input [4:0] rs2, rs1;
        input [11:0] imm;
        sw = {imm[11:5], rs2, rs1, 3'b010, imm[4:0], 7'b0100011};
    endfunction

    // BEQ rs1, rs2, imm13
    function [31:0] beq;
        input [4:0] rs1, rs2;
        input [12:0] imm;
        beq = {imm[12], imm[10:5], rs2, rs1, 3'b000, imm[4:1], imm[11], 7'b1100011};
    endfunction

    // BNE rs1, rs2, imm13
    function [31:0] bne;
        input [4:0] rs1, rs2;
        input [12:0] imm;
        bne = {imm[12], imm[10:5], rs2, rs1, 3'b001, imm[4:1], imm[11], 7'b1100011};
    endfunction

    // JAL rd, imm21
    function [31:0] jal;
        input [4:0] rd;
        input [20:0] imm;
        jal = {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'b1101111};
    endfunction

    //=========================================================
    // AES Encryption Custom Instructions (funct7 = 0x20-0x24)
    //=========================================================
    function [31:0] aes_load_pt;
        input [4:0] rd, rs1, rs2;
        aes_load_pt = {7'b0100000, rs2, rs1, 3'b000, rd, 7'b0001011};
    endfunction

    function [31:0] aes_load_key;
        input [4:0] rd, rs1, rs2;
        aes_load_key = {7'b0100001, rs2, rs1, 3'b000, rd, 7'b0001011};
    endfunction

    function [31:0] aes_start;
        input [4:0] rd, rs1, rs2;
        aes_start = {7'b0100010, rs2, rs1, 3'b000, rd, 7'b0001011};
    endfunction

    //=========================================================
    // AES Decryption Custom Instructions (funct7 = 0x28-0x2C)
    //=========================================================
    function [31:0] aes_dec_load_ct;
        input [4:0] rd, rs1, rs2;
        aes_dec_load_ct = {7'b0101000, rs2, rs1, 3'b000, rd, 7'b0001011};
    endfunction

    function [31:0] aes_dec_load_key;
        input [4:0] rd, rs1, rs2;
        aes_dec_load_key = {7'b0101001, rs2, rs1, 3'b000, rd, 7'b0001011};
    endfunction

    function [31:0] aes_dec_start;
        input [4:0] rd, rs1, rs2;
        aes_dec_start = {7'b0101010, rs2, rs1, 3'b000, rd, 7'b0001011};
    endfunction

    function [31:0] aes_dec_read;
        input [4:0] rd, rs1, rs2;
        aes_dec_read = {7'b0101011, rs2, rs1, 3'b000, rd, 7'b0001011};
    endfunction

    //=========================================================
    // Main Test Sequence
    //=========================================================
    integer i;

    initial begin
        $display("");
        $display("================================================================");
        $display("  Two-CPU Encrypted Image Transfer");
        $display("  AES-128 Encrypt --> 8-Lane SPI --> AES-128 Decrypt");
        $display("================================================================");
        $display("  Image: %0d blocks (%0d bytes)", NUM_BLOCKS, NUM_BLOCKS * 16);
        $display("  Memory: %0d words per device (%0d KB)", MEM_SIZE, MEM_SIZE * 4 / 1024);
        $display("  Timeout: %0d cycles", TIMEOUT_CYCLES);
        $display("================================================================");
        $display("");

        // Initialize
        resetn = 0;
        cycle_count = 0;
        blocks_sent = 0;
        errors = 0;

        //=====================================================
        // Initialize both memories to NOPs
        //=====================================================
        for (i = 0; i < MEM_SIZE; i = i + 1) begin
            device_a.memory[i] = 32'h00000013;
            device_b.memory[i] = 32'h00000013;
        end

        //=====================================================
        // DEVICE A FIRMWARE: Encrypt and transmit all blocks
        //=====================================================
        // Register usage:
        //   x1 = word index (0-3)
        //   x2 = plaintext pointer (increments by 16 each block)
        //   x3 = key base address (0x200)
        //   x4 = block counter (num_blocks → 0)
        //   x5 = data temp
        //   x6 = delay counter
        //
        // Memory map:
        //   0x000-0x0FF: Firmware
        //   0x200-0x20F: AES key (16 bytes)
        //   0x300:       NUM_BLOCKS (loaded by firmware with lw)
        //   0x400+:      Image plaintext data (loaded from image_data.hex)

        i = 0;

        // Setup
        device_a.memory[i] = addi(3, 0, 12'h200);                i=i+1;  // x3 = 0x200 (key base)
        device_a.memory[i] = addi(2, 0, 12'h400);                i=i+1;  // x2 = 0x400 (image base)
        device_a.memory[i] = lw(4, 0, 12'h300);                  i=i+1;  // x4 = mem[0x300] = num_blocks

        // block_loop: (instruction 3, address 0x0C)
        // Load 4 plaintext words from mem[x2] into AES encrypt
        device_a.memory[i] = addi(1, 0, 0);                      i=i+1;  // x1 = 0
        device_a.memory[i] = lw(5, 2, 12'h000);                  i=i+1;  // x5 = mem[x2+0]
        device_a.memory[i] = aes_load_pt(0, 1, 5);               i=i+1;
        device_a.memory[i] = addi(1, 0, 1);                      i=i+1;  // x1 = 1
        device_a.memory[i] = lw(5, 2, 12'h004);                  i=i+1;
        device_a.memory[i] = aes_load_pt(0, 1, 5);               i=i+1;
        device_a.memory[i] = addi(1, 0, 2);                      i=i+1;  // x1 = 2
        device_a.memory[i] = lw(5, 2, 12'h008);                  i=i+1;
        device_a.memory[i] = aes_load_pt(0, 1, 5);               i=i+1;
        device_a.memory[i] = addi(1, 0, 3);                      i=i+1;  // x1 = 3
        device_a.memory[i] = lw(5, 2, 12'h00c);                  i=i+1;
        device_a.memory[i] = aes_load_pt(0, 1, 5);               i=i+1;

        // Load 4 key words from mem[x3] into AES encrypt
        device_a.memory[i] = addi(1, 0, 0);                      i=i+1;
        device_a.memory[i] = lw(5, 3, 12'h000);                  i=i+1;
        device_a.memory[i] = aes_load_key(0, 1, 5);              i=i+1;
        device_a.memory[i] = addi(1, 0, 1);                      i=i+1;
        device_a.memory[i] = lw(5, 3, 12'h004);                  i=i+1;
        device_a.memory[i] = aes_load_key(0, 1, 5);              i=i+1;
        device_a.memory[i] = addi(1, 0, 2);                      i=i+1;
        device_a.memory[i] = lw(5, 3, 12'h008);                  i=i+1;
        device_a.memory[i] = aes_load_key(0, 1, 5);              i=i+1;
        device_a.memory[i] = addi(1, 0, 3);                      i=i+1;
        device_a.memory[i] = lw(5, 3, 12'h00c);                  i=i+1;
        device_a.memory[i] = aes_load_key(0, 1, 5);              i=i+1;

        // Encrypt + auto SPI send (CPU blocks until done)
        device_a.memory[i] = aes_start(0, 0, 0);                 i=i+1;

        // Delay loop: give Device B time to poll, decrypt, and clear
        // x6 = 100, then count down (~800 cycles delay per block)
        device_a.memory[i] = addi(6, 0, 12'd100);                i=i+1;  // x6 = 100
        // delay_loop:
        device_a.memory[i] = addi(6, 6, -1);                     i=i+1;  // x6 -= 1
        device_a.memory[i] = bne(6, 0, -13'd4);                  i=i+1;  // → delay_loop

        // Loop control
        device_a.memory[i] = addi(2, 2, 16);                     i=i+1;  // x2 += 16 (next block)
        device_a.memory[i] = addi(4, 4, -1);                     i=i+1;  // x4 -= 1
        device_a.memory[i] = bne(4, 0, -13'd120);                i=i+1;  // → block_loop (addr 0x0C)

        // Halt (infinite loop)
        device_a.memory[i] = jal(0, 21'd0);                      i=i+1;

        $display("Device A firmware: %0d instructions", i);

        // Store AES key at 0x200
        device_a.memory['h200 >> 2] = AES_KEY[31:0];
        device_a.memory['h204 >> 2] = AES_KEY[63:32];
        device_a.memory['h208 >> 2] = AES_KEY[95:64];
        device_a.memory['h20C >> 2] = AES_KEY[127:96];

        // Store block count at 0x300 (firmware reads with lw)
        device_a.memory['h300 >> 2] = NUM_BLOCKS;

        // Load image data from hex file at 0x400
        $readmemh("image_data.hex", device_a.memory, 'h400 >> 2);

        $display("Loaded image_data.hex into Device A memory at 0x400");

        //=====================================================
        // DEVICE B FIRMWARE: Poll RX buffer, decrypt, store
        //=====================================================
        // Register usage:
        //   x1  = word index (0-3)
        //   x2  = output pointer (increments by 16)
        //   x3  = key base address (0x200)
        //   x4  = block counter (num_blocks → 0)
        //   x5  = data temp
        //   x6  = temp
        //   x10 = RX buffer base (0x30000000)
        //
        // Memory map:
        //   0x000-0x0FF:    Firmware
        //   0x200-0x20F:    AES key
        //   0x300:          NUM_BLOCKS
        //   0x304:          Completion flag (set to 1 when done)
        //   0x400+:         Decrypted image output
        //   0x30000000+:    RX buffer registers (memory-mapped I/O)

        i = 0;

        // Setup
        device_b.memory[i] = lui(10, 20'h30000);                 i=i+1;  // x10 = 0x30000000
        device_b.memory[i] = addi(3, 0, 12'h200);                i=i+1;  // x3 = 0x200 (key base)
        device_b.memory[i] = addi(2, 0, 12'h400);                i=i+1;  // x2 = 0x400 (output base)
        device_b.memory[i] = lw(4, 0, 12'h300);                  i=i+1;  // x4 = mem[0x300] = num_blocks

        // poll: (instruction 4, address 0x10)
        device_b.memory[i] = lw(5, 10, 12'h000);                 i=i+1;  // x5 = RX_STATUS
        device_b.memory[i] = beq(5, 0, -13'd4);                  i=i+1;  // if 0, loop to poll

        // Load 4 ciphertext words from RX buffer into AES decrypt
        device_b.memory[i] = lw(5, 10, 12'h004);                 i=i+1;  // x5 = RX_DATA_0
        device_b.memory[i] = addi(1, 0, 0);                      i=i+1;
        device_b.memory[i] = aes_dec_load_ct(0, 1, 5);           i=i+1;
        device_b.memory[i] = lw(5, 10, 12'h008);                 i=i+1;  // x5 = RX_DATA_1
        device_b.memory[i] = addi(1, 0, 1);                      i=i+1;
        device_b.memory[i] = aes_dec_load_ct(0, 1, 5);           i=i+1;
        device_b.memory[i] = lw(5, 10, 12'h00c);                 i=i+1;  // x5 = RX_DATA_2
        device_b.memory[i] = addi(1, 0, 2);                      i=i+1;
        device_b.memory[i] = aes_dec_load_ct(0, 1, 5);           i=i+1;
        device_b.memory[i] = lw(5, 10, 12'h010);                 i=i+1;  // x5 = RX_DATA_3
        device_b.memory[i] = addi(1, 0, 3);                      i=i+1;
        device_b.memory[i] = aes_dec_load_ct(0, 1, 5);           i=i+1;

        // Load 4 key words from mem[x3] into AES decrypt
        device_b.memory[i] = addi(1, 0, 0);                      i=i+1;
        device_b.memory[i] = lw(5, 3, 12'h000);                  i=i+1;
        device_b.memory[i] = aes_dec_load_key(0, 1, 5);          i=i+1;
        device_b.memory[i] = addi(1, 0, 1);                      i=i+1;
        device_b.memory[i] = lw(5, 3, 12'h004);                  i=i+1;
        device_b.memory[i] = aes_dec_load_key(0, 1, 5);          i=i+1;
        device_b.memory[i] = addi(1, 0, 2);                      i=i+1;
        device_b.memory[i] = lw(5, 3, 12'h008);                  i=i+1;
        device_b.memory[i] = aes_dec_load_key(0, 1, 5);          i=i+1;
        device_b.memory[i] = addi(1, 0, 3);                      i=i+1;
        device_b.memory[i] = lw(5, 3, 12'h00c);                  i=i+1;
        device_b.memory[i] = aes_dec_load_key(0, 1, 5);          i=i+1;

        // Decrypt (CPU blocks until done)
        device_b.memory[i] = aes_dec_start(0, 0, 0);             i=i+1;

        // Read 4 decrypted words and store to output memory
        device_b.memory[i] = addi(1, 0, 0);                      i=i+1;
        device_b.memory[i] = aes_dec_read(5, 1, 0);              i=i+1;  // x5 = plaintext[31:0]
        device_b.memory[i] = sw(5, 2, 12'd0);                    i=i+1;  // mem[x2+0] = x5
        device_b.memory[i] = addi(1, 0, 1);                      i=i+1;
        device_b.memory[i] = aes_dec_read(5, 1, 0);              i=i+1;  // x5 = plaintext[63:32]
        device_b.memory[i] = sw(5, 2, 12'd4);                    i=i+1;
        device_b.memory[i] = addi(1, 0, 2);                      i=i+1;
        device_b.memory[i] = aes_dec_read(5, 1, 0);              i=i+1;  // x5 = plaintext[95:64]
        device_b.memory[i] = sw(5, 2, 12'd8);                    i=i+1;
        device_b.memory[i] = addi(1, 0, 3);                      i=i+1;
        device_b.memory[i] = aes_dec_read(5, 1, 0);              i=i+1;  // x5 = plaintext[127:96]
        device_b.memory[i] = sw(5, 2, 12'd12);                   i=i+1;

        // Clear RX buffer (acknowledge block consumed)
        device_b.memory[i] = sw(0, 10, 12'd20);                  i=i+1;  // write to RX_CLEAR

        // Loop control
        device_b.memory[i] = addi(2, 2, 16);                     i=i+1;  // x2 += 16 (next block)
        device_b.memory[i] = addi(4, 4, -1);                     i=i+1;  // x4 -= 1
        device_b.memory[i] = bne(4, 0, -13'd168);                i=i+1;  // → poll (addr 0x10)

        // Done: write completion flag
        device_b.memory[i] = addi(6, 0, 1);                      i=i+1;  // x6 = 1
        device_b.memory[i] = sw(6, 0, 12'h304);                  i=i+1;  // mem[0x304] = 1

        // Halt (infinite loop)
        device_b.memory[i] = jal(0, 21'd0);                      i=i+1;

        $display("Device B firmware: %0d instructions", i);

        // Store AES key at 0x200 (same key as Device A)
        device_b.memory['h200 >> 2] = AES_KEY[31:0];
        device_b.memory['h204 >> 2] = AES_KEY[63:32];
        device_b.memory['h208 >> 2] = AES_KEY[95:64];
        device_b.memory['h20C >> 2] = AES_KEY[127:96];

        // Store block count at 0x300
        device_b.memory['h300 >> 2] = NUM_BLOCKS;

        $display("");

        //=====================================================
        // Release reset and run
        //=====================================================
        #(CLK_PERIOD * 10);
        resetn = 1;
        $display("Reset released, both CPUs starting...");
        $display("Processing %0d blocks...", NUM_BLOCKS);
        $display("");

        //=====================================================
        // Wait for completion
        //=====================================================
        fork
            // Thread 1: Progress monitor
            begin
                while (device_b.memory['h304 >> 2] !== 32'd1 && cycle_count < TIMEOUT_CYCLES) begin
                    @(posedge clk);
                    cycle_count = cycle_count + 1;

                    // Progress report: at 10%, 20%, ... or every 50K cycles
                    if (NUM_BLOCKS >= 20) begin
                        if (blocks_sent > 0 && blocks_sent % (NUM_BLOCKS / 10) == 0
                            && blocks_sent != NUM_BLOCKS) begin
                            // Check if we just hit a 10% boundary
                            if (blocks_sent == (blocks_sent / (NUM_BLOCKS/10)) * (NUM_BLOCKS/10))
                                ; // handled by SPI counter thread
                        end
                    end
                    if (cycle_count % 50000 == 0)
                        $display("  [%0dk cycles] %0d/%0d blocks sent",
                                 cycle_count / 1000, blocks_sent, NUM_BLOCKS);
                end
            end

            // Thread 2: Count SPI transfers from Device A
            begin
                wait(resetn == 1);
                forever begin
                    @(negedge spi_cs_n);
                    blocks_sent = blocks_sent + 1;
                    @(posedge spi_cs_n);

                    // Progress display
                    if (NUM_BLOCKS <= 16) begin
                        // Small image: show each block
                        $display("  [SPI] Block %0d/%0d transferred (cycle %0d)",
                                 blocks_sent, NUM_BLOCKS, cycle_count);
                    end else if (blocks_sent % (NUM_BLOCKS / 10) == 0 || blocks_sent == NUM_BLOCKS) begin
                        // Large image: show every 10%
                        $display("  [SPI] Progress: %0d/%0d blocks (%0d%%) at cycle %0d",
                                 blocks_sent, NUM_BLOCKS,
                                 blocks_sent * 100 / NUM_BLOCKS, cycle_count);
                    end
                end
            end
        join_any
        disable fork;

        // Extra time for final processing
        #(CLK_PERIOD * 200);

        //=====================================================
        // Verify Results
        //=====================================================
        $display("");
        $display("================================================================");
        $display("  Results");
        $display("================================================================");
        $display("Blocks sent via SPI:  %0d / %0d", blocks_sent, NUM_BLOCKS);
        $display("Completion flag:      %0d", device_b.memory['h304 >> 2]);
        $display("Total cycles:         %0d", cycle_count);
        $display("Throughput:           %0d cycles/block", cycle_count / (NUM_BLOCKS > 0 ? NUM_BLOCKS : 1));
        $display("");

        // Word-by-word comparison: Device A input vs Device B output
        $display("Verifying decrypted data...");
        errors = 0;

        for (i = 0; i < NUM_BLOCKS * 4; i = i + 1) begin
            if (device_a.memory['h400/4 + i] !== device_b.memory['h400/4 + i]) begin
                if (errors < 20) begin
                    // Show first 20 mismatches with detail
                    $display("  MISMATCH at word %0d (block %0d, word %0d):", i, i/4, i%4);
                    $display("    Original:  %08h", device_a.memory['h400/4 + i]);
                    $display("    Decrypted: %08h", device_b.memory['h400/4 + i]);
                end
                errors = errors + 1;
            end
        end

        if (errors > 20)
            $display("  ... and %0d more mismatches", errors - 20);

        // Write decrypted output to hex file for Python reconstruction
        fd = $fopen("decrypted_output.hex", "w");
        for (i = 0; i < NUM_BLOCKS * 4; i = i + 1)
            $fdisplay(fd, "%08h", device_b.memory['h400/4 + i]);
        $fclose(fd);
        $display("Written: decrypted_output.hex (%0d words)", NUM_BLOCKS * 4);

        $display("");
        if (errors == 0 && blocks_sent == NUM_BLOCKS) begin
            $display("****************************************");
            $display("*  SUCCESS! All %0d blocks match!", NUM_BLOCKS);
            $display("*");
            $display("*  %0d bytes encrypted by CPU A,", NUM_BLOCKS * 16);
            $display("*  transmitted over 8-lane SPI,");
            $display("*  received and decrypted by CPU B.");
            $display("*");
            $display("*  Run: python3 hex_to_image.py");
            $display("*  to reconstruct the image.");
            $display("****************************************");
        end else begin
            $display("FAILED: %0d word errors, %0d/%0d blocks sent",
                     errors, blocks_sent, NUM_BLOCKS);
        end

        $display("");
        $finish;
    end

    //=========================================================
    // Timeout Watchdog
    //=========================================================
    initial begin
        #(CLK_PERIOD * TIMEOUT_CYCLES);
        $display("");
        $display("ERROR: Simulation timeout after %0d cycles!", TIMEOUT_CYCLES);
        $display("Blocks sent: %0d / %0d", blocks_sent, NUM_BLOCKS);
        $display("Completion:  %0d", device_b.memory['h304 >> 2]);
        $finish;
    end

    //=========================================================
    // Trap Monitor
    //=========================================================
    always @(posedge clk) begin
        if (trap_a) $display("[%0t] WARNING: Device A trapped!", $time);
        if (trap_b) $display("[%0t] WARNING: Device B trapped!", $time);
    end

endmodule
