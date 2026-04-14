/*
 * SPI RX Buffer - Memory-Mapped Interface
 *
 * Provides CPU access to received SPI data via memory-mapped registers.
 * Directly interfaces with spi_slave_8lane module.
 *
 * Memory Map:
 *   BASE + 0x00: RX_STATUS   (R)   - Bit 0: data ready
 *   BASE + 0x04: RX_DATA_0   (R)   - Ciphertext bytes [31:0]
 *   BASE + 0x08: RX_DATA_1   (R)   - Ciphertext bytes [63:32]
 *   BASE + 0x0C: RX_DATA_2   (R)   - Ciphertext bytes [95:64]
 *   BASE + 0x10: RX_DATA_3   (R)   - Ciphertext bytes [127:96]
 *   BASE + 0x14: RX_CLEAR    (W)   - Write any value to clear status
 *   BASE + 0x18: IRQ_ENABLE  (R/W) - Bit 0: enable RX interrupt
 */

module spi_rx_buffer #(
    parameter BASE_ADDR = 32'h3000_0000
) (
    // System interface
    input  wire        clk,
    input  wire        resetn,

    // Memory bus interface (directly from PicoRV32)
    input  wire        mem_valid,
    output reg         mem_ready,
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [3:0]  mem_wstrb,    // Write strobes (0 = read, non-zero = write)
    output reg  [31:0] mem_rdata,

    // Interface to SPI Slave
    input  wire [127:0] spi_rx_data,   // Data from spi_slave_8lane
    input  wire        spi_rx_valid,   // Valid pulse from spi_slave_8lane

    // Interrupt output
    output wire        irq_rx
);

    // =========================================================================
    // Address Decoding
    // =========================================================================
    localparam ADDR_RX_STATUS   = BASE_ADDR + 32'h00;
    localparam ADDR_RX_DATA_0   = BASE_ADDR + 32'h04;
    localparam ADDR_RX_DATA_1   = BASE_ADDR + 32'h08;
    localparam ADDR_RX_DATA_2   = BASE_ADDR + 32'h0C;
    localparam ADDR_RX_DATA_3   = BASE_ADDR + 32'h10;
    localparam ADDR_RX_CLEAR    = BASE_ADDR + 32'h14;
    localparam ADDR_IRQ_ENABLE  = BASE_ADDR + 32'h18;

    // Check if address is within our range
    wire addr_valid = (mem_addr >= BASE_ADDR) && (mem_addr < BASE_ADDR + 32'h20);
    wire is_write   = (mem_wstrb != 4'b0000);
    wire is_read    = (mem_wstrb == 4'b0000);

    // =========================================================================
    // Registers
    // =========================================================================
    reg         rx_data_ready;      // Status bit: data available
    reg [127:0] rx_data_buffer;     // Latched received data
    reg         irq_enable;         // Interrupt enable

    // =========================================================================
    // RX Data Capture - Latch data when spi_rx_valid pulses
    // =========================================================================
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            rx_data_ready  <= 1'b0;
            rx_data_buffer <= 128'd0;
        end else begin
            // Capture new data when valid pulse arrives
            if (spi_rx_valid) begin
                rx_data_buffer <= spi_rx_data;
                rx_data_ready  <= 1'b1;
            end
            // Clear status when CPU writes to RX_CLEAR
            else if (mem_valid && addr_valid && is_write && mem_addr == ADDR_RX_CLEAR) begin
                rx_data_ready <= 1'b0;
            end
        end
    end

    // =========================================================================
    // IRQ Enable Register
    // =========================================================================
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            irq_enable <= 1'b0;
        end else begin
            if (mem_valid && addr_valid && is_write && mem_addr == ADDR_IRQ_ENABLE) begin
                irq_enable <= mem_wdata[0];
            end
        end
    end

    // =========================================================================
    // IRQ Output - Active when data ready AND interrupts enabled
    // =========================================================================
    assign irq_rx = rx_data_ready && irq_enable;

    // =========================================================================
    // Memory Bus Interface
    // =========================================================================
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            mem_ready <= 1'b0;
            mem_rdata <= 32'd0;
        end else begin
            mem_ready <= 1'b0;
            mem_rdata <= 32'd0;

            if (mem_valid && addr_valid && !mem_ready) begin
                mem_ready <= 1'b1;

                if (is_read) begin
                    case (mem_addr)
                        ADDR_RX_STATUS:  mem_rdata <= {31'd0, rx_data_ready};
                        ADDR_RX_DATA_0:  mem_rdata <= rx_data_buffer[31:0];
                        ADDR_RX_DATA_1:  mem_rdata <= rx_data_buffer[63:32];
                        ADDR_RX_DATA_2:  mem_rdata <= rx_data_buffer[95:64];
                        ADDR_RX_DATA_3:  mem_rdata <= rx_data_buffer[127:96];
                        ADDR_RX_CLEAR:   mem_rdata <= 32'd0;  // Write-only, reads as 0
                        ADDR_IRQ_ENABLE: mem_rdata <= {31'd0, irq_enable};
                        default:         mem_rdata <= 32'd0;
                    endcase
                end
                // Writes are handled in the register blocks above
            end
        end
    end

endmodule
