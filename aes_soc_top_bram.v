`timescale 1ns / 1ps

/*******************************************************************
 * Top-Level SoC Module for FPGA Synthesis
 * PicoRV32 + AES Co-Processor + BRAM Memory
 *
 * This module is ready for FPGA synthesis and includes:
 * - PicoRV32 CPU core
 * - AES-128 encryption co-processor
 * - 8KB BRAM for instruction and data memory
 * - 8-lane parallel SPI output
 *
 * Target: Xilinx 7-Series FPGAs (XC7A35T)
 *******************************************************************/

module aes_soc_top_bram (
    input  wire        clk,          // System clock (100 MHz recommended)
    input  wire        resetn,       // Active-low reset (button input)

    // 8-Lane Parallel SPI Output
    output wire [7:0]  spi_data,     // 8 parallel data lanes
    output wire        spi_clk,      // Clock strobe
    output wire        spi_cs_n,     // Chip select (active low)
    output wire        spi_active,   // Transfer indicator

    // Debug outputs (optional - can route to LEDs)
    output wire        cpu_trap,     // CPU trap signal (indicates error)
    output wire [7:0]  debug_leds    // Debug LEDs
);

    //=========================================================
    // Internal Signals
    //=========================================================
    wire        mem_valid;
    wire        mem_instr;
    wire        mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    wire [31:0] mem_rdata;

    //=========================================================
    // PicoRV32 CPU with AES Co-Processor
    //=========================================================
    picorv32 #(
        .ENABLE_COUNTERS(1),
        .ENABLE_REGS_16_31(1),
        .ENABLE_REGS_DUALPORT(1),
        .LATCHED_MEM_RDATA(0),
        .TWO_STAGE_SHIFT(1),
        .TWO_CYCLE_COMPARE(0),
        .TWO_CYCLE_ALU(0),
        .CATCH_MISALIGN(1),
        .CATCH_ILLINSN(1),
        .ENABLE_PCPI(1),
        .ENABLE_MUL(1),
        .ENABLE_DIV(1),
        .ENABLE_FAST_MUL(1),
        .ENABLE_IRQ(0),
        .ENABLE_IRQ_QREGS(0),
        // **Enable AES encryption co-processor**
        .ENABLE_AES(1),
        .ENABLE_AES_DEC(0)
    ) cpu (
        .clk         (clk),
        .resetn      (resetn),
        .trap        (cpu_trap),

        // Memory Interface
        .mem_valid   (mem_valid),
        .mem_instr   (mem_instr),
        .mem_ready   (mem_ready),
        .mem_addr    (mem_addr),
        .mem_wdata   (mem_wdata),
        .mem_wstrb   (mem_wstrb),
        .mem_rdata   (mem_rdata),

        // 8-Lane Parallel SPI Interface
        .aes_spi_data   (spi_data),
        .aes_spi_clk    (spi_clk),
        .aes_spi_cs_n   (spi_cs_n),
        .aes_spi_active (spi_active)
    );

    //=========================================================
    // BRAM Memory (8 KB)
    //=========================================================
    bram_memory #(
        .MEM_SIZE_WORDS(2048),           // 2K words = 8 KB
        .MEM_INIT_FILE("program.hex")    // Initialized from hex file
    ) memory (
        .clk        (clk),
        .resetn     (resetn),
        .mem_valid  (mem_valid),
        .mem_instr  (mem_instr),
        .mem_ready  (mem_ready),
        .mem_addr   (mem_addr),
        .mem_wdata  (mem_wdata),
        .mem_wstrb  (mem_wstrb),
        .mem_rdata  (mem_rdata)
    );

    //=========================================================
    // Debug Output (route to LEDs)
    //=========================================================
    assign debug_leds = {
        cpu_trap,           // LED[7] - Trap indicator (error)
        spi_active,         // LED[6] - SPI transmission active
        1'b0,               // LED[5] - Reserved
        1'b0,               // LED[4] - Reserved
        mem_valid,          // LED[3] - Memory access
        mem_ready,          // LED[2] - Memory ready
        mem_instr,          // LED[1] - Instruction fetch
        resetn              // LED[0] - Reset status
    };

endmodule
