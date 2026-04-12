`timescale 1ns / 1ps
//=============================================================================
// top_8lane_bidir.v
// Bidirectional 8-Lane SPI Transfer - No CPU, No SD Card
//
// *** SAME BITSTREAM ON BOTH FPGAs ***
//
// How it works:
//   - SW[7:0]  set the 8-bit data value you want to send.
//              The same byte is replicated 16 times ? 128-bit packet.
//   - Press BTNC to transmit. Your board becomes master for this transfer.
//   - The other board is always listening (slave mode).
//   - When a full packet is received, LED[15:8] show the received byte.
//   - 7-Segment display:
//       "SEND"  while transmitting
//       "rECU"  while receiving
//       "--XX"  when idle (XX = last received byte in hex)
//
// Wiring between the two FPGAs (use male-male jumper wires):
// ????????????????????????????????????????????????????????
// ?  Board A PIN      Signal         Board B PIN         ?
// ?  JA1 (SPI_DATA[0]) ??????????? JC1 (SPI_DATA_IN[0]) ?
// ?  JA2 (SPI_DATA[1]) ??????????? JC2 (SPI_DATA_IN[1]) ?
// ?  JA3 (SPI_DATA[2]) ??????????? JC3 (SPI_DATA_IN[2]) ?
// ?  JA4 (SPI_DATA[3]) ??????????? JC4 (SPI_DATA_IN[3]) ?
// ?  JB1 (SPI_DATA[4]) ??????????? JD1 (SPI_DATA_IN[4]) ?
// ?  JB2 (SPI_DATA[5]) ??????????? JD2 (SPI_DATA_IN[5]) ?
// ?  JB3 (SPI_DATA[6]) ??????????? JD3 (SPI_DATA_IN[6]) ?
// ?  JB4 (SPI_DATA[7]) ??????????? JD4 (SPI_DATA_IN[7]) ?
// ?  JB7 (SPI_CLK)     ??????????? JD7 (SPI_CLK_IN)     ?
// ?  JB8 (SPI_CS_N)    ??????????? JD8 (SPI_CS_N_IN)    ?
// ?  AND THE REVERSE: B's TX ? A's RX (same connections) ?
// ?  GND (any Pmod GND pin) ??????? GND (other board)    ?
// ????????????????????????????????????????????????????????
//
// LED Map:
//   LED[0]    TX busy (I am currently sending)
//   LED[1]    RX busy (I am currently receiving from other board)
//   LED[2]    TX done (1-cycle pulse ? stays latched until next send)
//   LED[3]    RX valid (1-cycle pulse ? stays latched until next receive)
//   LED[4]    SPI_CLK output (live, blinks fast during TX)
//   LED[5]    SPI_CLK_IN  (live, blinks fast during RX)
//   LED[6]    SPI_CS_N output  (1 = CS asserted = I am sending)
//   LED[7]    SPI_CS_N_IN (1 = CS asserted = other board is sending to me)
//   LED[15:8] Last received byte [7:0] (latched until next reception)
//=============================================================================

module top_8lane_bidir (
    input  wire        CLK100MHZ,   // 100 MHz board clock
    input  wire        BTNC,        // Centre button ? SEND (press to transmit)
    input  wire        BTND,        // Down button   ? RESET
    input  wire [7:0]  SW,          // SW[7:0]: byte value to transmit

    // -----------------------------------------------------------------------
    // SPI TX outputs  ?  connect to other board's SPI RX inputs
    // -----------------------------------------------------------------------
    output wire [7:0]  SPI_DATA,    // 8 data lanes out (Pmod JA1-4, JB1-4)
    output wire        SPI_CLK,     // Clock out (Pmod JB7)
    output wire        SPI_CS_N,    // Chip select out, active low (Pmod JB8)

    // -----------------------------------------------------------------------
    // SPI RX inputs  ?  connect to other board's SPI TX outputs
    // -----------------------------------------------------------------------
    input  wire [7:0]  SPI_DATA_IN, // 8 data lanes in  (Pmod JC1-4, JD1-4)
    input  wire        SPI_CLK_IN,  // Clock in (Pmod JD7)
    input  wire        SPI_CS_N_IN, // Chip select in, active low (Pmod JD8)

    // -----------------------------------------------------------------------
    // Status outputs
    // -----------------------------------------------------------------------
    output wire [15:0] LED,
    output wire [7:0]  AN,   // 7-seg anodes  (active low)
    output wire [6:0]  SEG   // 7-seg segments (active low)
);

    //=========================================================================
    // Reset & button debouncing
    //=========================================================================
    wire btn_send_level;
    wire btn_send_pulse;   // 1-cycle pulse on BTNC press - starts TX
    wire btn_rst_level;

    wire resetn = ~btn_rst_level;  // Active-low reset from BTND

    debounce db_send (
        .clk       (CLK100MHZ),
        .btn_in    (BTNC),
        .btn_out   (btn_send_level),
        .btn_pulse (btn_send_pulse)
    );

    debounce db_reset (
        .clk       (CLK100MHZ),
        .btn_in    (BTND),
        .btn_out   (btn_rst_level),
        .btn_pulse ()
    );

    //=========================================================================
    // TX Payload: SW[7:0] replicated 16 times = 128-bit packet
    //   e.g. SW = 8'hAB  ?  packet = { AB AB AB AB  AB AB AB AB
    //                                    AB AB AB AB  AB AB AB AB }
    //=========================================================================
    wire [127:0] tx_payload = {16{SW}};

    //=========================================================================
    // SPI Master (TX side)
    //=========================================================================
    wire [7:0] master_data_out;
    wire       master_clk_out;
    wire       master_cs_n_out;
    wire       master_busy;
    wire       master_done_pulse;

    spi_master_8lane master_i (
        .clk      (CLK100MHZ),
        .resetn   (resetn),
        .start    (btn_send_pulse),   // triggered by button press
        .tx_data  (tx_payload),
        .spi_data (master_data_out),
        .spi_clk  (master_clk_out),
        .spi_cs_n (master_cs_n_out),
        .busy     (master_busy),
        .done     (master_done_pulse)
    );

    // Drive board's TX Pmod pins
    assign SPI_DATA  = master_data_out;
    assign SPI_CLK   = master_clk_out;
    assign SPI_CS_N  = master_cs_n_out;

    //=========================================================================
    // SPI Slave (RX side) - always listening on Pmod JC / JD
    //=========================================================================
    wire [127:0] rx_block_data;
    wire         rx_valid_pulse;
    wire         rx_busy;

    spi_slave_8lane slave_i (
        .clk         (CLK100MHZ),
        .resetn      (resetn),
        .spi_clk_in  (SPI_CLK_IN),
        .spi_data_in (SPI_DATA_IN),
        .spi_cs_n_in (SPI_CS_N_IN),
        .rx_data     (rx_block_data),
        .rx_valid    (rx_valid_pulse),
        .rx_busy     (rx_busy),
        .irq_rx      ()
    );

    //=========================================================================
    // Latch last received byte for display
    //=========================================================================
    reg [7:0] last_rx_byte;

    always @(posedge CLK100MHZ) begin
        if (!resetn)
            last_rx_byte <= 8'h00;
        else if (rx_valid_pulse)
            last_rx_byte <= rx_block_data[7:0];  // Byte 0 = first received byte
    end

    //=========================================================================
    // LED Status indicators
    // Latch done/valid pulses so they stay visible on LEDs
    //=========================================================================
    reg led_tx_done;
    reg led_rx_valid;

    always @(posedge CLK100MHZ) begin
        if (!resetn) begin
            led_tx_done  <= 1'b0;
            led_rx_valid <= 1'b0;
        end else begin
            if (master_done_pulse) led_tx_done  <= 1'b1;  // Set on done pulse
            if (btn_send_pulse)    led_tx_done  <= 1'b0;  // Clear on next send
            if (rx_valid_pulse)    led_rx_valid <= 1'b1;  // Set on receive
            if (btn_send_pulse)    led_rx_valid <= 1'b0;  // Clear on next send
        end
    end

    assign LED[0]    = master_busy;          // I am transmitting
    assign LED[1]    = rx_busy;              // I am receiving
    assign LED[2]    = led_tx_done;          // TX completed (latched)
    assign LED[3]    = led_rx_valid;         // Data received (latched)
    assign LED[4]    = master_clk_out;       // My SPI CLK output (live)
    assign LED[5]    = SPI_CLK_IN;           // Incoming SPI CLK (live)
    assign LED[6]    = ~master_cs_n_out;     // 1 when I am asserting CS (sending)
    assign LED[7]    = ~SPI_CS_N_IN;         // 1 when other board is asserting CS
    assign LED[15:8] = last_rx_byte;         // Last received byte

    //=========================================================================
    // 7-Segment Display
    //=========================================================================
    status_display disp_i (
        .clk          (CLK100MHZ),
        .tx_busy      (master_busy),
        .rx_busy      (rx_busy),
        .last_rx_byte (last_rx_byte),
        .an           (AN),
        .seg          (SEG)
    );

endmodule
