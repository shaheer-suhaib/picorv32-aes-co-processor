module uart_mmio #(
    parameter [31:0] BASE_ADDR = 32'h0200_0000,
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD = 921600
) (
    input  wire        clk,
    input  wire        resetn,

    input  wire        mem_valid,
    output reg         mem_ready,
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [3:0]  mem_wstrb,
    output reg  [31:0] mem_rdata,

    output wire        uart_tx,
    input  wire        uart_rx
);

    localparam [31:0] ADDR_DIV = BASE_ADDR + 32'h04;
    localparam [31:0] ADDR_DAT = BASE_ADDR + 32'h08;
    localparam [31:0] DEFAULT_DIV = CLK_HZ / BAUD;

    wire addr_valid = (mem_addr == ADDR_DIV) || (mem_addr == ADDR_DAT);
    wire is_write = (mem_wstrb != 4'b0000);
    wire is_read = ~is_write;

    wire [31:0] reg_div_do;
    wire [31:0] reg_dat_do;
    wire reg_dat_wait;

    wire [3:0] reg_div_we = (mem_valid && addr_valid && is_write && mem_addr == ADDR_DIV) ? mem_wstrb : 4'b0000;
    wire reg_dat_we = mem_valid && addr_valid && is_write && mem_addr == ADDR_DAT;
    wire reg_dat_re = mem_valid && addr_valid && is_read  && mem_addr == ADDR_DAT;

    simpleuart #(
        .DEFAULT_DIV(DEFAULT_DIV)
    ) uart_i (
        .clk(clk),
        .resetn(resetn),
        .ser_tx(uart_tx),
        .ser_rx(uart_rx),
        .reg_div_we(reg_div_we),
        .reg_div_di(mem_wdata),
        .reg_div_do(reg_div_do),
        .reg_dat_we(reg_dat_we),
        .reg_dat_re(reg_dat_re),
        .reg_dat_di(mem_wdata),
        .reg_dat_do(reg_dat_do),
        .reg_dat_wait(reg_dat_wait)
    );

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            mem_ready <= 1'b0;
            mem_rdata <= 32'd0;
        end else begin
            mem_ready <= 1'b0;
            mem_rdata <= 32'd0;

            if (mem_valid && addr_valid) begin
                if (mem_addr == ADDR_DAT && reg_dat_wait) begin
                    mem_ready <= 1'b0;
                end else begin
                    mem_ready <= 1'b1;
                    case (mem_addr)
                        ADDR_DIV: mem_rdata <= reg_div_do;
                        ADDR_DAT: mem_rdata <= reg_dat_do;
                        default:  mem_rdata <= 32'd0;
                    endcase
                end
            end
        end
    end
endmodule
