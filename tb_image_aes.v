`timescale 1ns / 1ps

/***************************************************************
 * Image Encryption/Decryption Testbench
 *
 * This testbench demonstrates end-to-end image processing:
 * 1. Load image data from hex file into memory
 * 2. Encrypt each 128-bit block using AES-128
 * 3. Decrypt each block back (loopback test)
 * 4. Verify decrypted data matches original
 * 5. Dump results to hex files
 *
 * Usage:
 *   1. Convert image:  python3 scripts/image_to_hex.py image.png image_input.hex
 *   2. Run simulation: vvp tb_image_aes.vvp
 *   3. Convert back:   python3 scripts/hex_to_image.py image_decrypted.hex recovered.png
 ***************************************************************/

module tb_image_aes;

    //=========================================================
    // Parameters
    //=========================================================
    parameter CLK_PERIOD = 10;              // 100 MHz
    parameter MAX_BLOCKS = 4096;            // Max 64KB image (4096 * 16 bytes)

    //=========================================================
    // Test Configuration - EDIT THESE
    //=========================================================
    // AES-128 Key (same key for encrypt and decrypt)
    reg [127:0] aes_key = 128'h000102030405060708090a0b0c0d0e0f;

    //=========================================================
    // Clock and Reset
    //=========================================================
    reg clk = 0;
    reg reset = 1;

    always #(CLK_PERIOD/2) clk = ~clk;

    //=========================================================
    // Memory for Image Data
    //=========================================================
    reg [127:0] input_data   [0:MAX_BLOCKS-1];  // Original image
    reg [127:0] encrypted    [0:MAX_BLOCKS-1];  // After encryption
    reg [127:0] decrypted    [0:MAX_BLOCKS-1];  // After decryption

    integer num_blocks;
    reg [127:0] metadata_block;
    integer original_file_size;

    //=========================================================
    // AES Encryption Module Signals
    //=========================================================
    reg  [127:0] enc_plaintext;
    reg  [127:0] enc_key;
    reg          enc_start;
    wire [127:0] enc_ciphertext;
    wire         enc_done;

    //=========================================================
    // AES Decryption Module Signals
    //=========================================================
    reg  [127:0] dec_ciphertext;
    reg  [127:0] dec_key;
    reg          dec_start;
    wire [127:0] dec_plaintext;
    wire         dec_done;

    //=========================================================
    // Instantiate AES Encryption Module
    //=========================================================
    ASMD_Encryption aes_enc (
        .done       (enc_done),
        .Dout       (enc_ciphertext),
        .plain_text_in (enc_plaintext),
        .key_in     (enc_key),
        .encrypt    (enc_start),
        .clock      (clk),
        .reset      (reset)
    );

    //=========================================================
    // Instantiate AES Decryption Module
    //=========================================================
    ASMD_Decryption aes_dec (
        .done       (dec_done),
        .Dout       (dec_plaintext),
        .encrypted_text_in (dec_ciphertext),
        .key_in     (dec_key),
        .decrypt    (dec_start),
        .clock      (clk),
        .reset      (reset)
    );

    //=========================================================
    // Test Control
    //=========================================================
    integer i, j;
    integer errors;
    integer block_idx;
    reg [127:0] temp_block;

    // State machine
    localparam IDLE = 0, ENCRYPT = 1, WAIT_ENC = 2, DECRYPT = 3, WAIT_DEC = 4, DONE = 5;
    reg [2:0] state;

    //=========================================================
    // VCD Dump
    //=========================================================
    initial begin
        $dumpfile("tb_image_aes.vcd");
        $dumpvars(0, tb_image_aes);
    end

    //=========================================================
    // Main Test Sequence
    //=========================================================
    initial begin
        $display("");
        $display("========================================");
        $display("  Image AES Encryption/Decryption Test");
        $display("========================================");
        $display("");

        // Initialize
        enc_start = 0;
        dec_start = 0;
        enc_key = aes_key;
        dec_key = aes_key;
        enc_plaintext = 0;
        dec_ciphertext = 0;
        errors = 0;
        block_idx = 0;
        state = IDLE;

        // Initialize memories to zero
        for (i = 0; i < MAX_BLOCKS; i = i + 1) begin
            input_data[i] = 128'h0;
            encrypted[i] = 128'h0;
            decrypted[i] = 128'h0;
        end

        // Load image data from hex file
        $display("Loading image data from: image_input.hex");
        $readmemh("image_input.hex", input_data);

        // Extract metadata (first block contains original file size in upper 32 bits)
        metadata_block = input_data[0];
        original_file_size = metadata_block[127:96];
        $display("Metadata block: %h", metadata_block);
        $display("Original file size: %0d bytes", original_file_size);

        // Debug: show first few data blocks
        $display("Data block 1: %h", input_data[1]);
        $display("Data block 2: %h", input_data[2]);

        // Calculate number of blocks from file size
        num_blocks = ((original_file_size + 15) / 16) + 1;  // +1 for metadata block

        // Sanity check
        if (original_file_size == 0 || num_blocks < 2) begin
            $display("ERROR: Invalid metadata. Check hex file format.");
            $display("Expected format: 32 hex chars per line (128 bits)");
            $finish;
        end

        $display("Number of blocks to process: %0d (including metadata)", num_blocks);
        $display("");

        // Release reset
        #(CLK_PERIOD * 5);
        reset = 0;
        #(CLK_PERIOD * 2);

        //=====================================================
        // PHASE 1: Encrypt all blocks
        //=====================================================
        $display("--- PHASE 1: ENCRYPTION ---");

        // Copy metadata block as-is (don't encrypt it)
        encrypted[0] = input_data[0];
        $display("Block 0 (metadata): copied as-is");

        // Encrypt data blocks
        for (block_idx = 1; block_idx < num_blocks; block_idx = block_idx + 1) begin
            // Load plaintext and let it settle
            enc_plaintext = input_data[block_idx];
            @(posedge clk);

            // Start encryption - set BEFORE clock edge
            enc_start = 1;
            @(posedge clk);  // This edge captures start signal
            @(posedge clk);  // Let FSM process
            enc_start = 0;

            // Wait for completion
            wait(enc_done);
            @(posedge clk);

            // Store ciphertext
            encrypted[block_idx] = enc_ciphertext;

            // Debug first few blocks
            if (block_idx <= 3) begin
                $display("Block %0d: plain=%h", block_idx, input_data[block_idx]);
                $display("         cipher=%h", enc_ciphertext);
            end

            // Progress indicator
            if (block_idx % 100 == 0 || block_idx == num_blocks - 1)
                $display("Encrypted block %0d/%0d", block_idx, num_blocks - 1);
        end

        $display("Encryption complete!");
        $display("");

        // Small delay between phases
        #(CLK_PERIOD * 10);

        //=====================================================
        // PHASE 2: Decrypt all blocks (loopback)
        //=====================================================
        $display("--- PHASE 2: DECRYPTION ---");

        // Copy metadata block as-is
        decrypted[0] = encrypted[0];
        $display("Block 0 (metadata): copied as-is");

        // Decrypt data blocks
        for (block_idx = 1; block_idx < num_blocks; block_idx = block_idx + 1) begin
            // Load ciphertext and let it settle
            dec_ciphertext = encrypted[block_idx];
            @(posedge clk);

            // Start decryption - set BEFORE clock edge
            dec_start = 1;
            @(posedge clk);  // This edge captures start signal
            @(posedge clk);  // Let FSM process
            dec_start = 0;

            // Wait for completion
            wait(dec_done);
            @(posedge clk);

            // Store plaintext
            decrypted[block_idx] = dec_plaintext;

            // Debug first few blocks
            if (block_idx <= 3) begin
                $display("Block %0d: cipher=%h", block_idx, encrypted[block_idx]);
                $display("         decrypted=%h", dec_plaintext);
                $display("         expected =%h", input_data[block_idx]);
            end

            // Progress indicator
            if (block_idx % 100 == 0 || block_idx == num_blocks - 1)
                $display("Decrypted block %0d/%0d", block_idx, num_blocks - 1);
        end

        $display("Decryption complete!");
        $display("");

        //=====================================================
        // PHASE 3: Verify Results
        //=====================================================
        $display("--- PHASE 3: VERIFICATION ---");

        errors = 0;
        for (block_idx = 0; block_idx < num_blocks; block_idx = block_idx + 1) begin
            if (input_data[block_idx] !== decrypted[block_idx]) begin
                errors = errors + 1;
                if (errors <= 10) begin  // Only show first 10 errors
                    $display("MISMATCH at block %0d:", block_idx);
                    $display("  Original:  %h", input_data[block_idx]);
                    $display("  Decrypted: %h", decrypted[block_idx]);
                end
            end
        end

        if (errors == 0) begin
            $display("");
            $display("****************************************");
            $display("*  SUCCESS! All %0d blocks match!  *", num_blocks);
            $display("****************************************");
        end else begin
            $display("");
            $display("FAILED: %0d blocks mismatched out of %0d", errors, num_blocks);
        end
        $display("");

        //=====================================================
        // PHASE 4: Write Output Files
        //=====================================================
        $display("--- PHASE 4: WRITING OUTPUT FILES ---");

        // Write encrypted data
        $writememh("image_encrypted.hex", encrypted);
        $display("Written: image_encrypted.hex");

        // Write decrypted data
        $writememh("image_decrypted.hex", decrypted);
        $display("Written: image_decrypted.hex");

        $display("");
        $display("========================================");
        $display("  Test Complete!");
        $display("========================================");
        $display("");
        $display("To recover the image:");
        $display("  python3 scripts/hex_to_image.py image_decrypted.hex recovered_image.png");
        $display("");

        #(CLK_PERIOD * 10);
        $finish;
    end

    //=========================================================
    // Timeout Watchdog
    //=========================================================
    initial begin
        #(CLK_PERIOD * 10000000);  // 10M cycles max
        $display("ERROR: Simulation timeout!");
        $finish;
    end

endmodule
