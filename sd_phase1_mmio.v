`timescale 1ns / 1ps

module sd_phase1_mmio #(
    parameter [31:0] BASE_ADDR = 32'h0200_0000
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

    output wire        sd_reset,
    output wire        sd_sck,
    output wire        sd_cmd,
    input  wire        sd_dat0,
    output wire        sd_dat3,

    output wire        init_done,
    output wire        init_err,
    output wire        busy,
    output wire [4:0]  debug_state,
    output wire [4:0]  debug_last
);

    localparam [31:0] ADDR_SD_CTRL   = BASE_ADDR + 32'h000;
    localparam [31:0] ADDR_SD_STATUS = BASE_ADDR + 32'h004;
    localparam [31:0] ADDR_SD_SECTOR = BASE_ADDR + 32'h008;
    localparam [31:0] ADDR_GPIO_STAT = BASE_ADDR + 32'h100;
    localparam [31:0] ADDR_GPIO_OUT  = BASE_ADDR + 32'h104;
    localparam [31:0] ADDR_BUF_BASE  = BASE_ADDR + 32'h200;
    localparam [31:0] ADDR_BUF_END   = BASE_ADDR + 32'h3ff;

    reg [7:0] sector_buf [0:511];
    reg [31:0] sector_addr_reg;
    reg rd_start_reg;
    reg wr_start_reg;
    reg rd_done_latched;
    reg wr_done_latched;

    wire [7:0] sd_rd_data;
    wire sd_rd_valid;
    wire sd_rd_done;
    wire [8:0] sd_wr_byte_idx;
    wire sd_wr_done;

    wire is_write = |mem_wstrb;
    wire is_read = !is_write;
    wire ctrl_sel = mem_addr == ADDR_SD_CTRL;
    wire status_sel = mem_addr == ADDR_SD_STATUS;
    wire sector_sel = mem_addr == ADDR_SD_SECTOR;
    wire gpio_stat_sel = mem_addr == ADDR_GPIO_STAT;
    wire gpio_out_sel = mem_addr == ADDR_GPIO_OUT;
    wire buf_sel = mem_addr >= ADDR_BUF_BASE && mem_addr <= ADDR_BUF_END;
    wire addr_valid = ctrl_sel || status_sel || sector_sel || gpio_stat_sel || gpio_out_sel || buf_sel;

    wire [9:0] buf_word_addr = mem_addr[9:0] - ADDR_BUF_BASE[9:0];
    integer i;

    assign sd_dat3 = sd_cs_wire;

    wire sd_cs_wire;

    sd_spi_controller sd_ctrl (
        .clk        (clk),
        .rst        (!resetn),
        .sd_cs      (sd_cs_wire),
        .sd_sclk    (sd_sck),
        .sd_mosi    (sd_cmd),
        .sd_miso    (sd_dat0),
        .sd_reset   (sd_reset),
        .init_start (1'b1),
        .init_done  (init_done),
        .init_err   (init_err),
        .rd_start   (rd_start_reg),
        .rd_addr    (sector_addr_reg),
        .rd_data    (sd_rd_data),
        .rd_valid   (sd_rd_valid),
        .rd_done    (sd_rd_done),
        .wr_start   (wr_start_reg),
        .wr_addr    (sector_addr_reg),
        .wr_data    (sector_buf[sd_wr_byte_idx]),
        .wr_byte_idx(sd_wr_byte_idx),
        .wr_done    (sd_wr_done),
        .busy       (busy),
        .debug_state(debug_state),
        .debug_last (debug_last)
    );

    always @(posedge clk) begin
        if (!resetn) begin
            mem_ready <= 1'b0;
            mem_rdata <= 32'd0;
            sector_addr_reg <= 32'd0;
            gpio_out_reg <= 32'd0;
            rd_start_reg <= 1'b0;
            wr_start_reg <= 1'b0;
            rd_done_latched <= 1'b0;
            wr_done_latched <= 1'b0;
            for (i = 0; i < 512; i = i + 1)
                sector_buf[i] <= 8'h00;
        end else begin
            mem_ready <= 1'b0;
            mem_rdata <= 32'd0;
            rd_start_reg <= 1'b0;
            wr_start_reg <= 1'b0;

            if (sd_rd_valid)
                sector_buf[sd_capture_idx] <= sd_rd_data;

            if (sd_rd_done)
                rd_done_latched <= 1'b1;

            if (sd_wr_done)
                wr_done_latched <= 1'b1;

            if (mem_valid && addr_valid) begin
                mem_ready <= 1'b1;

                if (is_write) begin
                    case (mem_addr)
                        ADDR_SD_CTRL: begin
                            if (mem_wdata[2])
                                rd_done_latched <= 1'b0;
                            if (mem_wdata[3])
                                wr_done_latched <= 1'b0;
                            if (mem_wdata[0] && !busy) begin
                                rd_start_reg <= 1'b1;
                                rd_done_latched <= 1'b0;
                            end
                            if (mem_wdata[1] && !busy) begin
                                wr_start_reg <= 1'b1;
                                wr_done_latched <= 1'b0;
                            end
                        end
                        ADDR_SD_SECTOR: begin
                            sector_addr_reg <= mem_wdata;
                        end
                        ADDR_GPIO_OUT: begin
                            gpio_out_reg <= mem_wdata;
                        end
                        default: begin
                            if (buf_sel) begin
                                if (buf_word_addr <= 10'd508) begin
                                    if (mem_wstrb[0]) sector_buf[buf_word_addr + 10'd0] <= mem_wdata[7:0];
                                    if (mem_wstrb[1]) sector_buf[buf_word_addr + 10'd1] <= mem_wdata[15:8];
                                    if (mem_wstrb[2]) sector_buf[buf_word_addr + 10'd2] <= mem_wdata[23:16];
                                    if (mem_wstrb[3]) sector_buf[buf_word_addr + 10'd3] <= mem_wdata[31:24];
                                end
                            end
                        end
                    endcase
                end else if (is_read) begin
                    case (mem_addr)
                        ADDR_SD_CTRL: begin
                            mem_rdata <= 32'd0;
                        end
                        ADDR_SD_STATUS: begin
                            mem_rdata <= {11'd0, debug_last, 3'd0, debug_state, 3'd0,
                                          wr_done_latched, rd_done_latched, busy, init_err, init_done};
                        end
                        ADDR_SD_SECTOR: begin
                            mem_rdata <= sector_addr_reg;
                        end
                        ADDR_GPIO_STAT: begin
                            mem_rdata <= {31'd0, btnc_level};
                        end
                        ADDR_GPIO_OUT: begin
                            mem_rdata <= gpio_out_reg;
                        end
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

    reg [8:0] sd_capture_idx;
    always @(posedge clk) begin
        if (!resetn) begin
            sd_capture_idx <= 9'd0;
        end else begin
            if (rd_start_reg)
                sd_capture_idx <= 9'd0;
            else if (sd_rd_valid && sd_capture_idx != 9'd511)
                sd_capture_idx <= sd_capture_idx + 9'd1;
        end
    end

endmodule
