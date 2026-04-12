`timescale 1ns / 1ps

// Simple AES Encryption/Decryption Top Module for Two FPGAs over SPI
// 1. Enter number on SW[15:0].
// 2. Press BTNC -> Board encrypts SW via PicoRV32/AES and transmits via SPI.
// 3. Receiving board gets data, decrypts it, and shows on LEDs/7-Seg.
//
// Shared codebase for both boards, idle mode continually polls RX buffer.

module aes_soc_top_simple (
    input  wire        CLK100MHZ,
    input  wire        BTNC,
    input  wire        BTND,
    input  wire [15:0] SW,

    // SPI master outputs (TX direction)
    output wire        SPI_CLK,
    output wire        SPI_CS_N,
    output wire [7:0]  SPI_DATA,

    // SPI slave inputs (RX direction)
    input  wire        SPI_CLK_IN,
    input  wire        SPI_CS_N_IN,
    input  wire [7:0]  SPI_DATA_IN,

    // Outputs
    output wire [15:0] LED,
    output wire [7:0]  AN,
    output wire [6:0]  SEG
);

    localparam integer MEM_SIZE_WORDS = 4096;
    localparam [31:0] GPIO_BASE  = 32'h2000_0000;
    localparam [31:0] RXBUF_BASE = 32'h3000_0000;

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

    wire bram_sel  = mem_addr < 32'h0000_4000;
    wire gpio_sel  = mem_addr >= GPIO_BASE && mem_addr < (GPIO_BASE + 32'h100);
    wire rxbuf_sel = mem_addr >= RXBUF_BASE && mem_addr < (RXBUF_BASE + 32'h100);

    wire        bram_ready;
    wire [31:0] bram_rdata;
    wire        rxbuf_ready;
    wire [31:0] rxbuf_rdata;

    // GPIO MMIO logic
    reg        gpio_ready;
    reg [31:0] gpio_rdata;
    reg [15:0] led_reg;
    reg [3:0]  seg_digit_reg;

    always @(posedge CLK100MHZ or negedge resetn) begin
        if (!resetn) begin
            gpio_ready <= 1'b0;
            gpio_rdata <= 32'd0;
            led_reg    <= 16'd0;
            seg_digit_reg <= 4'd0;
        end else begin
            gpio_ready <= 1'b0;
            gpio_rdata <= 32'd0;
            if (mem_valid && gpio_sel && !gpio_ready) begin
                gpio_ready <= 1'b1;
                if (mem_wstrb == 4'b0000) begin // Read
                    if (mem_addr == GPIO_BASE) // BASE + 0x00: read SW
                        gpio_rdata <= {16'd0, SW};
                    else if (mem_addr == GPIO_BASE + 32'h04) // BASE + 0x04: read BTNC
                        gpio_rdata <= {31'd0, btn_start_level};
                end else begin // Write
                    if (mem_addr == GPIO_BASE + 32'h08)
                        led_reg <= mem_wdata[15:0];
                    else if (mem_addr == GPIO_BASE + 32'h0C)
                        seg_digit_reg <= mem_wdata[3:0];
                end
            end
        end
    end

    wire [127:0] rx_block_data;
    wire         rx_block_valid;
    wire         rx_block_busy;

    // CPU-driven SPI signals
    wire [7:0] cpu_spi_data;
    wire       cpu_spi_clk;
    wire       cpu_spi_cs_n;
    wire       cpu_spi_active;

    assign mem_ready = bram_sel ? bram_ready :
                       (gpio_sel ? gpio_ready :
                       (rxbuf_sel ? rxbuf_ready : 1'b1));
    assign mem_rdata = bram_sel ? bram_rdata :
                       (gpio_sel ? gpio_rdata :
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
        .ENABLE_AES_DEC       (1)  // Enable Decryption!
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
        .aes_spi_data   (SPI_DATA), // output
        .aes_spi_clk    (SPI_CLK),  // output
        .aes_spi_cs_n   (SPI_CS_N), // output
        .aes_spi_active (cpu_spi_active)
    );

    bram_memory #(
        .MEM_SIZE_WORDS (MEM_SIZE_WORDS),
        .MEM_INIT_FILE  ("program_simple.hex")
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
        .digit      (seg_digit_reg),
        .show_digit (1'b1),
        .init_ok    (1'b1),
        .error_flag (trap),
        .an         (AN),
        .seg        (SEG)
    );

    assign LED = led_reg | {15'd0, trap}; // visually indicate CPU trap

endmodule
