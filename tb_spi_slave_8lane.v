/*
 * Testbench for 8-Lane Parallel SPI Slave
 *
 * Simulates an external SPI master sending 128-bit data
 * and verifies the slave receives it correctly.
 */

`timescale 1ns/1ps

module tb_spi_slave_8lane;

    // =========================================================================
    // Clock and Reset
    // =========================================================================
    reg clk;
    reg resetn;

    // System clock: 50 MHz (20 ns period)
    initial clk = 0;
    always #10 clk = ~clk;

    // =========================================================================
    // SPI Master Signals (driven by testbench)
    // =========================================================================
    reg        spi_clk_in;
    reg [7:0]  spi_data_in;
    reg        spi_cs_n_in;

    // =========================================================================
    // SPI Slave Outputs
    // =========================================================================
    wire [127:0] rx_data;
    wire         rx_valid;
    wire         rx_busy;
    wire         irq_rx;

    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    spi_slave_8lane dut (
        .clk         (clk),
        .resetn      (resetn),
        .spi_clk_in  (spi_clk_in),
        .spi_data_in (spi_data_in),
        .spi_cs_n_in (spi_cs_n_in),
        .rx_data     (rx_data),
        .rx_valid    (rx_valid),
        .rx_busy     (rx_busy),
        .irq_rx      (irq_rx)
    );

    // =========================================================================
    // Test Data - FIPS-197 AES Test Vector (Ciphertext)
    // =========================================================================
    // Ciphertext: 0x69c4e0d86a7b0430d8cdb78070b4c55a
    // Sent as 16 bytes, LSB first
    reg [7:0] test_bytes [0:15];

    initial begin
        // Little-endian byte order
        test_bytes[0]  = 8'h5a;  // LSB
        test_bytes[1]  = 8'hc5;
        test_bytes[2]  = 8'hb4;
        test_bytes[3]  = 8'h70;
        test_bytes[4]  = 8'h80;
        test_bytes[5]  = 8'hb7;
        test_bytes[6]  = 8'hcd;
        test_bytes[7]  = 8'hd8;
        test_bytes[8]  = 8'h30;
        test_bytes[9]  = 8'h04;
        test_bytes[10] = 8'h7b;
        test_bytes[11] = 8'h6a;
        test_bytes[12] = 8'hd8;
        test_bytes[13] = 8'he0;
        test_bytes[14] = 8'hc4;
        test_bytes[15] = 8'h69;  // MSB
    end

    // Expected 128-bit result (after reassembly)
    wire [127:0] expected_data = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

    // =========================================================================
    // SPI Master Task - Send one byte
    // =========================================================================
    task spi_send_byte;
        input [7:0] data;
        begin
            // Setup data
            spi_data_in = data;
            #20;  // Wait 1 system clock

            // Rising edge of SPI clock
            spi_clk_in = 1;
            #40;  // Hold for 2 system clocks

            // Falling edge of SPI clock
            spi_clk_in = 0;
            #40;  // Inter-byte gap
        end
    endtask

    // =========================================================================
    // SPI Master Task - Send 16 bytes (full transfer)
    // =========================================================================
    task spi_send_128bits;
        integer i;
        begin
            $display("[%0t] SPI Master: Starting 128-bit transfer", $time);

            // Assert chip select (active low)
            spi_cs_n_in = 0;
            #40;

            // Send 16 bytes
            for (i = 0; i < 16; i = i + 1) begin
                $display("[%0t] SPI Master: Sending byte[%0d] = 0x%02h", $time, i, test_bytes[i]);
                spi_send_byte(test_bytes[i]);
            end

            // Deassert chip select
            #40;
            spi_cs_n_in = 1;
            $display("[%0t] SPI Master: Transfer complete, CS deasserted", $time);
        end
    endtask

    // =========================================================================
    // Monitor rx_valid
    // =========================================================================
    always @(posedge clk) begin
        if (rx_valid) begin
            $display("[%0t] SPI Slave: rx_valid asserted!", $time);
            $display("[%0t] SPI Slave: Received data = 0x%032h", $time, rx_data);
        end
    end

    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        $dumpfile("tb_spi_slave_8lane.vcd");
        $dumpvars(0, tb_spi_slave_8lane);

        $display("========================================");
        $display("  8-Lane SPI Slave Testbench");
        $display("========================================");

        // Initialize
        resetn      = 0;
        spi_clk_in  = 0;
        spi_data_in = 8'h00;
        spi_cs_n_in = 1;

        // Reset
        #100;
        resetn = 1;
        $display("[%0t] Reset released", $time);
        #100;

        // =====================================================================
        // Test 1: Normal 128-bit transfer
        // =====================================================================
        $display("\n--- Test 1: Normal 128-bit transfer ---");
        spi_send_128bits();

        // Wait for processing
        #200;

        // Verify received data
        if (rx_data == expected_data) begin
            $display("[PASS] Received data matches expected!");
            $display("       Expected: 0x%032h", expected_data);
            $display("       Received: 0x%032h", rx_data);
        end else begin
            $display("[FAIL] Data mismatch!");
            $display("       Expected: 0x%032h", expected_data);
            $display("       Received: 0x%032h", rx_data);
        end

        // =====================================================================
        // Test 2: Second transfer (verify slave resets properly)
        // =====================================================================
        $display("\n--- Test 2: Second transfer (verify reset) ---");
        #200;

        // Modify test data slightly
        test_bytes[0] = 8'hAA;
        test_bytes[15] = 8'hBB;

        spi_send_128bits();
        #200;

        $display("       Received: 0x%032h", rx_data);

        if (rx_data[7:0] == 8'hAA && rx_data[127:120] == 8'hBB) begin
            $display("[PASS] Second transfer received correctly!");
        end else begin
            $display("[FAIL] Second transfer failed!");
        end

        // =====================================================================
        // Test 3: Aborted transfer (CS goes high early)
        // =====================================================================
        $display("\n--- Test 3: Aborted transfer ---");
        #200;

        spi_cs_n_in = 0;
        #40;

        // Send only 4 bytes then abort
        spi_send_byte(8'h11);
        spi_send_byte(8'h22);
        spi_send_byte(8'h33);
        spi_send_byte(8'h44);

        // Abort by raising CS
        spi_cs_n_in = 1;
        $display("[%0t] SPI Master: Aborted transfer", $time);
        #200;

        // Slave should still have previous valid data
        $display("       rx_data after abort: 0x%032h", rx_data);
        $display("[INFO] Slave should retain last valid data");

        // =====================================================================
        // Done
        // =====================================================================
        #500;
        $display("\n========================================");
        $display("  Testbench Complete");
        $display("========================================");
        $finish;
    end

    // Timeout
    initial begin
        #50000;
        $display("[TIMEOUT] Simulation took too long!");
        $finish;
    end

endmodule
