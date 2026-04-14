`timescale 1ns / 1ps

/***************************************************************
 * Full SoC Image Transfer Testbench
 *
 * This testbench simulates the complete system:
 *
 *   ┌─────────────────────────┐         ┌─────────────────────────┐
 *   │      DEVICE 1           │   SPI   │      DEVICE 2           │
 *   │     (Transmitter)       │ ══════> │      (Receiver)         │
 *   │                         │         │                         │
 *   │  ┌─────────────────┐    │         │    ┌─────────────────┐  │
 *   │  │   PicoRV32 CPU  │    │         │    │   SPI Slave     │  │
 *   │  │   + AES Encrypt │    │         │    │   8-lane RX     │  │
 *   │  │   + SPI Master  │    │         │    └────────┬────────┘  │
 *   │  └────────┬────────┘    │         │             │           │
 *   │           │             │         │             ▼           │
 *   │    ┌──────┴──────┐      │         │    ┌─────────────────┐  │
 *   │    │   Memory    │      │         │    │  AES Decrypt    │  │
 *   │    │ (firmware + │      │         │    └────────┬────────┘  │
 *   │    │  image data)│      │         │             │           │
 *   │    └─────────────┘      │         │    ┌────────┴────────┐  │
 *   │                         │         │    │     Memory      │  │
 *   └─────────────────────────┘         │    │ (decrypted img) │  │
 *                                       │    └─────────────────┘  │
 *                                       └─────────────────────────┘
 *
 * Flow:
 * 1. Image data loaded into Device 1 memory
 * 2. PicoRV32 executes firmware to encrypt each block
 * 3. After each encryption, ciphertext auto-transmitted via 8-lane SPI
 * 4. Device 2 SPI slave receives ciphertext
 * 5. Device 2 decrypts each block
 * 6. Decrypted data stored in Device 2 memory
 * 7. Compare Device 2 memory with original image
 ***************************************************************/

module tb_soc_image_transfer;

    //=========================================================
    // Parameters
    //=========================================================
    parameter CLK_PERIOD = 10;          // 100 MHz
    parameter MEM_SIZE = 2048;          // 2K words = 8KB memory
    parameter MAX_BLOCKS = 256;         // Max image blocks (4KB image)
    parameter TIMEOUT_CYCLES = 500000;  // Simulation timeout

    //=========================================================
    // AES Key (must match on both devices)
    //=========================================================
    localparam [127:0] AES_KEY = 128'h000102030405060708090a0b0c0d0e0f;

    //=========================================================
    // Clock and Reset
    //=========================================================
    reg clk = 0;
    reg resetn = 0;

    always #(CLK_PERIOD/2) clk = ~clk;

    //=========================================================
    // Device 1: PicoRV32 + AES + SPI Master (Transmitter)
    //=========================================================
    wire        trap;

    // Memory interface
    wire        mem_valid;
    wire        mem_instr;
    reg         mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    reg  [31:0] mem_rdata;

    // 8-Lane SPI outputs from PicoRV32
    wire [7:0]  spi_data;
    wire        spi_clk;
    wire        spi_cs_n;
    wire        spi_active;

    // Device 1 Memory
    reg [31:0] dev1_memory [0:MEM_SIZE-1];

    //=========================================================
    // Device 2: SPI Slave + AES Decrypt (Receiver)
    //=========================================================
    // SPI Slave signals
    wire [127:0] rx_block_data;
    wire         rx_block_valid;

    // AES Decryption signals
    reg  [127:0] dec_ciphertext;
    reg  [127:0] dec_key;
    reg          dec_start;
    wire [127:0] dec_plaintext;
    wire         dec_done;

    // Device 2 Memory for decrypted data
    reg [127:0] dev2_memory [0:MAX_BLOCKS-1];
    integer     dev2_block_count;

    //=========================================================
    // Test Control
    //=========================================================
    integer i, j;
    integer num_blocks;
    integer cycle_count;
    integer blocks_encrypted;
    integer blocks_received;
    integer blocks_decrypted;
    integer errors;

    // Original image data for comparison
    reg [127:0] original_image [0:MAX_BLOCKS-1];

    //=========================================================
    // VCD Dump
    //=========================================================
    initial begin
        $dumpfile("tb_soc_image_transfer.vcd");
        $dumpvars(0, tb_soc_image_transfer);
    end

    //=========================================================
    // Instantiate PicoRV32 (Device 1 - Transmitter)
    //=========================================================
    picorv32 #(
        .ENABLE_COUNTERS     (0),
        .ENABLE_COUNTERS64   (0),
        .ENABLE_REGS_16_31   (1),
        .ENABLE_REGS_DUALPORT(1),
        .LATCHED_MEM_RDATA   (0),
        .TWO_STAGE_SHIFT     (0),
        .BARREL_SHIFTER      (1),
        .TWO_CYCLE_COMPARE   (0),
        .TWO_CYCLE_ALU       (0),
        .COMPRESSED_ISA      (1),
        .CATCH_MISALIGN      (0),
        .CATCH_ILLINSN       (0),
        .ENABLE_PCPI         (0),
        .ENABLE_MUL          (0),
        .ENABLE_FAST_MUL     (0),
        .ENABLE_DIV          (0),
        .ENABLE_IRQ          (0),
        .ENABLE_IRQ_QREGS    (0),
        .ENABLE_IRQ_TIMER    (0),
        .ENABLE_TRACE        (0),
        .ENABLE_AES          (1),   // Enable AES encryption
        .ENABLE_AES_DEC      (0)    // No decryption on transmitter
    ) pico_tx (
        .clk           (clk),
        .resetn        (resetn),
        .trap          (trap),

        .mem_valid     (mem_valid),
        .mem_instr     (mem_instr),
        .mem_ready     (mem_ready),
        .mem_addr      (mem_addr),
        .mem_wdata     (mem_wdata),
        .mem_wstrb     (mem_wstrb),
        .mem_rdata     (mem_rdata),

        // 8-Lane SPI outputs
        .aes_spi_data  (spi_data),
        .aes_spi_clk   (spi_clk),
        .aes_spi_cs_n  (spi_cs_n),
        .aes_spi_active(spi_active),

        // Unused
        .mem_la_read   (),
        .mem_la_write  (),
        .mem_la_addr   (),
        .mem_la_wdata  (),
        .mem_la_wstrb  (),
        .pcpi_valid    (),
        .pcpi_insn     (),
        .pcpi_rs1      (),
        .pcpi_rs2      (),
        .pcpi_wr       (1'b0),
        .pcpi_rd       (32'b0),
        .pcpi_wait     (1'b0),
        .pcpi_ready    (1'b0),
        .irq           (32'b0),
        .eoi           (),
        .trace_valid   (),
        .trace_data    ()
    );

    //=========================================================
    // Device 1 Memory Controller
    //=========================================================
    always @(posedge clk) begin
        mem_ready <= 0;
        if (resetn && mem_valid && !mem_ready) begin
            mem_ready <= 1;
            mem_rdata <= dev1_memory[mem_addr[31:2] & (MEM_SIZE-1)];
            if (mem_wstrb[0]) dev1_memory[mem_addr[31:2] & (MEM_SIZE-1)][7:0]   <= mem_wdata[7:0];
            if (mem_wstrb[1]) dev1_memory[mem_addr[31:2] & (MEM_SIZE-1)][15:8]  <= mem_wdata[15:8];
            if (mem_wstrb[2]) dev1_memory[mem_addr[31:2] & (MEM_SIZE-1)][23:16] <= mem_wdata[23:16];
            if (mem_wstrb[3]) dev1_memory[mem_addr[31:2] & (MEM_SIZE-1)][31:24] <= mem_wdata[31:24];
        end
    end

    //=========================================================
    // Instantiate SPI Slave 8-Lane (Device 2 - Receiver)
    //=========================================================
    spi_slave_8lane spi_rx (
        .clk        (clk),
        .resetn     (resetn),

        // SPI interface (directly connected to PicoRV32's SPI master)
        .spi_clk_in (spi_clk),
        .spi_cs_n_in(spi_cs_n),
        .spi_data_in(spi_data),

        // Block output
        .rx_data    (rx_block_data),
        .rx_valid   (rx_block_valid),
        .rx_busy    (),
        .irq_rx     ()
    );

    //=========================================================
    // Instantiate AES Decryption (Device 2)
    //=========================================================
    ASMD_Decryption aes_decrypt (
        .done       (dec_done),
        .Dout       (dec_plaintext),
        .encrypted_text_in (dec_ciphertext),
        .key_in     (dec_key),
        .decrypt    (dec_start),
        .clock      (clk),
        .reset      (!resetn)
    );

    //=========================================================
    // Device 2 State Machine - Receive, Decrypt, Store
    //=========================================================
    localparam RX_IDLE = 0, RX_DECRYPT_START = 1, RX_DECRYPT_WAIT = 2, RX_STORE = 3;
    reg [2:0] rx_state;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            rx_state <= RX_IDLE;
            dec_start <= 0;
            dec_ciphertext <= 0;
            dec_key <= AES_KEY;
            dev2_block_count <= 0;
        end else begin
            dec_start <= 0;

            case (rx_state)
                RX_IDLE: begin
                    if (rx_block_valid) begin
                        // Received a block via SPI (rx_valid pulses for 1 cycle)
                        dec_ciphertext <= rx_block_data;
                        blocks_received <= blocks_received + 1;
                        rx_state <= RX_DECRYPT_START;
                    end
                end

                RX_DECRYPT_START: begin
                    // Start decryption - hold for 2 cycles for proper capture
                    dec_start <= 1;
                    rx_state <= RX_DECRYPT_WAIT;
                end

                RX_DECRYPT_WAIT: begin
                    if (dec_done) begin
                        rx_state <= RX_STORE;
                    end
                end

                RX_STORE: begin
                    // Store decrypted plaintext
                    dev2_memory[dev2_block_count] <= dec_plaintext;
                    dev2_block_count <= dev2_block_count + 1;
                    blocks_decrypted <= blocks_decrypted + 1;
                    rx_state <= RX_IDLE;
                end
            endcase
        end
    end

    //=========================================================
    // Custom AES Instructions (from firmware/custom_ops.S)
    //=========================================================
    // Opcode 0x0B (custom-0), funct3=0x0
    // funct7 determines operation:
    //   0100000 (0x20) = AES_LOAD_PT  - Load plaintext word
    //   0100001 (0x21) = AES_LOAD_KEY - Load key word
    //   0100010 (0x22) = AES_START    - Start encryption
    //   0100011 (0x23) = AES_READ     - Read ciphertext word
    //   0100100 (0x24) = AES_STATUS   - Check if done

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

    function [31:0] aes_read;
        input [4:0] rd, rs1, rs2;
        aes_read = {7'b0100011, rs2, rs1, 3'b000, rd, 7'b0001011};
    endfunction

    function [31:0] aes_status;
        input [4:0] rd, rs1, rs2;
        aes_status = {7'b0100100, rs2, rs1, 3'b000, rd, 7'b0001011};
    endfunction

    // Standard RISC-V instructions
    function [31:0] lui;
        input [4:0] rd;
        input [19:0] imm;
        lui = {imm, rd, 7'b0110111};
    endfunction

    function [31:0] addi;
        input [4:0] rd, rs1;
        input [11:0] imm;
        addi = {imm, rs1, 3'b000, rd, 7'b0010011};
    endfunction

    function [31:0] ori;
        input [4:0] rd, rs1;
        input [11:0] imm;
        ori = {imm, rs1, 3'b110, rd, 7'b0010011};
    endfunction

    function [31:0] lw;
        input [4:0] rd, rs1;
        input [11:0] imm;
        lw = {imm, rs1, 3'b010, rd, 7'b0000011};
    endfunction

    function [31:0] sw;
        input [4:0] rs2, rs1;
        input [11:0] imm;
        sw = {imm[11:5], rs2, rs1, 3'b010, imm[4:0], 7'b0100011};
    endfunction

    function [31:0] beq;
        input [4:0] rs1, rs2;
        input [12:0] imm;
        beq = {imm[12], imm[10:5], rs2, rs1, 3'b000, imm[4:1], imm[11], 7'b1100011};
    endfunction

    function [31:0] bne;
        input [4:0] rs1, rs2;
        input [12:0] imm;
        bne = {imm[12], imm[10:5], rs2, rs1, 3'b001, imm[4:1], imm[11], 7'b1100011};
    endfunction

    function [31:0] jal;
        input [4:0] rd;
        input [20:0] imm;
        jal = {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'b1101111};
    endfunction

    function [31:0] nop;
        input dummy;
        nop = 32'h00000013;  // addi x0, x0, 0
    endfunction

    //=========================================================
    // Test Data - Small test image (4 blocks = 64 bytes)
    //=========================================================
    localparam NUM_TEST_BLOCKS = 4;

    // Test plaintext blocks
    localparam [127:0] TEST_PT_0 = 128'h00112233445566778899aabbccddeeff;
    localparam [127:0] TEST_PT_1 = 128'hffeeddccbbaa99887766554433221100;
    localparam [127:0] TEST_PT_2 = 128'h0f1e2d3c4b5a69788796a5b4c3d2e1f0;
    localparam [127:0] TEST_PT_3 = 128'hdeadbeefcafebabe0123456789abcdef;

    //=========================================================
    // Main Test Sequence
    //=========================================================
    initial begin
        $display("");
        $display("================================================================");
        $display("  Full SoC Image Transfer Test");
        $display("  PicoRV32 + AES Encrypt + 8-Lane SPI --> SPI Slave + AES Decrypt");
        $display("================================================================");
        $display("");

        // Initialize
        resetn = 0;
        cycle_count = 0;
        blocks_encrypted = 0;
        blocks_received = 0;
        blocks_decrypted = 0;
        errors = 0;
        num_blocks = NUM_TEST_BLOCKS;

        // Initialize Device 1 memory to NOPs
        for (i = 0; i < MEM_SIZE; i = i + 1)
            dev1_memory[i] = 32'h00000013;

        // Initialize Device 2 memory
        for (i = 0; i < MAX_BLOCKS; i = i + 1)
            dev2_memory[i] = 128'h0;

        // Store original image for later comparison
        original_image[0] = TEST_PT_0;
        original_image[1] = TEST_PT_1;
        original_image[2] = TEST_PT_2;
        original_image[3] = TEST_PT_3;

        $display("Loading firmware and image data into Device 1 memory...");

        //=====================================================
        // Load Firmware into Device 1 Memory
        //=====================================================
        // Memory map:
        //   0x0000 - 0x00FF: Firmware (instructions)
        //   0x0100 - 0x010F: AES Key (4 words)
        //   0x0200 - 0x02FF: Image data (plaintext blocks)
        //   0x0300 - 0x03FF: Results storage

        // Store AES key at 0x100
        dev1_memory['h100 >> 2] = AES_KEY[31:0];
        dev1_memory['h104 >> 2] = AES_KEY[63:32];
        dev1_memory['h108 >> 2] = AES_KEY[95:64];
        dev1_memory['h10C >> 2] = AES_KEY[127:96];

        // Store image plaintext at 0x200 (4 words per block)
        // Block 0
        dev1_memory['h200 >> 2] = TEST_PT_0[31:0];
        dev1_memory['h204 >> 2] = TEST_PT_0[63:32];
        dev1_memory['h208 >> 2] = TEST_PT_0[95:64];
        dev1_memory['h20C >> 2] = TEST_PT_0[127:96];
        // Block 1
        dev1_memory['h210 >> 2] = TEST_PT_1[31:0];
        dev1_memory['h214 >> 2] = TEST_PT_1[63:32];
        dev1_memory['h218 >> 2] = TEST_PT_1[95:64];
        dev1_memory['h21C >> 2] = TEST_PT_1[127:96];
        // Block 2
        dev1_memory['h220 >> 2] = TEST_PT_2[31:0];
        dev1_memory['h224 >> 2] = TEST_PT_2[63:32];
        dev1_memory['h228 >> 2] = TEST_PT_2[95:64];
        dev1_memory['h22C >> 2] = TEST_PT_2[127:96];
        // Block 3
        dev1_memory['h230 >> 2] = TEST_PT_3[31:0];
        dev1_memory['h234 >> 2] = TEST_PT_3[63:32];
        dev1_memory['h238 >> 2] = TEST_PT_3[95:64];
        dev1_memory['h23C >> 2] = TEST_PT_3[127:96];

        //=====================================================
        // Firmware: Encrypt and transmit all blocks
        //=====================================================
        // Using a simpler approach: unrolled loop for 4 blocks
        // This avoids branch offset calculation issues

        i = 0;

        // ===== BLOCK 0 =====
        // Load key
        dev1_memory[i] = lui(8, AES_KEY[31:12]);  i=i+1;
        dev1_memory[i] = ori(8, 8, AES_KEY[11:0]); i=i+1;
        dev1_memory[i] = addi(7, 0, 0);           i=i+1;
        dev1_memory[i] = aes_load_key(0, 7, 8);   i=i+1;

        dev1_memory[i] = lui(8, AES_KEY[63:44]);  i=i+1;
        dev1_memory[i] = ori(8, 8, AES_KEY[43:32]); i=i+1;
        dev1_memory[i] = addi(7, 0, 1);           i=i+1;
        dev1_memory[i] = aes_load_key(0, 7, 8);   i=i+1;

        dev1_memory[i] = lui(8, AES_KEY[95:76]);  i=i+1;
        dev1_memory[i] = ori(8, 8, AES_KEY[75:64]); i=i+1;
        dev1_memory[i] = addi(7, 0, 2);           i=i+1;
        dev1_memory[i] = aes_load_key(0, 7, 8);   i=i+1;

        dev1_memory[i] = lui(8, AES_KEY[127:108]); i=i+1;
        dev1_memory[i] = ori(8, 8, AES_KEY[107:96]); i=i+1;
        dev1_memory[i] = addi(7, 0, 3);           i=i+1;
        dev1_memory[i] = aes_load_key(0, 7, 8);   i=i+1;

        // Load plaintext block 0
        dev1_memory[i] = lui(8, TEST_PT_0[31:12]); i=i+1;
        dev1_memory[i] = ori(8, 8, TEST_PT_0[11:0]); i=i+1;
        dev1_memory[i] = addi(7, 0, 0);           i=i+1;
        dev1_memory[i] = aes_load_pt(0, 7, 8);    i=i+1;

        dev1_memory[i] = lui(8, TEST_PT_0[63:44]); i=i+1;
        dev1_memory[i] = ori(8, 8, TEST_PT_0[43:32]); i=i+1;
        dev1_memory[i] = addi(7, 0, 1);           i=i+1;
        dev1_memory[i] = aes_load_pt(0, 7, 8);    i=i+1;

        dev1_memory[i] = lui(8, TEST_PT_0[95:76]); i=i+1;
        dev1_memory[i] = ori(8, 8, TEST_PT_0[75:64]); i=i+1;
        dev1_memory[i] = addi(7, 0, 2);           i=i+1;
        dev1_memory[i] = aes_load_pt(0, 7, 8);    i=i+1;

        dev1_memory[i] = lui(8, TEST_PT_0[127:108]); i=i+1;
        dev1_memory[i] = ori(8, 8, TEST_PT_0[107:96]); i=i+1;
        dev1_memory[i] = addi(7, 0, 3);           i=i+1;
        dev1_memory[i] = aes_load_pt(0, 7, 8);    i=i+1;

        // Start encryption
        dev1_memory[i] = aes_start(0, 0, 0);      i=i+1;

        // Wait for done
        dev1_memory[i] = aes_status(10, 0, 0);    i=i+1;
        dev1_memory[i] = beq(10, 0, -13'd4);      i=i+1;

        // Delay for SPI
        dev1_memory[i] = addi(11, 0, 200);        i=i+1;
        dev1_memory[i] = addi(11, 11, -1);        i=i+1;
        dev1_memory[i] = bne(11, 0, -13'd4);      i=i+1;

        // ===== BLOCK 1 =====
        // Load plaintext block 1 (key already loaded)
        dev1_memory[i] = lui(8, TEST_PT_1[31:12]); i=i+1;
        dev1_memory[i] = ori(8, 8, TEST_PT_1[11:0]); i=i+1;
        dev1_memory[i] = addi(7, 0, 0);           i=i+1;
        dev1_memory[i] = aes_load_pt(0, 7, 8);    i=i+1;

        dev1_memory[i] = lui(8, TEST_PT_1[63:44]); i=i+1;
        dev1_memory[i] = ori(8, 8, TEST_PT_1[43:32]); i=i+1;
        dev1_memory[i] = addi(7, 0, 1);           i=i+1;
        dev1_memory[i] = aes_load_pt(0, 7, 8);    i=i+1;

        dev1_memory[i] = lui(8, TEST_PT_1[95:76]); i=i+1;
        dev1_memory[i] = ori(8, 8, TEST_PT_1[75:64]); i=i+1;
        dev1_memory[i] = addi(7, 0, 2);           i=i+1;
        dev1_memory[i] = aes_load_pt(0, 7, 8);    i=i+1;

        dev1_memory[i] = lui(8, TEST_PT_1[127:108]); i=i+1;
        dev1_memory[i] = ori(8, 8, TEST_PT_1[107:96]); i=i+1;
        dev1_memory[i] = addi(7, 0, 3);           i=i+1;
        dev1_memory[i] = aes_load_pt(0, 7, 8);    i=i+1;

        // Reload key for block 1 (required after previous encryption)
        dev1_memory[i] = lui(8, AES_KEY[31:12]);  i=i+1;
        dev1_memory[i] = ori(8, 8, AES_KEY[11:0]); i=i+1;
        dev1_memory[i] = addi(7, 0, 0);           i=i+1;
        dev1_memory[i] = aes_load_key(0, 7, 8);   i=i+1;

        dev1_memory[i] = lui(8, AES_KEY[63:44]);  i=i+1;
        dev1_memory[i] = ori(8, 8, AES_KEY[43:32]); i=i+1;
        dev1_memory[i] = addi(7, 0, 1);           i=i+1;
        dev1_memory[i] = aes_load_key(0, 7, 8);   i=i+1;

        dev1_memory[i] = lui(8, AES_KEY[95:76]);  i=i+1;
        dev1_memory[i] = ori(8, 8, AES_KEY[75:64]); i=i+1;
        dev1_memory[i] = addi(7, 0, 2);           i=i+1;
        dev1_memory[i] = aes_load_key(0, 7, 8);   i=i+1;

        dev1_memory[i] = lui(8, AES_KEY[127:108]); i=i+1;
        dev1_memory[i] = ori(8, 8, AES_KEY[107:96]); i=i+1;
        dev1_memory[i] = addi(7, 0, 3);           i=i+1;
        dev1_memory[i] = aes_load_key(0, 7, 8);   i=i+1;

        dev1_memory[i] = aes_start(0, 0, 0);      i=i+1;
        dev1_memory[i] = aes_status(10, 0, 0);    i=i+1;
        dev1_memory[i] = beq(10, 0, -13'd4);      i=i+1;
        dev1_memory[i] = addi(11, 0, 200);        i=i+1;
        dev1_memory[i] = addi(11, 11, -1);        i=i+1;
        dev1_memory[i] = bne(11, 0, -13'd4);      i=i+1;

        // ===== BLOCK 2 =====
        dev1_memory[i] = lui(8, TEST_PT_2[31:12]); i=i+1;
        dev1_memory[i] = ori(8, 8, TEST_PT_2[11:0]); i=i+1;
        dev1_memory[i] = addi(7, 0, 0);           i=i+1;
        dev1_memory[i] = aes_load_pt(0, 7, 8);    i=i+1;

        dev1_memory[i] = lui(8, TEST_PT_2[63:44]); i=i+1;
        dev1_memory[i] = ori(8, 8, TEST_PT_2[43:32]); i=i+1;
        dev1_memory[i] = addi(7, 0, 1);           i=i+1;
        dev1_memory[i] = aes_load_pt(0, 7, 8);    i=i+1;

        dev1_memory[i] = lui(8, TEST_PT_2[95:76]); i=i+1;
        dev1_memory[i] = ori(8, 8, TEST_PT_2[75:64]); i=i+1;
        dev1_memory[i] = addi(7, 0, 2);           i=i+1;
        dev1_memory[i] = aes_load_pt(0, 7, 8);    i=i+1;

        dev1_memory[i] = lui(8, TEST_PT_2[127:108]); i=i+1;
        dev1_memory[i] = ori(8, 8, TEST_PT_2[107:96]); i=i+1;
        dev1_memory[i] = addi(7, 0, 3);           i=i+1;
        dev1_memory[i] = aes_load_pt(0, 7, 8);    i=i+1;

        // Reload key
        dev1_memory[i] = lui(8, AES_KEY[31:12]);  i=i+1;
        dev1_memory[i] = ori(8, 8, AES_KEY[11:0]); i=i+1;
        dev1_memory[i] = addi(7, 0, 0);           i=i+1;
        dev1_memory[i] = aes_load_key(0, 7, 8);   i=i+1;
        dev1_memory[i] = lui(8, AES_KEY[63:44]);  i=i+1;
        dev1_memory[i] = ori(8, 8, AES_KEY[43:32]); i=i+1;
        dev1_memory[i] = addi(7, 0, 1);           i=i+1;
        dev1_memory[i] = aes_load_key(0, 7, 8);   i=i+1;
        dev1_memory[i] = lui(8, AES_KEY[95:76]);  i=i+1;
        dev1_memory[i] = ori(8, 8, AES_KEY[75:64]); i=i+1;
        dev1_memory[i] = addi(7, 0, 2);           i=i+1;
        dev1_memory[i] = aes_load_key(0, 7, 8);   i=i+1;
        dev1_memory[i] = lui(8, AES_KEY[127:108]); i=i+1;
        dev1_memory[i] = ori(8, 8, AES_KEY[107:96]); i=i+1;
        dev1_memory[i] = addi(7, 0, 3);           i=i+1;
        dev1_memory[i] = aes_load_key(0, 7, 8);   i=i+1;

        dev1_memory[i] = aes_start(0, 0, 0);      i=i+1;
        dev1_memory[i] = aes_status(10, 0, 0);    i=i+1;
        dev1_memory[i] = beq(10, 0, -13'd4);      i=i+1;
        dev1_memory[i] = addi(11, 0, 200);        i=i+1;
        dev1_memory[i] = addi(11, 11, -1);        i=i+1;
        dev1_memory[i] = bne(11, 0, -13'd4);      i=i+1;

        // ===== BLOCK 3 =====
        dev1_memory[i] = lui(8, TEST_PT_3[31:12]); i=i+1;
        dev1_memory[i] = ori(8, 8, TEST_PT_3[11:0]); i=i+1;
        dev1_memory[i] = addi(7, 0, 0);           i=i+1;
        dev1_memory[i] = aes_load_pt(0, 7, 8);    i=i+1;

        dev1_memory[i] = lui(8, TEST_PT_3[63:44]); i=i+1;
        dev1_memory[i] = ori(8, 8, TEST_PT_3[43:32]); i=i+1;
        dev1_memory[i] = addi(7, 0, 1);           i=i+1;
        dev1_memory[i] = aes_load_pt(0, 7, 8);    i=i+1;

        dev1_memory[i] = lui(8, TEST_PT_3[95:76]); i=i+1;
        dev1_memory[i] = ori(8, 8, TEST_PT_3[75:64]); i=i+1;
        dev1_memory[i] = addi(7, 0, 2);           i=i+1;
        dev1_memory[i] = aes_load_pt(0, 7, 8);    i=i+1;

        dev1_memory[i] = lui(8, TEST_PT_3[127:108]); i=i+1;
        dev1_memory[i] = ori(8, 8, TEST_PT_3[107:96]); i=i+1;
        dev1_memory[i] = addi(7, 0, 3);           i=i+1;
        dev1_memory[i] = aes_load_pt(0, 7, 8);    i=i+1;

        // Reload key
        dev1_memory[i] = lui(8, AES_KEY[31:12]);  i=i+1;
        dev1_memory[i] = ori(8, 8, AES_KEY[11:0]); i=i+1;
        dev1_memory[i] = addi(7, 0, 0);           i=i+1;
        dev1_memory[i] = aes_load_key(0, 7, 8);   i=i+1;
        dev1_memory[i] = lui(8, AES_KEY[63:44]);  i=i+1;
        dev1_memory[i] = ori(8, 8, AES_KEY[43:32]); i=i+1;
        dev1_memory[i] = addi(7, 0, 1);           i=i+1;
        dev1_memory[i] = aes_load_key(0, 7, 8);   i=i+1;
        dev1_memory[i] = lui(8, AES_KEY[95:76]);  i=i+1;
        dev1_memory[i] = ori(8, 8, AES_KEY[75:64]); i=i+1;
        dev1_memory[i] = addi(7, 0, 2);           i=i+1;
        dev1_memory[i] = aes_load_key(0, 7, 8);   i=i+1;
        dev1_memory[i] = lui(8, AES_KEY[127:108]); i=i+1;
        dev1_memory[i] = ori(8, 8, AES_KEY[107:96]); i=i+1;
        dev1_memory[i] = addi(7, 0, 3);           i=i+1;
        dev1_memory[i] = aes_load_key(0, 7, 8);   i=i+1;

        dev1_memory[i] = aes_start(0, 0, 0);      i=i+1;
        dev1_memory[i] = aes_status(10, 0, 0);    i=i+1;
        dev1_memory[i] = beq(10, 0, -13'd4);      i=i+1;
        dev1_memory[i] = addi(11, 0, 200);        i=i+1;
        dev1_memory[i] = addi(11, 11, -1);        i=i+1;
        dev1_memory[i] = bne(11, 0, -13'd4);      i=i+1;

        // Done - infinite loop
        dev1_memory[i] = jal(0, 21'd0);           i=i+1;

        $display("Firmware loaded: %0d instructions", i);
        $display("Image data: %0d blocks (%0d bytes)", NUM_TEST_BLOCKS, NUM_TEST_BLOCKS * 16);
        $display("");

        // Release reset
        #(CLK_PERIOD * 10);
        resetn = 1;
        $display("Reset released, PicoRV32 starting...");
        $display("");

        // Wait for all blocks to be processed
        $display("Waiting for encryption and SPI transfer...");

        // Monitor progress
        fork
            // Progress monitor
            begin
                while (blocks_decrypted < NUM_TEST_BLOCKS && cycle_count < TIMEOUT_CYCLES) begin
                    @(posedge clk);
                    cycle_count = cycle_count + 1;

                    if (cycle_count % 10000 == 0)
                        $display("  Cycle %0d: Received=%0d, Decrypted=%0d",
                                 cycle_count, blocks_received, blocks_decrypted);
                end
            end

            // Encryption counter (monitor SPI activity)
            begin
                @(posedge resetn);
                forever begin
                    @(negedge spi_cs_n);  // SPI transfer started
                    @(posedge spi_cs_n);  // SPI transfer ended
                    blocks_encrypted = blocks_encrypted + 1;
                    $display("  [TX] Block %0d encrypted and transmitted", blocks_encrypted);
                end
            end
        join_any
        disable fork;

        #(CLK_PERIOD * 1000);  // Extra time for last decryption

        $display("");
        $display("================================================================");
        $display("  Results");
        $display("================================================================");
        $display("Blocks encrypted: %0d", blocks_encrypted);
        $display("Blocks received:  %0d", blocks_received);
        $display("Blocks decrypted: %0d", blocks_decrypted);
        $display("");

        //=====================================================
        // Verify Results
        //=====================================================
        $display("Verifying decrypted data...");
        errors = 0;

        for (i = 0; i < NUM_TEST_BLOCKS; i = i + 1) begin
            $display("Block %0d:", i);
            $display("  Original:  %h", original_image[i]);
            $display("  Decrypted: %h", dev2_memory[i]);

            if (original_image[i] !== dev2_memory[i]) begin
                $display("  STATUS: MISMATCH!");
                errors = errors + 1;
            end else begin
                $display("  STATUS: OK");
            end
        end

        $display("");
        if (errors == 0 && blocks_decrypted == NUM_TEST_BLOCKS) begin
            $display("****************************************");
            $display("*  SUCCESS! All blocks match!          *");
            $display("*  Image transferred and decrypted     *");
            $display("*  correctly over SPI!                 *");
            $display("****************************************");
        end else begin
            $display("FAILED: %0d errors, %0d/%0d blocks decrypted",
                     errors, blocks_decrypted, NUM_TEST_BLOCKS);
        end

        $display("");
        $display("Simulation complete at cycle %0d", cycle_count);
        $finish;
    end

    //=========================================================
    // Timeout Watchdog
    //=========================================================
    initial begin
        #(CLK_PERIOD * TIMEOUT_CYCLES);
        $display("");
        $display("ERROR: Simulation timeout after %0d cycles!", TIMEOUT_CYCLES);
        $display("Blocks encrypted: %0d", blocks_encrypted);
        $display("Blocks received:  %0d", blocks_received);
        $display("Blocks decrypted: %0d", blocks_decrypted);
        $finish;
    end

endmodule
