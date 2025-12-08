`timescale 1 ns / 1 ps

/*******************************************************************************
 * FPGA Top-Level Module for PicoRV32 with AES Decryption Co-Processor
 * 
 * This module instantiates PicoRV32 CPU with AES decryption enabled and
 * connects it to Block RAM for instruction and data memory.
 * 
 * Usage in Vivado:
 * 1. Add this file and picorv32.v to your project
 * 2. Add all AES decryption files from decryption_files.txt
 * 3. Add aes_decryption.hex as a source file
 * 4. Set this module as top-level
 * 5. Add constraints file (fpga_top_decryption.xdc)
 * 6. Run synthesis and implementation
 *******************************************************************************/

module fpga_top_decryption (
    input  wire clk,           // FPGA clock (typically 50MHz or 100MHz)
    input  wire resetn,         // Reset button (active low)
    output wire trap            // Optional: trap indicator LED
);

    // Memory interface signals
    wire        mem_valid;
    wire        mem_instr;
    reg         mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    reg  [31:0] mem_rdata;

    // PicoRV32 instance with AES decryption enabled
    picorv32 #(
        .ENABLE_COUNTERS     (0),
        .ENABLE_COUNTERS64   (0),
        .ENABLE_REGS_16_31   (1),
        .ENABLE_REGS_DUALPORT(1),
        .ENABLE_MUL          (0),
        .ENABLE_DIV          (0),
        .ENABLE_AES          (0),  // Disable AES encryption
        .ENABLE_AES_DEC      (1),  // Enable AES decryption co-processor
        .ENABLE_IRQ          (0),
        .ENABLE_TRACE        (0),
        .CATCH_MISALIGN      (0),
        .CATCH_ILLINSN       (0)
    ) cpu (
        .clk         (clk),
        .resetn      (resetn),
        .trap        (trap),
        .mem_valid   (mem_valid),
        .mem_instr   (mem_instr),
        .mem_ready   (mem_ready),
        .mem_addr    (mem_addr),
        .mem_wdata   (mem_wdata),
        .mem_wstrb   (mem_wstrb),
        .mem_rdata   (mem_rdata),
        .pcpi_wr     (1'b0),
        .pcpi_rd     (32'b0),
        .pcpi_wait   (1'b0),
        .pcpi_ready  (1'b0),
        .irq         (32'b0)
    );

    // Memory: 4KB (1024 x 32-bit words)
    // Adjust MEM_SIZE if you need more memory
    parameter MEM_SIZE = 1024;
    reg [31:0] memory [0:MEM_SIZE-1];
    
    // Load program from hex file at synthesis time
    initial begin
        $readmemh("aes_decryption.hex", memory);
    end

    // Memory read/write logic
    always @(posedge clk) begin
        mem_ready <= 0;
        if (mem_valid && !mem_ready) begin
            if (mem_addr < (MEM_SIZE * 4)) begin  // Check address range (byte addressable)
                mem_ready <= 1;
                mem_rdata <= memory[mem_addr >> 2];  // Word-aligned access
                
                // Handle writes (byte-enable support)
                if (mem_wstrb[0]) memory[mem_addr >> 2][ 7: 0] <= mem_wdata[ 7: 0];
                if (mem_wstrb[1]) memory[mem_addr >> 2][15: 8] <= mem_wdata[15: 8];
                if (mem_wstrb[2]) memory[mem_addr >> 2][23:16] <= mem_wdata[23:16];
                if (mem_wstrb[3]) memory[mem_addr >> 2][31:24] <= mem_wdata[31:24];
            end else begin
                // Address out of range - return zero
                mem_ready <= 1;
                mem_rdata <= 32'h00000000;
            end
        end
    end

endmodule

