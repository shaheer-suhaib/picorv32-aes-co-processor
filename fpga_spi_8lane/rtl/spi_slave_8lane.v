`timescale 1ns / 1ps
//=============================================================================
// spi_slave_8lane.v
// 8-Lane Parallel SPI Slave Receiver
//
// Receives 16 bytes (128 bits) over 8 parallel data lines.
//   - Samples data on RISING edge of external SPI clock (SPI Mode 0)
//   - Double-flop synchronizer for safe clock-domain crossing
//   - rx_valid pulses high for exactly 1 system clock cycle when done
//   - rx_busy stays high during active reception
//
// Byte order: little-endian (first received byte → rx_data[7:0])
//=============================================================================
module spi_slave_8lane (
    input  wire        clk,         // System clock (100 MHz)
    input  wire        resetn,      // Active-low reset

    // SPI bus inputs from the master (other FPGA)
    input  wire        spi_clk_in,  // SPI clock from remote master
    input  wire [7:0]  spi_data_in, // 8-lane parallel data
    input  wire        spi_cs_n_in, // Chip select (active low)

    // Outputs to top-level logic
    output reg  [127:0] rx_data,   // Received 128-bit word
    output reg          rx_valid,  // 1-cycle pulse: new data ready
    output wire         rx_busy,   // High while receiving
    output wire         irq_rx     // Mirrors rx_valid (for CPU if needed)
);

    // -------------------------------------------------------------------------
    // FSM states
    // -------------------------------------------------------------------------
    localparam S_IDLE      = 2'b00;
    localparam S_RECEIVING = 2'b01;
    localparam S_COMPLETE  = 2'b10;

    reg [1:0] state, state_next, state_prev;

    // -------------------------------------------------------------------------
    // Double-flop synchronizers (spi_clk_in is asynchronous to system clock)
    // -------------------------------------------------------------------------
    reg spi_clk_s1, spi_clk_s2, spi_clk_s3; // 3-stage for edge detect
    reg spi_cs_n_s1, spi_cs_n_s2;
    reg [7:0] spi_data_s1, spi_data_s2;

    always @(posedge clk) begin
        if (!resetn) begin
            spi_clk_s1  <= 1'b0; spi_clk_s2  <= 1'b0; spi_clk_s3  <= 1'b0;
            spi_cs_n_s1 <= 1'b1; spi_cs_n_s2 <= 1'b1;
            spi_data_s1 <= 8'h0; spi_data_s2 <= 8'h0;
        end else begin
            spi_clk_s1  <= spi_clk_in;
            spi_clk_s2  <= spi_clk_s1;
            spi_clk_s3  <= spi_clk_s2;
            spi_cs_n_s1 <= spi_cs_n_in;
            spi_cs_n_s2 <= spi_cs_n_s1;
            spi_data_s1 <= spi_data_in;
            spi_data_s2 <= spi_data_s1;
        end
    end

    // Rising edge: was low, now high (detected one cycle late after S3)
    wire spi_clk_rising = (spi_clk_s2 == 1'b1) && (spi_clk_s3 == 1'b0);

    // Use the most recently synchronized values
    wire        cs_n_sync  = spi_cs_n_s2;
    wire [7:0]  data_sync  = spi_data_s2;

    // -------------------------------------------------------------------------
    // Byte counter (0..15 = 16 bytes)
    // -------------------------------------------------------------------------
    reg [3:0] byte_cnt;

    // -------------------------------------------------------------------------
    // Shift register accumulates incoming bytes
    // -------------------------------------------------------------------------
    reg [127:0] shift_reg;

    // -------------------------------------------------------------------------
    // FSM: Sequential
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!resetn) begin
            state      <= S_IDLE;
            state_prev <= S_IDLE;
        end else begin
            state_prev <= state;
            state      <= state_next;
        end
    end

    // -------------------------------------------------------------------------
    // FSM: Combinational
    // -------------------------------------------------------------------------
    always @(*) begin
        state_next = state;
        case (state)
            S_IDLE: begin
                if (!cs_n_sync)
                    state_next = S_RECEIVING;
            end
            S_RECEIVING: begin
                if (cs_n_sync)
                    state_next = S_IDLE;          // CS deasserted → abort
                else if ((byte_cnt == 4'd15) && spi_clk_rising)
                    state_next = S_COMPLETE;      // All 16 bytes received
            end
            S_COMPLETE: begin
                if (cs_n_sync)
                    state_next = S_IDLE;          // Wait for CS to go high
            end
            default: state_next = S_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // Data reception & output
    // -------------------------------------------------------------------------
    wire entering_complete = (state == S_COMPLETE) && (state_prev != S_COMPLETE);

    always @(posedge clk) begin
        if (!resetn) begin
            byte_cnt  <= 4'd0;
            shift_reg <= 128'd0;
            rx_data   <= 128'd0;
            rx_valid  <= 1'b0;
        end else begin
            rx_valid <= 1'b0; // Default: deassert

            case (state)
                S_IDLE: begin
                    byte_cnt  <= 4'd0;
                    shift_reg <= 128'd0;
                end
                S_RECEIVING: begin
                    if (spi_clk_rising) begin
                        // Shift new byte in (little-endian: first byte → LSB)
                        shift_reg <= {data_sync, shift_reg[127:8]};
                        byte_cnt  <= byte_cnt + 4'd1;
                    end
                end
                S_COMPLETE: begin
                    if (entering_complete) begin
                        rx_data  <= shift_reg; // Latch final value
                        rx_valid <= 1'b1;      // Pulse valid for 1 cycle
                    end
                    byte_cnt <= 4'd0;
                end
                default: byte_cnt <= 4'd0;
            endcase
        end
    end

    assign rx_busy = (state == S_RECEIVING);
    assign irq_rx  = rx_valid;

endmodule
