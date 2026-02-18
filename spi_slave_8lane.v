/*
 * 8-Lane Parallel SPI Slave Receiver
 *
 * Receives 128-bit data over 8 parallel data lines.
 * - Samples data on rising edge of external SPI clock
 * - Handles clock domain crossing (async spi_clk to system clk)
 * - Raises interrupt when 16 bytes (128 bits) received
 * - Little-endian byte order (LSB first)
 */

module spi_slave_8lane (
    // System interface
    input  wire        clk,           // System clock
    input  wire        resetn,        // Active-low reset

    // SPI Slave interface (directly from external master)
    input  wire        spi_clk_in,    // SPI clock from remote master
    input  wire [7:0]  spi_data_in,   // 8-lane parallel data input
    input  wire        spi_cs_n_in,   // Chip select (active low)

    // Output interface
    output reg  [127:0] rx_data,      // Received 128-bit data
    output reg         rx_valid,      // Pulses high for 1 cycle when complete
    output wire        rx_busy,       // High during active reception
    output wire        irq_rx         // Directly connects to CPU interrupt
);

    // =========================================================================
    // State Machine States
    // =========================================================================
    localparam STATE_IDLE      = 2'b00;
    localparam STATE_RECEIVING = 2'b01;
    localparam STATE_COMPLETE  = 2'b10;

    reg [1:0] state, state_next;

    // =========================================================================
    // Clock Domain Crossing - Synchronize async SPI signals to system clock
    // =========================================================================

    // Triple-flop synchronizers for SPI clock (3 stages for edge detection)
    reg spi_clk_sync1, spi_clk_sync2, spi_clk_sync3;

    // Double-flop synchronizers for chip select
    reg spi_cs_n_sync1, spi_cs_n_sync2;

    // Double-flop synchronizers for data
    // Data uses 2 stages to match the clock edge detection timing
    // When edge = (clk_sync2=1 && clk_sync3=0), data_sync2 has the correct data
    reg [7:0] spi_data_sync1, spi_data_sync2;

    // Edge detection for SPI clock
    wire spi_clk_rising_edge;

    // Synchronized signals
    wire spi_cs_n_sync;
    wire [7:0] spi_data_sync;

    // Synchronization logic
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            spi_clk_sync1  <= 1'b0;
            spi_clk_sync2  <= 1'b0;
            spi_clk_sync3  <= 1'b0;
            spi_cs_n_sync1 <= 1'b1;  // CS is active low, default high
            spi_cs_n_sync2 <= 1'b1;
            spi_data_sync1 <= 8'b0;
            spi_data_sync2 <= 8'b0;
        end else begin
            // SPI clock synchronizer (3-stage for edge detection)
            spi_clk_sync1 <= spi_clk_in;
            spi_clk_sync2 <= spi_clk_sync1;
            spi_clk_sync3 <= spi_clk_sync2;

            // CS synchronizer
            spi_cs_n_sync1 <= spi_cs_n_in;
            spi_cs_n_sync2 <= spi_cs_n_sync1;

            // Data synchronizer (2 stages to align with clock edge detection)
            // When edge = (clk_sync2=1 && clk_sync3=0), data_sync2 is valid
            spi_data_sync1 <= spi_data_in;
            spi_data_sync2 <= spi_data_sync1;
        end
    end

    // Rising edge detection: was low, now high
    assign spi_clk_rising_edge = (spi_clk_sync2 == 1'b1) && (spi_clk_sync3 == 1'b0);

    // Synchronized outputs
    assign spi_cs_n_sync = spi_cs_n_sync2;
    assign spi_data_sync = spi_data_sync2;  // Use 2nd stage - aligned with clock edge detection

    // =========================================================================
    // Byte Counter - counts 0 to 15 (16 bytes = 128 bits)
    // =========================================================================
    reg [3:0] byte_count;
    wire byte_count_done;

    assign byte_count_done = (byte_count == 4'd15);

    // =========================================================================
    // Shift Register - accumulates received bytes
    // =========================================================================
    reg [127:0] shift_reg;

    // =========================================================================
    // State Machine - Sequential Logic
    // =========================================================================
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state <= STATE_IDLE;
        end else begin
            state <= state_next;
        end
    end

    // =========================================================================
    // State Machine - Combinational Logic
    // =========================================================================
    // CS falling edge detection for first byte capture
    reg spi_cs_n_sync_prev;
    wire cs_falling_edge;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            spi_cs_n_sync_prev <= 1'b1;
        end else begin
            spi_cs_n_sync_prev <= spi_cs_n_sync;
        end
    end

    assign cs_falling_edge = spi_cs_n_sync_prev && !spi_cs_n_sync;

    always @(*) begin
        state_next = state;

        case (state)
            STATE_IDLE: begin
                // Wait for CS falling edge (new transfer starting)
                // Using cs_falling_edge prevents false triggering from
                // glitches or if CS is already low when we enter IDLE
                if (cs_falling_edge) begin
                    state_next = STATE_RECEIVING;
                end
            end

            STATE_RECEIVING: begin
                // If CS goes high before complete, abort and go idle
                if (spi_cs_n_sync) begin
                    state_next = STATE_IDLE;
                end
                // Check if we've received all 16 bytes
                else if (byte_count_done && spi_clk_rising_edge) begin
                    state_next = STATE_COMPLETE;
                end
            end

            STATE_COMPLETE: begin
                // Stay in complete for one cycle, then back to idle
                // Wait for CS to go high before accepting new transfer
                if (spi_cs_n_sync) begin
                    state_next = STATE_IDLE;
                end
            end

            default: begin
                state_next = STATE_IDLE;
            end
        endcase
    end

    // =========================================================================
    // Data Reception Logic
    // =========================================================================

    // Track state transitions to pulse rx_valid only once
    reg [1:0] state_prev;
    wire entering_complete;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state_prev <= STATE_IDLE;
        end else begin
            state_prev <= state;
        end
    end

    assign entering_complete = (state == STATE_COMPLETE) && (state_prev != STATE_COMPLETE);

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            byte_count <= 4'd0;
            shift_reg  <= 128'd0;
            rx_data    <= 128'd0;
            rx_valid   <= 1'b0;
        end else begin
            // Default: clear rx_valid after one cycle
            rx_valid <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    // Only reset when CS is high (truly idle)
                    // Don't reset if we're transitioning to RECEIVING
                    if (spi_cs_n_sync) begin
                        byte_count <= 4'd0;
                        shift_reg  <= 128'd0;
                    end
                    // CRITICAL: If CS is low AND there's a rising edge,
                    // capture the first byte immediately! This handles the
                    // case where CS and first clock happen at nearly the same time.
                    else if (spi_clk_rising_edge) begin
                        shift_reg <= {120'b0, spi_data_sync};
                        byte_count <= 4'd1;
                    end
                end

                STATE_RECEIVING: begin
                    // On rising edge of SPI clock, sample data
                    if (spi_clk_rising_edge) begin
                        // Shift in new byte (little-endian: first byte goes to LSB)
                        // Byte 0 → bits [7:0], Byte 1 → bits [15:8], etc.
                        shift_reg <= {spi_data_sync, shift_reg[127:8]};
                        byte_count <= byte_count + 4'd1;
                    end
                end

                STATE_COMPLETE: begin
                    // Latch the received data and signal valid ONLY on entry
                    if (entering_complete) begin
                        rx_data  <= shift_reg;
                        rx_valid <= 1'b1;
                    end
                    // Keep shift_reg intact until we return to IDLE
                    // Only reset byte_count, not shift_reg
                    byte_count <= 4'd0;
                end

                default: begin
                    byte_count <= 4'd0;
                end
            endcase
        end
    end

    // =========================================================================
    // Output Assignments
    // =========================================================================

    // Busy when receiving
    assign rx_busy = (state == STATE_RECEIVING);

    // IRQ directly mirrors rx_valid (active for one cycle)
    assign irq_rx = rx_valid;

endmodule
