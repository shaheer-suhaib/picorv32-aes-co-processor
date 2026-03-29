`timescale 1ns / 1ps

module aes_soc_top_nexys_loopback_sd (
    input  wire        CLK100MHZ,
    input  wire        BTNC,
    input  wire        BTND,

    output wire        SD_RESET,
    output wire        SD_SCK,
    output wire        SD_CMD,
    input  wire        SD_DAT0,
    output wire        SD_DAT3,

    output wire [15:0] LED,
    output wire [7:0]  AN,
    output wire [6:0]  SEG
);

    localparam integer MEM_SIZE_WORDS = 4096;
    localparam [31:0] RX_MMIO_END = 32'h0300_1100;

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

    wire bram_sel = mem_addr < 32'h0000_4000;
    wire sd_sel   = mem_addr >= 32'h0200_0000 && mem_addr < 32'h0200_0400;
    wire rx_sel   = mem_addr >= 32'h0300_0000 && mem_addr < RX_MMIO_END;

    wire        bram_ready;
    wire [31:0] bram_rdata;
    wire        sd_ready;
    wire [31:0] sd_rdata;
    wire        rx_ready;
    wire [31:0] rx_rdata;

    wire [31:0] gpio_out_reg;
    wire sd_init_done;
    wire sd_init_err;
    wire sd_busy;
    wire [4:0] sd_debug_state;
    wire [4:0] sd_debug_last;
    wire cpu_trap;

    wire [7:0] loop_spi_data;
    wire       loop_spi_clk;
    wire       loop_spi_cs_n;
    wire       loop_spi_active;

    wire       rx_active;
    wire       decrypt_active;
    wire [7:0] stored_blocks;
    wire       rx_overflow;

    wire [3:0] display_digit = sd_init_done ? gpio_out_reg[3:0] : sd_debug_state[3:0];
    wire display_error = sd_init_err | cpu_trap | gpio_out_reg[9] | rx_overflow;

    assign mem_ready = bram_sel ? bram_ready : (sd_sel ? sd_ready : (rx_sel ? rx_ready : 1'b1));
    assign mem_rdata = bram_sel ? bram_rdata : (sd_sel ? sd_rdata : (rx_sel ? rx_rdata : 32'hDEAD_BEEF));

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
    ) cpu (
        .clk            (CLK100MHZ),
        .resetn         (resetn),
        .trap           (cpu_trap),
        .mem_valid      (mem_valid),
        .mem_instr      (mem_instr),
        .mem_ready      (mem_ready),
        .mem_addr       (mem_addr),
        .mem_wdata      (mem_wdata),
        .mem_wstrb      (mem_wstrb),
        .mem_rdata      (mem_rdata),
        .irq            (32'd0),
        .aes_spi_data   (loop_spi_data),
        .aes_spi_clk    (loop_spi_clk),
        .aes_spi_cs_n   (loop_spi_cs_n),
        .aes_spi_active (loop_spi_active)
    );

    bram_memory #(
        .MEM_SIZE_WORDS (MEM_SIZE_WORDS),
        .MEM_INIT_FILE  ("program_loopback.hex")
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

    sd_phase1_mmio sd_mmio_i (
        .clk         (CLK100MHZ),
        .resetn      (resetn),
        .mem_valid   (mem_valid && sd_sel),
        .mem_ready   (sd_ready),
        .mem_addr    (mem_addr),
        .mem_wdata   (mem_wdata),
        .mem_wstrb   (mem_wstrb),
        .mem_rdata   (sd_rdata),
        .btnc_level  (btn_start_level),
        .gpio_out_reg(gpio_out_reg),
        .sd_reset    (SD_RESET),
        .sd_sck      (SD_SCK),
        .sd_cmd      (SD_CMD),
        .sd_dat0     (SD_DAT0),
        .sd_dat3     (SD_DAT3),
        .init_done   (sd_init_done),
        .init_err    (sd_init_err),
        .busy        (sd_busy),
        .debug_state (sd_debug_state),
        .debug_last  (sd_debug_last)
    );

    spi_loopback_receiver #(
        .BASE_ADDR  (32'h0300_0000),
        .MAX_BLOCKS (256)
    ) rx_loop_i (
        .clk            (CLK100MHZ),
        .resetn         (resetn),
        .mem_valid      (mem_valid && rx_sel),
        .mem_ready      (rx_ready),
        .mem_addr       (mem_addr),
        .mem_wdata      (mem_wdata),
        .mem_wstrb      (mem_wstrb),
        .mem_rdata      (rx_rdata),
        .spi_clk_in     (loop_spi_clk),
        .spi_data_in    (loop_spi_data),
        .spi_cs_n_in    (loop_spi_cs_n),
        .rx_active      (rx_active),
        .decrypt_active (decrypt_active),
        .stored_blocks  (stored_blocks),
        .overflow_flag  (rx_overflow)
    );

    seven_seg seg_i (
        .clk        (CLK100MHZ),
        .digit      (display_digit),
        .show_digit (1'b1),
        .init_ok    (sd_init_done),
        .error_flag (display_error),
        .an         (AN),
        .seg        (SEG)
    );

    assign LED[0] = sd_init_done;
    assign LED[1] = gpio_out_reg[4];
    assign LED[2] = gpio_out_reg[5];
    assign LED[3] = gpio_out_reg[6];
    assign LED[4] = gpio_out_reg[7];
    assign LED[5] = gpio_out_reg[8];
    assign LED[6] = sd_busy;
    assign LED[7] = btn_start_level;
    assign LED[8] = cpu_trap;
    assign LED[9] = loop_spi_active;
    assign LED[10] = rx_active;
    assign LED[11] = decrypt_active;
    assign LED[14:12] = stored_blocks[2:0];
    assign LED[15] = display_error;

endmodule
