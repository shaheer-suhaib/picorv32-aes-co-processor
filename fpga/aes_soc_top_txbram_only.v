`timescale 1ns / 1ps

// TX FPGA top: PicoRV32 encrypts and streams ciphertext out over 8-lane SPI.
// Use with aes_soc_top_rxsd_only.v on the RX FPGA.
module aes_soc_top_txbram_only (
    input  wire        CLK100MHZ,
    input  wire        BTNC,
    input  wire        BTND,

    output wire [7:0]  SPI_DATA,
    output wire        SPI_CLK,
    output wire        SPI_CS_N,

    output wire [15:0] LED,
    output wire [7:0]  AN,
    output wire [6:0]  SEG
);

    localparam integer MEM_SIZE_WORDS = 4096;

    wire btn_start_level;
    wire btn_reset_level;
    wire resetn = ~btn_reset_level;

    wire        mem_valid;
    wire        mem_instr;
    wire        mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    wire [31:0] mem_rdata;
    wire        trap;

    wire bram_sel = mem_addr < 32'h0000_4000;

    wire        bram_ready;
    wire [31:0] bram_rdata;

    wire        spi_active;

    assign mem_ready = bram_sel ? bram_ready : 1'b1;
    assign mem_rdata = bram_sel ? bram_rdata : 32'hDEAD_BEEF;

    debounce db_start (
        .clk       (CLK100MHZ),
        .btn_in    (BTNC),
        .btn_out   (btn_start_level),
        .btn_pulse ()
    );

    debounce db_reset (
        .clk       (CLK100MHZ),
        .btn_in    (BTND),
        .btn_out   (btn_reset_level),
        .btn_pulse ()
    );

    picorv32 #(
        .ENABLE_COUNTERS      (1),
        .ENABLE_COUNTERS64    (1),
        .ENABLE_REGS_16_31    (1),
        .ENABLE_REGS_DUALPORT (1),
        .LATCHED_MEM_RDATA    (0),
        .TWO_STAGE_SHIFT      (1),
        .BARREL_SHIFTER       (0),
        .TWO_CYCLE_COMPARE    (0),
        .TWO_CYCLE_ALU        (0),
        .COMPRESSED_ISA       (1),
        .CATCH_MISALIGN       (1),
        .CATCH_ILLINSN        (1),
        .ENABLE_PCPI          (0),
        .ENABLE_MUL           (1),
        .ENABLE_FAST_MUL      (1),
        .ENABLE_DIV           (1),
        .ENABLE_IRQ           (0),
        .ENABLE_IRQ_QREGS     (0),
        .ENABLE_IRQ_TIMER     (0),
        .ENABLE_TRACE         (0),
        .REGS_INIT_ZERO       (1),
        .PROGADDR_RESET       (32'h0000_0000),
        .PROGADDR_IRQ         (32'h0000_0010),
        .STACKADDR            (32'h0000_4000),
        .ENABLE_AES           (1),
        .ENABLE_AES_DEC       (0)
    ) cpu_tx (
        .clk            (CLK100MHZ),
        .resetn         (resetn),
        .trap           (trap),
        .mem_valid      (mem_valid),
        .mem_instr      (mem_instr),
        .mem_ready      (mem_ready),
        .mem_addr       (mem_addr),
        .mem_wdata      (mem_wdata),
        .mem_wstrb      (mem_wstrb),
        .mem_rdata      (mem_rdata),
        .irq            (32'd0),
        .aes_spi_data   (SPI_DATA),
        .aes_spi_clk    (SPI_CLK),
        .aes_spi_cs_n   (SPI_CS_N),
        .aes_spi_active (spi_active)
    );

    bram_memory #(
        .MEM_SIZE_WORDS (MEM_SIZE_WORDS),
        .MEM_INIT_FILE  ("program_tx_bram_rxsd.hex")
    ) bram_i (
        .clk       (CLK100MHZ),
        .resetn    (resetn),
        .mem_valid (mem_valid && bram_sel),
        .mem_instr (mem_instr),
        .mem_ready (bram_ready),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_wstrb (mem_wstrb),
        .mem_rdata (bram_rdata)
    );

    // Minimal user feedback on TX FPGA.
    seven_seg seg_i (
        .clk        (CLK100MHZ),
        .digit      (4'h0),
        .show_digit (1'b1),
        .init_ok    (1'b1),
        .error_flag (trap),
        .an         (AN),
        .seg        (SEG)
    );

    assign LED[0]  = btn_start_level;
    assign LED[1]  = spi_active;
    assign LED[2]  = ~SPI_CS_N;
    assign LED[3]  = SPI_CLK;
    assign LED[4]  = SPI_DATA[0];
    assign LED[5]  = SPI_DATA[1];
    assign LED[6]  = SPI_DATA[2];
    assign LED[7]  = SPI_DATA[3];
    assign LED[8]  = SPI_DATA[4];
    assign LED[9]  = SPI_DATA[5];
    assign LED[10] = SPI_DATA[6];
    assign LED[11] = SPI_DATA[7];
    assign LED[12] = trap;
    assign LED[15:13] = 3'b000;

endmodule

