`timescale 1ns / 1ps

module tb_single_block;
    parameter CLK_PERIOD = 10;
    parameter MEM_SIZE = 2048;

    reg clk = 0;
    reg resetn = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    wire        trap, mem_valid, mem_instr;
    reg         mem_ready;
    wire [31:0] mem_addr, mem_wdata;
    wire [3:0]  mem_wstrb;
    reg  [31:0] mem_rdata;
    wire [7:0]  spi_data;
    wire        spi_clk, spi_cs_n, spi_active;
    reg [31:0] memory [0:MEM_SIZE-1];
    integer i;

    localparam [127:0] AES_KEY = 128'h000102030405060708090a0b0c0d0e0f;
    localparam [127:0] TEST_PT = 128'h00112233445566778899aabbccddeeff;
    localparam [127:0] EXPECTED_CT = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

    initial begin
        $dumpfile("tb_single_block.vcd");
        $dumpvars(0, tb_single_block);
    end

    picorv32 #(
        .ENABLE_COUNTERS     (0),
        .ENABLE_COUNTERS64   (0),
        .ENABLE_REGS_16_31   (1),
        .ENABLE_REGS_DUALPORT(1),
        .BARREL_SHIFTER      (1),
        .COMPRESSED_ISA      (1),
        .ENABLE_PCPI         (0),
        .ENABLE_MUL          (0),
        .ENABLE_DIV          (0),
        .ENABLE_AES          (1),
        .ENABLE_AES_DEC      (0)
    ) cpu (
        .clk(clk), .resetn(resetn), .trap(trap),
        .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb), .mem_rdata(mem_rdata),
        .aes_spi_data(spi_data), .aes_spi_clk(spi_clk), .aes_spi_cs_n(spi_cs_n), .aes_spi_active(spi_active),
        .mem_la_read(), .mem_la_write(), .mem_la_addr(), .mem_la_wdata(), .mem_la_wstrb(),
        .pcpi_valid(), .pcpi_insn(), .pcpi_rs1(), .pcpi_rs2(),
        .pcpi_wr(1'b0), .pcpi_rd(32'b0), .pcpi_wait(1'b0), .pcpi_ready(1'b0),
        .irq(32'b0), .eoi(), .trace_valid(), .trace_data()
    );

    always @(posedge clk) begin
        mem_ready <= 0;
        if (resetn && mem_valid && !mem_ready) begin
            mem_ready <= 1;
            mem_rdata <= memory[mem_addr[31:2] & (MEM_SIZE-1)];
            if (mem_wstrb[0]) memory[mem_addr[31:2] & (MEM_SIZE-1)][7:0]   <= mem_wdata[7:0];
            if (mem_wstrb[1]) memory[mem_addr[31:2] & (MEM_SIZE-1)][15:8]  <= mem_wdata[15:8];
            if (mem_wstrb[2]) memory[mem_addr[31:2] & (MEM_SIZE-1)][23:16] <= mem_wdata[23:16];
            if (mem_wstrb[3]) memory[mem_addr[31:2] & (MEM_SIZE-1)][31:24] <= mem_wdata[31:24];
        end
    end

    // Monitor SPI transfers
    reg [127:0] spi_received;
    integer spi_count = 0;
    always @(posedge clk) begin
        if (!spi_cs_n && spi_clk) begin
            spi_received <= {spi_data, spi_received[127:8]};
            spi_count <= spi_count + 1;
            if (spi_count == 15) begin
                $display("SPI Transfer Complete: %h", {spi_data, spi_received[127:8]});
            end
        end
        if (spi_cs_n) spi_count <= 0;
    end

    // Instruction encoding functions
    function [31:0] addi; input [4:0] rd, rs1; input [11:0] imm;
        addi = {imm, rs1, 3'b000, rd, 7'b0010011}; endfunction
    function [31:0] lw; input [4:0] rd, rs1; input [11:0] imm;
        lw = {imm, rs1, 3'b010, rd, 7'b0000011}; endfunction
    function [31:0] aes_load_pt; input [4:0] rd, rs1, rs2;
        aes_load_pt = {7'b0100000, rs2, rs1, 3'b000, rd, 7'b0001011}; endfunction
    function [31:0] aes_load_key; input [4:0] rd, rs1, rs2;
        aes_load_key = {7'b0100001, rs2, rs1, 3'b000, rd, 7'b0001011}; endfunction
    function [31:0] aes_start; input [4:0] rd, rs1, rs2;
        aes_start = {7'b0100010, rs2, rs1, 3'b000, rd, 7'b0001011}; endfunction
    function [31:0] jal; input [4:0] rd; input [20:0] imm;
        jal = {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'b1101111}; endfunction

    initial begin
        $display("Single Block AES Test");
        resetn = 0;
        for (i = 0; i < MEM_SIZE; i = i + 1) memory[i] = 32'h00000013;

        // Store data
        memory['h200 >> 2] = AES_KEY[31:0];
        memory['h204 >> 2] = AES_KEY[63:32];
        memory['h208 >> 2] = AES_KEY[95:64];
        memory['h20C >> 2] = AES_KEY[127:96];
        memory['h400 >> 2] = TEST_PT[31:0];
        memory['h404 >> 2] = TEST_PT[63:32];
        memory['h408 >> 2] = TEST_PT[95:64];
        memory['h40C >> 2] = TEST_PT[127:96];

        // Generate firmware
        i = 0;
        memory[i] = addi(3, 0, 12'h200); i=i+1;  // x3 = key addr
        memory[i] = addi(2, 0, 12'h400); i=i+1;  // x2 = pt addr
        // Load PT
        memory[i] = addi(1, 0, 0);       i=i+1;
        memory[i] = lw(5, 2, 12'h000);   i=i+1;
        memory[i] = aes_load_pt(0, 1, 5);i=i+1;
        memory[i] = addi(1, 0, 1);       i=i+1;
        memory[i] = lw(5, 2, 12'h004);   i=i+1;
        memory[i] = aes_load_pt(0, 1, 5);i=i+1;
        memory[i] = addi(1, 0, 2);       i=i+1;
        memory[i] = lw(5, 2, 12'h008);   i=i+1;
        memory[i] = aes_load_pt(0, 1, 5);i=i+1;
        memory[i] = addi(1, 0, 3);       i=i+1;
        memory[i] = lw(5, 2, 12'h00c);   i=i+1;
        memory[i] = aes_load_pt(0, 1, 5);i=i+1;
        // Load KEY
        memory[i] = addi(1, 0, 0);       i=i+1;
        memory[i] = lw(5, 3, 12'h000);   i=i+1;
        memory[i] = aes_load_key(0, 1, 5);i=i+1;
        memory[i] = addi(1, 0, 1);       i=i+1;
        memory[i] = lw(5, 3, 12'h004);   i=i+1;
        memory[i] = aes_load_key(0, 1, 5);i=i+1;
        memory[i] = addi(1, 0, 2);       i=i+1;
        memory[i] = lw(5, 3, 12'h008);   i=i+1;
        memory[i] = aes_load_key(0, 1, 5);i=i+1;
        memory[i] = addi(1, 0, 3);       i=i+1;
        memory[i] = lw(5, 3, 12'h00c);   i=i+1;
        memory[i] = aes_load_key(0, 1, 5);i=i+1;
        // Start encryption
        memory[i] = aes_start(0, 0, 0);  i=i+1;
        // Infinite loop
        memory[i] = jal(0, 21'd0);       i=i+1;

        $display("Firmware: %0d instructions", i);
        #(CLK_PERIOD * 10);
        resetn = 1;
        #(CLK_PERIOD * 1000);
        $display("Test complete");
        $finish;
    end
endmodule
