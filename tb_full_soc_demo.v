`timescale 1ns / 1ps

/***************************************************************
 * Full SoC Demonstration
 *
 * Demonstrates the complete encryption → SPI → decryption flow:
 *
 *   [Testbench]                          [SPI Slave + Decrypt]
 *        |                                        |
 *        v                                        v
 *   ┌─────────┐      SPI 8-lane           ┌─────────────┐
 *   │   AES   │ ────────────────────────> │  SPI Slave  │
 *   │ Encrypt │    (auto-transmit)        │   8-lane    │
 *   └─────────┘                           └──────┬──────┘
 *        |                                       |
 *        | plaintext                             | ciphertext
 *        |                                       v
 *        |                                ┌─────────────┐
 *        |                                │    AES      │
 *        |                                │  Decrypt    │
 *        |                                └──────┬──────┘
 *        |                                       |
 *        └───────── Compare ─────────────────────┘
 *
 * Uses the real pcpi_aes module from picorv32.v
 ***************************************************************/

module tb_full_soc_demo;

    parameter CLK_PERIOD = 10;
    parameter NUM_BLOCKS = 4;

    //=========================================================
    // Clock and Reset
    //=========================================================
    reg clk = 0;
    reg resetn = 0;

    always #(CLK_PERIOD/2) clk = ~clk;

    //=========================================================
    // AES Key
    //=========================================================
    localparam [127:0] AES_KEY = 128'h000102030405060708090a0b0c0d0e0f;

    //=========================================================
    // Test Plaintexts
    //=========================================================
    reg [127:0] test_plaintexts [0:NUM_BLOCKS-1];

    initial begin
        test_plaintexts[0] = 128'h00112233445566778899aabbccddeeff;
        test_plaintexts[1] = 128'hffeeddccbbaa99887766554433221100;
        test_plaintexts[2] = 128'h0f1e2d3c4b5a69788796a5b4c3d2e1f0;
        test_plaintexts[3] = 128'hdeadbeefcafebabe0123456789abcdef;
    end

    //=========================================================
    // AES Encryption Module (from picorv32.v)
    //=========================================================
    reg         enc_valid;
    reg  [31:0] enc_insn;
    reg  [31:0] enc_rs1;
    reg  [31:0] enc_rs2;
    wire        enc_wr;
    wire [31:0] enc_rd;
    wire        enc_wait;
    wire        enc_ready;

    // SPI outputs
    wire [7:0]  spi_data;
    wire        spi_clk;
    wire        spi_cs_n;
    wire        spi_active;

    pcpi_aes aes_enc (
        .clk            (clk),
        .resetn         (resetn),
        .pcpi_valid     (enc_valid),
        .pcpi_insn      (enc_insn),
        .pcpi_rs1       (enc_rs1),
        .pcpi_rs2       (enc_rs2),
        .pcpi_wr        (enc_wr),
        .pcpi_rd        (enc_rd),
        .pcpi_wait      (enc_wait),
        .pcpi_ready     (enc_ready),
        .aes_spi_data   (spi_data),
        .aes_spi_clk    (spi_clk),
        .aes_spi_cs_n   (spi_cs_n),
        .aes_spi_active (spi_active)
    );

    //=========================================================
    // SPI Slave Receiver
    //=========================================================
    wire [127:0] rx_data;
    wire         rx_valid;

    spi_slave_8lane spi_rx (
        .clk         (clk),
        .resetn      (resetn),
        .spi_clk_in  (spi_clk),
        .spi_cs_n_in (spi_cs_n),
        .spi_data_in (spi_data),
        .rx_data     (rx_data),
        .rx_valid    (rx_valid),
        .rx_busy     (),
        .irq_rx      ()
    );

    //=========================================================
    // AES Decryption Module
    //=========================================================
    reg  [127:0] dec_ciphertext;
    reg          dec_start;
    wire [127:0] dec_plaintext;
    wire         dec_done;

    ASMD_Decryption aes_dec (
        .done       (dec_done),
        .Dout       (dec_plaintext),
        .encrypted_text_in (dec_ciphertext),
        .key_in     (AES_KEY),
        .decrypt    (dec_start),
        .clock      (clk),
        .reset      (!resetn)
    );

    //=========================================================
    // Capture logic for rx_valid pulse
    //=========================================================
    reg rx_captured;
    reg [127:0] rx_captured_data;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            rx_captured <= 0;
            rx_captured_data <= 0;
        end else begin
            if (rx_valid && !rx_captured) begin
                rx_captured <= 1;
                rx_captured_data <= rx_data;
            end
        end
    end

    //=========================================================
    // AES Instruction Encoding
    //=========================================================
    localparam [6:0] OPCODE_CUSTOM0 = 7'b0001011;
    localparam [2:0] FUNCT3 = 3'b000;
    localparam [6:0] AES_LOAD_PT  = 7'b0100000;
    localparam [6:0] AES_LOAD_KEY = 7'b0100001;
    localparam [6:0] AES_START    = 7'b0100010;
    localparam [6:0] AES_READ     = 7'b0100011;
    localparam [6:0] AES_STATUS   = 7'b0100100;

    function [31:0] make_insn;
        input [6:0] funct7;
        make_insn = {funct7, 5'd0, 5'd0, FUNCT3, 5'd0, OPCODE_CUSTOM0};
    endfunction

    //=========================================================
    // Test Variables
    //=========================================================
    integer block_idx;
    integer word_idx;
    integer errors;
    reg [127:0] current_plaintext;
    reg [127:0] decrypted_result;
    reg [127:0] received_ciphertext;

    //=========================================================
    // VCD Dump
    //=========================================================
    initial begin
        $dumpfile("tb_full_soc_demo.vcd");
        $dumpvars(0, tb_full_soc_demo);
    end

    //=========================================================
    // Task: Execute AES instruction
    //=========================================================
    task aes_exec;
        input [6:0] funct7;
        input [31:0] rs1_val;
        input [31:0] rs2_val;
        begin
            enc_insn = make_insn(funct7);
            enc_rs1 = rs1_val;
            enc_rs2 = rs2_val;
            enc_valid = 1;
            @(posedge clk);
            while (!enc_ready) @(posedge clk);
            enc_valid = 0;
            @(posedge clk);
        end
    endtask

    //=========================================================
    // Task: Load 128-bit value into AES (key or plaintext)
    //=========================================================
    task aes_load_128;
        input [6:0] funct7;
        input [127:0] data;
        begin
            aes_exec(funct7, 32'd0, data[31:0]);
            aes_exec(funct7, 32'd1, data[63:32]);
            aes_exec(funct7, 32'd2, data[95:64]);
            aes_exec(funct7, 32'd3, data[127:96]);
        end
    endtask

    //=========================================================
    // Main Test
    //=========================================================
    initial begin
        $display("");
        $display("================================================================");
        $display("  Full SoC Demonstration");
        $display("  AES Encrypt --> 8-Lane SPI --> SPI Slave --> AES Decrypt");
        $display("================================================================");
        $display("");

        // Initialize
        enc_valid = 0;
        enc_insn = 0;
        enc_rs1 = 0;
        enc_rs2 = 0;
        dec_start = 0;
        dec_ciphertext = 0;
        errors = 0;

        // Reset
        #(CLK_PERIOD * 5);
        resetn = 1;
        #(CLK_PERIOD * 10);

        $display("Key: %h", AES_KEY);
        $display("");

        //=====================================================
        // Process each block
        //=====================================================
        for (block_idx = 0; block_idx < NUM_BLOCKS; block_idx = block_idx + 1) begin
            current_plaintext = test_plaintexts[block_idx];
            $display("--- Block %0d ---", block_idx);
            $display("  Plaintext:  %h", current_plaintext);

            // Reset capture flag
            rx_captured = 0;
            rx_captured_data = 0;

            // Load key
            aes_load_128(AES_LOAD_KEY, AES_KEY);

            // Load plaintext
            aes_load_128(AES_LOAD_PT, current_plaintext);

            // Start encryption
            aes_exec(AES_START, 0, 0);

            // Wait for encryption to complete (poll status)
            begin
                reg [31:0] status;
                status = 0;
                while (status == 0) begin
                    enc_insn = make_insn(AES_STATUS);
                    enc_rs1 = 0;
                    enc_rs2 = 0;
                    enc_valid = 1;
                    @(posedge clk);
                    while (!enc_ready) @(posedge clk);
                    status = enc_rd;
                    enc_valid = 0;
                    @(posedge clk);
                end
            end

            $display("  Encryption done, SPI transmitting...");

            // Wait for SPI transmission to complete
            while (spi_active) @(posedge clk);
            repeat(100) @(posedge clk);  // Extra time for slave to process

            // Get received ciphertext
            if (rx_captured) begin
                received_ciphertext = rx_captured_data;
                $display("  Received:   %h", received_ciphertext);
            end else begin
                $display("  ERROR: SPI receive failed!");
                errors = errors + 1;
                received_ciphertext = 128'hx;
            end

            // Decrypt
            dec_ciphertext = received_ciphertext;
            dec_start = 1;
            @(posedge clk);
            @(posedge clk);
            dec_start = 0;

            wait(dec_done);
            @(posedge clk);
            decrypted_result = dec_plaintext;
            $display("  Decrypted:  %h", decrypted_result);

            // Verify
            if (decrypted_result == current_plaintext) begin
                $display("  Status: PASS");
            end else begin
                $display("  Status: FAIL");
                errors = errors + 1;
            end
            $display("");

            // Wait before next block
            repeat(50) @(posedge clk);
        end

        //=====================================================
        // Summary
        //=====================================================
        $display("================================================================");
        if (errors == 0) begin
            $display("  SUCCESS! All %0d blocks encrypted, transmitted, and", NUM_BLOCKS);
            $display("  decrypted correctly!");
        end else begin
            $display("  FAILED: %0d errors out of %0d blocks", errors, NUM_BLOCKS);
        end
        $display("================================================================");
        $display("");

        #(CLK_PERIOD * 100);
        $finish;
    end

    //=========================================================
    // Timeout
    //=========================================================
    initial begin
        #(CLK_PERIOD * 500000);
        $display("TIMEOUT!");
        $finish;
    end

endmodule
