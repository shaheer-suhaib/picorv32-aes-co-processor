/*
 * FPGA Top Module for PicoRV32 + AES Co-Processor
 * with 8-Lane Parallel SPI Output
 */

module aes_soc_top (
    input         clk,          // FPGA clock (e.g., 100 MHz on Basys3)
    input         resetn_btn,   // Active-low reset button

    // 8-Lane Parallel SPI Output
    output [7:0]  spi_data,     // Connect to 8 GPIO pins (e.g., Pmod)
    output        spi_clk,      // SPI clock strobe
    output        spi_cs_n,     // Chip select (active low)
    output        spi_active,   // Transfer in progress (optional LED)

    // Status LEDs
    output        led_trap,     // CPU trap indicator
    output        led_running   // Heartbeat / running indicator
);

    //=========================================================
    // Parameters
    //=========================================================
    parameter MEM_SIZE = 1024;  // Memory words (4KB)

    //=========================================================
    // Internal Signals
    //=========================================================
    wire        resetn;
    wire        trap;

    // Memory interface
    wire        mem_valid;
    wire        mem_instr;
    wire        mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    wire [31:0] mem_rdata;

    //=========================================================
    // Reset Synchronizer (debounce external reset)
    //=========================================================
    reg [3:0] reset_cnt = 0;
    wire resetn_sync = &reset_cnt;

    always @(posedge clk) begin
        if (!resetn_btn)
            reset_cnt <= 0;
        else if (!resetn_sync)
            reset_cnt <= reset_cnt + 1;
    end

    assign resetn = resetn_sync;

    //=========================================================
    // PicoRV32 CPU with AES Co-Processor
    //=========================================================
    picorv32 #(
        .ENABLE_COUNTERS     (0),
        .ENABLE_COUNTERS64   (0),
        .ENABLE_REGS_16_31   (1),
        .ENABLE_REGS_DUALPORT(1),
        .LATCHED_MEM_RDATA   (0),
        .TWO_STAGE_SHIFT     (0),
        .BARREL_SHIFTER      (1),
        .TWO_CYCLE_COMPARE   (0),
        .TWO_CYCLE_ALU       (0),
        .COMPRESSED_ISA      (1),
        .CATCH_MISALIGN      (0),
        .CATCH_ILLINSN       (0),
        .ENABLE_PCPI         (0),
        .ENABLE_MUL          (1),
        .ENABLE_FAST_MUL     (0),
        .ENABLE_DIV          (1),
        .ENABLE_IRQ          (0),
        .ENABLE_IRQ_QREGS    (0),
        .ENABLE_IRQ_TIMER    (0),
        .ENABLE_TRACE        (0),
        .ENABLE_AES          (1),  // Enable AES encryption
        .ENABLE_AES_DEC      (0)   // Disable decryption (saves area)
    ) cpu (
        .clk           (clk),
        .resetn        (resetn),
        .trap          (trap),

        // Memory interface
        .mem_valid     (mem_valid),
        .mem_instr     (mem_instr),
        .mem_ready     (mem_ready),
        .mem_addr      (mem_addr),
        .mem_wdata     (mem_wdata),
        .mem_wstrb     (mem_wstrb),
        .mem_rdata     (mem_rdata),

        // 8-Lane Parallel SPI
        .aes_spi_data  (spi_data),
        .aes_spi_clk   (spi_clk),
        .aes_spi_cs_n  (spi_cs_n),
        .aes_spi_active(spi_active),

        // Unused interfaces
        .mem_la_read   (),
        .mem_la_write  (),
        .mem_la_addr   (),
        .mem_la_wdata  (),
        .mem_la_wstrb  (),
        .pcpi_valid    (),
        .pcpi_insn     (),
        .pcpi_rs1      (),
        .pcpi_rs2      (),
        .pcpi_wr       (1'b0),
        .pcpi_rd       (32'b0),
        .pcpi_wait     (1'b0),
        .pcpi_ready    (1'b0),
        .irq           (32'b0),
        .eoi           (),
        .trace_valid   (),
        .trace_data    ()
    );

    //=========================================================
    // Block RAM (Firmware Storage)
    //=========================================================
    reg [31:0] memory [0:MEM_SIZE-1];
    reg [31:0] mem_rdata_reg;
    reg mem_ready_reg;

    // Initialize memory from hex file (firmware)
    initial begin
        $readmemh("firmware.hex", memory);
    end

    // Memory controller
    always @(posedge clk) begin
        mem_ready_reg <= 0;
        if (mem_valid && !mem_ready_reg) begin
            mem_ready_reg <= 1;
            mem_rdata_reg <= memory[mem_addr[31:2]];
            if (mem_wstrb[0]) memory[mem_addr[31:2]][7:0]   <= mem_wdata[7:0];
            if (mem_wstrb[1]) memory[mem_addr[31:2]][15:8]  <= mem_wdata[15:8];
            if (mem_wstrb[2]) memory[mem_addr[31:2]][23:16] <= mem_wdata[23:16];
            if (mem_wstrb[3]) memory[mem_addr[31:2]][31:24] <= mem_wdata[31:24];
        end
    end

    assign mem_ready = mem_ready_reg;
    assign mem_rdata = mem_rdata_reg;

    //=========================================================
    // Status LEDs
    //=========================================================
    assign led_trap = trap;

    // Heartbeat LED (blinks when running)
    reg [23:0] heartbeat_cnt;
    always @(posedge clk)
        heartbeat_cnt <= heartbeat_cnt + 1;
    assign led_running = heartbeat_cnt[23];

endmodule
