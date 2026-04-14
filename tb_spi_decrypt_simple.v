`timescale 1ns / 1ps

/***************************************************************
 * Simplified SPI + Decryption Test
 *
 * Directly tests: SPI Master TX --> SPI Slave RX --> AES Decrypt
 * Bypasses PicoRV32 to verify the communication path works.
 *
 *   Testbench                   SPI Slave           AES Decrypt
 *   (simulates TX)              (receives)          (decrypts)
 *       |                           |                    |
 *       |--- spi_data[7:0] -------->|                    |
 *       |--- spi_clk -------------->|                    |
 *       |--- spi_cs_n ------------->|                    |
 *       |                           |--- rx_data ------->|
 *       |                           |--- rx_valid ------>|
 *       |                           |                    |--- plaintext
 ***************************************************************/

module tb_spi_decrypt_simple;

    parameter CLK_PERIOD = 10;

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
    // Test Data - Known plaintext/ciphertext pairs (FIPS-197)
    //=========================================================
    // Using test vectors we KNOW work from earlier tests
    localparam [127:0] PLAINTEXT_0  = 128'h00112233445566778899aabbccddeeff;
    localparam [127:0] CIPHERTEXT_0 = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

    localparam [127:0] PLAINTEXT_1  = 128'hffeeddccbbaa99887766554433221100;
    // We'll encrypt this to get the ciphertext

    //=========================================================
    // SPI Signals (testbench drives these as master)
    //=========================================================
    reg [7:0] spi_data_out;
    reg       spi_clk_out;
    reg       spi_cs_n_out;

    //=========================================================
    // SPI Slave Outputs
    //=========================================================
    wire [127:0] rx_data;
    wire         rx_valid;

    //=========================================================
    // Decryption Module
    //=========================================================
    reg  [127:0] dec_ciphertext;
    reg          dec_start;
    wire [127:0] dec_plaintext;
    wire         dec_done;

    //=========================================================
    // Instantiate SPI Slave
    //=========================================================
    spi_slave_8lane spi_rx (
        .clk         (clk),
        .resetn      (resetn),
        .spi_clk_in  (spi_clk_out),
        .spi_cs_n_in (spi_cs_n_out),
        .spi_data_in (spi_data_out),
        .rx_data     (rx_data),
        .rx_valid    (rx_valid),
        .rx_busy     (),
        .irq_rx      ()
    );

    //=========================================================
    // Instantiate AES Decryption
    //=========================================================
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
    // Test Variables
    //=========================================================
    integer i;
    integer wait_cycles;
    reg [127:0] received_block;
    reg [127:0] decrypted_block;

    // Capture rx_valid pulse (it's only high for 1 cycle!)
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
                $display("  [CAPTURE] rx_valid pulse! data=%h", rx_data);
            end
        end
    end

    //=========================================================
    // VCD Dump
    //=========================================================
    initial begin
        $dumpfile("tb_spi_decrypt_simple.vcd");
        $dumpvars(0, tb_spi_decrypt_simple);
    end

    //=========================================================
    // Task: Send one byte over 8-lane SPI
    // Need enough system clock cycles for CDC synchronizers (3-stage)
    //=========================================================
    integer byte_num;

    task spi_send_byte;
        input [7:0] data;
        begin
            spi_data_out = data;
            repeat(5) @(posedge clk);  // Data setup time
            spi_clk_out = 1;           // Rising edge - slave samples
            repeat(8) @(posedge clk);  // Hold time for CDC (need 3+ cycles)

            // Debug: show slave status after each byte
            $display("    Byte %d: sent=%h, slave_state=%d, byte_count=%d, edge_det=%b",
                     byte_num, data, spi_rx.state, spi_rx.byte_count,
                     spi_rx.spi_clk_rising_edge);
            byte_num = byte_num + 1;

            spi_clk_out = 0;
            repeat(5) @(posedge clk);  // Between bytes
        end
    endtask

    //=========================================================
    // Task: Send 128-bit block over 8-lane SPI (16 bytes)
    //=========================================================
    task spi_send_block;
        input [127:0] block;
        begin
            byte_num = 0;
            spi_cs_n_out = 0;  // Assert CS
            repeat(10) @(posedge clk);  // CS setup time
            $display("    CS asserted, slave state=%d", spi_rx.state);

            // Send 16 bytes, LSB first (little-endian)
            spi_send_byte(block[7:0]);
            spi_send_byte(block[15:8]);
            spi_send_byte(block[23:16]);
            spi_send_byte(block[31:24]);
            spi_send_byte(block[39:32]);
            spi_send_byte(block[47:40]);
            spi_send_byte(block[55:48]);
            spi_send_byte(block[63:56]);
            spi_send_byte(block[71:64]);
            spi_send_byte(block[79:72]);
            spi_send_byte(block[87:80]);
            spi_send_byte(block[95:88]);
            spi_send_byte(block[103:96]);
            spi_send_byte(block[111:104]);
            spi_send_byte(block[119:112]);
            spi_send_byte(block[127:120]);

            repeat(10) @(posedge clk);  // Hold before deassert
            spi_cs_n_out = 1;  // Deassert CS
            repeat(20) @(posedge clk);  // Wait for rx_valid
        end
    endtask

    //=========================================================
    // Main Test
    //=========================================================
    initial begin
        $display("");
        $display("===========================================");
        $display("  SPI + Decryption Simple Test");
        $display("===========================================");
        $display("");

        // Initialize
        spi_data_out = 8'h00;
        spi_clk_out = 0;
        spi_cs_n_out = 1;
        dec_start = 0;
        dec_ciphertext = 0;

        // Reset
        #(CLK_PERIOD * 5);
        resetn = 1;
        #(CLK_PERIOD * 10);

        //=====================================================
        // Test 1: Send known ciphertext, decrypt, verify
        //=====================================================
        $display("Test 1: Send FIPS-197 ciphertext via SPI");
        $display("  Ciphertext: %h", CIPHERTEXT_0);
        $display("  Expected:   %h", PLAINTEXT_0);

        // Reset capture flag
        rx_captured = 0;
        rx_captured_data = 0;

        // Send ciphertext via SPI
        $display("  Sending block...");
        spi_send_block(CIPHERTEXT_0);

        // Wait for capture
        repeat(50) @(posedge clk);

        if (rx_captured) begin
            $display("  Block captured via rx_valid pulse");
            received_block = rx_captured_data;
        end else begin
            $display("  WARNING: Using rx_data directly (rx_valid pulse missed)");
            received_block = rx_data;
        end
        $display("  Received:   %h", received_block);

        // Decrypt
        dec_ciphertext = received_block;
        dec_start = 1;
        @(posedge clk);
        @(posedge clk);
        dec_start = 0;

        wait(dec_done);
        @(posedge clk);
        decrypted_block = dec_plaintext;
        $display("  Decrypted:  %h", decrypted_block);

        if (decrypted_block == PLAINTEXT_0)
            $display("  PASS!\n");
        else
            $display("  FAIL!\n");

        #(CLK_PERIOD * 20);

        //=====================================================
        // Test 2: Send different ciphertext
        //=====================================================
        // PLAINTEXT_1 = ffeeddccbbaa99887766554433221100
        // with key 000102030405060708090a0b0c0d0e0f
        // Ciphertext = 1b872378795f4ffd772855fc87ca964d (from our earlier test)
        $display("Test 2: Send PLAINTEXT_1's ciphertext via SPI, decrypt");
        $display("  Plaintext:  %h", PLAINTEXT_1);
        $display("  Ciphertext: 1b872378795f4ffd772855fc87ca964d");

        // Reset capture flag
        rx_captured = 0;

        // Send via SPI
        spi_send_block(128'h1b872378795f4ffd772855fc87ca964d);

        // Wait for capture
        repeat(50) @(posedge clk);

        if (rx_captured) begin
            received_block = rx_captured_data;
        end else begin
            received_block = rx_data;
        end
        $display("  Received:   %h", received_block);

        // Decrypt
        dec_ciphertext = received_block;
        dec_start = 1;
        @(posedge clk);
        @(posedge clk);
        dec_start = 0;

        wait(dec_done);
        @(posedge clk);
        decrypted_block = dec_plaintext;
        $display("  Decrypted:  %h", decrypted_block);

        if (decrypted_block == PLAINTEXT_1)
            $display("  PASS!\n");
        else
            $display("  FAIL!\n");

        $display("===========================================");
        $display("  Test Complete");
        $display("===========================================");

        #(CLK_PERIOD * 20);
        $finish;
    end

    // Timeout
    initial begin
        #(CLK_PERIOD * 50000);
        $display("TIMEOUT!");
        $finish;
    end

endmodule
