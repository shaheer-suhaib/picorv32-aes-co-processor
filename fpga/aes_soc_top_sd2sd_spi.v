`timescale 1ns / 1ps

// Single top module for two-FPGA SD-to-SD transfer.
// Program BOTH boards with this bitstream.
// - On the TX board: press BTNC to read image from its SD and transmit via SPI.
// - On the RX board: keep idle; it receives SPI data and writes to its SD.
//
// Wire TX->RX:
//   TX SPI_CLK  -> RX SPI_CLK
//   TX SPI_CS_N -> RX SPI_CS_N
//   TX SPI_DATA[7:0] -> RX SPI_DATA[7:0]
//
// RX board's SPI outputs can be left unconnected.
module aes_soc_top_sd2sd_spi (
    input  wire        CLK100MHZ,
    input  wire        BTNC,
    input  wire        BTND,

    // SPI master outputs (TX direction)
    output wire        SPI_CLK,
    output wire        SPI_CS_N,
    output wire [7:0]  SPI_DATA,

    // SPI slave inputs (RX direction)
    input  wire        SPI_CLK_IN,
    input  wire        SPI_CS_N_IN,
    input  wire [7:0]  SPI_DATA_IN,

    // SD card (on each FPGA)
    output wire        SD_RESET,
    output wire        SD_SCK,
    output wire        SD_CMD,
    input  wire        SD_DAT0,
    output wire        SD_DAT3,

    output wire [15:0] LED,
    output wire [7:0]  AN,
    output wire [6:0]  SEG
);

    localparam ENABLE_MANUAL_SPI_TEST = 1'b0;
    localparam integer MEM_SIZE_WORDS = 4096;
    localparam [31:0] SD_BASE    = 32'h0200_0000;
    localparam [31:0] SD_END     = 32'h0200_0400;
    localparam [31:0] RXBUF_BASE = 32'h3000_0000;
    localparam [31:0] RXBUF_END  = 32'h3000_0020;

    wire btn_start_level;
    wire btn_reset_level;
    wire resetn = ~btn_reset_level;

    wire [31:0] gpio_out_reg;
    wire sd_init_done;
    wire sd_init_err;
    wire sd_busy;
    wire [4:0] sd_debug_state;
    wire [4:0] sd_debug_last;

    wire        mem_valid;
    wire        mem_instr;
    wire        mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    wire [31:0] mem_rdata;
    wire        trap;

    wire bram_sel  = mem_addr < 32'h0000_4000;
    wire sd_sel    = mem_addr >= SD_BASE && mem_addr < SD_END;
    wire rxbuf_sel = mem_addr >= RXBUF_BASE && mem_addr < RXBUF_END;

    wire        bram_ready;
    wire [31:0] bram_rdata;
    wire        rxbuf_ready;
    wire [31:0] rxbuf_rdata;
    wire        sd_mmio_ready;
    wire [31:0] sd_mmio_rdata;

    wire [127:0] rx_block_data;
    wire         rx_block_valid;
    wire         rx_block_busy;

    wire        spi_active;
    // CPU-driven SPI signals (internal wires so we can multiplex for test)
    wire [7:0] cpu_spi_data;
    wire       cpu_spi_clk;
    wire       cpu_spi_cs_n;
    wire       cpu_spi_active;

    wire [3:0] display_digit = sd_init_done ? gpio_out_reg[3:0] : sd_debug_state[3:0];
    wire display_error = sd_init_err | trap | gpio_out_reg[9];

    assign mem_ready = bram_sel ? bram_ready :
                       (sd_sel ? sd_mmio_ready :
                       (rxbuf_sel ? rxbuf_ready : 1'b1));
    assign mem_rdata = bram_sel ? bram_rdata :
                       (sd_sel ? sd_mmio_rdata :
                       (rxbuf_sel ? rxbuf_rdata : 32'hDEAD_BEEF));

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
    ) cpu_i (
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
        .aes_spi_data   (cpu_spi_data),
        .aes_spi_clk    (cpu_spi_clk),
        .aes_spi_cs_n   (cpu_spi_cs_n),
        .aes_spi_active (cpu_spi_active)
    );

    bram_memory #(
        .MEM_SIZE_WORDS (MEM_SIZE_WORDS),
        .MEM_INIT_FILE  ("program_sd2sd.hex")
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
        .mem_ready   (sd_mmio_ready),
        .mem_addr    (mem_addr),
        .mem_wdata   (mem_wdata),
        .mem_wstrb   (mem_wstrb),
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
        .SAME_CLK_DOMAIN(1'b0)
    ) spi_rx_i (
        .clk         (CLK100MHZ),
        .resetn      (resetn),
        .spi_clk_in  (SPI_CLK_IN),
        .spi_data_in (SPI_DATA_IN),
        .spi_cs_n_in (SPI_CS_N_IN),
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
        .mem_valid    (mem_valid && rxbuf_sel),
        .mem_ready    (rxbuf_ready),
        .mem_addr     (mem_addr),
        .mem_wdata    (mem_wdata),
        .mem_wstrb    (mem_wstrb),
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
    assign LED[8] = trap;
    assign LED[9] = rx_block_busy;
    assign LED[10] = cpu_spi_active | manual_active;
    assign LED[11] = ~SPI_CS_N_IN;
    assign LED[12] = (~SPI_CS_N_IN) & SPI_CLK_IN;
    assign LED[13] = (~SPI_CS_N_IN) & SPI_DATA_IN[0];
    assign LED[14] = (~SPI_CS_N_IN) & SPI_DATA_IN[1];
    assign LED[15] = display_error;

    // --- Manual SPI test generator (debug only) ---
    // Pressing BTNC will start a simple 16-byte transfer driven from the
    // top module. The outputs are multiplexed with the CPU/AES outputs so
    // you can verify wiring between TX/RX boards without relying on SD
    // or firmware behavior.
    reg btn_start_prev;
    reg manual_active;
    reg [3:0] manual_byte_idx;
    reg [7:0] manual_byte_cnt;
    reg [7:0] manual_spi_data;
    reg manual_spi_clk;
    reg manual_spi_cs_n;
    reg [15:0] manual_clk_div;

    always @(posedge CLK100MHZ) begin
        if (!resetn) begin
            btn_start_prev <= 1'b0;
            manual_active  <= 1'b0;
            manual_byte_idx<= 4'd0;
            manual_spi_data<= 8'd0;
            manual_spi_clk <= 1'b0;
            manual_spi_cs_n<= 1'b1;
            manual_clk_div <= 16'd0;
        end else begin
            btn_start_prev <= btn_start_level;

            // start on rising edge of button
            if (ENABLE_MANUAL_SPI_TEST && btn_start_level && !btn_start_prev) begin
                manual_active   <= 1'b1;
                manual_byte_idx <= 4'd0;
                manual_byte_cnt <= 8'd0;
                manual_spi_cs_n <= 1'b0; // assert CS
            end

            if (manual_active) begin
                // simple slow clock for manual SPI (divide 100MHz to ~390kHz)
                manual_clk_div <= manual_clk_div + 16'd1;
                if (manual_clk_div == 16'd128) begin
                    manual_clk_div <= 16'd0;
                    manual_spi_clk <= ~manual_spi_clk;
                    // on falling edge, present next byte
                    if (!manual_spi_clk) begin
                        manual_spi_data <= manual_byte_cnt; // increasing pattern
                        manual_byte_cnt <= manual_byte_cnt + 8'd1;
                        if (manual_byte_idx < 4'd15) begin
                            manual_byte_idx <= manual_byte_idx + 1'b1;
                        end else begin
                            // finished
                            manual_active <= 1'b0;
                            manual_spi_cs_n <= 1'b1; // deassert CS
                        end
                    end
                end
            end
        end
    end

    // Multiplex top-level SPI outputs between CPU and manual generator
    assign SPI_DATA   = (ENABLE_MANUAL_SPI_TEST && manual_active) ? manual_spi_data : cpu_spi_data;
    assign SPI_CLK    = (ENABLE_MANUAL_SPI_TEST && manual_active) ? manual_spi_clk  : cpu_spi_clk;
    assign SPI_CS_N   = (ENABLE_MANUAL_SPI_TEST && manual_active) ? manual_spi_cs_n : cpu_spi_cs_n;

endmodule

