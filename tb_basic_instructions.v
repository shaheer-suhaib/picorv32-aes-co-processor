`timescale 1 ns / 1 ps

/***************************************************************
 * Minimal PicoRV32 Testbench — Understanding Instruction Flow
 *
 * This testbench strips away AES/SPI and focuses ONLY on how
 * the CPU fetches and executes basic RISC-V instructions.
 *
 * ┌──────────────────────────────────────────────────────────┐
 * │ HOW IT WORKS                                            │
 * │                                                         │
 * │ PicoRV32 has NO internal memory. It talks to the        │
 * │ outside world through a simple memory bus:              │
 * │                                                         │
 * │   CPU asserts:  mem_valid = 1                           │
 * │                 mem_addr  = address to read/write       │
 * │                 mem_instr = 1 if fetching instruction   │
 * │                 mem_wstrb = 0000 for read, else write   │
 * │                                                         │
 * │   Testbench responds:  mem_rdata = data at that addr    │
 * │                        mem_ready = 1 (done)             │
 * │                                                         │
 * │ The CPU starts at PROGADDR_RESET (0x00000000 by         │
 * │ default), reads 4 bytes (one 32-bit instruction),       │
 * │ executes it, then fetches the next one at PC+4.         │
 * │                                                         │
 * │ Instructions and data live in the SAME memory array.    │
 * │ The CPU uses mem_instr to tell you which is which,      │
 * │ but the memory doesn't care — it just returns data.     │
 * └──────────────────────────────────────────────────────────┘
 *
 * Program:
 *   0x00: addi x1, x0, 5       // x1 = 5
 *   0x04: addi x2, x0, 10      // x2 = 10
 *   0x08: add  x3, x1, x2      // x3 = x1 + x2 = 15
 *   0x0C: sw   x3, 0x100(x0)   // mem[0x100] = x3 (store result)
 *   0x10: lw   x4, 0x100(x0)   // x4 = mem[0x100] (load it back)
 *   0x14: addi x5, x0, 15      // x5 = 15 (expected value)
 *   0x18: beq  x4, x5, +8      // if x4 == x5, jump to PASS
 *   0x1C: jal  x0, 0x1C        // FAIL: infinite loop here
 *   0x20: sw   x4, 0x200(x0)   // PASS: store to 0x200 as flag
 *   0x24: jal  x0, 0x24        // PASS: halt (infinite loop)
 *
 * Run:
 *   iverilog -g2012 -o tb_basic.vvp picorv32.v tb_basic_instructions.v
 *   vvp tb_basic.vvp
 *   gtkwave tb_basic_instructions.vcd   (optional)
 ***************************************************************/

module tb_basic_instructions;

    // =========================================================
    // Clock and Reset
    // =========================================================
    reg clk = 0;
    reg resetn = 0;
    wire trap;

    always #5 clk = ~clk;  // 100 MHz (10ns period)

    // =========================================================
    // VCD Waveform Dump
    // =========================================================
    initial begin
        $dumpfile("tb_basic_instructions.vcd");
        $dumpvars(0, tb_basic_instructions);
    end

    // =========================================================
    // Memory Bus Signals
    //
    // This is the ONLY interface between the CPU and the world.
    // There is no separate "instruction bus" — instructions and
    // data share the same bus. mem_instr tells you which it is.
    // =========================================================
    wire        mem_valid;   // CPU says: "I want to access memory"
    wire        mem_instr;   // CPU says: "this access is an instruction fetch"
    reg         mem_ready;   // We say:   "here's your data / write accepted"
    wire [31:0] mem_addr;    // CPU says: "at this address"
    wire [31:0] mem_wdata;   // CPU says: "write this data" (for stores)
    wire [ 3:0] mem_wstrb;   // CPU says: "which bytes to write" (0=read)
    reg  [31:0] mem_rdata;   // We say:   "here's the data you asked for"

    // =========================================================
    // Memory Array — 256 words = 1KB
    //
    // This is just a Verilog reg array. The CPU doesn't know or
    // care what's behind the bus. It could be BRAM, SRAM, or
    // a peripheral — the protocol is the same.
    // =========================================================
    parameter MEM_SIZE = 256;
    reg [31:0] memory [0:MEM_SIZE-1];

    // =========================================================
    // Memory Controller
    //
    // This is the critical piece that connects CPU to memory.
    // Every clock cycle, we check if mem_valid is high.
    // If so, we serve the request in ONE cycle (mem_ready=1).
    //
    // Timing diagram for an instruction fetch:
    //
    //   clk     ──┐ ┌─┐ ┌─┐ ┌─┐ ┌─
    //             │ │ │ │ │ │ │ │
    //   mem_valid _/───────\________    CPU raises valid
    //   mem_addr  X| 0x00  |X           Address of instruction
    //   mem_instr _/───────\________    It's a fetch (not load/store)
    //   mem_wstrb  | 0000  |            All zeros = read
    //   mem_rdata  X| instr|X           We put instruction on rdata
    //   mem_ready ________/─\______     We assert ready after 1 cycle
    //
    // For a store (sw):
    //   mem_wstrb = 4'b1111   (write all 4 bytes)
    //   mem_wdata = data to write
    //   mem_instr = 0         (not an instruction fetch)
    // =========================================================
    always @(posedge clk) begin
        mem_ready <= 0;      // Default: not ready

        if (mem_valid && !mem_ready) begin
            mem_ready <= 1;  // Respond next cycle

            if (mem_addr < MEM_SIZE * 4) begin
                // === READ (instruction fetch or lw) ===
                mem_rdata <= memory[mem_addr >> 2];

                // === WRITE (sw instruction) ===
                // mem_wstrb bits tell us which bytes to write:
                //   wstrb = 4'b0000 → read  (no bytes written)
                //   wstrb = 4'b1111 → write all 4 bytes (sw)
                //   wstrb = 4'b0011 → write lower 2 bytes (sh)
                //   wstrb = 4'b0001 → write lowest byte (sb)
                if (mem_wstrb[0]) memory[mem_addr >> 2][ 7: 0] <= mem_wdata[ 7: 0];
                if (mem_wstrb[1]) memory[mem_addr >> 2][15: 8] <= mem_wdata[15: 8];
                if (mem_wstrb[2]) memory[mem_addr >> 2][23:16] <= mem_wdata[23:16];
                if (mem_wstrb[3]) memory[mem_addr >> 2][31:24] <= mem_wdata[31:24];
            end else begin
                mem_rdata <= 32'hDEADBEEF;  // Unmapped address
            end
        end
    end

    // =========================================================
    // PicoRV32 CPU Instance
    //
    // Minimal config: no AES, no IRQs, no MUL/DIV, no PCPI.
    // Just a bare RV32I core that fetches and executes.
    // =========================================================
    picorv32 #(
        .ENABLE_COUNTERS     (0),
        .ENABLE_COUNTERS64   (0),
        .ENABLE_REGS_16_31   (1),
        .ENABLE_REGS_DUALPORT(1),
        .LATCHED_MEM_RDATA   (0),
        .TWO_STAGE_SHIFT     (0),
        .BARREL_SHIFTER      (0),
        .TWO_CYCLE_COMPARE   (0),
        .TWO_CYCLE_ALU       (0),
        .COMPRESSED_ISA      (0),
        .CATCH_MISALIGN      (0),
        .CATCH_ILLINSN       (0),
        .ENABLE_PCPI         (0),
        .ENABLE_MUL          (0),
        .ENABLE_DIV          (0),
        .ENABLE_AES          (0),
        .ENABLE_AES_DEC      (0),
        .ENABLE_IRQ          (0),
        .ENABLE_TRACE        (0),
        .REGS_INIT_ZERO      (1),
        .PROGADDR_RESET      (32'h0000_0000)  // CPU starts fetching here
    ) cpu (
        .clk       (clk),
        .resetn    (resetn),
        .trap      (trap),

        // Memory bus — the ONLY connection
        .mem_valid  (mem_valid),
        .mem_instr  (mem_instr),
        .mem_ready  (mem_ready),
        .mem_addr   (mem_addr),
        .mem_wdata  (mem_wdata),
        .mem_wstrb  (mem_wstrb),
        .mem_rdata  (mem_rdata),

        // Unused interfaces — tie off
        .pcpi_wr    (1'b0),
        .pcpi_rd    (32'b0),
        .pcpi_wait  (1'b0),
        .pcpi_ready (1'b0),
        .irq        (32'b0),
        .eoi        (),
        .trace_valid(),
        .trace_data ()
    );

    // =========================================================
    // RISC-V Instruction Encoding Helpers
    //
    // These functions build 32-bit machine code from fields.
    // Each RISC-V instruction is exactly 32 bits with a fixed
    // format. The CPU reads these bits and decodes them.
    //
    // Example: addi x1, x0, 5
    //   imm12=5, rs1=x0(0), funct3=000, rd=x1(1), opcode=0010011
    //   Binary: 000000000101 | 00000 | 000 | 00001 | 0010011
    //   Hex:    0x00500093
    // =========================================================

    // R-type: add rd, rs1, rs2
    function [31:0] add;
        input [4:0] rd, rs1, rs2;
        add = {7'b0000000, rs2, rs1, 3'b000, rd, 7'b0110011};
    endfunction

    // I-type: addi rd, rs1, imm12
    function [31:0] addi;
        input [4:0] rd, rs1;
        input [11:0] imm;
        addi = {imm, rs1, 3'b000, rd, 7'b0010011};
    endfunction

    // S-type: sw rs2, imm12(rs1)
    function [31:0] sw;
        input [4:0] rs2, rs1;
        input [11:0] imm;
        sw = {imm[11:5], rs2, rs1, 3'b010, imm[4:0], 7'b0100011};
    endfunction

    // I-type: lw rd, imm12(rs1)
    function [31:0] lw;
        input [4:0] rd, rs1;
        input [11:0] imm;
        lw = {imm, rs1, 3'b010, rd, 7'b0000011};
    endfunction

    // B-type: beq rs1, rs2, imm13
    function [31:0] beq;
        input [4:0] rs1, rs2;
        input [12:0] imm;
        beq = {imm[12], imm[10:5], rs2, rs1, 3'b000, imm[4:1], imm[11], 7'b1100011};
    endfunction

    // J-type: jal rd, imm21  (jal x0 = jump without link = plain jump)
    function [31:0] jal;
        input [4:0] rd;
        input [20:0] imm;
        jal = {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'b1101111};
    endfunction

    // =========================================================
    // Load Program Into Memory
    //
    // We manually place encoded instructions at word-aligned
    // addresses. The CPU will start at 0x00 and fetch them
    // sequentially (unless a branch/jump changes the PC).
    //
    // Memory layout:
    //   0x000-0x024: Instructions (our program)
    //   0x100:       Scratch location for sw/lw test
    //   0x200:       "PASS" flag location
    // =========================================================
    integer idx;

    initial begin
        // Fill memory with NOPs (addi x0, x0, 0 = 0x00000013)
        // This is a safety net — if the CPU goes off the rails,
        // it executes NOPs instead of garbage.
        for (idx = 0; idx < MEM_SIZE; idx = idx + 1)
            memory[idx] = 32'h00000013;  // NOP

        // ── The actual program ──

        // Addr 0x00: x1 = 5
        memory[0] = addi(1, 0, 12'd5);
        //          ^^^^  ^  ^  ^^^^
        //          rd=x1 |  |  imm=5
        //             rs1=x0 (zero register, always 0)
        //          Result: x1 = 0 + 5 = 5

        // Addr 0x04: x2 = 10
        memory[1] = addi(2, 0, 12'd10);

        // Addr 0x08: x3 = x1 + x2 = 15
        memory[2] = add(3, 1, 2);

        // Addr 0x0C: mem[0x100] = x3
        // Store the result to memory so we can verify it
        memory[3] = sw(3, 0, 12'h100);
        //          sw(rs2=x3, rs1=x0, offset=0x100)
        //          Address = x0 + 0x100 = 0x100
        //          The CPU will issue:
        //            mem_valid=1, mem_addr=0x100, mem_wstrb=4'b1111,
        //            mem_wdata=15, mem_instr=0

        // Addr 0x10: x4 = mem[0x100]  (load it back)
        memory[4] = lw(4, 0, 12'h100);
        //          The CPU will issue:
        //            mem_valid=1, mem_addr=0x100, mem_wstrb=0,
        //            mem_instr=0
        //          We respond with mem_rdata=memory[0x40]=15

        // Addr 0x14: x5 = 15  (expected value)
        memory[5] = addi(5, 0, 12'd15);

        // Addr 0x18: if (x4 == x5) jump to 0x20 (+8 bytes forward)
        memory[6] = beq(4, 5, 13'd8);
        //          If equal, PC = 0x18 + 8 = 0x20 (PASS)
        //          If not equal, PC = 0x1C (FAIL)

        // Addr 0x1C: FAIL — infinite loop
        memory[7] = jal(0, 21'd0);  // jump to self (offset 0)

        // Addr 0x20: PASS — store result to 0x200 as success flag
        memory[8] = sw(4, 0, 12'h200);

        // Addr 0x24: PASS — halt (infinite loop)
        memory[9] = jal(0, 21'd0);

        $display("");
        $display("============================================================");
        $display("  PicoRV32 Basic Instruction Testbench");
        $display("============================================================");
        $display("  Program:");
        $display("    0x00: addi x1, x0, 5       // x1 = 5");
        $display("    0x04: addi x2, x0, 10      // x2 = 10");
        $display("    0x08: add  x3, x1, x2      // x3 = 15");
        $display("    0x0C: sw   x3, 0x100(x0)   // mem[0x100] = 15");
        $display("    0x10: lw   x4, 0x100(x0)   // x4 = mem[0x100]");
        $display("    0x14: addi x5, x0, 15      // x5 = 15");
        $display("    0x18: beq  x4, x5, +8      // if equal, goto PASS");
        $display("    0x1C: jal  x0, 0            // FAIL: loop forever");
        $display("    0x20: sw   x4, 0x200(x0)   // PASS: flag = result");
        $display("    0x24: jal  x0, 0            // PASS: halt");
        $display("============================================================");
        $display("");

        // Release reset after 100ns
        #100;
        resetn = 1;
        $display("[%0t] Reset released — CPU starts fetching at 0x00000000", $time);
        $display("");
    end

    // =========================================================
    // Bus Monitor — Watch Every Memory Transaction
    //
    // This is the key to understanding how instructions flow.
    // Every time the CPU completes a memory access, we print
    // what happened and WHY.
    // =========================================================
    integer cycle_count = 0;

    always @(posedge clk) begin
        if (resetn) cycle_count <= cycle_count + 1;

        if (mem_valid && mem_ready) begin
            if (mem_instr) begin
                // ── INSTRUCTION FETCH ──
                // The CPU is reading the next instruction to execute.
                // mem_addr = current PC (program counter)
                // mem_rdata = the 32-bit instruction at that address
                $display("[Cycle %3d] FETCH  addr=0x%03h  instr=0x%08h  ← %s",
                    cycle_count, mem_addr, mem_rdata, decode_instr(mem_rdata));
            end
            else if (mem_wstrb == 4'b0000) begin
                // ── DATA READ (lw) ──
                // wstrb=0 means read. CPU is executing a load instruction.
                $display("[Cycle %3d] LOAD   addr=0x%03h  data=0x%08h  (=%0d)",
                    cycle_count, mem_addr, mem_rdata, mem_rdata);
            end
            else begin
                // ── DATA WRITE (sw) ──
                // wstrb!=0 means write. CPU is executing a store instruction.
                $display("[Cycle %3d] STORE  addr=0x%03h  data=0x%08h  (=%0d)  wstrb=%b",
                    cycle_count, mem_addr, mem_wdata, mem_wdata, mem_wstrb);
            end
        end
    end

    // =========================================================
    // Simple Instruction Decoder (for display only)
    //
    // Decodes the 32-bit instruction back to human-readable text
    // so you can see what the CPU is about to execute.
    // =========================================================
    function [255:0] decode_instr;  // 32-char string
        input [31:0] instr;
        reg [6:0] opcode;
        reg [4:0] rd, rs1, rs2;
        reg [2:0] funct3;
        reg [6:0] funct7;
        reg [11:0] imm_i, imm_s;
        reg [12:0] imm_b;
        begin
            opcode = instr[6:0];
            rd     = instr[11:7];
            funct3 = instr[14:12];
            rs1    = instr[19:15];
            rs2    = instr[24:20];
            funct7 = instr[31:25];
            imm_i  = instr[31:20];
            imm_s  = {instr[31:25], instr[11:7]};
            imm_b  = {instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};

            case (opcode)
                7'b0110011: begin // R-type
                    if (funct7 == 0 && funct3 == 0)
                        $sformat(decode_instr, "add  x%0d, x%0d, x%0d", rd, rs1, rs2);
                    else if (funct7 == 7'h20 && funct3 == 0)
                        $sformat(decode_instr, "sub  x%0d, x%0d, x%0d", rd, rs1, rs2);
                    else
                        $sformat(decode_instr, "R-type f3=%0d f7=%0d", funct3, funct7);
                end
                7'b0010011: begin // I-type ALU
                    if (funct3 == 0)
                        $sformat(decode_instr, "addi x%0d, x%0d, %0d", rd, rs1, $signed(imm_i));
                    else
                        $sformat(decode_instr, "I-alu f3=%0d imm=%0d", funct3, $signed(imm_i));
                end
                7'b0000011: begin // Load
                    $sformat(decode_instr, "lw   x%0d, 0x%0h(x%0d)", rd, imm_i, rs1);
                end
                7'b0100011: begin // Store
                    $sformat(decode_instr, "sw   x%0d, 0x%0h(x%0d)", rs2, imm_s, rs1);
                end
                7'b1100011: begin // Branch
                    if (funct3 == 0)
                        $sformat(decode_instr, "beq  x%0d, x%0d, %0d", rs1, rs2, $signed(imm_b));
                    else if (funct3 == 1)
                        $sformat(decode_instr, "bne  x%0d, x%0d, %0d", rs1, rs2, $signed(imm_b));
                    else
                        $sformat(decode_instr, "branch f3=%0d", funct3);
                end
                7'b1101111: begin // JAL
                    $sformat(decode_instr, "jal  x%0d, ...", rd);
                end
                7'b0110111: begin // LUI
                    $sformat(decode_instr, "lui  x%0d, 0x%05h", rd, instr[31:12]);
                end
                default: begin
                    if (instr == 32'h00000013)
                        decode_instr = "nop";
                    else
                        $sformat(decode_instr, "??? (0x%08h)", instr);
                end
            endcase
        end
    endfunction

    // =========================================================
    // Result Checker & Timeout
    // =========================================================
    always @(posedge clk) begin
        // Check for success: CPU stored result to 0x200
        if (resetn && mem_valid && mem_ready && mem_wstrb != 0 && mem_addr == 32'h200) begin
            $display("");
            $display("============================================================");
            if (mem_wdata == 32'd15) begin
                $display("  PASS!  mem[0x200] = %0d (5 + 10 = 15)", mem_wdata);
            end else begin
                $display("  FAIL!  mem[0x200] = %0d (expected 15)", mem_wdata);
            end
            $display("  Completed in %0d cycles", cycle_count);
            $display("============================================================");
            $display("");
            #100;
            $finish;
        end

        // Timeout
        if (cycle_count > 500) begin
            $display("");
            $display("TIMEOUT after %0d cycles", cycle_count);
            // Check if CPU halted at FAIL address (0x1C)
            if (memory['h200 >> 2] == 32'h00000013)
                $display("  mem[0x200] was never written — CPU may have taken FAIL path");
            $finish;
        end

        // Trap detection
        if (trap) begin
            $display("[Cycle %3d] CPU TRAPPED!", cycle_count);
            $finish;
        end
    end

endmodule