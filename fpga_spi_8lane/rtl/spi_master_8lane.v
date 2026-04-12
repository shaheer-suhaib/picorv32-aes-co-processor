`timescale 1ns / 1ps
//=============================================================================
// spi_master_8lane.v
// 8-Lane Parallel SPI Master FSM
//
// Transmits 16 bytes (128 bits) over 8 parallel data lines in SPI Mode 0:
//   - CPOL=0 : clock idle low
//   - CPHA=0 : data presented on falling edge, slave samples on rising edge
//
// SPI clock = 100MHz / 256 ≈ 390 kHz (safe for Pmod jumper wires)
//
// Ports:
//   start     - 1-cycle pulse to begin a transfer
//   tx_data   - 128-bit payload (byte 0 = bits [7:0], transmitted first)
//   spi_data  - 8 parallel data bits (one full byte per SPI clock cycle)
//   spi_clk   - SPI clock output
//   spi_cs_n  - Chip select (active low)
//   busy      - High during transfer
//   done      - 1-cycle pulse when transfer is complete
//=============================================================================
module spi_master_8lane (
    input  wire         clk,       // 100 MHz system clock
    input  wire         resetn,    // Active-low synchronous reset
    input  wire         start,     // 1-cycle pulse: begin transfer
    input  wire [127:0] tx_data,   // 16 bytes to send (byte0=[7:0])

    output reg  [7:0]   spi_data,  // 8-lane parallel data out
    output reg          spi_clk,   // SPI clock out
    output reg          spi_cs_n,  // Chip select (active low)
    output wire         busy,      // High while transferring
    output reg          done       // 1-cycle pulse when done
);

    // -------------------------------------------------------------------------
    // Clock divider: half-period = 128 cycles → SPI CLK ~390 kHz
    // -------------------------------------------------------------------------
    localparam HALF_PERIOD = 8'd127;   // count 0..127 = 128 cycles

    // -------------------------------------------------------------------------
    // FSM states
    // -------------------------------------------------------------------------
    localparam IDLE        = 3'd0;
    localparam CS_ASSERT   = 3'd1;   // Assert CS, put first byte on data lines
    localparam CLK_LO      = 3'd2;   // Clock low half-period (data stable)
    localparam CLK_HI      = 3'd3;   // Clock high half-period (slave samples)
    localparam CS_DEASSERT = 3'd4;   // Deassert CS after last byte
    localparam DONE_ST     = 3'd5;   // Pulse done for 1 cycle, return to IDLE

    reg [2:0]   state;
    reg [7:0]   clk_cnt;     // Clock divider counter
    reg [3:0]   byte_cnt;    // Byte index 0..15
    reg [127:0] shift_reg;   // Working copy of tx_data, shifted as bytes are sent

    assign busy = (state != IDLE) && (state != DONE_ST);

    always @(posedge clk) begin
        if (!resetn) begin
            state     <= IDLE;
            spi_data  <= 8'h00;
            spi_clk   <= 1'b0;
            spi_cs_n  <= 1'b1;
            done      <= 1'b0;
            clk_cnt   <= 8'd0;
            byte_cnt  <= 4'd0;
            shift_reg <= 128'd0;
        end else begin
            done <= 1'b0; // Default: deassert done

            case (state)
                // ---------------------------------------------------------
                // IDLE: wait for start pulse
                // ---------------------------------------------------------
                IDLE: begin
                    spi_clk  <= 1'b0;
                    spi_cs_n <= 1'b1;
                    spi_data <= 8'h00;
                    if (start) begin
                        shift_reg <= tx_data;
                        state     <= CS_ASSERT;
                    end
                end

                // ---------------------------------------------------------
                // CS_ASSERT: pull CS low, present byte 0, start clocking
                // ---------------------------------------------------------
                CS_ASSERT: begin
                    spi_cs_n  <= 1'b0;             // Assert chip select
                    spi_clk   <= 1'b0;
                    spi_data  <= shift_reg[7:0];   // Byte 0 on the bus
                    shift_reg <= shift_reg >> 8;   // Byte 1 ready at [7:0]
                    byte_cnt  <= 4'd0;
                    clk_cnt   <= 8'd0;
                    state     <= CLK_LO;
                end

                // ---------------------------------------------------------
                // CLK_LO: keep clock low for half period (data is stable)
                // ---------------------------------------------------------
                CLK_LO: begin
                    spi_clk <= 1'b0;
                    if (clk_cnt == HALF_PERIOD) begin
                        clk_cnt <= 8'd0;
                        state   <= CLK_HI;
                    end else begin
                        clk_cnt <= clk_cnt + 8'd1;
                    end
                end

                // ---------------------------------------------------------
                // CLK_HI: raise clock (slave samples data on this edge)
                // After half period: either start next byte or end transfer
                // ---------------------------------------------------------
                CLK_HI: begin
                    spi_clk <= 1'b1;
                    if (clk_cnt == HALF_PERIOD) begin
                        clk_cnt <= 8'd0;
                        if (byte_cnt == 4'd15) begin
                            // All 16 bytes have been clocked out
                            state <= CS_DEASSERT;
                        end else begin
                            // Advance to next byte
                            byte_cnt  <= byte_cnt + 4'd1;
                            spi_data  <= shift_reg[7:0];   // Present next byte
                            shift_reg <= shift_reg >> 8;   // Prepare byte after that
                            state     <= CLK_LO;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 8'd1;
                    end
                end

                // ---------------------------------------------------------
                // CS_DEASSERT: lower clock, deassert CS
                // ---------------------------------------------------------
                CS_DEASSERT: begin
                    spi_clk  <= 1'b0;
                    spi_cs_n <= 1'b1;
                    spi_data <= 8'h00;
                    state    <= DONE_ST;
                end

                // ---------------------------------------------------------
                // DONE_ST: pulse done for exactly 1 clock cycle
                // ---------------------------------------------------------
                DONE_ST: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
