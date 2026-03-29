`timescale 1ns / 1ps

module dual_soc_mailbox #(
    parameter [31:0] BASE_ADDR = 32'h0400_0000
) (
    input  wire        clk,
    input  wire        resetn,

    input  wire        mem_valid_a,
    output reg         mem_ready_a,
    input  wire [31:0] mem_addr_a,
    input  wire [31:0] mem_wdata_a,
    input  wire [3:0]  mem_wstrb_a,
    output reg  [31:0] mem_rdata_a,

    input  wire        mem_valid_b,
    output reg         mem_ready_b,
    input  wire [31:0] mem_addr_b,
    input  wire [31:0] mem_wdata_b,
    input  wire [3:0]  mem_wstrb_b,
    output reg  [31:0] mem_rdata_b,

    output wire        sd_owner_is_rx
);

    localparam [31:0] ADDR_FLAGS    = BASE_ADDR + 32'h00;
    localparam [31:0] ADDR_EXPECTED = BASE_ADDR + 32'h04;
    localparam [31:0] ADDR_TX_COUNT = BASE_ADDR + 32'h08;
    localparam [31:0] ADDR_RX_COUNT = BASE_ADDR + 32'h0C;
    localparam [31:0] ADDR_AUX0     = BASE_ADDR + 32'h10;
    localparam [31:0] ADDR_AUX1     = BASE_ADDR + 32'h14;

    reg [31:0] flags_reg;
    reg [31:0] expected_blocks_reg;
    reg [31:0] tx_count_reg;
    reg [31:0] rx_count_reg;
    reg [31:0] aux0_reg;
    reg [31:0] aux1_reg;

    wire addr_valid_a = (mem_addr_a >= BASE_ADDR) && (mem_addr_a < BASE_ADDR + 32'h20);
    wire addr_valid_b = (mem_addr_b >= BASE_ADDR) && (mem_addr_b < BASE_ADDR + 32'h20);

    assign sd_owner_is_rx = flags_reg[5];

    function [31:0] read_reg;
        input [31:0] addr;
        begin
            case (addr)
                ADDR_FLAGS:    read_reg = flags_reg;
                ADDR_EXPECTED: read_reg = expected_blocks_reg;
                ADDR_TX_COUNT: read_reg = tx_count_reg;
                ADDR_RX_COUNT: read_reg = rx_count_reg;
                ADDR_AUX0:     read_reg = aux0_reg;
                ADDR_AUX1:     read_reg = aux1_reg;
                default:       read_reg = 32'd0;
            endcase
        end
    endfunction

    task automatic write_reg;
        input [31:0] addr;
        input [31:0] data;
        begin
            case (addr)
                ADDR_FLAGS:    flags_reg <= data;
                ADDR_EXPECTED: expected_blocks_reg <= data;
                ADDR_TX_COUNT: tx_count_reg <= data;
                ADDR_RX_COUNT: rx_count_reg <= data;
                ADDR_AUX0:     aux0_reg <= data;
                ADDR_AUX1:     aux1_reg <= data;
                default: begin
                end
            endcase
        end
    endtask

    always @(posedge clk) begin
        if (!resetn) begin
            mem_ready_a <= 1'b0;
            mem_ready_b <= 1'b0;
            mem_rdata_a <= 32'd0;
            mem_rdata_b <= 32'd0;
            flags_reg <= 32'd0;
            expected_blocks_reg <= 32'd0;
            tx_count_reg <= 32'd0;
            rx_count_reg <= 32'd0;
            aux0_reg <= 32'd0;
            aux1_reg <= 32'd0;
        end else begin
            mem_ready_a <= 1'b0;
            mem_ready_b <= 1'b0;
            mem_rdata_a <= 32'd0;
            mem_rdata_b <= 32'd0;

            if (mem_valid_a && addr_valid_a) begin
                mem_ready_a <= 1'b1;
                if (|mem_wstrb_a)
                    write_reg(mem_addr_a, mem_wdata_a);
                else
                    mem_rdata_a <= read_reg(mem_addr_a);
            end

            if (mem_valid_b && addr_valid_b) begin
                mem_ready_b <= 1'b1;
                if (|mem_wstrb_b)
                    write_reg(mem_addr_b, mem_wdata_b);
                else
                    mem_rdata_b <= read_reg(mem_addr_b);
            end
        end
    end

endmodule
