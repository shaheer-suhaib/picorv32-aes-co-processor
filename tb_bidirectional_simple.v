/*
 * Simplified Bidirectional Communication Testbench
 *
 * Uses direct instruction injection (like original testbench)
 * to test the full flow:
 * - Device A encrypts and sends via SPI Master
 * - Device B receives via SPI Slave
 * - Verify data received correctly
 */

`timescale 1ns/1ps

module tb_bidirectional_simple;

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter CLK_PERIOD = 20;
    parameter MEM_SIZE = 512;

    // =========================================================================
    // Test Vectors (FIPS-197)
    // =========================================================================
    localparam [127:0] PLAINTEXT  = 128'h00112233445566778899aabbccddeeff;
    localparam [127:0] KEY        = 128'h000102030405060708090a0b0c0d0e0f;
    localparam [127:0] CIPHERTEXT = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

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
    // Instantiate Devices with Channel Wiring
    // =========================================================================

    aes_soc_device #(.MEM_SIZE_WORDS(MEM_SIZE)) device_a (
        .clk            (clk),
        .resetn         (resetn),
        .trap           (trap_a),
        .spi_tx_data    (a_tx_data),
        .spi_tx_clk     (a_tx_clk),
        .spi_tx_cs_n    (a_tx_cs_n),
        .spi_tx_active  (a_tx_active),
        .spi_rx_clk_in  (b_tx_clk),
        .spi_rx_data_in (b_tx_data),
        .spi_rx_cs_n_in (b_tx_cs_n),
        .spi_rx_irq     ()
    );

    aes_soc_device #(.MEM_SIZE_WORDS(MEM_SIZE)) device_b (
        .clk            (clk),
        .resetn         (resetn),
        .trap           (trap_b),
        .spi_tx_data    (b_tx_data),
        .spi_tx_clk     (b_tx_clk),
        .spi_tx_cs_n    (b_tx_cs_n),
        .spi_tx_active  (b_tx_active),
        .spi_rx_clk_in  (a_tx_clk),
        .spi_rx_data_in (a_tx_data),
        .spi_rx_cs_n_in (a_tx_cs_n),
        .spi_rx_irq     (b_rx_irq)
    );

    // =========================================================================
    // SPI Capture on Channel 1 (A → B) - for debug/monitoring
    // Note: The actual received data in Device B's RX buffer is the authoritative source
    // =========================================================================
    reg [7:0]   ch1_bytes [0:15];
    reg [4:0]   ch1_count = 0;
    reg         ch1_prev_clk = 0;
    wire [127:0] ch1_captured;

    // Assemble captured bytes into 128-bit value (little-endian)
    assign ch1_captured = {ch1_bytes[15], ch1_bytes[14], ch1_bytes[13], ch1_bytes[12],
                           ch1_bytes[11], ch1_bytes[10], ch1_bytes[9],  ch1_bytes[8],
                           ch1_bytes[7],  ch1_bytes[6],  ch1_bytes[5],  ch1_bytes[4],
                           ch1_bytes[3],  ch1_bytes[2],  ch1_bytes[1],  ch1_bytes[0]};

    always @(posedge clk) begin
        ch1_prev_clk <= a_tx_clk;
        if (!a_tx_cs_n && a_tx_clk && !ch1_prev_clk) begin
            if (ch1_count < 16) begin
                ch1_bytes[ch1_count] <= a_tx_data;
            end
            ch1_count <= ch1_count + 1;
        end
        if (a_tx_cs_n) ch1_count <= 0;
    end

    integer j;
    initial begin
        for (j = 0; j < 16; j = j + 1)
            ch1_bytes[j] = 8'h00;
    end

    // =========================================================================
    // Instruction Encoding Functions
    // =========================================================================

    // ADDI: rd = rs1 + imm
    function [31:0] encode_addi;
        input [4:0] rd;
        input [4:0] rs1;
        input [11:0] imm;
        begin
            encode_addi = {imm, rs1, 3'b000, rd, 7'b0010011};
        end
    endfunction

    // LW: rd = mem[rs1 + offset]
    function [31:0] encode_lw;
        input [4:0] rd;
        input [4:0] rs1;
        input [11:0] offset;
        begin
            encode_lw = {offset, rs1, 3'b010, rd, 7'b0000011};
        end
    endfunction

    // AES custom instruction: funct7 | rs2 | rs1 | funct3=000 | rd | opcode=0001011
    function [31:0] encode_aes;
        input [6:0] funct7;
        input [4:0] rs2;
        input [4:0] rs1;
        input [4:0] rd;
        begin
            encode_aes = {funct7, rs2, rs1, 3'b000, rd, 7'b0001011};
        end
    endfunction

    // JAL: rd = PC+4; PC = PC + offset
    function [31:0] encode_jal;
        input [4:0] rd;
        input signed [20:0] offset;
        begin
            encode_jal = {offset[20], offset[10:1], offset[11], offset[19:12], rd, 7'b1101111};
        end
    endfunction

    // AES funct7 codes
    localparam AES_LOAD_PT  = 7'b0100000;
    localparam AES_LOAD_KEY = 7'b0100001;
    localparam AES_START    = 7'b0100010;

    // NOP
    localparam [31:0] NOP = 32'h00000013;

    // =========================================================================
    // Load Device A Program - Encrypt Plaintext (using LW from memory)
    // =========================================================================
    task load_program_a;
        integer i;
        begin
            // Initialize memory
            for (i = 0; i < MEM_SIZE; i = i + 1)
                device_a.memory[i] = NOP;

            // === CODE SECTION ===
            // Register allocation:
            //   x1-x3  : Index values 1, 2, 3
            //   x4     : Key base address (0x200)
            //   x5     : Temporary data register
            //   x6     : Plaintext base address (0x100)

            i = 0;

            // Setup registers with constants
            device_a.memory[i] = encode_addi(5'd1, 5'd0, 12'd1);     i = i + 1;  // x1 = 1
            device_a.memory[i] = encode_addi(5'd2, 5'd0, 12'd2);     i = i + 1;  // x2 = 2
            device_a.memory[i] = encode_addi(5'd3, 5'd0, 12'd3);     i = i + 1;  // x3 = 3
            device_a.memory[i] = encode_addi(5'd6, 5'd0, 12'h100);   i = i + 1;  // x6 = 0x100 (PT addr)
            device_a.memory[i] = encode_addi(5'd4, 5'd0, 12'h200);   i = i + 1;  // x4 = 0x200 (KEY addr)

            // Load Plaintext into AES co-processor
            // PT[31:0]
            device_a.memory[i] = encode_lw(5'd5, 5'd6, 12'd0);       i = i + 1;  // lw x5, 0(x6)
            device_a.memory[i] = encode_aes(AES_LOAD_PT, 5'd5, 5'd0, 5'd0); i = i + 1;

            // PT[63:32]
            device_a.memory[i] = encode_lw(5'd5, 5'd6, 12'd4);       i = i + 1;  // lw x5, 4(x6)
            device_a.memory[i] = encode_aes(AES_LOAD_PT, 5'd5, 5'd1, 5'd0); i = i + 1;

            // PT[95:64]
            device_a.memory[i] = encode_lw(5'd5, 5'd6, 12'd8);       i = i + 1;  // lw x5, 8(x6)
            device_a.memory[i] = encode_aes(AES_LOAD_PT, 5'd5, 5'd2, 5'd0); i = i + 1;

            // PT[127:96]
            device_a.memory[i] = encode_lw(5'd5, 5'd6, 12'd12);      i = i + 1;  // lw x5, 12(x6)
            device_a.memory[i] = encode_aes(AES_LOAD_PT, 5'd5, 5'd3, 5'd0); i = i + 1;

            // Load Key into AES co-processor
            // KEY[31:0]
            device_a.memory[i] = encode_lw(5'd5, 5'd4, 12'd0);       i = i + 1;  // lw x5, 0(x4)
            device_a.memory[i] = encode_aes(AES_LOAD_KEY, 5'd5, 5'd0, 5'd0); i = i + 1;

            // KEY[63:32]
            device_a.memory[i] = encode_lw(5'd5, 5'd4, 12'd4);       i = i + 1;  // lw x5, 4(x4)
            device_a.memory[i] = encode_aes(AES_LOAD_KEY, 5'd5, 5'd1, 5'd0); i = i + 1;

            // KEY[95:64]
            device_a.memory[i] = encode_lw(5'd5, 5'd4, 12'd8);       i = i + 1;  // lw x5, 8(x4)
            device_a.memory[i] = encode_aes(AES_LOAD_KEY, 5'd5, 5'd2, 5'd0); i = i + 1;

            // KEY[127:96]
            device_a.memory[i] = encode_lw(5'd5, 5'd4, 12'd12);      i = i + 1;  // lw x5, 12(x4)
            device_a.memory[i] = encode_aes(AES_LOAD_KEY, 5'd5, 5'd3, 5'd0); i = i + 1;

            // Start AES Encryption (triggers SPI auto-send)
            device_a.memory[i] = encode_aes(AES_START, 5'd0, 5'd0, 5'd0); i = i + 1;

            // Infinite loop
            device_a.memory[i] = encode_jal(5'd0, 21'd0); i = i + 1;

            // === DATA SECTION ===
            // Plaintext at 0x100 (word index 64)
            device_a.memory[64] = PLAINTEXT[31:0];     // 0xccddeeff
            device_a.memory[65] = PLAINTEXT[63:32];    // 0x8899aabb
            device_a.memory[66] = PLAINTEXT[95:64];    // 0x44556677
            device_a.memory[67] = PLAINTEXT[127:96];   // 0x00112233

            // Key at 0x200 (word index 128)
            device_a.memory[128] = KEY[31:0];    // 0x0c0d0e0f
            device_a.memory[129] = KEY[63:32];   // 0x08090a0b
            device_a.memory[130] = KEY[95:64];   // 0x04050607
            device_a.memory[131] = KEY[127:96];  // 0x00010203

            $display("Device A: Program loaded (%0d instructions)", i);
            $display("  Plaintext @ 0x100: 0x%08h_%08h_%08h_%08h",
                     device_a.memory[67], device_a.memory[66],
                     device_a.memory[65], device_a.memory[64]);
            $display("  Key @ 0x200:       0x%08h_%08h_%08h_%08h",
                     device_a.memory[131], device_a.memory[130],
                     device_a.memory[129], device_a.memory[128]);
        end
    endtask

    // =========================================================================
    // Load Device B Program - Just idle
    // =========================================================================
    task load_program_b;
        integer i;
        begin
            for (i = 0; i < MEM_SIZE; i = i + 1)
                device_b.memory[i] = NOP;

            device_b.memory[0] = encode_jal(5'd0, 21'd0);  // Infinite loop
            $display("Device B: Idle program loaded");
        end
    endtask

    // =========================================================================
    // Main Test
    // =========================================================================
    initial begin
        $dumpfile("tb_bidirectional_simple.vcd");
        $dumpvars(0, tb_bidirectional_simple);

        $display("");
        $display("================================================================");
        $display("  Bidirectional Communication Test (Simplified)");
        $display("================================================================");
        $display("  Plaintext:  0x%032h", PLAINTEXT);
        $display("  Key:        0x%032h", KEY);
        $display("  Expected:   0x%032h", CIPHERTEXT);
        $display("================================================================");

        load_program_a();
        load_program_b();

        #100;
        resetn = 1;
        $display("\n[%0t] Reset released", $time);

        // Wait for SPI transfer
        $display("[%0t] Waiting for encryption and SPI transfer...", $time);
        wait(a_tx_active == 1);
        $display("[%0t] SPI transfer started", $time);
        wait(a_tx_active == 0);
        $display("[%0t] SPI transfer complete", $time);

        #(CLK_PERIOD * 50);

        // Results
        $display("");
        $display("================================================================");
        $display("  Results");
        $display("================================================================");
        $display("  Transmitted (captured): 0x%032h", ch1_captured);
        $display("  Expected ciphertext:    0x%032h", CIPHERTEXT);

        if (ch1_captured == CIPHERTEXT) begin
            $display("  [PASS] Ciphertext transmitted correctly!");
        end else begin
            $display("  [FAIL] Ciphertext mismatch!");
        end

        $display("");
        $display("  Device B RX ready: %b", device_b.rx_buffer_inst.rx_data_ready);
        $display("  Device B RX data:  0x%032h", device_b.rx_buffer_inst.rx_data_buffer);

        if (device_b.rx_buffer_inst.rx_data_buffer == CIPHERTEXT) begin
            $display("  [PASS] Device B received ciphertext correctly!");
        end else begin
            $display("  [FAIL] Device B received wrong data!");
        end

        $display("================================================================");
        $finish;
    end

    // Timeout
    initial begin
        #2000000;
        $display("[TIMEOUT]");
        $finish;
    end

endmodule
