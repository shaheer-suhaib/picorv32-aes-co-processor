`timescale 1ns / 1ps

module fake_sd_phase1_mmio #(
    parameter [31:0] BASE_ADDR = 32'h0200_0000,
    parameter integer MAX_SECTORS = 1024
) (
    input  wire        clk,
    input  wire        resetn,
    input  wire        mem_valid,
    output reg         mem_ready,
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [3:0]  mem_wstrb,
    output reg  [31:0] mem_rdata,
    input  wire        btnc_level,
    output reg  [31:0] gpio_out_reg,
    output wire        init_done,
    output wire        init_err,
    output wire        busy
);
    localparam [31:0] ADDR_SD_CTRL   = BASE_ADDR + 32'h000;
    localparam [31:0] ADDR_SD_STATUS = BASE_ADDR + 32'h004;
    localparam [31:0] ADDR_SD_SECTOR = BASE_ADDR + 32'h008;
    localparam [31:0] ADDR_GPIO_STAT = BASE_ADDR + 32'h100;
    localparam [31:0] ADDR_GPIO_OUT  = BASE_ADDR + 32'h104;
    localparam [31:0] ADDR_BUF_BASE  = BASE_ADDR + 32'h200;

    reg [7:0] sector_buf [0:511];
    reg [7:0] disk_mem [0:(MAX_SECTORS*512)-1];
    reg [31:0] sector_addr_reg;
    reg wr_done_latched;
    reg busy_reg;
    integer i;
    integer base;
    wire is_write = |mem_wstrb;
    wire [9:0] buf_word_addr = mem_addr[9:0] - ADDR_BUF_BASE[9:0];
    wire buf_sel = (mem_addr >= ADDR_BUF_BASE) && (mem_addr <= BASE_ADDR + 32'h3ff);

    assign init_done = 1'b1;
    assign init_err  = 1'b0;
    assign busy      = busy_reg;

    always @(posedge clk) begin
        if (!resetn) begin
            mem_ready <= 1'b0;
            mem_rdata <= 32'd0;
            gpio_out_reg <= 32'd0;
            sector_addr_reg <= 32'd0;
            wr_done_latched <= 1'b0;
            busy_reg <= 1'b0;
            for (i = 0; i < 512; i = i + 1)
                sector_buf[i] <= 8'h00;
            for (i = 0; i < MAX_SECTORS*512; i = i + 1)
                disk_mem[i] <= 8'h00;
        end else begin
            mem_ready <= 1'b0;
            mem_rdata <= 32'd0;
            busy_reg <= 1'b0;

            if (mem_valid) begin
                mem_ready <= 1'b1;
                if (is_write) begin
                    case (mem_addr)
                        ADDR_SD_CTRL: begin
                            if (mem_wdata[3])
                                wr_done_latched <= 1'b0;
                            if (mem_wdata[1]) begin
                                base = sector_addr_reg * 512;
                                if (base + 511 < MAX_SECTORS*512) begin
                                    for (i = 0; i < 512; i = i + 1)
                                        disk_mem[base + i] <= sector_buf[i];
                                end
                                wr_done_latched <= 1'b1;
                            end
                        end
                        ADDR_SD_SECTOR: begin
                            sector_addr_reg <= mem_wdata;
                        end
                        ADDR_GPIO_OUT: begin
                            gpio_out_reg <= mem_wdata;
                        end
                        default: begin
                            if (buf_sel && buf_word_addr <= 10'd508) begin
                                if (mem_wstrb[0]) sector_buf[buf_word_addr + 10'd0] <= mem_wdata[7:0];
                                if (mem_wstrb[1]) sector_buf[buf_word_addr + 10'd1] <= mem_wdata[15:8];
                                if (mem_wstrb[2]) sector_buf[buf_word_addr + 10'd2] <= mem_wdata[23:16];
                                if (mem_wstrb[3]) sector_buf[buf_word_addr + 10'd3] <= mem_wdata[31:24];
                            end
                        end
                    endcase
                end else begin
                    case (mem_addr)
                        ADDR_SD_CTRL:   mem_rdata <= 32'd0;
                        ADDR_SD_STATUS: mem_rdata <= {27'd0, wr_done_latched, 2'd0, init_err, init_done};
                        ADDR_SD_SECTOR: mem_rdata <= sector_addr_reg;
                        ADDR_GPIO_STAT: mem_rdata <= {31'd0, btnc_level};
                        ADDR_GPIO_OUT:  mem_rdata <= gpio_out_reg;
                        default: begin
                            if (buf_sel && buf_word_addr <= 10'd508) begin
                                mem_rdata <= {sector_buf[buf_word_addr + 10'd3],
                                              sector_buf[buf_word_addr + 10'd2],
                                              sector_buf[buf_word_addr + 10'd1],
                                              sector_buf[buf_word_addr + 10'd0]};
                            end
                        end
                    endcase
                end
            end
        end
    end
endmodule

module tb_dual_txbram_rxsd;
    localparam integer MEM_SIZE_WORDS = 4096;
    localparam [31:0] SD_BASE      = 32'h0200_0000;
    localparam [31:0] SD_END       = 32'h0200_0400;
    localparam [31:0] RXBUF_BASE   = 32'h3000_0000;
    localparam [31:0] RXBUF_END    = 32'h3000_0020;
    localparam [31:0] MAILBOX_BASE = 32'h0400_0000;
    localparam [31:0] MAILBOX_END  = 32'h0400_0020;
    localparam integer IMAGE_BLOCKS = 196;
    localparam integer META_SECTOR = 20;
    localparam integer KEY_SECTOR = 21;
    localparam integer CT_BASE_SECTOR = 22;
    localparam integer DEC_BASE_SECTOR = 218;
    localparam integer IMAGE_BASE_WORD = (32'h1000 >> 2);

    reg clk = 0;
    reg resetn = 0;
    reg btn_start_level = 0;
    always #5 clk = ~clk;

    wire        tx_mem_valid;
    wire        tx_mem_instr;
    wire        tx_mem_ready;
    wire [31:0] tx_mem_addr;
    wire [31:0] tx_mem_wdata;
    wire [3:0]  tx_mem_wstrb;
    wire [31:0] tx_mem_rdata;
    wire        tx_trap;

    wire        rx_mem_valid;
    wire        rx_mem_instr;
    wire        rx_mem_ready;
    wire [31:0] rx_mem_addr;
    wire [31:0] rx_mem_wdata;
    wire [3:0]  rx_mem_wstrb;
    wire [31:0] rx_mem_rdata;
    wire        rx_trap;

    wire tx_bram_sel = tx_mem_addr < 32'h0000_4000;
    wire tx_mb_sel   = tx_mem_addr >= MAILBOX_BASE && tx_mem_addr < MAILBOX_END;
    wire rx_bram_sel  = rx_mem_addr < 32'h0000_4000;
    wire rx_sd_sel    = rx_mem_addr >= SD_BASE && rx_mem_addr < SD_END;
    wire rx_rxbuf_sel = rx_mem_addr >= RXBUF_BASE && rx_mem_addr < RXBUF_END;
    wire rx_mb_sel    = rx_mem_addr >= MAILBOX_BASE && rx_mem_addr < MAILBOX_END;

    wire        tx_bram_ready;
    wire [31:0] tx_bram_rdata;
    wire        rx_bram_ready;
    wire [31:0] rx_bram_rdata;
    wire        tx_mb_ready;
    wire [31:0] tx_mb_rdata;
    wire        rx_mb_ready;
    wire [31:0] rx_mb_rdata;
    wire        rxbuf_ready;
    wire [31:0] rxbuf_rdata;
    wire        sd_mmio_ready;
    wire [31:0] sd_mmio_rdata;
    wire [31:0] gpio_out_reg;

    wire [7:0] tx_spi_data;
    wire       tx_spi_clk;
    wire       tx_spi_cs_n;
    wire       tx_spi_active;
    wire [7:0] rx_unused_spi_data;
    wire       rx_unused_spi_clk;
    wire       rx_unused_spi_cs_n;
    wire       rx_unused_spi_active;
    wire [127:0] rx_block_data;
    wire         rx_block_valid;
    wire         rx_block_busy;

    integer i;
    integer errors;
    integer base;
    integer mismatch_idx;
    integer tx_data_log_count;
    integer rx_valid_count;
    reg [31:0] last_tx_count;
    reg [7:0] expected_byte;
    reg [7:0] got_byte;

    assign tx_mem_ready = tx_bram_sel ? tx_bram_ready : (tx_mb_sel ? tx_mb_ready : 1'b1);
    assign tx_mem_rdata = tx_bram_sel ? tx_bram_rdata : (tx_mb_sel ? tx_mb_rdata : 32'hDEAD_BEEF);

    assign rx_mem_ready = rx_bram_sel ? rx_bram_ready :
                          (rx_sd_sel ? sd_mmio_ready :
                          (rx_rxbuf_sel ? rxbuf_ready :
                          (rx_mb_sel ? rx_mb_ready : 1'b1)));
    assign rx_mem_rdata = rx_bram_sel ? rx_bram_rdata :
                          (rx_sd_sel ? sd_mmio_rdata :
                          (rx_rxbuf_sel ? rxbuf_rdata :
                          (rx_mb_sel ? rx_mb_rdata : 32'hDEAD_BEEF)));

    picorv32 #(
        .ENABLE_COUNTERS      (1),
        .ENABLE_COUNTERS64    (1),
        .ENABLE_REGS_16_31    (1),
        .ENABLE_REGS_DUALPORT (1),
        .LATCHED_MEM_RDATA    (0),
        .TWO_STAGE_SHIFT      (1),
        .BARREL_SHIFTER       (0),
        .TWO_CYCLE_COMPARE    (0),
        .TWO_CYCLE_ALU        (0),
        .COMPRESSED_ISA       (1),
        .CATCH_MISALIGN       (1),
        .CATCH_ILLINSN        (1),
        .ENABLE_PCPI          (0),
        .ENABLE_MUL           (1),
        .ENABLE_FAST_MUL      (1),
        .ENABLE_DIV           (1),
        .ENABLE_IRQ           (0),
        .ENABLE_IRQ_QREGS     (0),
        .ENABLE_IRQ_TIMER     (0),
        .ENABLE_TRACE         (0),
        .REGS_INIT_ZERO       (1),
        .PROGADDR_RESET       (32'h0000_0000),
        .PROGADDR_IRQ         (32'h0000_0010),
        .STACKADDR            (32'h0000_4000),
        .ENABLE_AES           (1),
        .ENABLE_AES_DEC       (0)
    ) cpu_tx (
        .clk            (clk),
        .resetn         (resetn),
        .trap           (tx_trap),
        .mem_valid      (tx_mem_valid),
        .mem_instr      (tx_mem_instr),
        .mem_ready      (tx_mem_ready),
        .mem_addr       (tx_mem_addr),
        .mem_wdata      (tx_mem_wdata),
        .mem_wstrb      (tx_mem_wstrb),
        .mem_rdata      (tx_mem_rdata),
        .irq            (32'd0),
        .aes_spi_data   (tx_spi_data),
        .aes_spi_clk    (tx_spi_clk),
        .aes_spi_cs_n   (tx_spi_cs_n),
        .aes_spi_active (tx_spi_active)
    );

    picorv32 #(
        .ENABLE_COUNTERS      (1),
        .ENABLE_COUNTERS64    (1),
        .ENABLE_REGS_16_31    (1),
        .ENABLE_REGS_DUALPORT (1),
        .LATCHED_MEM_RDATA    (0),
        .TWO_STAGE_SHIFT      (1),
        .BARREL_SHIFTER       (0),
        .TWO_CYCLE_COMPARE    (0),
        .TWO_CYCLE_ALU        (0),
        .COMPRESSED_ISA       (1),
        .CATCH_MISALIGN       (1),
        .CATCH_ILLINSN        (1),
        .ENABLE_PCPI          (0),
        .ENABLE_MUL           (1),
        .ENABLE_FAST_MUL      (1),
        .ENABLE_DIV           (1),
        .ENABLE_IRQ           (0),
        .ENABLE_IRQ_QREGS     (0),
        .ENABLE_IRQ_TIMER     (0),
        .ENABLE_TRACE         (0),
        .REGS_INIT_ZERO       (1),
        .PROGADDR_RESET       (32'h0000_0000),
        .PROGADDR_IRQ         (32'h0000_0010),
        .STACKADDR            (32'h0000_4000),
        .ENABLE_AES           (0),
        .ENABLE_AES_DEC       (1)
    ) cpu_rx (
        .clk            (clk),
        .resetn         (resetn),
        .trap           (rx_trap),
        .mem_valid      (rx_mem_valid),
        .mem_instr      (rx_mem_instr),
        .mem_ready      (rx_mem_ready),
        .mem_addr       (rx_mem_addr),
        .mem_wdata      (rx_mem_wdata),
        .mem_wstrb      (rx_mem_wstrb),
        .mem_rdata      (rx_mem_rdata),
        .irq            (32'd0),
        .aes_spi_data   (rx_unused_spi_data),
        .aes_spi_clk    (rx_unused_spi_clk),
        .aes_spi_cs_n   (rx_unused_spi_cs_n),
        .aes_spi_active (rx_unused_spi_active)
    );

    bram_memory #(
        .MEM_SIZE_WORDS (MEM_SIZE_WORDS),
        .MEM_INIT_FILE  ("program_tx_bram_rxsd.hex")
    ) tx_bram_i (
        .clk       (clk),
        .resetn    (resetn),
        .mem_valid (tx_mem_valid && tx_bram_sel),
        .mem_instr (tx_mem_instr),
        .mem_ready (tx_bram_ready),
        .mem_addr  (tx_mem_addr),
        .mem_wdata (tx_mem_wdata),
        .mem_wstrb (tx_mem_wstrb),
        .mem_rdata (tx_bram_rdata)
    );

    bram_memory #(
        .MEM_SIZE_WORDS (MEM_SIZE_WORDS),
        .MEM_INIT_FILE  ("program_rx_bram_rxsd.hex")
    ) rx_bram_i (
        .clk       (clk),
        .resetn    (resetn),
        .mem_valid (rx_mem_valid && rx_bram_sel),
        .mem_instr (rx_mem_instr),
        .mem_ready (rx_bram_ready),
        .mem_addr  (rx_mem_addr),
        .mem_wdata (rx_mem_wdata),
        .mem_wstrb (rx_mem_wstrb),
        .mem_rdata (rx_bram_rdata)
    );

    dual_soc_mailbox mailbox_i (
        .clk         (clk),
        .resetn      (resetn),
        .mem_valid_a (tx_mem_valid && tx_mb_sel),
        .mem_ready_a (tx_mb_ready),
        .mem_addr_a  (tx_mem_addr),
        .mem_wdata_a (tx_mem_wdata),
        .mem_wstrb_a (tx_mem_wstrb),
        .mem_rdata_a (tx_mb_rdata),
        .mem_valid_b (rx_mem_valid && rx_mb_sel),
        .mem_ready_b (rx_mb_ready),
        .mem_addr_b  (rx_mem_addr),
        .mem_wdata_b (rx_mem_wdata),
        .mem_wstrb_b (rx_mem_wstrb),
        .mem_rdata_b (rx_mb_rdata),
        .sd_owner_is_rx()
    );

    fake_sd_phase1_mmio sd_mmio_i (
        .clk         (clk),
        .resetn      (resetn),
        .mem_valid   (rx_mem_valid && rx_sd_sel),
        .mem_ready   (sd_mmio_ready),
        .mem_addr    (rx_mem_addr),
        .mem_wdata   (rx_mem_wdata),
        .mem_wstrb   (rx_mem_wstrb),
        .mem_rdata   (sd_mmio_rdata),
        .btnc_level  (btn_start_level),
        .gpio_out_reg(gpio_out_reg),
        .init_done   (),
        .init_err    (),
        .busy        ()
    );

    spi_slave_8lane #(
        .SAME_CLK_DOMAIN(1'b1)
    ) spi_rx_i (
        .clk         (clk),
        .resetn      (resetn),
        .spi_clk_in  (tx_spi_clk),
        .spi_data_in (tx_spi_data),
        .spi_cs_n_in (tx_spi_cs_n),
        .rx_data     (rx_block_data),
        .rx_valid    (rx_block_valid),
        .rx_busy     (rx_block_busy),
        .irq_rx      ()
    );

    spi_rx_buffer #(
        .BASE_ADDR (RXBUF_BASE)
    ) rxbuf_i (
        .clk          (clk),
        .resetn       (resetn),
        .mem_valid    (rx_mem_valid && rx_rxbuf_sel),
        .mem_ready    (rxbuf_ready),
        .mem_addr     (rx_mem_addr),
        .mem_wdata    (rx_mem_wdata),
        .mem_wstrb    (rx_mem_wstrb),
        .mem_rdata    (rxbuf_rdata),
        .spi_rx_data  (rx_block_data),
        .spi_rx_valid (rx_block_valid),
        .irq_rx       ()
    );

    always @(posedge clk) begin
        if (!resetn)
            rx_valid_count <= 0;
        else if (rx_block_valid) begin
            if (rx_valid_count < 4)
                $display("RX block valid[%0d] data=%032x", rx_valid_count, rx_block_data);
            rx_valid_count <= rx_valid_count + 1;
        end
        if (!resetn)
            last_tx_count <= 0;
        else if (mailbox_i.tx_count_reg != last_tx_count) begin
            if (mailbox_i.tx_count_reg <= 4)
                $display("TX count -> %0d PT=%032x RESULT=%032x",
                         mailbox_i.tx_count_reg,
                         cpu_tx.genblk3.pcpi_aes_inst.PT,
                         cpu_tx.genblk3.pcpi_aes_inst.RESULT);
            last_tx_count <= mailbox_i.tx_count_reg;
        end
        if (resetn && tx_mem_valid && tx_mem_ready && !tx_mem_instr &&
            tx_bram_sel && tx_mem_wstrb == 4'b0000 &&
            tx_mem_addr >= 32'h0000_1000 && tx_data_log_count < 16) begin
            $display("TX data read[%0d] addr=0x%08x data=0x%08x",
                     tx_data_log_count, tx_mem_addr, tx_mem_rdata);
            tx_data_log_count <= tx_data_log_count + 1;
        end
        if (!resetn)
            tx_data_log_count <= 0;
    end

    initial begin : sim_wait
        $display("=== tb_dual_txbram_rxsd ===");
        repeat (8) @(posedge clk);
        resetn <= 1'b1;
        repeat (200) @(posedge clk);
        btn_start_level <= 1'b1;
        repeat (2000) @(posedge clk);
        btn_start_level <= 1'b0;

        repeat (2000000) begin
            @(posedge clk);
            if (tx_trap || rx_trap) begin
                $display("FAIL: trap detected tx=%0d rx=%0d", tx_trap, rx_trap);
                $finish;
            end
            if (gpio_out_reg[8] || gpio_out_reg[9])
                disable sim_wait;
        end
        $display("FAIL: timeout waiting for pass/fail");
        $display("  gpio_out_reg = 0x%08x", gpio_out_reg);
        $display("  mailbox flags=0x%08x expected=%0d tx_count=%0d rx_count=%0d",
                 mailbox_i.flags_reg, mailbox_i.expected_blocks_reg,
                 mailbox_i.tx_count_reg, mailbox_i.rx_count_reg);
        $display("  rx_valid_count=%0d", rx_valid_count);
        $display("  tx trap=%0d rx trap=%0d tx spi active=%0d rx valid=%0d rx busy=%0d",
                 tx_trap, rx_trap, tx_spi_active, rx_block_valid, rx_block_busy);
        $finish;
    end

    initial begin : verify_after_done
        wait (gpio_out_reg[8] || gpio_out_reg[9]);
        repeat (20) @(posedge clk);
        $display("GPIO_OUT = 0x%08x", gpio_out_reg);
        $write("TX BRAM blk0:");
        for (i = 0; i < 16; i = i + 1)
            $write(" %02x", tx_bram_i.memory[IMAGE_BASE_WORD + 4 + (i >> 2)][8*(i & 32'd3) +: 8]);
        $write("\nTX BRAM blk1:");
        for (i = 0; i < 16; i = i + 1)
            $write(" %02x", tx_bram_i.memory[IMAGE_BASE_WORD + 8 + (i >> 2)][8*(i & 32'd3) +: 8]);
        $write("\n");
        $write("CT block0 :");
        for (i = 0; i < 16; i = i + 1)
            $write(" %02x", sd_mmio_i.disk_mem[(CT_BASE_SECTOR * 512) + i]);
        $write("\nCT block1 :");
        for (i = 0; i < 16; i = i + 1)
            $write(" %02x", sd_mmio_i.disk_mem[((CT_BASE_SECTOR + 1) * 512) + i]);
        $write("\nDEC block0:");
        for (i = 0; i < 16; i = i + 1)
            $write(" %02x", sd_mmio_i.disk_mem[(DEC_BASE_SECTOR * 512) + i]);
        $write("\nDEC block1:");
        for (i = 0; i < 16; i = i + 1)
            $write(" %02x", sd_mmio_i.disk_mem[((DEC_BASE_SECTOR + 1) * 512) + i]);
        $write("\n");
        errors = 0;
        mismatch_idx = -1;

        for (i = 0; i < (IMAGE_BLOCKS * 16); i = i + 1) begin
            if (i < 3126) begin
                got_byte = sd_mmio_i.disk_mem[(DEC_BASE_SECTOR * 512) + ((i / 16) * 512) + (i % 16)];
                expected_byte = rx_bram_i.memory[IMAGE_BASE_WORD + 4 + (i >> 2)][8*(i & 32'd3) +: 8];
            end else begin
                got_byte = 8'h00;
                expected_byte = 8'h00;
            end
            if (got_byte !== expected_byte) begin
                if (mismatch_idx < 0) begin
                    mismatch_idx = i;
                    $display("First mismatch at byte %0d (block %0d, block_byte %0d): got %02x exp %02x",
                             i, i / 16, i % 16, got_byte, expected_byte);
                end
                errors = errors + 1;
            end
        end

        begin : check_all
        for (i = 0; i < IMAGE_BLOCKS; i = i + 1) begin
            base = (DEC_BASE_SECTOR + i) * 512;
            if (sd_mmio_i.disk_mem[base + 16] !== 8'h00) begin
                $display("Nonzero tail at decrypt sector %0d", DEC_BASE_SECTOR + i);
                errors = errors + 1;
                disable check_all;
            end
        end
        end

        $display("Mailbox flags=0x%08x expected=%0d tx_count=%0d rx_count=%0d",
                 mailbox_i.flags_reg, mailbox_i.expected_blocks_reg,
                 mailbox_i.tx_count_reg, mailbox_i.rx_count_reg);

        if (gpio_out_reg[8] && errors == 0) begin
            $display("PASS: RX firmware reported pass and first block matches expected image");
        end else if (gpio_out_reg[9]) begin
            $display("FAIL: RX firmware reported fail (errors=%0d)", errors);
        end else begin
            $display("FAIL: verification errors=%0d", errors);
        end
        $finish;
    end
endmodule
