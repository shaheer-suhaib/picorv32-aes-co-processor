
`timescale 1 ns / 1 ps

/***************************************************************
 * Comprehensive Testbench for PicoRV32 AES Co-Processor
 * with 8-Lane Parallel SPI Output
 *
 * This testbench verifies:
 * 1. Direct instruction injection into memory
 * 2. AES-128 encryption correctness with NIST test vectors
 * 3. 8-Lane Parallel SPI transmission (8 bits per clock)
 *    - 128 bits transmitted in just 16 clock cycles!
 * 4. AES_READ instruction to verify ciphertext readback
 * 5. Memory storage verification
 *
 * Test Vectors (FIPS-197 Appendix B):
 *   Plaintext:  0x00112233445566778899aabbccddeeff
 *   Key:        0x000102030405060708090a0b0c0d0e0f
 *   Ciphertext: 0x69c4e0d86a7b0430d8cdb78070b4c55a
 ***************************************************************/

module tb_picorv32_aes_coprocessor;

    //=========================================================
    // Parameters
    //=========================================================
    parameter CLK_PERIOD = 10;          // 100 MHz clock
    parameter MEM_SIZE = 512;           // 512 words = 2KB memory
    parameter TIMEOUT_CYCLES = 50000;   // Max cycles before timeout

    //=========================================================
    // Clock and Reset
    //=========================================================
    reg clk = 1;
    reg resetn = 0;
    wire trap;

    always #(CLK_PERIOD/2) clk = ~clk;

    //=========================================================
    // VCD Dump for Waveform Viewing
    //=========================================================
    initial begin
        $dumpfile("tb_picorv32_aes_coprocessor.vcd");
        $dumpvars(0, tb_picorv32_aes_coprocessor);
    end

    //=========================================================
    // 8-Lane Parallel SPI Interface Signals
    //=========================================================
    wire [7:0] aes_spi_data;    // 8 parallel data lanes
    wire       aes_spi_clk;     // Clock strobe for each byte
    wire       aes_spi_cs_n;    // Chip select (active low)
    wire       aes_spi_active;  // Transfer in progress

    //=========================================================
    // 8-Lane SPI Capture Logic (much simpler than serial!)
    //=========================================================
    reg [7:0]  spi_received_bytes [0:15];
    reg [4:0]  spi_byte_count = 0;
    reg        spi_prev_clk = 0;
    reg        spi_transfer_complete = 0;

    //=========================================================
    // Memory Interface
    //=========================================================
    wire        mem_valid;
    wire        mem_instr;
    reg         mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    reg  [31:0] mem_rdata;

    // Main memory array
    reg [31:0] memory [0:MEM_SIZE-1];

    //=========================================================
    // Test Control Signals
    //=========================================================
    integer i;
    reg [31:0] cycle_count = 0;
    reg [31:0] instruction_count = 0;
    reg [31:0] last_pc = 32'hFFFFFFFF;
    reg        test_passed = 0;
    reg        encryption_done = 0;

    // Expected ciphertext (FIPS-197 test vector)
    reg [127:0] expected_ciphertext = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;
    reg [127:0] received_ciphertext;

    // Memory write tracking for AES result storage
    reg [3:0]  result_words_written = 0;
    reg        all_results_stored = 0;

    //=========================================================
    // Memory Controller
    //=========================================================
    always @(posedge clk) begin
        mem_ready <= 0;
        if (mem_valid && !mem_ready) begin
            if (mem_addr < (MEM_SIZE * 4)) begin
                mem_ready <= 1;
                mem_rdata <= memory[mem_addr >> 2];
                // Handle byte-wise writes
                if (mem_wstrb[0]) memory[mem_addr >> 2][ 7: 0] <= mem_wdata[ 7: 0];
                if (mem_wstrb[1]) memory[mem_addr >> 2][15: 8] <= mem_wdata[15: 8];
                if (mem_wstrb[2]) memory[mem_addr >> 2][23:16] <= mem_wdata[23:16];
                if (mem_wstrb[3]) memory[mem_addr >> 2][31:24] <= mem_wdata[31:24];
            end else begin
                $display("[%0t] ERROR: Memory access out of range: 0x%08x", $time, mem_addr);
                mem_ready <= 1;
                mem_rdata <= 32'hDEADBEEF;
            end
        end
    end

    //=========================================================
    // AES Result Memory Write Monitor
    // Tracks writes to result area at 0x300 (word indices 192-195)
    //=========================================================
    always @(posedge clk) begin
        if (mem_valid && mem_ready && (mem_wstrb != 4'b0000)) begin
            // Check for writes to the result area (0x300 = addr 768 to 780)
            if (mem_addr >= 32'h300 && mem_addr < 32'h310) begin
                $display("");
                $display("[Cycle %0d] *** AES RESULT STORED TO MEMORY ***", cycle_count);
                $display("    Address:  0x%03x (word index %0d)", mem_addr, mem_addr >> 2);
                $display("    Data:     0x%08x", mem_wdata);

                // Determine which word of the ciphertext this is
                case (mem_addr)
                    32'h300: begin
                        $display("    Meaning:  Ciphertext[31:0]   (AES_READ idx=0 from x8)");
                        $display("    Expected: 0x%08x", expected_ciphertext[31:0]);
                        if (mem_wdata == expected_ciphertext[31:0])
                            $display("    Match:    *** CORRECT ***");
                        else
                            $display("    Match:    *** MISMATCH ***");
                        result_words_written[0] <= 1;
                    end
                    32'h304: begin
                        $display("    Meaning:  Ciphertext[63:32]  (AES_READ idx=1 from x9)");
                        $display("    Expected: 0x%08x", expected_ciphertext[63:32]);
                        if (mem_wdata == expected_ciphertext[63:32])
                            $display("    Match:    *** CORRECT ***");
                        else
                            $display("    Match:    *** MISMATCH ***");
                        result_words_written[1] <= 1;
                    end
                    32'h308: begin
                        $display("    Meaning:  Ciphertext[95:64]  (AES_READ idx=2 from x10)");
                        $display("    Expected: 0x%08x", expected_ciphertext[95:64]);
                        if (mem_wdata == expected_ciphertext[95:64])
                            $display("    Match:    *** CORRECT ***");
                        else
                            $display("    Match:    *** MISMATCH ***");
                        result_words_written[2] <= 1;
                    end
                    32'h30C: begin
                        $display("    Meaning:  Ciphertext[127:96] (AES_READ idx=3 from x11)");
                        $display("    Expected: 0x%08x", expected_ciphertext[127:96]);
                        if (mem_wdata == expected_ciphertext[127:96])
                            $display("    Match:    *** CORRECT ***");
                        else
                            $display("    Match:    *** MISMATCH ***");
                        result_words_written[3] <= 1;
                    end
                endcase
                $display("");
            end
        end
    end

    // Detect when all 4 words have been written
    always @(posedge clk) begin
        if (result_words_written == 4'b1111 && !all_results_stored) begin
            all_results_stored <= 1;
            $display("================================================================");
            $display("  ALL 4 CIPHERTEXT WORDS STORED TO MEMORY!");
            $display("================================================================");
            $display("  Memory[0x300] = 0x%08x  (CT[31:0])",   memory[192]);
            $display("  Memory[0x304] = 0x%08x  (CT[63:32])",  memory[193]);
            $display("  Memory[0x308] = 0x%08x  (CT[95:64])",  memory[194]);
            $display("  Memory[0x30C] = 0x%08x  (CT[127:96])", memory[195]);
            $display("");
            $display("  Full Ciphertext: 0x%08x_%08x_%08x_%08x",
                     memory[195], memory[194], memory[193], memory[192]);
            $display("  Expected:        0x%08x_%08x_%08x_%08x",
                     expected_ciphertext[127:96], expected_ciphertext[95:64],
                     expected_ciphertext[63:32], expected_ciphertext[31:0]);
            $display("================================================================");
            $display("");
        end
    end

    //=========================================================
    // PicoRV32 CPU Instance
    //=========================================================
    picorv32 #(
        .ENABLE_COUNTERS     (0),
        .ENABLE_COUNTERS64   (0),
        .ENABLE_REGS_16_31   (1),
        .ENABLE_REGS_DUALPORT(1),
        .ENABLE_MUL          (0),
        .ENABLE_DIV          (0),
        .ENABLE_AES          (1),
        .ENABLE_IRQ          (0),
        .ENABLE_TRACE        (0),
        .CATCH_MISALIGN      (0),
        .CATCH_ILLINSN       (1)
    ) cpu (
        .clk         (clk),
        .resetn      (resetn),
        .trap        (trap),
        .mem_valid   (mem_valid),
        .mem_instr   (mem_instr),
        .mem_ready   (mem_ready),
        .mem_addr    (mem_addr),
        .mem_wdata   (mem_wdata),
        .mem_wstrb   (mem_wstrb),
        .mem_rdata   (mem_rdata),
        // External PCPI (unused - internal AES used)
        .pcpi_wr     (1'b0),
        .pcpi_rd     (32'b0),
        .pcpi_wait   (1'b0),
        .pcpi_ready  (1'b0),
        // IRQ (unused)
        .irq         (32'b0),
        // 8-Lane Parallel SPI Interface
        .aes_spi_data   (aes_spi_data),
        .aes_spi_clk    (aes_spi_clk),
        .aes_spi_cs_n   (aes_spi_cs_n),
        .aes_spi_active (aes_spi_active)
    );

    //=========================================================
    // Cycle Counter
    //=========================================================
    always @(posedge clk) begin
        if (resetn)
            cycle_count <= cycle_count + 1;
    end

    //=========================================================
    // Instruction Execution Tracker
    //=========================================================
    always @(posedge clk) begin
        if (resetn && mem_valid && mem_instr && mem_ready) begin
            if (mem_addr != last_pc) begin
                last_pc <= mem_addr;
                instruction_count <= instruction_count + 1;
                // Print first 30 instructions for debug
                if (instruction_count < 30) begin
                    $display("[Cycle %0d] PC=0x%04x  Instr=0x%08x  %s",
                             cycle_count, mem_addr, mem_rdata, decode_instruction(mem_rdata));
                end

                // Special tracking for AES_READ instructions
                if (mem_rdata[6:0] == 7'b0001011 && mem_rdata[31:25] == 7'b0100011) begin
                    $display("");
                    $display("[Cycle %0d] >>> AES_READ INSTRUCTION DETECTED <<<", cycle_count);
                    $display("    Instruction: 0x%08x", mem_rdata);
                    $display("    Index (rs1): %0d", mem_rdata[19:15]);
                    $display("    Dest (rd):   x%0d", mem_rdata[11:7]);
                    $display("");
                end

                // Special tracking for SW (store word) instructions to result area
                if (mem_rdata[6:0] == 7'b0100011 && mem_rdata[14:12] == 3'b010) begin
                    // Store word instruction - check if it's storing to result area
                    // rs1 should be x12 (result base addr) for our program
                    if (mem_rdata[19:15] == 5'd12) begin
                        $display("");
                        $display("[Cycle %0d] >>> STORE WORD TO RESULT AREA <<<", cycle_count);
                        $display("    Instruction: 0x%08x", mem_rdata);
                        $display("    Source reg:  x%0d", mem_rdata[24:20]);
                        $display("    Base reg:    x%0d (0x300)", mem_rdata[19:15]);
                        $display("    Offset:      %0d", {mem_rdata[31:25], mem_rdata[11:7]});
                        $display("");
                    end
                end
            end
        end
    end

    //=========================================================
    // Trap Monitor
    //=========================================================
    always @(posedge clk) begin
        if (trap) begin
            $display("");
            $display("!!! TRAP detected at cycle %0d, PC=0x%08x !!!", cycle_count, last_pc);
            $display("    This may indicate an illegal instruction or error.");
            $display("");
        end
    end

//=========================================================
    // 8-Lane Parallel SPI Capture Logic
    // Much simpler than serial - captures full byte on each clock!
    //=========================================================
    reg spi_prev_cs_n = 1;

    always @(posedge clk) begin
        spi_prev_clk <= aes_spi_clk;
        spi_prev_cs_n <= aes_spi_cs_n;

        // Reset counters on CS falling edge (Start of transaction)
        if (!aes_spi_cs_n && spi_prev_cs_n) begin
            spi_byte_count <= 0;
            spi_transfer_complete <= 0;
            $display("[Cycle %0d] >>> 8-Lane Parallel SPI Transfer Started", cycle_count);
        end

        // Detect End of Transfer (CS rising edge)
        if (aes_spi_cs_n && !spi_prev_cs_n) begin
            spi_transfer_complete <= 1;
            $display("[Cycle %0d] <<< 8-Lane SPI Transfer Complete (%0d bytes in %0d clocks)",
                     cycle_count, spi_byte_count, spi_byte_count);
        end

        // Capture Data: 8-lane parallel - full byte on each clock pulse!
        if (!aes_spi_cs_n) begin
            if (aes_spi_clk && !spi_prev_clk) begin // Rising Edge Detect
                // Capture full byte directly from 8 parallel data lines
                spi_received_bytes[spi_byte_count] <= aes_spi_data;
                $display("    SPI Byte[%2d] = 0x%02x (8-lane parallel)", spi_byte_count, aes_spi_data);
                spi_byte_count <= spi_byte_count + 1;
            end
        end
    end
    //=========================================================
    // Instruction Decoder (for debug display)
    //=========================================================
    function [255:0] decode_instruction;
        input [31:0] instr;
        reg [6:0] opcode;
        reg [6:0] funct7;
        reg [2:0] funct3;
        begin
            opcode = instr[6:0];
            funct7 = instr[31:25];
            funct3 = instr[14:12];

            case (opcode)
                7'b0010011: decode_instruction = "ADDI/ALU-I";
                7'b0110011: decode_instruction = "ADD/ALU-R";
                7'b0000011: decode_instruction = "LOAD";
                7'b0100011: decode_instruction = "STORE";
                7'b1100011: decode_instruction = "BRANCH";
                7'b1101111: decode_instruction = "JAL";
                7'b1100111: decode_instruction = "JALR";
                7'b0110111: decode_instruction = "LUI";
                7'b0010111: decode_instruction = "AUIPC";
                7'b0001011: begin  // Custom opcode for AES
                    case (funct7)
                        7'b0100000: decode_instruction = "AES_LOAD_PT";
                        7'b0100001: decode_instruction = "AES_LOAD_KEY";
                        7'b0100010: decode_instruction = "AES_START";
                        7'b0100011: decode_instruction = "AES_READ";
                        7'b0100100: decode_instruction = "AES_STATUS";
                        default:    decode_instruction = "AES_UNKNOWN";
                    endcase
                end
                default: decode_instruction = "UNKNOWN";
            endcase
        end
    endfunction

    //=========================================================
    // AES Instruction Encoding Functions
    //=========================================================

    // RISC-V I-type: imm[11:0] | rs1 | funct3 | rd | opcode
    function [31:0] encode_addi;
        input [4:0] rd;
        input [4:0] rs1;
        input [11:0] imm;
        begin
            encode_addi = {imm, rs1, 3'b000, rd, 7'b0010011};
        end
    endfunction

    // RISC-V Load Word: imm[11:0] | rs1 | funct3=010 | rd | opcode
    function [31:0] encode_lw;
        input [4:0] rd;
        input [4:0] rs1;
        input [11:0] offset;
        begin
            encode_lw = {offset, rs1, 3'b010, rd, 7'b0000011};
        end
    endfunction

    // RISC-V Store Word: imm[11:5] | rs2 | rs1 | funct3=010 | imm[4:0] | opcode
    function [31:0] encode_sw;
        input [4:0] rs2;
        input [4:0] rs1;
        input [11:0] offset;
        begin
            encode_sw = {offset[11:5], rs2, rs1, 3'b010, offset[4:0], 7'b0100011};
        end
    endfunction

    // AES custom instruction: funct7 | rs2 | rs1 | funct3=000 | rd | opcode=0001011
    function [31:0] encode_aes;
        input [6:0] funct7;
        input [4:0] rs2;
        input [4:0] rs1;
        input [4:0] rd;
        begin
            encode_aes = {funct7, rs2, rs1, 3'b000, rd, 7'b0001011};
        end
    endfunction

    // Branch if equal: imm[12|10:5] | rs2 | rs1 | funct3=000 | imm[4:1|11] | opcode
    function [31:0] encode_beq;
        input [4:0] rs1;
        input [4:0] rs2;
        input signed [12:0] offset;  // Byte offset (must be even)
        begin
            encode_beq = {offset[12], offset[10:5], rs2, rs1, 3'b000, offset[4:1], offset[11], 7'b1100011};
        end
    endfunction

    // Jump and Link: imm[20|10:1|11|19:12] | rd | opcode
    function [31:0] encode_jal;
        input [4:0] rd;
        input signed [20:0] offset;
        begin
            encode_jal = {offset[20], offset[10:1], offset[11], offset[19:12], rd, 7'b1101111};
        end
    endfunction

    //=========================================================
    // AES Instruction Encodings (Constants)
    //=========================================================
    localparam AES_FUNCT7_LOAD_PT  = 7'b0100000;  // 0x20
    localparam AES_FUNCT7_LOAD_KEY = 7'b0100001;  // 0x21
    localparam AES_FUNCT7_START    = 7'b0100010;  // 0x22
    localparam AES_FUNCT7_READ     = 7'b0100011;  // 0x23
    localparam AES_FUNCT7_STATUS   = 7'b0100100;  // 0x24

    //=========================================================
    // Memory Initialization - Load Test Program
    //=========================================================
    initial begin
        // Initialize all memory to NOP
        for (i = 0; i < MEM_SIZE; i = i + 1)
            memory[i] = 32'h00000013;  // NOP (addi x0, x0, 0)

        //=====================================================
        // TEST PROGRAM: AES Encryption with SPI Output
        //=====================================================
        // Register allocation:
        //   x1-x3  : Index values 1, 2, 3
        //   x4     : Key base address (0x200)
        //   x5     : Temporary data register
        //   x6     : Plaintext base address (0x100)
        //   x7     : Status/result register
        //   x8-x11 : Ciphertext readback registers
        //   x12    : Result storage address (0x300)
        //=====================================================

        // === Setup registers with constants ===
        memory[0]  = encode_addi(5'd1, 5'd0, 12'd1);     // addi x1, x0, 1
        memory[1]  = encode_addi(5'd2, 5'd0, 12'd2);     // addi x2, x0, 2
        memory[2]  = encode_addi(5'd3, 5'd0, 12'd3);     // addi x3, x0, 3
        memory[3]  = encode_addi(5'd6, 5'd0, 12'h100);   // addi x6, x0, 0x100 (PT addr)
        memory[4]  = encode_addi(5'd4, 5'd0, 12'h200);   // addi x4, x0, 0x200 (KEY addr)
        memory[5]  = encode_addi(5'd12, 5'd0, 12'h300);  // addi x12, x0, 0x300 (result addr)

        // === Load Plaintext into AES co-processor ===
        // PT[31:0]
        memory[6]  = encode_lw(5'd5, 5'd6, 12'd0);       // lw x5, 0(x6)
        memory[7]  = encode_aes(AES_FUNCT7_LOAD_PT, 5'd5, 5'd0, 5'd0);  // AES_LOAD_PT idx=0

        // PT[63:32]
        memory[8]  = encode_lw(5'd5, 5'd6, 12'd4);       // lw x5, 4(x6)
        memory[9]  = encode_aes(AES_FUNCT7_LOAD_PT, 5'd5, 5'd1, 5'd0);  // AES_LOAD_PT idx=1

        // PT[95:64]
        memory[10] = encode_lw(5'd5, 5'd6, 12'd8);       // lw x5, 8(x6)
        memory[11] = encode_aes(AES_FUNCT7_LOAD_PT, 5'd5, 5'd2, 5'd0);  // AES_LOAD_PT idx=2

        // PT[127:96]
        memory[12] = encode_lw(5'd5, 5'd6, 12'd12);      // lw x5, 12(x6)
        memory[13] = encode_aes(AES_FUNCT7_LOAD_PT, 5'd5, 5'd3, 5'd0);  // AES_LOAD_PT idx=3

        // === Load Key into AES co-processor ===
        // KEY[31:0]
        memory[14] = encode_lw(5'd5, 5'd4, 12'd0);       // lw x5, 0(x4)
        memory[15] = encode_aes(AES_FUNCT7_LOAD_KEY, 5'd5, 5'd0, 5'd0); // AES_LOAD_KEY idx=0

        // KEY[63:32]
        memory[16] = encode_lw(5'd5, 5'd4, 12'd4);       // lw x5, 4(x4)
        memory[17] = encode_aes(AES_FUNCT7_LOAD_KEY, 5'd5, 5'd1, 5'd0); // AES_LOAD_KEY idx=1

        // KEY[95:64]
        memory[18] = encode_lw(5'd5, 5'd4, 12'd8);       // lw x5, 8(x4)
        memory[19] = encode_aes(AES_FUNCT7_LOAD_KEY, 5'd5, 5'd2, 5'd0); // AES_LOAD_KEY idx=2

        // KEY[127:96]
        memory[20] = encode_lw(5'd5, 5'd4, 12'd12);      // lw x5, 12(x4)
        memory[21] = encode_aes(AES_FUNCT7_LOAD_KEY, 5'd5, 5'd3, 5'd0); // AES_LOAD_KEY idx=3

        // === Start AES Encryption ===
        memory[22] = encode_aes(AES_FUNCT7_START, 5'd0, 5'd0, 5'd0);    // AES_START

        // === Poll for completion ===
        // poll_loop: (address 0x5C = instruction 23)
        memory[23] = encode_aes(AES_FUNCT7_STATUS, 5'd0, 5'd0, 5'd7);   // AES_STATUS -> x7
        memory[24] = encode_beq(5'd7, 5'd0, -13'd4);                     // beq x7, x0, poll_loop

        // === Read back ciphertext for verification ===
        memory[25] = encode_aes(AES_FUNCT7_READ, 5'd0, 5'd0, 5'd8);     // AES_READ idx=0 -> x8
        memory[26] = encode_aes(AES_FUNCT7_READ, 5'd0, 5'd1, 5'd9);     // AES_READ idx=1 -> x9
        memory[27] = encode_aes(AES_FUNCT7_READ, 5'd0, 5'd2, 5'd10);    // AES_READ idx=2 -> x10
        memory[28] = encode_aes(AES_FUNCT7_READ, 5'd0, 5'd3, 5'd11);    // AES_READ idx=3 -> x11

        // === Store ciphertext to memory for verification ===
        memory[29] = encode_sw(5'd8, 5'd12, 12'd0);     // sw x8, 0(x12)
        memory[30] = encode_sw(5'd9, 5'd12, 12'd4);     // sw x9, 4(x12)
        memory[31] = encode_sw(5'd10, 5'd12, 12'd8);    // sw x10, 8(x12)
        memory[32] = encode_sw(5'd11, 5'd12, 12'd12);   // sw x11, 12(x12)

        // === End: Infinite loop ===
        memory[33] = encode_jal(5'd0, 21'd0);           // jal x0, 0 (infinite loop)

        //=====================================================
        // DATA SECTION
        //=====================================================

        // Plaintext at 0x100 (word index 64)
        // Full plaintext: 0x00112233_44556677_8899aabb_ccddeeff
        memory[64] = 32'hccddeeff;  // PT[31:0]
        memory[65] = 32'h8899aabb;  // PT[63:32]
        memory[66] = 32'h44556677;  // PT[95:64]
        memory[67] = 32'h00112233;  // PT[127:96]

        // Key at 0x200 (word index 128)
        // Full key: 0x00010203_04050607_08090a0b_0c0d0e0f
        memory[128] = 32'h0c0d0e0f;  // KEY[31:0]
        memory[129] = 32'h08090a0b;  // KEY[63:32]
        memory[130] = 32'h04050607;  // KEY[95:64]
        memory[131] = 32'h00010203;  // KEY[127:96]

        // Result area at 0x300 (word index 192) - will be written by program
        memory[192] = 32'h00000000;
        memory[193] = 32'h00000000;
        memory[194] = 32'h00000000;
        memory[195] = 32'h00000000;
    end

    //=========================================================
    // Main Test Sequence
    //=========================================================
    initial begin
        $display("");
        $display("================================================================");
        $display("  PicoRV32 AES Co-Processor Comprehensive Testbench");
        $display("================================================================");
        $display("");
        $display("Test Configuration:");
        $display("  - Clock Period: %0d ns (100 MHz)", CLK_PERIOD);
        $display("  - Memory Size:  %0d bytes", MEM_SIZE * 4);
        $display("  - Timeout:      %0d cycles", TIMEOUT_CYCLES);
        $display("");

        // Initialize 8-lane SPI capture
        spi_byte_count = 0;
        spi_transfer_complete = 0;
        for (i = 0; i < 16; i = i + 1)
            spi_received_bytes[i] = 8'h00;

        // Print test vector info
        $display("AES-128 Test Vector (FIPS-197):");
        $display("  Plaintext:        0x%08x_%08x_%08x_%08x",
                 memory[67], memory[66], memory[65], memory[64]);
        $display("  Key:              0x%08x_%08x_%08x_%08x",
                 memory[131], memory[130], memory[129], memory[128]);
        $display("  Expected Cipher:  0x%08x_%08x_%08x_%08x",
                 expected_ciphertext[127:96], expected_ciphertext[95:64],
                 expected_ciphertext[63:32], expected_ciphertext[31:0]);
        $display("");
        $display("================================================================");
        $display("  Starting Execution");
        $display("================================================================");
        $display("");

        // Hold reset
        repeat (20) @(posedge clk);
        resetn <= 1;
        $display("[Cycle 0] Reset released - CPU starting");
        $display("");

        // Wait for completion or timeout
        fork
            begin : wait_complete
                // Wait for SPI transfer to complete
                wait(spi_transfer_complete == 1);
                $display("[INFO] SPI transfer complete, waiting for memory storage...");
                // Wait for all 4 result words to be stored
                wait(all_results_stored == 1);
                $display("[INFO] All results stored to memory!");
                // Give some extra cycles for program to finish
                repeat (100) @(posedge clk);
                disable timeout_check;
            end
            begin : timeout_check
                repeat (TIMEOUT_CYCLES) @(posedge clk);
                $display("");
                $display("!!! TIMEOUT after %0d cycles !!!", TIMEOUT_CYCLES);
                $display("    SPI Complete:      %s", spi_transfer_complete ? "YES" : "NO");
                $display("    Results Stored:    %b (4'b1111 = all)", result_words_written);
                disable wait_complete;
            end
        join

        // Run verification
        verify_results();

        $display("");
        $display("================================================================");
        $display("  Simulation Complete");
        $display("================================================================");
        $display("");
        $finish;
    end

    //=========================================================
    // Results Verification Task
    //=========================================================
    task verify_results;
        reg [127:0] spi_ciphertext;
        reg [127:0] mem_ciphertext;
        reg spi_pass, mem_pass;
        reg [3:0] word_match;
        begin
            $display("");
            $display("================================================================");
            $display("  Verification Results");
            $display("================================================================");
            $display("");

            // Summary statistics
            $display("Execution Statistics:");
            $display("  Total Cycles:       %0d", cycle_count);
            $display("  Instructions Run:   %0d", instruction_count);
            $display("  SPI Bytes Sent:     %0d", spi_byte_count);
            $display("  Result Words Written: %b (1111 = all 4 words)", result_words_written);
            $display("");

            // Reconstruct ciphertext from SPI (bytes transmitted LSB first)
            spi_ciphertext = {
                spi_received_bytes[15], spi_received_bytes[14],
                spi_received_bytes[13], spi_received_bytes[12],
                spi_received_bytes[11], spi_received_bytes[10],
                spi_received_bytes[9],  spi_received_bytes[8],
                spi_received_bytes[7],  spi_received_bytes[6],
                spi_received_bytes[5],  spi_received_bytes[4],
                spi_received_bytes[3],  spi_received_bytes[2],
                spi_received_bytes[1],  spi_received_bytes[0]
            };

            // Read ciphertext from memory (written by AES_READ + SW)
            mem_ciphertext = {
                memory[195], memory[194], memory[193], memory[192]
            };

            $display("SPI Verification:");
            $display("  Received Bytes (hex):");
            $display("    [ 0- 3]: %02x %02x %02x %02x",
                     spi_received_bytes[0], spi_received_bytes[1],
                     spi_received_bytes[2], spi_received_bytes[3]);
            $display("    [ 4- 7]: %02x %02x %02x %02x",
                     spi_received_bytes[4], spi_received_bytes[5],
                     spi_received_bytes[6], spi_received_bytes[7]);
            $display("    [ 8-11]: %02x %02x %02x %02x",
                     spi_received_bytes[8], spi_received_bytes[9],
                     spi_received_bytes[10], spi_received_bytes[11]);
            $display("    [12-15]: %02x %02x %02x %02x",
                     spi_received_bytes[12], spi_received_bytes[13],
                     spi_received_bytes[14], spi_received_bytes[15]);
            $display("");
            $display("  Reconstructed: 0x%032x", spi_ciphertext);
            $display("  Expected:      0x%032x", expected_ciphertext);

            spi_pass = (spi_ciphertext == expected_ciphertext) && (spi_byte_count == 16);
            if (spi_pass)
                $display("  Status:        *** PASS ***");
            else
                $display("  Status:        *** FAIL ***");
            $display("");

            // Detailed Memory Verification
            $display("================================================================");
            $display("  DETAILED MEMORY STORAGE VERIFICATION");
            $display("================================================================");
            $display("");
            $display("  This verifies that AES_READ correctly returns the ciphertext");
            $display("  and that store word (SW) correctly writes it to memory.");
            $display("");

            // Word-by-word comparison
            word_match = 4'b0000;
            $display("  +-----------+------------+------------+--------+");
            $display("  | Address   | Stored     | Expected   | Status |");
            $display("  +-----------+------------+------------+--------+");

            // Word 0: CT[31:0]
            if (memory[192] == expected_ciphertext[31:0]) word_match[0] = 1;
            $display("  | 0x300     | 0x%08x | 0x%08x | %s |",
                     memory[192], expected_ciphertext[31:0],
                     word_match[0] ? " PASS " : " FAIL ");

            // Word 1: CT[63:32]
            if (memory[193] == expected_ciphertext[63:32]) word_match[1] = 1;
            $display("  | 0x304     | 0x%08x | 0x%08x | %s |",
                     memory[193], expected_ciphertext[63:32],
                     word_match[1] ? " PASS " : " FAIL ");

            // Word 2: CT[95:64]
            if (memory[194] == expected_ciphertext[95:64]) word_match[2] = 1;
            $display("  | 0x308     | 0x%08x | 0x%08x | %s |",
                     memory[194], expected_ciphertext[95:64],
                     word_match[2] ? " PASS " : " FAIL ");

            // Word 3: CT[127:96]
            if (memory[195] == expected_ciphertext[127:96]) word_match[3] = 1;
            $display("  | 0x30C     | 0x%08x | 0x%08x | %s |",
                     memory[195], expected_ciphertext[127:96],
                     word_match[3] ? " PASS " : " FAIL ");

            $display("  +-----------+------------+------------+--------+");
            $display("");

            $display("  Instruction Flow Verification:");
            $display("    1. AES_READ idx=0 -> x8  -> SW to 0x300: %s",
                     word_match[0] ? "OK" : "FAILED");
            $display("    2. AES_READ idx=1 -> x9  -> SW to 0x304: %s",
                     word_match[1] ? "OK" : "FAILED");
            $display("    3. AES_READ idx=2 -> x10 -> SW to 0x308: %s",
                     word_match[2] ? "OK" : "FAILED");
            $display("    4. AES_READ idx=3 -> x11 -> SW to 0x30C: %s",
                     word_match[3] ? "OK" : "FAILED");
            $display("");

            mem_pass = (mem_ciphertext == expected_ciphertext);

            $display("  Full Ciphertext Comparison:");
            $display("    Stored:   0x%08x_%08x_%08x_%08x",
                     memory[195], memory[194], memory[193], memory[192]);
            $display("    Expected: 0x%08x_%08x_%08x_%08x",
                     expected_ciphertext[127:96], expected_ciphertext[95:64],
                     expected_ciphertext[63:32], expected_ciphertext[31:0]);
            $display("");

            if (mem_pass)
                $display("  Memory Storage Status: *** PASS ***");
            else
                $display("  Memory Storage Status: *** FAIL ***");
            $display("");

            // Overall result
            $display("================================================================");
            $display("  FINAL TEST SUMMARY");
            $display("================================================================");
            if (spi_pass && mem_pass) begin
                $display("  OVERALL TEST RESULT: *** PASS ***");
                $display("");
                $display("  [OK] AES-128 encryption correct (FIPS-197 test vector)");
                $display("  [OK] 8-Lane Parallel SPI successful (16 bytes in 16 clocks)");
                $display("  [OK] AES_READ instruction works correctly");
                $display("  [OK] Ciphertext correctly stored to memory");
                $display("");
                $display("  Performance: 128-bit transfer in 16 clock cycles (8x faster than serial!)");
            end else begin
                $display("  OVERALL TEST RESULT: *** FAIL ***");
                $display("");
                if (!spi_pass)
                    $display("  [FAIL] 8-Lane SPI transmission");
                else
                    $display("  [OK]   8-Lane SPI transmission");
                if (!mem_pass)
                    $display("  [FAIL] Memory storage");
                else
                    $display("  [OK]   Memory storage");
            end
            $display("================================================================");
        end
    endtask

endmodule
