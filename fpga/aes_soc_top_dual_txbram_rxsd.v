`timescale 1ns / 1ps

module aes_soc_top_dual_txbram_rxsd (
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
    localparam [31:0] SD_BASE      = 32'h0200_0000;
    localparam [31:0] SD_END       = 32'h0200_0400;
    localparam [31:0] RXBUF_BASE   = 32'h3000_0000;
    localparam [31:0] RXBUF_END    = 32'h3000_0020;
    localparam [31:0] MAILBOX_BASE = 32'h0400_0000;
    localparam [31:0] MAILBOX_END  = 32'h0400_0020;

    wire btn_start_level;
    wire btn_reset_level;
    wire resetn = ~btn_reset_level;

    wire [31:0] gpio_out_reg;
    wire sd_init_done;
    wire sd_init_err;
    wire sd_busy;
    wire [4:0] sd_debug_state;
    wire [4:0] sd_debug_last;

    wire        tx_mem_valid;
    wire        tx_mem_instr;
    wire        tx_mem_ready;
    wire [31:0] tx_mem_addr;
    wire [31:0] tx_mem_wdata;
    wire [3:0]  tx_mem_wstrb;
    wire [31:0] tx_mem_rdata;
    wire        tx_trap;

    wire        rx_mem_valid;
    wire        rx_mem_instr;
    wire        rx_mem_ready;
    wire [31:0] rx_mem_addr;
    wire [31:0] rx_mem_wdata;
    wire [3:0]  rx_mem_wstrb;
    wire [31:0] rx_mem_rdata;
    wire        rx_trap;

    wire tx_bram_sel = tx_mem_addr < 32'h0000_4000;
    wire tx_mb_sel   = tx_mem_addr >= MAILBOX_BASE && tx_mem_addr < MAILBOX_END;

    wire rx_bram_sel  = rx_mem_addr < 32'h0000_4000;
    wire rx_sd_sel    = rx_mem_addr >= SD_BASE && rx_mem_addr < SD_END;
    wire rx_rxbuf_sel = rx_mem_addr >= RXBUF_BASE && rx_mem_addr < RXBUF_END;
    wire rx_mb_sel    = rx_mem_addr >= MAILBOX_BASE && rx_mem_addr < MAILBOX_END;

    wire        tx_bram_ready;
    wire [31:0] tx_bram_rdata;
    wire        rx_bram_ready;
    wire [31:0] rx_bram_rdata;
    wire        tx_mb_ready;
    wire [31:0] tx_mb_rdata;
    wire        rx_mb_ready;
    wire [31:0] rx_mb_rdata;
    wire        rxbuf_ready;
    wire [31:0] rxbuf_rdata;
    wire        sd_mmio_ready;
    wire [31:0] sd_mmio_rdata;

    wire [7:0] tx_spi_data;
    wire       tx_spi_clk;
    wire       tx_spi_cs_n;
    wire       tx_spi_active;

    wire [7:0] rx_unused_spi_data;
    wire       rx_unused_spi_clk;
    wire       rx_unused_spi_cs_n;
    wire       rx_unused_spi_active;

    wire [127:0] rx_block_data;
    wire         rx_block_valid;
    wire         rx_block_busy;

    wire [3:0] display_digit = sd_init_done ? gpio_out_reg[3:0] : sd_debug_state[3:0];
    wire display_error = sd_init_err | tx_trap | rx_trap | gpio_out_reg[9];

    assign tx_mem_ready = tx_bram_sel ? tx_bram_ready : (tx_mb_sel ? tx_mb_ready : 1'b1);
    assign tx_mem_rdata = tx_bram_sel ? tx_bram_rdata : (tx_mb_sel ? tx_mb_rdata : 32'hDEAD_BEEF);

    assign rx_mem_ready = rx_bram_sel ? rx_bram_ready :
                          (rx_sd_sel ? sd_mmio_ready :
                          (rx_rxbuf_sel ? rxbuf_ready :
                          (rx_mb_sel ? rx_mb_ready : 1'b1)));
    assign rx_mem_rdata = rx_bram_sel ? rx_bram_rdata :
                          (rx_sd_sel ? sd_mmio_rdata :
                          (rx_rxbuf_sel ? rxbuf_rdata :
                          (rx_mb_sel ? rx_mb_rdata : 32'hDEAD_BEEF)));

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
        .trap           (tx_trap),
        .mem_valid      (tx_mem_valid),
        .mem_instr      (tx_mem_instr),
        .mem_ready      (tx_mem_ready),
        .mem_addr       (tx_mem_addr),
        .mem_wdata      (tx_mem_wdata),
        .mem_wstrb      (tx_mem_wstrb),
        .mem_rdata      (tx_mem_rdata),
        .irq            (32'd0),
        .aes_spi_data   (tx_spi_data),
        .aes_spi_clk    (tx_spi_clk),
        .aes_spi_cs_n   (tx_spi_cs_n),
        .aes_spi_active (tx_spi_active)
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
        .ENABLE_AES_DEC       (1)
    ) cpu_rx (
        .clk            (CLK100MHZ),
        .resetn         (resetn),
        .trap           (rx_trap),
        .mem_valid      (rx_mem_valid),
        .mem_instr      (rx_mem_instr),
        .mem_ready      (rx_mem_ready),
        .mem_addr       (rx_mem_addr),
        .mem_wdata      (rx_mem_wdata),
        .mem_wstrb      (rx_mem_wstrb),
        .mem_rdata      (rx_mem_rdata),
        .irq            (32'd0),
        .aes_spi_data   (rx_unused_spi_data),
        .aes_spi_clk    (rx_unused_spi_clk),
        .aes_spi_cs_n   (rx_unused_spi_cs_n),
        .aes_spi_active (rx_unused_spi_active)
    );

    bram_memory #(
        .MEM_SIZE_WORDS (MEM_SIZE_WORDS),
        .MEM_INIT_FILE  ("program_tx_bram_rxsd.hex")
    ) tx_bram_i (
        .clk       (CLK100MHZ),
        .resetn    (resetn),
        .mem_valid (tx_mem_valid && tx_bram_sel),
        .mem_instr (tx_mem_instr),
        .mem_ready (tx_bram_ready),
        .mem_addr  (tx_mem_addr),
        .mem_wdata (tx_mem_wdata),
        .mem_wstrb (tx_mem_wstrb),
        .mem_rdata (tx_bram_rdata)
    );

    bram_memory #(
        .MEM_SIZE_WORDS (MEM_SIZE_WORDS),
        .MEM_INIT_FILE  ("program_rx_bram_rxsd.hex")
    ) rx_bram_i (
        .clk       (CLK100MHZ),
        .resetn    (resetn),
        .mem_valid (rx_mem_valid && rx_bram_sel),
        .mem_instr (rx_mem_instr),
        .mem_ready (rx_bram_ready),
        .mem_addr  (rx_mem_addr),
        .mem_wdata (rx_mem_wdata),
        .mem_wstrb (rx_mem_wstrb),
        .mem_rdata (rx_bram_rdata)
    );

    dual_soc_mailbox mailbox_i (
        .clk         (CLK100MHZ),
        .resetn      (resetn),
        .mem_valid_a (tx_mem_valid && tx_mb_sel),
        .mem_ready_a (tx_mb_ready),
        .mem_addr_a  (tx_mem_addr),
        .mem_wdata_a (tx_mem_wdata),
        .mem_wstrb_a (tx_mem_wstrb),
        .mem_rdata_a (tx_mb_rdata),
        .mem_valid_b (rx_mem_valid && rx_mb_sel),
        .mem_ready_b (rx_mb_ready),
        .mem_addr_b  (rx_mem_addr),
        .mem_wdata_b (rx_mem_wdata),
        .mem_wstrb_b (rx_mem_wstrb),
        .mem_rdata_b (rx_mb_rdata),
        .sd_owner_is_rx()
    );

    sd_phase1_mmio sd_mmio_i (
        .clk         (CLK100MHZ),
        .resetn      (resetn),
        .mem_valid   (rx_mem_valid && rx_sd_sel),
        .mem_ready   (sd_mmio_ready),
        .mem_addr    (rx_mem_addr),
        .mem_wdata   (rx_mem_wdata),
        .mem_wstrb   (rx_mem_wstrb),
        .mem_rdata   (sd_mmio_rdata),
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

    spi_slave_8lane #(
        .SAME_CLK_DOMAIN(1'b1)
    ) spi_rx_i (
        .clk         (CLK100MHZ),
        .resetn      (resetn),
        .spi_clk_in  (tx_spi_clk),
        .spi_data_in (tx_spi_data),
        .spi_cs_n_in (tx_spi_cs_n),
        .rx_data     (rx_block_data),
        .rx_valid    (rx_block_valid),
        .rx_busy     (rx_block_busy),
        .irq_rx      ()
    );

    spi_rx_buffer #(
        .BASE_ADDR (RXBUF_BASE)
    ) rxbuf_i (
        .clk          (CLK100MHZ),
        .resetn       (resetn),
        .mem_valid    (rx_mem_valid && rx_rxbuf_sel),
        .mem_ready    (rxbuf_ready),
        .mem_addr     (rx_mem_addr),
        .mem_wdata    (rx_mem_wdata),
        .mem_wstrb    (rx_mem_wstrb),
        .mem_rdata    (rxbuf_rdata),
        .spi_rx_data  (rx_block_data),
        .spi_rx_valid (rx_block_valid),
        .irq_rx       ()
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
    assign LED[8] = tx_trap;
    assign LED[9] = rx_trap;
    assign LED[10] = tx_spi_active;
    assign LED[11] = rx_block_busy;
    assign LED[12] = ~tx_spi_cs_n;
    assign LED[13] = tx_spi_clk;
    assign LED[14] = tx_spi_data[0];
    assign LED[15] = display_error;

endmodule
