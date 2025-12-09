`timescale 1 ns / 1 ps

// Simple testbench for fpga_top_encryption
// - drives clock/reset
// - lets the program run
// - prints resulting ciphertext from memory addresses 0x120..0x12C (words 72..75)

module tb_fpga_top_encryption;
    reg clk = 1'b0;
    reg resetn = 1'b0;
    wire trap;

    // 100 MHz clock
    always #5 clk = ~clk;

    // DUT
    fpga_top_encryption uut (
        .clk   (clk),
        .resetn(resetn),
        .trap  (trap)
    );

    // VCD (optional)
    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_fpga_top_encryption.vcd");
            $dumpvars(0, tb_fpga_top_encryption);
        end
    end

    // Reset sequence and run
    initial begin
        $display("=== fpga_top_encryption testbench ===");
        $display("Expect ciphertext at memory[72..75] = 0x69c4e0d8_6a7b0430_d8cdb780_70b4c55a");

        // Hold reset for 20 cycles
        repeat (20) @(posedge clk);
        resetn <= 1'b1;
        $display("[%0t] Reset deasserted", $time);

        // Run long enough for AES to finish
        repeat (5000) @(posedge clk);

        // Show results
        show_results();

        $finish;
    end

    task show_results;
        begin
            $display("");
            $display("Memory dump at 0x120 (words 72..75):");
            $display("  mem[72] (CT[31:0]  ) = 0x%08x", uut.memory[72]);
            $display("  mem[73] (CT[63:32] ) = 0x%08x", uut.memory[73]);
            $display("  mem[74] (CT[95:64] ) = 0x%08x", uut.memory[74]);
            $display("  mem[75] (CT[127:96]) = 0x%08x", uut.memory[75]);
            $display("Full ciphertext: 0x%08x_%08x_%08x_%08x",
                     uut.memory[75], uut.memory[74], uut.memory[73], uut.memory[72]);

            if (uut.memory[72] == 32'h70b4c55a &&
                uut.memory[73] == 32'hd8cdb780 &&
                uut.memory[74] == 32'h6a7b0430 &&
                uut.memory[75] == 32'h69c4e0d8)
                $display("*** PASS: Ciphertext matches expected value ***");
            else
                $display("*** FAIL: Ciphertext mismatch ***");
            $display("");
        end
    endtask

    // Optional trap monitor
    always @(posedge clk) begin
        if (trap)
            $display("[%0t] TRAP asserted", $time);
    end

endmodule


