`timescale 1ns / 1ps

module tb_asmd_dec_pulse;

    reg clk = 0;
    always #5 clk = ~clk;

    reg enc_reset = 1;
    reg enc_start = 0;
    reg [127:0] enc_pt = 0;
    reg [127:0] key = 128'h000102030405060708090a0b0c0d0e0f;
    wire enc_done;
    wire [127:0] enc_out;

    reg dec_reset = 1;
    reg dec_start = 0;
    reg [127:0] dec_ct = 0;
    wire dec_done;
    wire [127:0] dec_out;

    reg [127:0] pt0 = 128'h00112233445566778899aabbccddeeff;
    reg [127:0] pt1 = 128'hffeeddccbbaa99887766554433221100;
    reg [127:0] ct0;
    reg [127:0] ct1;

    integer errors = 0;

    ASMD_Encryption enc_i (
        .done(enc_done),
        .Dout(enc_out),
        .plain_text_in(enc_pt),
        .key_in(key),
        .encrypt(enc_start),
        .clock(clk),
        .reset(enc_reset)
    );

    ASMD_Decryption dec_i (
        .done(dec_done),
        .Dout(dec_out),
        .encrypted_text_in(dec_ct),
        .key_in(key),
        .decrypt(dec_start),
        .clock(clk),
        .reset(dec_reset)
    );

    task automatic run_encrypt;
        input [127:0] pt;
        output [127:0] ct;
        begin
            enc_pt = pt;
            enc_reset = 1;
            @(posedge clk);
            enc_reset = 0;
            @(posedge clk);
            enc_start = 1;
            @(posedge clk);
            enc_start = 0;
            wait (enc_done);
            @(posedge clk);
            ct = enc_out;
        end
    endtask

    task automatic run_decrypt;
        input [127:0] ct;
        input integer pulse_cycles;
        output [127:0] pt;
        begin
            dec_ct = ct;
            repeat (pulse_cycles) begin
                @(posedge clk);
                dec_start = 1;
            end
            @(posedge clk);
            dec_start = 0;
            wait (dec_done);
            @(posedge clk);
            pt = dec_out;
        end
    endtask

    initial begin
        reg [127:0] dec_tmp0;
        reg [127:0] dec_tmp1;

        repeat (4) @(posedge clk);

        run_encrypt(pt0, ct0);
        run_encrypt(pt1, ct1);

        $display("CT0 = %032x", ct0);
        $display("CT1 = %032x", ct1);

        dec_reset = 1;
        @(posedge clk);
        dec_reset = 0;

        run_decrypt(ct0, 1, dec_tmp0);
        run_decrypt(ct1, 1, dec_tmp1);
        $display("1-cycle pulse:");
        $display("  DEC0 = %032x", dec_tmp0);
        $display("  DEC1 = %032x", dec_tmp1);

        dec_reset = 1;
        @(posedge clk);
        dec_reset = 0;

        run_decrypt(ct0, 2, dec_tmp0);
        run_decrypt(ct1, 2, dec_tmp1);
        $display("2-cycle pulse:");
        $display("  DEC0 = %032x", dec_tmp0);
        $display("  DEC1 = %032x", dec_tmp1);

        $finish;
    end

endmodule
