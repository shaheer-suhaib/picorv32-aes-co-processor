/*
 * Testbench for SPI RX Buffer
 *
 * Tests the memory-mapped interface together with SPI slave.
 * Simulates CPU reading received data.
 */

`timescale 1ns/1ps

module tb_spi_rx_buffer;

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
    // Memory Bus (CPU interface simulation)
    // =========================================================================
    reg         mem_valid;
    wire        mem_ready;
    reg  [31:0] mem_addr;
    reg  [31:0] mem_wdata;
    reg  [3:0]  mem_wstrb;
    wire [31:0] mem_rdata;

    // =========================================================================
    // SPI Slave <-> RX Buffer Interface
    // =========================================================================
    wire [127:0] spi_rx_data;
    wire         spi_rx_valid;
    wire         irq_rx;

    // =========================================================================
    // DUT Instantiations
    // =========================================================================
    spi_slave_8lane spi_slave (
        .clk         (clk),
        .resetn      (resetn),
        .spi_clk_in  (spi_clk_in),
        .spi_data_in (spi_data_in),
        .spi_cs_n_in (spi_cs_n_in),
        .rx_data     (spi_rx_data),
        .rx_valid    (spi_rx_valid),
        .rx_busy     (),
        .irq_rx      ()
    );

    spi_rx_buffer #(
        .BASE_ADDR(32'h3000_0000)
    ) rx_buffer (
        .clk          (clk),
        .resetn       (resetn),
        .mem_valid    (mem_valid),
        .mem_ready    (mem_ready),
        .mem_addr     (mem_addr),
        .mem_wdata    (mem_wdata),
        .mem_wstrb    (mem_wstrb),
        .mem_rdata    (mem_rdata),
        .spi_rx_data  (spi_rx_data),
        .spi_rx_valid (spi_rx_valid),
        .irq_rx       (irq_rx)
    );

    // =========================================================================
    // Test Data
    // =========================================================================
    reg [7:0] test_bytes [0:15];

    initial begin
        // Ciphertext: 0x69c4e0d86a7b0430d8cdb78070b4c55a (little-endian)
        test_bytes[0]  = 8'h5a;
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
        test_bytes[15] = 8'h69;
    end

    // =========================================================================
    // Memory Bus Tasks (Simulate CPU)
    // =========================================================================
    reg [31:0] read_result;

    task cpu_read;
        input [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            mem_valid <= 1'b1;
            mem_addr  <= addr;
            mem_wstrb <= 4'b0000;  // Read
            mem_wdata <= 32'd0;

            // Wait for ready
            @(posedge clk);
            while (!mem_ready) @(posedge clk);
            data = mem_rdata;

            @(posedge clk);
            mem_valid <= 1'b0;
        end
    endtask

    task cpu_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            mem_valid <= 1'b1;
            mem_addr  <= addr;
            mem_wstrb <= 4'b1111;  // Write all bytes
            mem_wdata <= data;

            // Wait for ready
            @(posedge clk);
            while (!mem_ready) @(posedge clk);

            @(posedge clk);
            mem_valid <= 1'b0;
        end
    endtask

    // =========================================================================
    // SPI Master Task - Send one byte
    // =========================================================================
    task spi_send_byte;
        input [7:0] data;
        begin
            spi_data_in = data;
            #20;
            spi_clk_in = 1;
            #40;
            spi_clk_in = 0;
            #40;
        end
    endtask

    // =========================================================================
    // SPI Master Task - Send 16 bytes
    // =========================================================================
    task spi_send_128bits;
        integer i;
        begin
            spi_cs_n_in = 0;
            #40;
            for (i = 0; i < 16; i = i + 1) begin
                spi_send_byte(test_bytes[i]);
            end
            #40;
            spi_cs_n_in = 1;
        end
    endtask

    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        $dumpfile("tb_spi_rx_buffer.vcd");
        $dumpvars(0, tb_spi_rx_buffer);

        $display("========================================");
        $display("  SPI RX Buffer Testbench");
        $display("========================================");

        // Initialize
        resetn      = 0;
        spi_clk_in  = 0;
        spi_data_in = 8'h00;
        spi_cs_n_in = 1;
        mem_valid   = 0;
        mem_addr    = 0;
        mem_wdata   = 0;
        mem_wstrb   = 0;

        // Reset
        #100;
        resetn = 1;
        $display("[%0t] Reset released", $time);
        #100;

        // =====================================================================
        // Test 1: Check initial status (should be 0)
        // =====================================================================
        $display("\n--- Test 1: Check initial status ---");
        cpu_read(32'h3000_0000, read_result);
        $display("RX_STATUS = 0x%08h (expected: 0x00000000)", read_result);
        if (read_result == 0) $display("[PASS] Initial status is 0");
        else $display("[FAIL] Initial status should be 0");

        // =====================================================================
        // Test 2: Enable interrupts
        // =====================================================================
        $display("\n--- Test 2: Enable interrupts ---");
        cpu_write(32'h3000_0018, 32'h0000_0001);
        cpu_read(32'h3000_0018, read_result);
        $display("IRQ_ENABLE = 0x%08h (expected: 0x00000001)", read_result);
        if (read_result == 1) $display("[PASS] IRQ enabled");
        else $display("[FAIL] IRQ enable failed");

        // =====================================================================
        // Test 3: Receive data via SPI
        // =====================================================================
        $display("\n--- Test 3: Receive data via SPI ---");
        $display("Sending 128-bit data over SPI...");
        spi_send_128bits();
        #200;

        // Check IRQ asserted
        $display("IRQ signal = %b (expected: 1)", irq_rx);
        if (irq_rx) $display("[PASS] IRQ asserted");
        else $display("[FAIL] IRQ not asserted");

        // Check status
        cpu_read(32'h3000_0000, read_result);
        $display("RX_STATUS = 0x%08h (expected: 0x00000001)", read_result);
        if (read_result == 1) $display("[PASS] Data ready flag set");
        else $display("[FAIL] Data ready flag not set");

        // =====================================================================
        // Test 4: Read received data
        // =====================================================================
        $display("\n--- Test 4: Read received data ---");

        cpu_read(32'h3000_0004, read_result);
        $display("RX_DATA_0 = 0x%08h (expected: 0x70b4c55a)", read_result);
        if (read_result == 32'h70b4c55a) $display("[PASS] DATA_0 correct");
        else $display("[FAIL] DATA_0 mismatch");

        cpu_read(32'h3000_0008, read_result);
        $display("RX_DATA_1 = 0x%08h (expected: 0xd8cdb780)", read_result);
        if (read_result == 32'hd8cdb780) $display("[PASS] DATA_1 correct");
        else $display("[FAIL] DATA_1 mismatch");

        cpu_read(32'h3000_000C, read_result);
        $display("RX_DATA_2 = 0x%08h (expected: 0x6a7b0430)", read_result);
        if (read_result == 32'h6a7b0430) $display("[PASS] DATA_2 correct");
        else $display("[FAIL] DATA_2 mismatch");

        cpu_read(32'h3000_0010, read_result);
        $display("RX_DATA_3 = 0x%08h (expected: 0x69c4e0d8)", read_result);
        if (read_result == 32'h69c4e0d8) $display("[PASS] DATA_3 correct");
        else $display("[FAIL] DATA_3 mismatch");

        // =====================================================================
        // Test 5: Clear status
        // =====================================================================
        $display("\n--- Test 5: Clear status ---");
        cpu_write(32'h3000_0014, 32'h0000_0001);  // Write anything to clear
        #20;

        $display("IRQ signal after clear = %b (expected: 0)", irq_rx);
        if (!irq_rx) $display("[PASS] IRQ cleared");
        else $display("[FAIL] IRQ still asserted");

        cpu_read(32'h3000_0000, read_result);
        $display("RX_STATUS after clear = 0x%08h (expected: 0x00000000)", read_result);
        if (read_result == 0) $display("[PASS] Status cleared");
        else $display("[FAIL] Status not cleared");

        // =====================================================================
        // Test 6: Second transfer (verify re-arm)
        // =====================================================================
        $display("\n--- Test 6: Second transfer ---");
        test_bytes[0] = 8'hDE;
        test_bytes[15] = 8'hAD;
        spi_send_128bits();
        #200;

        cpu_read(32'h3000_0000, read_result);
        $display("RX_STATUS = 0x%08h (expected: 0x00000001)", read_result);

        cpu_read(32'h3000_0004, read_result);
        $display("RX_DATA_0 = 0x%08h (should have 0xDE in LSB)", read_result);
        if (read_result[7:0] == 8'hDE) $display("[PASS] New data received");
        else $display("[FAIL] New data not captured");

        cpu_read(32'h3000_0010, read_result);
        $display("RX_DATA_3 = 0x%08h (should have 0xAD in MSB)", read_result);
        if (read_result[31:24] == 8'hAD) $display("[PASS] MSB correct");
        else $display("[FAIL] MSB mismatch");

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
        #100000;
        $display("[TIMEOUT] Simulation took too long!");
        $finish;
    end

endmodule
