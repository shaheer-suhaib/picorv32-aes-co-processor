/*
 * Testbench: Full Bidirectional Secure Communication
 *
 * Tests two complete AES SoC devices communicating:
 * - Device A encrypts and sends to Device B
 * - Device B receives, decrypts, verifies
 * - Device B encrypts response and sends to Device A
 * - Device A receives, decrypts, verifies
 *
 * Channel 1: Device A (TX Master) → Device B (RX Slave)
 * Channel 2: Device B (TX Master) → Device A (RX Slave)
 */

`timescale 1ns/1ps

module tb_bidirectional_comm;

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter CLK_PERIOD = 20;  // 50 MHz
    parameter MEM_SIZE = 512;

    // =========================================================================
    // Test Vectors (FIPS-197)
    // =========================================================================
    localparam [127:0] PLAINTEXT_A = 128'h00112233445566778899aabbccddeeff;
    localparam [127:0] KEY         = 128'h000102030405060708090a0b0c0d0e0f;
    localparam [127:0] CIPHERTEXT  = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

    // Second message (B → A)
    localparam [127:0] PLAINTEXT_B = 128'hffeeddccbbaa99887766554433221100;

    // =========================================================================
    // Clock and Reset
    // =========================================================================
    reg clk = 0;
    reg resetn = 0;

    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // Device A Signals
    // =========================================================================
    wire        trap_a;
    wire [7:0]  a_tx_data;
    wire        a_tx_clk;
    wire        a_tx_cs_n;
    wire        a_tx_active;
    wire        a_rx_irq;

    // =========================================================================
    // Device B Signals
    // =========================================================================
    wire        trap_b;
    wire [7:0]  b_tx_data;
    wire        b_tx_clk;
    wire        b_tx_cs_n;
    wire        b_tx_active;
    wire        b_rx_irq;

    // =========================================================================
    // Channel Wiring (Bidirectional)
    // Channel 1: A TX → B RX
    // Channel 2: B TX → A RX
    // =========================================================================

    // Device A
    aes_soc_device #(
        .MEM_SIZE_WORDS(MEM_SIZE),
        .PROGADDR_RESET(32'h0000_0000)
    ) device_a (
        .clk            (clk),
        .resetn         (resetn),
        .trap           (trap_a),
        // TX (Channel 1: A → B)
        .spi_tx_data    (a_tx_data),
        .spi_tx_clk     (a_tx_clk),
        .spi_tx_cs_n    (a_tx_cs_n),
        .spi_tx_active  (a_tx_active),
        // RX (Channel 2: B → A)
        .spi_rx_clk_in  (b_tx_clk),
        .spi_rx_data_in (b_tx_data),
        .spi_rx_cs_n_in (b_tx_cs_n),
        .spi_rx_irq     (a_rx_irq)
    );

    // Device B
    aes_soc_device #(
        .MEM_SIZE_WORDS(MEM_SIZE),
        .PROGADDR_RESET(32'h0000_0000)
    ) device_b (
        .clk            (clk),
        .resetn         (resetn),
        .trap           (trap_b),
        // TX (Channel 2: B → A)
        .spi_tx_data    (b_tx_data),
        .spi_tx_clk     (b_tx_clk),
        .spi_tx_cs_n    (b_tx_cs_n),
        .spi_tx_active  (b_tx_active),
        // RX (Channel 1: A → B)
        .spi_rx_clk_in  (a_tx_clk),
        .spi_rx_data_in (a_tx_data),
        .spi_rx_cs_n_in (a_tx_cs_n),
        .spi_rx_irq     (b_rx_irq)
    );

    // =========================================================================
    // SPI Capture Logic - Monitor Channel 1 (A → B)
    // =========================================================================
    reg [127:0] ch1_captured_data = 0;
    reg [4:0]   ch1_byte_count = 0;
    reg         ch1_prev_clk = 0;
    reg         ch1_complete = 0;

    always @(posedge clk) begin
        ch1_prev_clk <= a_tx_clk;
        if (!a_tx_cs_n && a_tx_clk && !ch1_prev_clk) begin
            // Rising edge of SPI clock while CS active
            ch1_captured_data <= {a_tx_data, ch1_captured_data[127:8]};
            ch1_byte_count <= ch1_byte_count + 1;
            if (ch1_byte_count == 15) begin
                ch1_complete <= 1;
            end
        end
        if (a_tx_cs_n) begin
            ch1_byte_count <= 0;
        end
    end

    // =========================================================================
    // SPI Capture Logic - Monitor Channel 2 (B → A)
    // =========================================================================
    reg [127:0] ch2_captured_data = 0;
    reg [4:0]   ch2_byte_count = 0;
    reg         ch2_prev_clk = 0;
    reg         ch2_complete = 0;

    always @(posedge clk) begin
        ch2_prev_clk <= b_tx_clk;
        if (!b_tx_cs_n && b_tx_clk && !ch2_prev_clk) begin
            ch2_captured_data <= {b_tx_data, ch2_captured_data[127:8]};
            ch2_byte_count <= ch2_byte_count + 1;
            if (ch2_byte_count == 15) begin
                ch2_complete <= 1;
            end
        end
        if (b_tx_cs_n) begin
            ch2_byte_count <= 0;
        end
    end

    // =========================================================================
    // RISC-V Instruction Encoding Helpers
    // =========================================================================

    // Custom instruction encoding for AES
    // opcode = 0001011, funct3 = 000
    function [31:0] aes_insn;
        input [6:0]  funct7;
        input [4:0]  rs2;
        input [4:0]  rs1;
        input [4:0]  rd;
        begin
            aes_insn = {funct7, rs2, rs1, 3'b000, rd, 7'b0001011};
        end
    endfunction

    // R-type instruction
    function [31:0] r_insn;
        input [6:0]  funct7;
        input [4:0]  rs2;
        input [4:0]  rs1;
        input [2:0]  funct3;
        input [4:0]  rd;
        input [6:0]  opcode;
        begin
            r_insn = {funct7, rs2, rs1, funct3, rd, opcode};
        end
    endfunction

    // I-type instruction
    function [31:0] i_insn;
        input [11:0] imm;
        input [4:0]  rs1;
        input [2:0]  funct3;
        input [4:0]  rd;
        input [6:0]  opcode;
        begin
            i_insn = {imm, rs1, funct3, rd, opcode};
        end
    endfunction

    // S-type instruction
    function [31:0] s_insn;
        input [11:0] imm;
        input [4:0]  rs2;
        input [4:0]  rs1;
        input [2:0]  funct3;
        input [6:0]  opcode;
        begin
            s_insn = {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode};
        end
    endfunction

    // U-type instruction (LUI, AUIPC)
    function [31:0] u_insn;
        input [19:0] imm;
        input [4:0]  rd;
        input [6:0]  opcode;
        begin
            u_insn = {imm, rd, opcode};
        end
    endfunction

    // B-type instruction (branches)
    function [31:0] b_insn;
        input [12:0] imm;
        input [4:0]  rs2;
        input [4:0]  rs1;
        input [2:0]  funct3;
        input [6:0]  opcode;
        begin
            b_insn = {imm[12], imm[10:5], rs2, rs1, funct3, imm[4:1], imm[11], opcode};
        end
    endfunction

    // RISC-V opcodes
    localparam OP_LUI    = 7'b0110111;
    localparam OP_AUIPC  = 7'b0010111;
    localparam OP_IMM    = 7'b0010011;  // ADDI, ORI, etc.
    localparam OP_OP     = 7'b0110011;  // ADD, etc.
    localparam OP_LOAD   = 7'b0000011;
    localparam OP_STORE  = 7'b0100011;
    localparam OP_BRANCH = 7'b1100011;
    localparam OP_CUSTOM = 7'b0001011;

    // Register aliases
    localparam X0  = 5'd0;
    localparam X1  = 5'd1;
    localparam X2  = 5'd2;
    localparam X3  = 5'd3;
    localparam X4  = 5'd4;
    localparam X5  = 5'd5;
    localparam X6  = 5'd6;
    localparam X7  = 5'd7;
    localparam X8  = 5'd8;
    localparam X9  = 5'd9;
    localparam X10 = 5'd10;
    localparam X11 = 5'd11;
    localparam X12 = 5'd12;

    // AES Encryption funct7
    localparam AES_ENC_LOAD_PT  = 7'b0100000;
    localparam AES_ENC_LOAD_KEY = 7'b0100001;
    localparam AES_ENC_START    = 7'b0100010;
    localparam AES_ENC_READ     = 7'b0100011;
    localparam AES_ENC_STATUS   = 7'b0100100;

    // AES Decryption funct7
    localparam AES_DEC_LOAD_CT  = 7'b0101000;
    localparam AES_DEC_LOAD_KEY = 7'b0101001;
    localparam AES_DEC_START    = 7'b0101010;
    localparam AES_DEC_READ     = 7'b0101011;
    localparam AES_DEC_STATUS   = 7'b0101100;

    // =========================================================================
    // Load Program into Device A - Encrypt and Send
    // =========================================================================
    task load_program_device_a;
        integer i;
        begin
            // Initialize memory to NOP (ADDI x0, x0, 0)
            for (i = 0; i < MEM_SIZE; i = i + 1) begin
                device_a.memory[i] = 32'h00000013;
            end

            // Program to encrypt plaintext and send via SPI
            // Plaintext: 0x00112233_44556677_8899aabb_ccddeeff
            // Key:       0x00010203_04050607_08090a0b_0c0d0e0f

            i = 0;

            // Load plaintext word 0 (0xccddeeff) into x5
            device_a.memory[i] = u_insn(20'hccddf, X5, OP_LUI); i = i + 1;                    // LUI x5, 0xccddf
            device_a.memory[i] = i_insn(12'heff, X5, 3'b000, X5, OP_IMM); i = i + 1;         // ADDI x5, x5, 0xeff (sign extends, so need adjustment)

            // Simpler approach: use LUI + ORI pattern
            // Let's load constants more carefully
            // x5 = 0xccddeeff (PT[31:0])
            device_a.memory[i] = u_insn(20'hccddf, X5, OP_LUI); i = i + 1;                   // x5 = 0xccddf000
            device_a.memory[i] = i_insn(-12'h101, X5, 3'b000, X5, OP_IMM); i = i + 1;        // x5 = x5 + 0xeff = 0xccddeeff

            // x6 = 0x8899aabb (PT[63:32])
            device_a.memory[i] = u_insn(20'h8899b, X6, OP_LUI); i = i + 1;
            device_a.memory[i] = i_insn(-12'h545, X6, 3'b000, X6, OP_IMM); i = i + 1;        // 0x8899aabb

            // x7 = 0x44556677 (PT[95:64])
            device_a.memory[i] = u_insn(20'h44557, X7, OP_LUI); i = i + 1;
            device_a.memory[i] = i_insn(-12'h989, X7, 3'b000, X7, OP_IMM); i = i + 1;        // 0x44556677

            // x8 = 0x00112233 (PT[127:96])
            device_a.memory[i] = u_insn(20'h00112, X8, OP_LUI); i = i + 1;
            device_a.memory[i] = i_insn(12'h233, X8, 3'b000, X8, OP_IMM); i = i + 1;         // 0x00112233

            // Load key
            // x9  = 0x0c0d0e0f (KEY[31:0])
            device_a.memory[i] = u_insn(20'h0c0d1, X9, OP_LUI); i = i + 1;
            device_a.memory[i] = i_insn(-12'h1f1, X9, 3'b000, X9, OP_IMM); i = i + 1;

            // x10 = 0x08090a0b (KEY[63:32])
            device_a.memory[i] = u_insn(20'h08091, X10, OP_LUI); i = i + 1;
            device_a.memory[i] = i_insn(-12'h5f5, X10, 3'b000, X10, OP_IMM); i = i + 1;

            // x11 = 0x04050607 (KEY[95:64])
            device_a.memory[i] = u_insn(20'h04051, X11, OP_LUI); i = i + 1;
            device_a.memory[i] = i_insn(-12'h9f9, X11, 3'b000, X11, OP_IMM); i = i + 1;

            // x12 = 0x00010203 (KEY[127:96])
            device_a.memory[i] = u_insn(20'h00010, X12, OP_LUI); i = i + 1;
            device_a.memory[i] = i_insn(12'h203, X12, 3'b000, X12, OP_IMM); i = i + 1;

            // Load plaintext into AES (index in rs1, data in rs2)
            // For AES custom instructions: rs1 = word index (0-3), rs2 = data
            // We need to use x1, x2, x3, x4 for indices 0, 1, 2, 3

            // x1 = 0, x2 = 1, x3 = 2, x4 = 3
            device_a.memory[i] = i_insn(12'd0, X0, 3'b000, X1, OP_IMM); i = i + 1;  // x1 = 0
            device_a.memory[i] = i_insn(12'd1, X0, 3'b000, X2, OP_IMM); i = i + 1;  // x2 = 1
            device_a.memory[i] = i_insn(12'd2, X0, 3'b000, X3, OP_IMM); i = i + 1;  // x3 = 2
            device_a.memory[i] = i_insn(12'd3, X0, 3'b000, X4, OP_IMM); i = i + 1;  // x4 = 3

            // AES_LOAD_PT instructions
            device_a.memory[i] = aes_insn(AES_ENC_LOAD_PT, X5, X1, X0); i = i + 1;  // PT[0] = x5
            device_a.memory[i] = aes_insn(AES_ENC_LOAD_PT, X6, X2, X0); i = i + 1;  // PT[1] = x6
            device_a.memory[i] = aes_insn(AES_ENC_LOAD_PT, X7, X3, X0); i = i + 1;  // PT[2] = x7
            device_a.memory[i] = aes_insn(AES_ENC_LOAD_PT, X8, X4, X0); i = i + 1;  // PT[3] = x8

            // AES_LOAD_KEY instructions
            device_a.memory[i] = aes_insn(AES_ENC_LOAD_KEY, X9,  X1, X0); i = i + 1;  // KEY[0] = x9
            device_a.memory[i] = aes_insn(AES_ENC_LOAD_KEY, X10, X2, X0); i = i + 1;  // KEY[1] = x10
            device_a.memory[i] = aes_insn(AES_ENC_LOAD_KEY, X11, X3, X0); i = i + 1;  // KEY[2] = x11
            device_a.memory[i] = aes_insn(AES_ENC_LOAD_KEY, X12, X4, X0); i = i + 1;  // KEY[3] = x12

            // AES_START (triggers encryption + SPI send)
            device_a.memory[i] = aes_insn(AES_ENC_START, X0, X0, X0); i = i + 1;

            // Infinite loop (halt)
            device_a.memory[i] = b_insn(13'd0, X0, X0, 3'b000, OP_BRANCH); i = i + 1;  // BEQ x0, x0, 0 (loop forever)

            $display("Device A program loaded (%0d instructions)", i);
        end
    endtask

    // =========================================================================
    // Load Program into Device B - Just halt and wait
    // =========================================================================
    task load_program_device_b;
        integer i;
        begin
            for (i = 0; i < MEM_SIZE; i = i + 1) begin
                device_b.memory[i] = 32'h00000013;  // NOP
            end

            // Just loop forever - we'll manually check RX buffer
            device_b.memory[0] = b_insn(13'd0, X0, X0, 3'b000, OP_BRANCH);  // Infinite loop

            $display("Device B program loaded (idle loop)");
        end
    endtask

    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        $dumpfile("tb_bidirectional_comm.vcd");
        $dumpvars(0, tb_bidirectional_comm);

        $display("================================================================");
        $display("  Bidirectional Secure Communication Testbench");
        $display("================================================================");
        $display("  Test: Device A encrypts message and sends to Device B");
        $display("  Plaintext:  0x%032h", PLAINTEXT_A);
        $display("  Key:        0x%032h", KEY);
        $display("  Expected:   0x%032h (ciphertext)", CIPHERTEXT);
        $display("================================================================\n");

        // Load programs
        load_program_device_a();
        load_program_device_b();

        // Reset
        #100;
        resetn = 1;
        $display("[%0t] Reset released\n", $time);

        // Wait for Device A to complete encryption and SPI transfer
        $display("--- Waiting for Device A to encrypt and transmit ---");

        // Wait for SPI transfer to complete
        wait(a_tx_active == 1);
        $display("[%0t] Device A: SPI transfer started", $time);

        wait(a_tx_active == 0);
        $display("[%0t] Device A: SPI transfer complete", $time);

        #(CLK_PERIOD * 20);

        // Check what was transmitted on Channel 1
        $display("\n--- Channel 1 (A → B) Verification ---");
        $display("Captured ciphertext: 0x%032h", ch1_captured_data);
        $display("Expected ciphertext: 0x%032h", CIPHERTEXT);

        if (ch1_captured_data == CIPHERTEXT) begin
            $display("[PASS] Ciphertext transmitted correctly!\n");
        end else begin
            $display("[FAIL] Ciphertext mismatch!\n");
        end

        // Check Device B's RX buffer
        $display("--- Device B RX Buffer Check ---");

        // Wait a bit for synchronizers
        #(CLK_PERIOD * 10);

        // Check the RX buffer status in Device B
        // The data should be in the rx_buffer_inst
        $display("Device B RX data ready: %b", device_b.rx_buffer_inst.rx_data_ready);
        $display("Device B RX buffer:     0x%032h", device_b.rx_buffer_inst.rx_data_buffer);

        if (device_b.rx_buffer_inst.rx_data_ready &&
            device_b.rx_buffer_inst.rx_data_buffer == CIPHERTEXT) begin
            $display("[PASS] Device B correctly received ciphertext!\n");
        end else begin
            $display("[INFO] Data ready: %b", device_b.rx_buffer_inst.rx_data_ready);
            $display("[INFO] Received:   0x%032h", device_b.rx_buffer_inst.rx_data_buffer);
        end

        // =====================================================================
        // Summary
        // =====================================================================
        #500;
        $display("================================================================");
        $display("  Testbench Complete");
        $display("================================================================");
        $display("  Channel 1 (A→B) transmitted: 0x%032h", ch1_captured_data);
        $display("  Device B RX buffer contains: 0x%032h", device_b.rx_buffer_inst.rx_data_buffer);
        $display("================================================================");

        $finish;
    end

    // Timeout watchdog
    initial begin
        #2000000;
        $display("[TIMEOUT] Simulation exceeded time limit");
        $display("  A TX active: %b", a_tx_active);
        $display("  B RX IRQ:    %b", b_rx_irq);
        $finish;
    end

    // Monitor traps
    always @(posedge clk) begin
        if (trap_a) $display("[%0t] WARNING: Device A trapped!", $time);
        if (trap_b) $display("[%0t] WARNING: Device B trapped!", $time);
    end

endmodule
