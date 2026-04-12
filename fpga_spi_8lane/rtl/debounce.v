`timescale 1ns / 1ps
//=============================================================================
// debounce.v  –  Simple button debouncer (20 ms @ 100 MHz)
//=============================================================================
module debounce (
    input  wire clk,
    input  wire btn_in,
    output reg  btn_out   = 0, // Debounced level (1 = held)
    output reg  btn_pulse = 0  // Single clock-cycle pulse on press
);

    reg [20:0] cnt       = 0;
    reg        btn_sync0 = 0;
    reg        btn_sync1 = 0;

    // Two-stage synchronizer
    always @(posedge clk) begin
        btn_sync0 <= btn_in;
        btn_sync1 <= btn_sync0;
    end

    always @(posedge clk) begin
        btn_pulse <= 0;
        if (btn_sync1 != btn_out) begin
            cnt <= cnt + 1;
            if (cnt == 21'd2_000_000) begin   // 20 ms at 100 MHz
                cnt     <= 0;
                btn_out <= btn_sync1;
                if (btn_sync1) btn_pulse <= 1; // Pulse only on press (0→1)
            end
        end else begin
            cnt <= 0;
        end
    end

endmodule
