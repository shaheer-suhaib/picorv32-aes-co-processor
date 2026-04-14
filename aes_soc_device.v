/*
 * AES SoC Device - Complete Bidirectional Secure Communication Unit
 *
 * Integrates:
 * - PicoRV32 CPU with AES Encrypt + Decrypt co-processors
 * - SPI Master (TX) - auto-transmits after encryption
 * - SPI Slave (RX) - receives from external master
 * - RX Buffer - memory-mapped interface for received data
 *
 * Memory Map:
 *   0x00000000 - 0x00000FFF: Program/Data Memory (directly connected)
 *   0x30000000 - 0x3000001F: SPI RX Buffer registers
 */

module aes_soc_device #(
    parameter MEM_SIZE_WORDS = 512,
    parameter [31:0] PROGADDR_RESET = 32'h0000_0000
) (
    // System
    input  wire        clk,
    input  wire        resetn,
    output wire        trap,

    // SPI Master (TX) - outgoing encrypted data
    output wire [7:0]  spi_tx_data,
    output wire        spi_tx_clk,
    output wire        spi_tx_cs_n,
    output wire        spi_tx_active,

    // SPI Slave (RX) - incoming encrypted data
    input  wire        spi_rx_clk_in,
    input  wire [7:0]  spi_rx_data_in,
    input  wire        spi_rx_cs_n_in,
    output wire        spi_rx_irq
);

    // =========================================================================
    // Memory Interface Signals
    // =========================================================================
    wire        mem_valid;
    wire        mem_instr;
    wire        mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    wire [31:0] mem_rdata;

    // =========================================================================
    // Memory Arbiter - Route to RAM or RX Buffer
    // =========================================================================
    wire ram_sel     = (mem_addr < 32'h1000_0000);
    wire rxbuf_sel   = (mem_addr >= 32'h3000_0000) && (mem_addr < 32'h3000_0020);

    // RAM signals
    reg         ram_ready;
    reg  [31:0] ram_rdata;
    reg  [31:0] memory [0:MEM_SIZE_WORDS-1];

    // RX Buffer signals
    wire        rxbuf_ready;
    wire [31:0] rxbuf_rdata;

    // Mux ready and rdata
    assign mem_ready = ram_sel ? ram_ready : (rxbuf_sel ? rxbuf_ready : 1'b1);
    assign mem_rdata = ram_sel ? ram_rdata : (rxbuf_sel ? rxbuf_rdata : 32'hDEAD_BEEF);

    // =========================================================================
    // RAM Memory Controller
    // =========================================================================
    always @(posedge clk) begin
        ram_ready <= 0;
        if (mem_valid && ram_sel && !ram_ready) begin
            ram_ready <= 1;
            ram_rdata <= memory[mem_addr[31:2]];
            if (mem_wstrb[0]) memory[mem_addr[31:2]][ 7: 0] <= mem_wdata[ 7: 0];
            if (mem_wstrb[1]) memory[mem_addr[31:2]][15: 8] <= mem_wdata[15: 8];
            if (mem_wstrb[2]) memory[mem_addr[31:2]][23:16] <= mem_wdata[23:16];
            if (mem_wstrb[3]) memory[mem_addr[31:2]][31:24] <= mem_wdata[31:24];
        end
    end

    // =========================================================================
    // SPI Slave + RX Buffer
    // =========================================================================
    wire [127:0] spi_slave_rx_data;
    wire         spi_slave_rx_valid;
    wire         spi_slave_rx_busy;

    spi_slave_8lane spi_slave_inst (
        .clk         (clk),
        .resetn      (resetn),
        .spi_clk_in  (spi_rx_clk_in),
        .spi_data_in (spi_rx_data_in),
        .spi_cs_n_in (spi_rx_cs_n_in),
        .rx_data     (spi_slave_rx_data),
        .rx_valid    (spi_slave_rx_valid),
        .rx_busy     (spi_slave_rx_busy),
        .irq_rx      ()
    );

    spi_rx_buffer #(
        .BASE_ADDR(32'h3000_0000)
    ) rx_buffer_inst (
        .clk          (clk),
        .resetn       (resetn),
        .mem_valid    (mem_valid && rxbuf_sel),
        .mem_ready    (rxbuf_ready),
        .mem_addr     (mem_addr),
        .mem_wdata    (mem_wdata),
        .mem_wstrb    (mem_wstrb),
        .mem_rdata    (rxbuf_rdata),
        .spi_rx_data  (spi_slave_rx_data),
        .spi_rx_valid (spi_slave_rx_valid),
        .irq_rx       (spi_rx_irq)
    );

    // =========================================================================
    // PicoRV32 CPU with AES Co-processors
    // =========================================================================
    picorv32 #(
        .ENABLE_COUNTERS     (0),
        .ENABLE_COUNTERS64   (0),
        .ENABLE_REGS_16_31   (1),
        .ENABLE_REGS_DUALPORT(1),
        .LATCHED_MEM_RDATA   (0),
        .TWO_STAGE_SHIFT     (0),
        .BARREL_SHIFTER      (1),
        .TWO_CYCLE_COMPARE   (0),
        .TWO_CYCLE_ALU       (0),
        .COMPRESSED_ISA      (1),
        .CATCH_MISALIGN      (0),
        .CATCH_ILLINSN       (0),
        .ENABLE_PCPI         (0),
        .ENABLE_MUL          (1),
        .ENABLE_FAST_MUL     (1),
        .ENABLE_DIV          (1),
        .ENABLE_IRQ          (0),
        .ENABLE_IRQ_QREGS    (0),
        .ENABLE_IRQ_TIMER    (0),
        .ENABLE_TRACE        (0),
        .REGS_INIT_ZERO      (1),
        .MASKED_IRQ          (32'h0000_0000),
        .LATCHED_IRQ         (32'hFFFF_FFFF),
        .PROGADDR_RESET      (PROGADDR_RESET),
        .PROGADDR_IRQ        (32'h0000_0010),
        .STACKADDR           (32'h0000_0400),
        .ENABLE_AES          (1),
        .ENABLE_AES_DEC      (1)
    ) cpu (
        .clk          (clk),
        .resetn       (resetn),
        .trap         (trap),
        .mem_valid    (mem_valid),
        .mem_instr    (mem_instr),
        .mem_ready    (mem_ready),
        .mem_addr     (mem_addr),
        .mem_wdata    (mem_wdata),
        .mem_wstrb    (mem_wstrb),
        .mem_rdata    (mem_rdata),
        // SPI Master TX interface
        .aes_spi_data   (spi_tx_data),
        .aes_spi_clk    (spi_tx_clk),
        .aes_spi_cs_n   (spi_tx_cs_n),
        .aes_spi_active (spi_tx_active),
        // Unused
        .pcpi_valid   (),
        .pcpi_insn    (),
        .pcpi_rs1     (),
        .pcpi_rs2     (),
        .pcpi_wr      (1'b0),
        .pcpi_rd      (32'b0),
        .pcpi_wait    (1'b0),
        .pcpi_ready   (1'b0),
        .irq          (32'b0),
        .eoi          (),
        .trace_valid  (),
        .trace_data   ()
    );

endmodule
