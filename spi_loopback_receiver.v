`timescale 1ns / 1ps

module spi_loopback_receiver #(
    parameter [31:0] BASE_ADDR = 32'h0300_0000,
    parameter integer MAX_BLOCKS = 256
) (
    input  wire        clk,
    input  wire        resetn,

    input  wire        mem_valid,
    output reg         mem_ready,
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [3:0]  mem_wstrb,
    output reg  [31:0] mem_rdata,

    input  wire        spi_clk_in,
    input  wire [7:0]  spi_data_in,
    input  wire        spi_cs_n_in,

    output wire        rx_active,
    output wire        decrypt_active,
    output wire [7:0]  stored_blocks,
    output wire        overflow_flag
);

    localparam [31:0] ADDR_CTRL        = BASE_ADDR + 32'h000;
    localparam [31:0] ADDR_STATUS      = BASE_ADDR + 32'h004;
    localparam [31:0] ADDR_BLOCK_COUNT = BASE_ADDR + 32'h008;
    localparam [31:0] ADDR_LAST_BLOCK  = BASE_ADDR + 32'h00C;
    localparam [31:0] ADDR_KEY0        = BASE_ADDR + 32'h010;
    localparam [31:0] ADDR_KEY1        = BASE_ADDR + 32'h014;
    localparam [31:0] ADDR_KEY2        = BASE_ADDR + 32'h018;
    localparam [31:0] ADDR_KEY3        = BASE_ADDR + 32'h01C;
    localparam [31:0] ADDR_DATA_BASE   = BASE_ADDR + 32'h100;

    localparam integer BLOCK_WORDS = MAX_BLOCKS * 4;
    localparam integer STATE_IDLE  = 0;
    localparam integer STATE_START = 1;
    localparam integer STATE_WAIT  = 2;
    localparam integer STATE_STORE = 3;

    wire addr_valid = (mem_addr >= BASE_ADDR) && (mem_addr < ADDR_DATA_BASE + (MAX_BLOCKS * 16));
    wire is_write = |mem_wstrb;
    wire is_read = !is_write;
    wire data_sel = (mem_addr >= ADDR_DATA_BASE) && (mem_addr < ADDR_DATA_BASE + (MAX_BLOCKS * 16));
    wire [31:0] data_word_addr = (mem_addr - ADDR_DATA_BASE) >> 2;

    reg [31:0] key_word0;
    reg [31:0] key_word1;
    reg [31:0] key_word2;
    reg [31:0] key_word3;
    wire [127:0] aes_key = {key_word3, key_word2, key_word1, key_word0};

    reg         receiver_enable;
    reg         clear_req;
    reg         overflow_reg;
    reg [7:0]   block_count;
    reg [7:0]   last_block_index;
    reg [1:0]   state;
    reg [127:0] dec_ciphertext;
    reg         dec_start;
    reg [31:0]  block_mem [0:BLOCK_WORDS-1];

    wire [127:0] rx_block_data;
    wire         rx_block_valid;
    wire         rx_block_busy;

    wire [127:0] dec_plaintext;
    wire         dec_done;

    integer i;

    spi_slave_8lane spi_rx_i (
        .clk         (clk),
        .resetn      (resetn),
        .spi_clk_in  (spi_clk_in),
        .spi_data_in (spi_data_in),
        .spi_cs_n_in (spi_cs_n_in),
        .rx_data     (rx_block_data),
        .rx_valid    (rx_block_valid),
        .rx_busy     (rx_block_busy),
        .irq_rx      ()
    );

    ASMD_Decryption aes_dec_i (
        .done              (dec_done),
        .Dout              (dec_plaintext),
        .encrypted_text_in (dec_ciphertext),
        .key_in            (aes_key),
        .decrypt           (dec_start),
        .clock             (clk),
        .reset             (!resetn)
    );

    assign rx_active = rx_block_busy;
    assign decrypt_active = (state != STATE_IDLE);
    assign stored_blocks = block_count;
    assign overflow_flag = overflow_reg;

    always @(posedge clk) begin
        if (!resetn) begin
            receiver_enable <= 1'b0;
            clear_req <= 1'b0;
            key_word0 <= 32'd0;
            key_word1 <= 32'd0;
            key_word2 <= 32'd0;
            key_word3 <= 32'd0;
            mem_ready <= 1'b0;
            mem_rdata <= 32'd0;
        end else begin
            mem_ready <= 1'b0;
            mem_rdata <= 32'd0;
            clear_req <= 1'b0;

            if (mem_valid && addr_valid) begin
                mem_ready <= 1'b1;

                if (is_write) begin
                    case (mem_addr)
                        ADDR_CTRL: begin
                            clear_req <= mem_wdata[0];
                            receiver_enable <= mem_wdata[1];
                        end
                        ADDR_KEY0: key_word0 <= mem_wdata;
                        ADDR_KEY1: key_word1 <= mem_wdata;
                        ADDR_KEY2: key_word2 <= mem_wdata;
                        ADDR_KEY3: key_word3 <= mem_wdata;
                        default: begin
                        end
                    endcase
                end else if (is_read) begin
                    case (mem_addr)
                        ADDR_CTRL:        mem_rdata <= {30'd0, receiver_enable, 1'b0};
                        ADDR_STATUS:      mem_rdata <= {28'd0, overflow_reg, (state != STATE_IDLE), rx_block_busy, receiver_enable};
                        ADDR_BLOCK_COUNT: mem_rdata <= {24'd0, block_count};
                        ADDR_LAST_BLOCK:  mem_rdata <= {24'd0, last_block_index};
                        ADDR_KEY0:        mem_rdata <= key_word0;
                        ADDR_KEY1:        mem_rdata <= key_word1;
                        ADDR_KEY2:        mem_rdata <= key_word2;
                        ADDR_KEY3:        mem_rdata <= key_word3;
                        default: begin
                            if (data_sel && data_word_addr < BLOCK_WORDS)
                                mem_rdata <= block_mem[data_word_addr];
                        end
                    endcase
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!resetn) begin
            overflow_reg <= 1'b0;
            block_count <= 8'd0;
            last_block_index <= 8'd0;
            state <= STATE_IDLE;
            dec_start <= 1'b0;
            dec_ciphertext <= 128'd0;
            for (i = 0; i < BLOCK_WORDS; i = i + 1)
                block_mem[i] <= 32'd0;
        end else begin
            dec_start <= 1'b0;

            if (clear_req) begin
                overflow_reg <= 1'b0;
                block_count <= 8'd0;
                last_block_index <= 8'd0;
                state <= STATE_IDLE;
                dec_ciphertext <= 128'd0;
                for (i = 0; i < BLOCK_WORDS; i = i + 1)
                    block_mem[i] <= 32'd0;
            end else begin
                case (state)
                    STATE_IDLE: begin
                        if (rx_block_valid) begin
                            if (!receiver_enable || block_count >= MAX_BLOCKS) begin
                                overflow_reg <= 1'b1;
                            end else begin
                                dec_ciphertext <= rx_block_data;
                                state <= STATE_START;
                            end
                        end
                    end

                    STATE_START: begin
                        dec_start <= 1'b1;
                        state <= STATE_WAIT;
                    end

                    STATE_WAIT: begin
                        if (dec_done)
                            state <= STATE_STORE;
                    end

                    STATE_STORE: begin
                        block_mem[{block_count, 2'b00} + 0] <= dec_plaintext[31:0];
                        block_mem[{block_count, 2'b00} + 1] <= dec_plaintext[63:32];
                        block_mem[{block_count, 2'b00} + 2] <= dec_plaintext[95:64];
                        block_mem[{block_count, 2'b00} + 3] <= dec_plaintext[127:96];
                        last_block_index <= block_count;
                        block_count <= block_count + 8'd1;
                        state <= STATE_IDLE;
                    end

                    default: begin
                        state <= STATE_IDLE;
                    end
                endcase
            end
        end
    end

endmodule
