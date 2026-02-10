`timescale 1ns / 1ps
/*******************************************************************
 * BRAM-Based Unified Memory for PicoRV32
 *
 * Features:
 * - Single-port BRAM with byte-write enable
 * - Vivado will infer this as BRAM18K/BRAM36K primitives
 * - Can be initialized from hex file for instructions/data
 * - 1-cycle read latency (standard BRAM behavior)
 *
 * Memory Map:
 *   0x00000000 - 0x00000FFF : Instructions (4 KB)
 *   0x00001000 - 0x00001FFF : Data memory (4 KB)
 *   Total: 8 KB = 2048 words
 *******************************************************************/
module bram_memory #(
    parameter MEM_SIZE_WORDS = 2048,  // 2K words = 8 KB
    parameter MEM_INIT_FILE = ""      // Optional initialization file
) (
    input  wire        clk,
    input  wire        resetn,
    // PicoRV32 Native Memory Interface
    input  wire        mem_valid,
    input  wire        mem_instr,     // 1=instruction fetch, 0=data access
    output reg         mem_ready,
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [3:0]  mem_wstrb,     // Byte write enables
    output reg  [31:0] mem_rdata
);
    // Integer for initialization loop
    integer i;
    
    // BRAM storage - Vivado will infer Block RAM
    (* ram_style = "block" *) reg [31:0] memory [0:MEM_SIZE_WORDS-1];
    
    // Internal address (word-aligned)
    wire [31:0] word_addr = mem_addr >> 2;
    
    // Valid address check
    wire addr_valid = word_addr < MEM_SIZE_WORDS;
    
    // State machine for BRAM read latency handling
    reg mem_valid_q;
    
    //=========================================================
    // Optional: Initialize from hex file
    //=========================================================
    initial begin
        if (MEM_INIT_FILE != "") begin
            $display("[BRAM] Initializing memory from %s", MEM_INIT_FILE);
            $readmemh(MEM_INIT_FILE, memory);
        end else begin
            // Initialize with NOPs if no file provided
            $display("[BRAM] Initializing memory with NOPs");
            for (i = 0; i < MEM_SIZE_WORDS; i = i + 1)
                memory[i] = 32'h00000013;  // NOP (addi x0, x0, 0)
        end
    end
    
    //=========================================================
    // BRAM Access Logic - Optimized for Block RAM Inference
    //=========================================================
    // Memory read/write operations
    always @(posedge clk) begin
        if (mem_valid && !mem_ready && addr_valid) begin
            // Read operation (happens before write in READ_FIRST mode)
            mem_rdata <= memory[word_addr];
            
            // Write operation (byte-wise)
            if (mem_wstrb[0]) memory[word_addr][ 7: 0] <= mem_wdata[ 7: 0];
            if (mem_wstrb[1]) memory[word_addr][15: 8] <= mem_wdata[15: 8];
            if (mem_wstrb[2]) memory[word_addr][23:16] <= mem_wdata[23:16];
            if (mem_wstrb[3]) memory[word_addr][31:24] <= mem_wdata[31:24];
        end
    end
    
    // Control signal management
    always @(posedge clk) begin
        if (!resetn) begin
            mem_ready <= 1'b0;
            mem_valid_q <= 1'b0;
        end else begin
            // Delay ready by 1 cycle to match BRAM read latency
            mem_valid_q <= mem_valid && !mem_ready;
            mem_ready <= mem_valid_q && addr_valid;
            
            // Out of bounds access handling
            if (mem_valid && !mem_ready && !addr_valid) begin
                mem_rdata <= 32'hDEADBEEF;
                $display("[BRAM] ERROR: Out-of-bounds access at time %t: addr=0x%08x, word_addr=%d, max=%d", 
                         $time, mem_addr, word_addr, MEM_SIZE_WORDS-1);
            end
        end
    end

endmodule