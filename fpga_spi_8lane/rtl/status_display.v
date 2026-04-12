`timescale 1ns / 1ps
//=============================================================================
// status_display.v  –  7-Segment status display for 8-lane SPI demo
//
// Shows:
//   While TX busy  → "SEND" on digits 3..0 (leftmost of the 4 used digits)
//   While RX busy  → "rECU" on digits 3..0
//   Idle           → "--XX" where XX = last received byte in hex (2 digits)
//
// 8-digit display (AN[7:0], active low):
//   Only digits 3..0 are used (rightmost 4 digits).
//   AN[7] = leftmost,  AN[0] = rightmost.
//=============================================================================
module status_display (
    input  wire        clk,
    input  wire        tx_busy,
    input  wire        rx_busy,
    input  wire [7:0]  last_rx_byte,  // Latched received byte to display

    output reg  [7:0]  an,   // Anode enables  (active low)
    output reg  [6:0]  seg   // Segment cathodes (active low), {g,f,e,d,c,b,a}
);

    // -------------------------------------------------------------------------
    // ~1 kHz refresh (100 MHz / 131072 ≈ 763 Hz, good enough)
    // -------------------------------------------------------------------------
    reg [16:0] refresh_cnt = 0;
    reg [2:0]  digit_pos   = 0;   // Which digit to drive

    always @(posedge clk) begin
        refresh_cnt <= refresh_cnt + 1;
        if (refresh_cnt == 17'd99_999) begin  // ~1 kHz
            refresh_cnt <= 0;
            digit_pos   <= digit_pos + 1;
            if (digit_pos == 3'd3) digit_pos <= 0;
        end
    end

    // -------------------------------------------------------------------------
    // Segment encoding (active low: 0 = segment ON)
    // Segments: {g, f, e, d, c, b, a}
    // -------------------------------------------------------------------------
    function [6:0] hex_seg;
        input [3:0] d;
        case (d)
            4'h0: hex_seg = 7'b1000000;  // 0
            4'h1: hex_seg = 7'b1111001;  // 1
            4'h2: hex_seg = 7'b0100100;  // 2
            4'h3: hex_seg = 7'b0110000;  // 3
            4'h4: hex_seg = 7'b0011001;  // 4
            4'h5: hex_seg = 7'b0010010;  // 5
            4'h6: hex_seg = 7'b0000010;  // 6
            4'h7: hex_seg = 7'b1111000;  // 7
            4'h8: hex_seg = 7'b0000000;  // 8
            4'h9: hex_seg = 7'b0010000;  // 9
            4'hA: hex_seg = 7'b0001000;  // A
            4'hB: hex_seg = 7'b0000011;  // b
            4'hC: hex_seg = 7'b1000110;  // C
            4'hD: hex_seg = 7'b0100001;  // d
            4'hE: hex_seg = 7'b0000110;  // E
            4'hF: hex_seg = 7'b0001110;  // F
            default: hex_seg = 7'b0111111; // -
        endcase
    endfunction

    // Pre-defined letter segments
    localparam SEG_S    = 7'b0010010;  // S
    localparam SEG_E    = 7'b0000110;  // E
    localparam SEG_N    = 7'b0101011;  // n (lowercase)
    localparam SEG_D    = 7'b0100001;  // d (lowercase)
    localparam SEG_R    = 7'b0101111;  // r (lowercase)
    localparam SEG_C    = 7'b1000110;  // C
    localparam SEG_U    = 7'b1000001;  // U
    localparam SEG_DASH = 7'b0111111;  // -
    localparam SEG_OFF  = 7'b1111111;  // all segments off

    // -------------------------------------------------------------------------
    // Display mux
    // digit_pos 0 = rightmost (AN[0]), digit_pos 3 = AN[3]
    // -------------------------------------------------------------------------
    always @(*) begin
        an  = 8'b1111_1111;  // Default: all digits off
        seg = SEG_DASH;

        if (tx_busy) begin
            // ---- S E N D ----  (digit3=S, digit2=E, digit1=N, digit0=D)
            case (digit_pos)
                3'd0: begin an = 8'b1111_1110; seg = SEG_D; end  // D
                3'd1: begin an = 8'b1111_1101; seg = SEG_N; end  // N
                3'd2: begin an = 8'b1111_1011; seg = SEG_E; end  // E
                3'd3: begin an = 8'b1111_0111; seg = SEG_S; end  // S
                default: begin an = 8'hFF; seg = SEG_OFF;  end
            endcase
        end else if (rx_busy) begin
            // ---- r E C U ----  (digit3=r, digit2=E, digit1=C, digit0=U)
            case (digit_pos)
                3'd0: begin an = 8'b1111_1110; seg = SEG_U; end  // U
                3'd1: begin an = 8'b1111_1101; seg = SEG_C; end  // C
                3'd2: begin an = 8'b1111_1011; seg = SEG_E; end  // E
                3'd3: begin an = 8'b1111_0111; seg = SEG_R; end  // r
                default: begin an = 8'hFF; seg = SEG_OFF;  end
            endcase
        end else begin
            // ---- - - X X ----  (dash dash upper nibble lower nibble)
            case (digit_pos)
                3'd0: begin an = 8'b1111_1110; seg = hex_seg(last_rx_byte[3:0]); end
                3'd1: begin an = 8'b1111_1101; seg = hex_seg(last_rx_byte[7:4]); end
                3'd2: begin an = 8'b1111_1011; seg = SEG_DASH; end
                3'd3: begin an = 8'b1111_0111; seg = SEG_DASH; end
                default: begin an = 8'hFF; seg = SEG_OFF; end
            endcase
        end
    end

endmodule
