`timescale 1ns / 1ps

// Simple single-block AES test to verify modules work correctly
module tb_aes_single;

    reg clk = 0;
    reg reset = 1;

    always #5 clk = ~clk;

    // AES Key (FIPS-197 test vector)
    wire [127:0] key = 128'h000102030405060708090a0b0c0d0e0f;

    // Test plaintexts
    wire [127:0] plaintext1 = 128'h00112233445566778899aabbccddeeff;
    wire [127:0] plaintext2 = 128'hffeeddccbbaa99887766554433221100;

    // Expected ciphertext for plaintext1 (FIPS-197)
    wire [127:0] expected1 = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

    // Encryption signals
    reg  [127:0] enc_plaintext;
    reg          enc_start;
    wire [127:0] enc_ciphertext;
    wire         enc_done;

    // Decryption signals
    reg  [127:0] dec_ciphertext;
    reg          dec_start;
    wire [127:0] dec_plaintext;
    wire         dec_done;

    // Instantiate encryption
    ASMD_Encryption aes_enc (
        .done       (enc_done),
        .Dout       (enc_ciphertext),
        .plain_text_in (enc_plaintext),
        .key_in     (key),
        .encrypt    (enc_start),
        .clock      (clk),
        .reset      (reset)
    );

    // Instantiate decryption
    ASMD_Decryption aes_dec (
        .done       (dec_done),
        .Dout       (dec_plaintext),
        .encrypted_text_in (dec_ciphertext),
        .key_in     (key),
        .decrypt    (dec_start),
        .clock      (clk),
        .reset      (reset)
    );

    reg [127:0] cipher1, cipher2;

    initial begin
        $dumpfile("tb_aes_single.vcd");
        $dumpvars(0, tb_aes_single);

        enc_start = 0;
        dec_start = 0;
        enc_plaintext = 0;
        dec_ciphertext = 0;

        // Release reset
        #100;
        reset = 0;
        #20;

        $display("\n=== AES Single Block Test ===\n");

        //--- Test 1: Encrypt plaintext1 ---
        $display("Test 1: Encrypting FIPS-197 test vector");
        enc_plaintext = plaintext1;
        @(posedge clk);  // Settle

        // Set enc_start BEFORE clock edge so FSM sees it
        enc_start = 1;
        @(posedge clk);  // This edge captures the start signal
        @(posedge clk);  // Let FSM process
        enc_start = 0;

        wait(enc_done);
        #10;
        cipher1 = enc_ciphertext;

        $display("  Plaintext:  %h", plaintext1);
        $display("  Ciphertext: %h", cipher1);
        $display("  Expected:   %h", expected1);
        if (cipher1 == expected1)
            $display("  PASS!\n");
        else
            $display("  FAIL!\n");

        // Wait some cycles before next test
        repeat(5) @(posedge clk);

        //--- Test 2: Encrypt different plaintext ---
        $display("Test 2: Encrypting different plaintext");
        $display("  FSM state before: %d", aes_enc.cu_enc.current);
        $display("  Plain_text reg: %h", aes_enc.dp_enc.plain_text);

        enc_plaintext = plaintext2;
        $display("  Setting enc_plaintext to: %h", plaintext2);
        #20;  // Let plaintext settle

        @(posedge clk);
        $display("  After clock, before enc_start=1:");
        $display("    FSM state: %d, enc_start: %d", aes_enc.cu_enc.current, enc_start);

        // Set enc_start BEFORE clock edge
        enc_start = 1;
        $display("  Set enc_start=1, init=%d", aes_enc.cu_enc.init);
        @(posedge clk);  // This edge captures enc_start=1
        #1;  // Wait for non-blocking assignments to complete
        $display("  After clock with enc_start=1:");
        $display("    FSM state: %d, init: %d", aes_enc.cu_enc.current, aes_enc.cu_enc.init);
        $display("    Plain_text reg now: %h", aes_enc.dp_enc.plain_text);
        @(posedge clk);  // Let FSM process
        enc_start = 0;

        wait(enc_done);
        #10;
        cipher2 = enc_ciphertext;

        $display("  Plaintext:  %h", plaintext2);
        $display("  Ciphertext: %h", cipher2);

        if (cipher2 == cipher1)
            $display("  FAIL - Same ciphertext as Test 1! (Bug: not capturing new plaintext)\n");
        else
            $display("  Ciphertext differs from Test 1 (expected)\n");

        // Wait some cycles
        repeat(5) @(posedge clk);

        //--- Test 3: Decrypt cipher1, should get plaintext1 ---
        $display("Test 3: Decrypting cipher1");
        dec_ciphertext = cipher1;
        @(posedge clk);  // Settle

        dec_start = 1;
        @(posedge clk);  // Capture start
        @(posedge clk);
        dec_start = 0;

        wait(dec_done);
        #10;

        $display("  Ciphertext: %h", cipher1);
        $display("  Decrypted:  %h", dec_plaintext);
        $display("  Expected:   %h", plaintext1);
        if (dec_plaintext == plaintext1)
            $display("  PASS!\n");
        else
            $display("  FAIL!\n");

        // Wait some cycles
        repeat(5) @(posedge clk);

        //--- Test 4: Decrypt cipher2, should get plaintext2 ---
        $display("Test 4: Decrypting cipher2");
        dec_ciphertext = cipher2;
        @(posedge clk);  // Settle

        dec_start = 1;
        @(posedge clk);  // Capture start
        @(posedge clk);
        dec_start = 0;

        wait(dec_done);
        #10;

        $display("  Ciphertext: %h", cipher2);
        $display("  Decrypted:  %h", dec_plaintext);
        $display("  Expected:   %h", plaintext2);
        if (dec_plaintext == plaintext2)
            $display("  PASS!\n");
        else
            $display("  FAIL!\n");

        $display("=== Test Complete ===\n");
        $finish;
    end

    // Timeout
    initial begin
        #100000;
        $display("TIMEOUT!");
        $finish;
    end

endmodule
