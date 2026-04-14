/*
 * Testbench: Full Receive and Decrypt Path
 *
 * Tests the complete receiver flow:
 * 1. External SPI master sends ciphertext
 * 2. SPI Slave receives and stores in RX buffer
 * 3. CPU reads ciphertext from RX buffer
 * 4. CPU loads ciphertext into AES decryption co-processor
 * 5. CPU starts decryption and reads plaintext
 * 6. Verify plaintext matches original
 *
 * Uses FIPS-197 test vectors.
 */

`timescale 1ns/1ps

module tb_receive_decrypt;

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter CLK_PERIOD = 20;  // 50 MHz
    parameter MEM_SIZE = 512;

    // =========================================================================
    // Test Vectors (FIPS-197)
    // =========================================================================
    // Plaintext:  0x00112233445566778899aabbccddeeff
    // Key:        0x000102030405060708090a0b0c0d0e0f
    // Ciphertext: 0x69c4e0d86a7b0430d8cdb78070b4c55a

    wire [127:0] expected_plaintext  = 128'h00112233445566778899aabbccddeeff;
    wire [127:0] aes_key             = 128'h000102030405060708090a0b0c0d0e0f;
    wire [127:0] ciphertext          = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

    // =========================================================================
    // Clock and Reset
    // =========================================================================
    reg clk = 0;
    reg resetn = 0;

    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // External SPI Master Signals (simulated sender)
    // =========================================================================
    reg        ext_spi_clk = 0;
    reg [7:0]  ext_spi_data = 0;
    reg        ext_spi_cs_n = 1;

    // =========================================================================
    // SPI Slave <-> RX Buffer Interface
    // =========================================================================
    wire [127:0] spi_rx_data;
    wire         spi_rx_valid;
    wire         spi_rx_busy;
    wire         spi_irq;

    // =========================================================================
    // Memory Bus for RX Buffer
    // =========================================================================
    reg         rxbuf_mem_valid = 0;
    wire        rxbuf_mem_ready;
    reg  [31:0] rxbuf_mem_addr = 0;
    reg  [31:0] rxbuf_mem_wdata = 0;
    reg  [3:0]  rxbuf_mem_wstrb = 0;
    wire [31:0] rxbuf_mem_rdata;

    // =========================================================================
    // AES Decryption PCPI Interface
    // =========================================================================
    reg         pcpi_valid = 0;
    reg  [31:0] pcpi_insn = 0;
    reg  [31:0] pcpi_rs1 = 0;
    reg  [31:0] pcpi_rs2 = 0;
    wire        pcpi_wr;
    wire [31:0] pcpi_rd;
    wire        pcpi_wait;
    wire        pcpi_ready;

    // =========================================================================
    // DUT Instantiations
    // =========================================================================

    // SPI Slave
    spi_slave_8lane spi_slave (
        .clk         (clk),
        .resetn      (resetn),
        .spi_clk_in  (ext_spi_clk),
        .spi_data_in (ext_spi_data),
        .spi_cs_n_in (ext_spi_cs_n),
        .rx_data     (spi_rx_data),
        .rx_valid    (spi_rx_valid),
        .rx_busy     (spi_rx_busy),
        .irq_rx      (spi_irq)
    );

    // RX Buffer
    spi_rx_buffer #(
        .BASE_ADDR(32'h3000_0000)
    ) rx_buffer (
        .clk          (clk),
        .resetn       (resetn),
        .mem_valid    (rxbuf_mem_valid),
        .mem_ready    (rxbuf_mem_ready),
        .mem_addr     (rxbuf_mem_addr),
        .mem_wdata    (rxbuf_mem_wdata),
        .mem_wstrb    (rxbuf_mem_wstrb),
        .mem_rdata    (rxbuf_mem_rdata),
        .spi_rx_data  (spi_rx_data),
        .spi_rx_valid (spi_rx_valid),
        .irq_rx       ()
    );

    // AES Decryption Co-processor
    pcpi_aes_dec aes_dec (
        .clk        (clk),
        .resetn     (resetn),
        .pcpi_valid (pcpi_valid),
        .pcpi_insn  (pcpi_insn),
        .pcpi_rs1   (pcpi_rs1),
        .pcpi_rs2   (pcpi_rs2),
        .pcpi_wr    (pcpi_wr),
        .pcpi_rd    (pcpi_rd),
        .pcpi_wait  (pcpi_wait),
        .pcpi_ready (pcpi_ready)
    );

    // =========================================================================
    // Test Data - Ciphertext bytes (little-endian)
    // =========================================================================
    reg [7:0] ct_bytes [0:15];

    initial begin
        // Ciphertext: 0x69c4e0d86a7b0430d8cdb78070b4c55a (little-endian)
        ct_bytes[0]  = 8'h5a;
        ct_bytes[1]  = 8'hc5;
        ct_bytes[2]  = 8'hb4;
        ct_bytes[3]  = 8'h70;
        ct_bytes[4]  = 8'h80;
        ct_bytes[5]  = 8'hb7;
        ct_bytes[6]  = 8'hcd;
        ct_bytes[7]  = 8'hd8;
        ct_bytes[8]  = 8'h30;
        ct_bytes[9]  = 8'h04;
        ct_bytes[10] = 8'h7b;
        ct_bytes[11] = 8'h6a;
        ct_bytes[12] = 8'hd8;
        ct_bytes[13] = 8'he0;
        ct_bytes[14] = 8'hc4;
        ct_bytes[15] = 8'h69;
    end

    // =========================================================================
    // SPI Master Task - Send one byte
    // =========================================================================
    task spi_send_byte;
        input [7:0] data;
        begin
            ext_spi_data = data;
            #(CLK_PERIOD);
            ext_spi_clk = 1;
            #(CLK_PERIOD*2);
            ext_spi_clk = 0;
            #(CLK_PERIOD*2);
        end
    endtask

    // =========================================================================
    // SPI Master Task - Send 16 bytes (full ciphertext)
    // =========================================================================
    task spi_send_ciphertext;
        integer i;
        begin
            $display("[%0t] SPI: Starting ciphertext transmission", $time);
            ext_spi_cs_n = 0;
            #(CLK_PERIOD*2);
            for (i = 0; i < 16; i = i + 1) begin
                spi_send_byte(ct_bytes[i]);
            end
            #(CLK_PERIOD*2);
            ext_spi_cs_n = 1;
            $display("[%0t] SPI: Transmission complete", $time);
        end
    endtask

    // =========================================================================
    // CPU Memory Read Task (for RX Buffer)
    // =========================================================================
    reg [31:0] cpu_read_result;

    task cpu_mem_read;
        input [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            rxbuf_mem_valid <= 1;
            rxbuf_mem_addr  <= addr;
            rxbuf_mem_wstrb <= 4'b0000;
            @(posedge clk);
            while (!rxbuf_mem_ready) @(posedge clk);
            data = rxbuf_mem_rdata;
            @(posedge clk);
            rxbuf_mem_valid <= 0;
        end
    endtask

    task cpu_mem_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            rxbuf_mem_valid <= 1;
            rxbuf_mem_addr  <= addr;
            rxbuf_mem_wdata <= data;
            rxbuf_mem_wstrb <= 4'b1111;
            @(posedge clk);
            while (!rxbuf_mem_ready) @(posedge clk);
            @(posedge clk);
            rxbuf_mem_valid <= 0;
        end
    endtask

    // =========================================================================
    // PCPI Instruction Execution Task
    // =========================================================================
    task pcpi_execute;
        input [6:0] funct7;
        input [31:0] rs1_val;
        input [31:0] rs2_val;
        output [31:0] rd_val;
        begin
            @(posedge clk);
            // Build instruction: funct7 | rs2 | rs1 | funct3 | rd | opcode
            // opcode = 0001011 (custom-0), funct3 = 000, rd = x1
            pcpi_insn  <= {funct7, 5'd0, 5'd0, 3'b000, 5'd1, 7'b0001011};
            pcpi_rs1   <= rs1_val;
            pcpi_rs2   <= rs2_val;
            pcpi_valid <= 1;

            // Wait for ready
            @(posedge clk);
            while (!pcpi_ready) @(posedge clk);
            rd_val = pcpi_rd;

            @(posedge clk);
            pcpi_valid <= 0;
            #(CLK_PERIOD*2);
        end
    endtask

    // =========================================================================
    // AES Decryption Instruction Definitions
    // =========================================================================
    localparam FUNCT7_LOAD_CT  = 7'b0101000;
    localparam FUNCT7_LOAD_KEY = 7'b0101001;
    localparam FUNCT7_START    = 7'b0101010;
    localparam FUNCT7_READ     = 7'b0101011;
    localparam FUNCT7_STATUS   = 7'b0101100;

    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    reg [31:0] ct_word0, ct_word1, ct_word2, ct_word3;
    reg [31:0] pt_word0, pt_word1, pt_word2, pt_word3;
    reg [31:0] status;
    reg [127:0] decrypted_plaintext;

    initial begin
        $dumpfile("tb_receive_decrypt.vcd");
        $dumpvars(0, tb_receive_decrypt);

        $display("==========================================================");
        $display("  Full Receive and Decrypt Path Testbench");
        $display("==========================================================");
        $display("  Ciphertext: 0x%032h", ciphertext);
        $display("  Key:        0x%032h", aes_key);
        $display("  Expected:   0x%032h", expected_plaintext);
        $display("==========================================================\n");

        // Reset
        #100;
        resetn = 1;
        $display("[%0t] Reset released\n", $time);
        #100;

        // =====================================================================
        // PHASE 1: Receive ciphertext via SPI
        // =====================================================================
        $display("--- PHASE 1: Receive Ciphertext via SPI ---");
        spi_send_ciphertext();
        #(CLK_PERIOD*10);

        // Check RX status
        cpu_mem_read(32'h3000_0000, cpu_read_result);
        $display("RX_STATUS = %d (expected: 1)", cpu_read_result);
        if (cpu_read_result != 1) begin
            $display("[FAIL] Data not received!");
            $finish;
        end
        $display("[PASS] Ciphertext received via SPI\n");

        // =====================================================================
        // PHASE 2: Read ciphertext from RX Buffer
        // =====================================================================
        $display("--- PHASE 2: Read Ciphertext from RX Buffer ---");

        cpu_mem_read(32'h3000_0004, ct_word0);
        cpu_mem_read(32'h3000_0008, ct_word1);
        cpu_mem_read(32'h3000_000C, ct_word2);
        cpu_mem_read(32'h3000_0010, ct_word3);

        $display("RX_DATA_0 = 0x%08h", ct_word0);
        $display("RX_DATA_1 = 0x%08h", ct_word1);
        $display("RX_DATA_2 = 0x%08h", ct_word2);
        $display("RX_DATA_3 = 0x%08h", ct_word3);

        // Verify ciphertext matches expected
        if ({ct_word3, ct_word2, ct_word1, ct_word0} == ciphertext) begin
            $display("[PASS] Ciphertext matches expected value\n");
        end else begin
            $display("[FAIL] Ciphertext mismatch!");
            $display("  Expected: 0x%032h", ciphertext);
            $display("  Got:      0x%032h", {ct_word3, ct_word2, ct_word1, ct_word0});
            $finish;
        end

        // Clear RX status
        cpu_mem_write(32'h3000_0014, 32'h1);

        // =====================================================================
        // PHASE 3: Load ciphertext into AES Decryption Co-processor
        // =====================================================================
        $display("--- PHASE 3: Load Ciphertext into AES Decryption ---");

        pcpi_execute(FUNCT7_LOAD_CT, 32'd0, ct_word0, status);
        $display("Loaded CT word 0: 0x%08h", ct_word0);

        pcpi_execute(FUNCT7_LOAD_CT, 32'd1, ct_word1, status);
        $display("Loaded CT word 1: 0x%08h", ct_word1);

        pcpi_execute(FUNCT7_LOAD_CT, 32'd2, ct_word2, status);
        $display("Loaded CT word 2: 0x%08h", ct_word2);

        pcpi_execute(FUNCT7_LOAD_CT, 32'd3, ct_word3, status);
        $display("Loaded CT word 3: 0x%08h", ct_word3);
        $display("");

        // =====================================================================
        // PHASE 4: Load key into AES Decryption Co-processor
        // =====================================================================
        $display("--- PHASE 4: Load Key into AES Decryption ---");

        pcpi_execute(FUNCT7_LOAD_KEY, 32'd0, aes_key[31:0], status);
        $display("Loaded KEY word 0: 0x%08h", aes_key[31:0]);

        pcpi_execute(FUNCT7_LOAD_KEY, 32'd1, aes_key[63:32], status);
        $display("Loaded KEY word 1: 0x%08h", aes_key[63:32]);

        pcpi_execute(FUNCT7_LOAD_KEY, 32'd2, aes_key[95:64], status);
        $display("Loaded KEY word 2: 0x%08h", aes_key[95:64]);

        pcpi_execute(FUNCT7_LOAD_KEY, 32'd3, aes_key[127:96], status);
        $display("Loaded KEY word 3: 0x%08h", aes_key[127:96]);
        $display("");

        // =====================================================================
        // PHASE 5: Start decryption
        // =====================================================================
        $display("--- PHASE 5: Start AES Decryption ---");

        pcpi_execute(FUNCT7_START, 32'd0, 32'd0, status);
        $display("Decryption started, waiting for completion...");

        // Poll status
        status = 0;
        while (status == 0) begin
            #(CLK_PERIOD*10);
            pcpi_execute(FUNCT7_STATUS, 32'd0, 32'd0, status);
        end
        $display("Decryption complete!\n");

        // =====================================================================
        // PHASE 6: Read decrypted plaintext
        // =====================================================================
        $display("--- PHASE 6: Read Decrypted Plaintext ---");

        pcpi_execute(FUNCT7_READ, 32'd0, 32'd0, pt_word0);
        pcpi_execute(FUNCT7_READ, 32'd1, 32'd0, pt_word1);
        pcpi_execute(FUNCT7_READ, 32'd2, 32'd0, pt_word2);
        pcpi_execute(FUNCT7_READ, 32'd3, 32'd0, pt_word3);

        decrypted_plaintext = {pt_word3, pt_word2, pt_word1, pt_word0};

        $display("PT_WORD_0 = 0x%08h", pt_word0);
        $display("PT_WORD_1 = 0x%08h", pt_word1);
        $display("PT_WORD_2 = 0x%08h", pt_word2);
        $display("PT_WORD_3 = 0x%08h", pt_word3);
        $display("");
        $display("Decrypted:  0x%032h", decrypted_plaintext);
        $display("Expected:   0x%032h", expected_plaintext);
        $display("");

        // =====================================================================
        // PHASE 7: Verify result
        // =====================================================================
        $display("--- PHASE 7: Verification ---");

        if (decrypted_plaintext == expected_plaintext) begin
            $display("==========================================================");
            $display("  [PASS] DECRYPTION SUCCESSFUL!");
            $display("  Plaintext correctly recovered from ciphertext.");
            $display("==========================================================");
        end else begin
            $display("==========================================================");
            $display("  [FAIL] DECRYPTION FAILED!");
            $display("  Plaintext does not match expected value.");
            $display("==========================================================");
        end

        #500;
        $finish;
    end

    // Timeout
    initial begin
        #500000;
        $display("[TIMEOUT] Simulation took too long!");
        $finish;
    end

endmodule
