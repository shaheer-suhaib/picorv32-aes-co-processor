`timescale 1ns / 1ps

module tb_pcpi_aes_roundtrip;

    reg clk = 0;
    reg resetn = 0;
    always #5 clk = ~clk;

    reg         enc_valid = 0;
    reg  [31:0] enc_insn = 0;
    reg  [31:0] enc_rs1 = 0;
    reg  [31:0] enc_rs2 = 0;
    wire        enc_wr;
    wire [31:0] enc_rd;
    wire        enc_wait;
    wire        enc_ready;
    wire [7:0]  enc_spi_data;
    wire        enc_spi_clk;
    wire        enc_spi_cs_n;
    wire        enc_spi_active;

    reg         dec_valid = 0;
    reg  [31:0] dec_insn = 0;
    reg  [31:0] dec_rs1 = 0;
    reg  [31:0] dec_rs2 = 0;
    wire        dec_wr;
    wire [31:0] dec_rd;
    wire        dec_wait;
    wire        dec_ready;

    reg [127:0] pt0 = 128'h00280000_00360000_00000000_0C364D42;
    reg [127:0] pt1 = 128'h00000018_00010000_00200000_00200000;
    reg [127:0] key = 128'h00010203_04050607_08090A0B_0C0D0E0F;

    reg [127:0] ct0;
    reg [127:0] ct1;
    reg [127:0] dec0;
    reg [127:0] dec1;
    reg [31:0]  tmp;

    integer errors = 0;

    function [31:0] custom_insn;
        input [6:0] funct7;
        input [4:0] rd;
        input [4:0] rs1_idx;
        input [4:0] rs2_idx;
        begin
            custom_insn = {funct7, rs2_idx, rs1_idx, 3'b000, rd, 7'b0001011};
        end
    endfunction

    task automatic exec_enc;
        input [31:0] insn;
        input [31:0] rs1_val;
        input [31:0] rs2_val;
        output [31:0] rd_val;
        begin
            @(negedge clk);
            enc_insn  <= insn;
            enc_rs1   <= rs1_val;
            enc_rs2   <= rs2_val;
            enc_valid <= 1'b1;
            while (!enc_ready) @(posedge clk);
            rd_val = enc_rd;
            @(negedge clk);
            enc_valid <= 1'b0;
            enc_insn  <= 32'd0;
            enc_rs1   <= 32'd0;
            enc_rs2   <= 32'd0;
        end
    endtask

    task automatic exec_dec;
        input [31:0] insn;
        input [31:0] rs1_val;
        input [31:0] rs2_val;
        output [31:0] rd_val;
        begin
            @(negedge clk);
            dec_insn  <= insn;
            dec_rs1   <= rs1_val;
            dec_rs2   <= rs2_val;
            dec_valid <= 1'b1;
            while (!dec_ready) @(posedge clk);
            rd_val = dec_rd;
            @(negedge clk);
            dec_valid <= 1'b0;
            dec_insn  <= 32'd0;
            dec_rs1   <= 32'd0;
            dec_rs2   <= 32'd0;
        end
    endtask

    task automatic load_enc_key;
        input [127:0] key_words;
        begin
            exec_enc(custom_insn(7'b0100001, 0, 5'd0, 0), 32'd0, key_words[31:0], tmp);
            exec_enc(custom_insn(7'b0100001, 0, 5'd1, 0), 32'd1, key_words[63:32], tmp);
            exec_enc(custom_insn(7'b0100001, 0, 5'd2, 0), 32'd2, key_words[95:64], tmp);
            exec_enc(custom_insn(7'b0100001, 0, 5'd3, 0), 32'd3, key_words[127:96], tmp);
        end
    endtask

    task automatic load_dec_key;
        input [127:0] key_words;
        begin
            exec_dec(custom_insn(7'b0101001, 0, 5'd0, 0), 32'd0, key_words[31:0], tmp);
            exec_dec(custom_insn(7'b0101001, 0, 5'd1, 0), 32'd1, key_words[63:32], tmp);
            exec_dec(custom_insn(7'b0101001, 0, 5'd2, 0), 32'd2, key_words[95:64], tmp);
            exec_dec(custom_insn(7'b0101001, 0, 5'd3, 0), 32'd3, key_words[127:96], tmp);
        end
    endtask

    task automatic encrypt_block;
        input [127:0] pt;
        output [127:0] ct;
        reg [31:0] w0, w1, w2, w3;
        begin
            exec_enc(custom_insn(7'b0100000, 0, 5'd0, 0), 32'd0, pt[31:0], tmp);
            exec_enc(custom_insn(7'b0100000, 0, 5'd1, 0), 32'd1, pt[63:32], tmp);
            exec_enc(custom_insn(7'b0100000, 0, 5'd2, 0), 32'd2, pt[95:64], tmp);
            exec_enc(custom_insn(7'b0100000, 0, 5'd3, 0), 32'd3, pt[127:96], tmp);
            exec_enc(custom_insn(7'b0100010, 0, 5'd0, 0), 32'd0, 32'd0, tmp);
            exec_enc(custom_insn(7'b0100011, 5'd1, 5'd0, 0), 32'd0, 32'd0, w0);
            exec_enc(custom_insn(7'b0100011, 5'd1, 5'd1, 0), 32'd1, 32'd0, w1);
            exec_enc(custom_insn(7'b0100011, 5'd1, 5'd2, 0), 32'd2, 32'd0, w2);
            exec_enc(custom_insn(7'b0100011, 5'd1, 5'd3, 0), 32'd3, 32'd0, w3);
            ct = {w3, w2, w1, w0};
        end
    endtask

    task automatic decrypt_block;
        input [127:0] ct;
        output [127:0] pt;
        reg [31:0] w0, w1, w2, w3;
        begin
            exec_dec(custom_insn(7'b0101000, 0, 5'd0, 0), 32'd0, ct[31:0], tmp);
            exec_dec(custom_insn(7'b0101000, 0, 5'd1, 0), 32'd1, ct[63:32], tmp);
            exec_dec(custom_insn(7'b0101000, 0, 5'd2, 0), 32'd2, ct[95:64], tmp);
            exec_dec(custom_insn(7'b0101000, 0, 5'd3, 0), 32'd3, ct[127:96], tmp);
            exec_dec(custom_insn(7'b0101010, 0, 5'd0, 0), 32'd0, 32'd0, tmp);
            exec_dec(custom_insn(7'b0101100, 5'd1, 5'd0, 0), 32'd0, 32'd0, tmp);
            while (tmp == 32'd0)
                exec_dec(custom_insn(7'b0101100, 5'd1, 5'd0, 0), 32'd0, 32'd0, tmp);
            exec_dec(custom_insn(7'b0101011, 5'd1, 5'd0, 0), 32'd0, 32'd0, w0);
            exec_dec(custom_insn(7'b0101011, 5'd1, 5'd1, 0), 32'd1, 32'd0, w1);
            exec_dec(custom_insn(7'b0101011, 5'd1, 5'd2, 0), 32'd2, 32'd0, w2);
            exec_dec(custom_insn(7'b0101011, 5'd1, 5'd3, 0), 32'd3, 32'd0, w3);
            pt = {w3, w2, w1, w0};
        end
    endtask

    pcpi_aes enc_i (
        .clk(clk),
        .resetn(resetn),
        .pcpi_valid(enc_valid),
        .pcpi_insn(enc_insn),
        .pcpi_rs1(enc_rs1),
        .pcpi_rs2(enc_rs2),
        .pcpi_wr(enc_wr),
        .pcpi_rd(enc_rd),
        .pcpi_wait(enc_wait),
        .pcpi_ready(enc_ready),
        .aes_spi_data(enc_spi_data),
        .aes_spi_clk(enc_spi_clk),
        .aes_spi_cs_n(enc_spi_cs_n),
        .aes_spi_active(enc_spi_active)
    );

    pcpi_aes_dec dec_i (
        .clk(clk),
        .resetn(resetn),
        .pcpi_valid(dec_valid),
        .pcpi_insn(dec_insn),
        .pcpi_rs1(dec_rs1),
        .pcpi_rs2(dec_rs2),
        .pcpi_wr(dec_wr),
        .pcpi_rd(dec_rd),
        .pcpi_wait(dec_wait),
        .pcpi_ready(dec_ready)
    );

    initial begin
        repeat (4) @(posedge clk);
        resetn = 1'b1;

        load_enc_key(key);
        load_dec_key(key);

        encrypt_block(pt0, ct0);
        decrypt_block(ct0, dec0);

        encrypt_block(pt1, ct1);
        decrypt_block(ct1, dec1);

        $display("PT0  = %032x", pt0);
        $display("CT0  = %032x", ct0);
        $display("DEC0 = %032x", dec0);
        $display("PT1  = %032x", pt1);
        $display("CT1  = %032x", ct1);
        $display("DEC1 = %032x", dec1);

        if (dec0 !== pt0) begin
            $display("FAIL: block 0 mismatch");
            errors = errors + 1;
        end

        if (dec1 !== pt1) begin
            $display("FAIL: block 1 mismatch");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: wrapper roundtrip works for two sequential blocks");
        else
            $display("FAIL: %0d mismatches", errors);

        $finish;
    end

endmodule
