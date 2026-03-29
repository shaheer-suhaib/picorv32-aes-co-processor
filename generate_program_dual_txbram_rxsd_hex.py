#!/usr/bin/env python3
"""
Generate BRAM images for the one-FPGA dual-SoC demo:

- TX CPU reads source image from BRAM, encrypts, and transmits over SPI.
- RX CPU receives ciphertext, decrypts it, and writes ciphertext/decrypted
  blocks to the SD card.
"""

from pathlib import Path


MEM_SIZE_WORDS = 4096

SD_MMIO_BASE = 0x0200_0000
GPIO_BASE = 0x0200_0100
BUF_BASE = 0x0200_0200
RXBUF_BASE = 0x3000_0000
MAILBOX_BASE = 0x0400_0000

MAILBOX_FLAGS = MAILBOX_BASE + 0x00
MAILBOX_EXPECTED = MAILBOX_BASE + 0x04
MAILBOX_TX_COUNT = MAILBOX_BASE + 0x08
MAILBOX_RX_COUNT = MAILBOX_BASE + 0x0C

RX_STATUS = RXBUF_BASE + 0x00
RX_DATA0 = RXBUF_BASE + 0x04
RX_DATA1 = RXBUF_BASE + 0x08
RX_DATA2 = RXBUF_BASE + 0x0C
RX_DATA3 = RXBUF_BASE + 0x10
RX_CLEAR = RXBUF_BASE + 0x14

META_SECTOR = 20
KEY_SECTOR = 21
CT_BASE_SECTOR = 22
IMAGE_FILE_BLOCKS = 196
DEC_BASE_SECTOR = CT_BASE_SECTOR + IMAGE_FILE_BLOCKS

IMAGE_BASE = 0x1000
KEY_BASE = 0x1C60

FLAG_START = 1 << 0
FLAG_TX_DONE = 1 << 1
FLAG_RX_DONE = 1 << 2
FLAG_PASS = 1 << 3
FLAG_FAIL = 1 << 4

GPIOF_PRELOAD_DONE = 1 << 4
GPIOF_CT_DONE = 1 << 5
GPIOF_DEC_DONE = 1 << 6
GPIOF_RUN_DONE = 1 << 7
GPIOF_PASS = 1 << 8
GPIOF_FAIL = 1 << 9
GPIOF_RUNNING = 1 << 10

DISP_IDLE = 0
DISP_PRELOAD = 1
DISP_TRANSFER = 2
DISP_RX_WAIT = 3
DISP_WRITE_CT = 4
DISP_WRITE_DEC = 5
DISP_PASS = 9
DISP_FAIL = 10
DISP_ERROR = 14

FIXED_KEY_BYTES = bytes([
    0x0F, 0x0E, 0x0D, 0x0C,
    0x0B, 0x0A, 0x09, 0x08,
    0x07, 0x06, 0x05, 0x04,
    0x03, 0x02, 0x01, 0x00,
])


def encode_i_type(opcode, funct3, rd, rs1, imm):
    imm &= 0xFFF
    return (imm << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def encode_r_type(opcode, funct3, funct7, rd, rs1, rs2):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def encode_s_type(opcode, funct3, rs1, rs2, imm):
    imm &= 0xFFF
    imm_11_5 = (imm >> 5) & 0x7F
    imm_4_0 = imm & 0x1F
    return (imm_11_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (imm_4_0 << 7) | opcode


def encode_b_type(opcode, funct3, rs1, rs2, imm):
    imm &= 0x1FFF
    imm_12 = (imm >> 12) & 0x1
    imm_10_5 = (imm >> 5) & 0x3F
    imm_4_1 = (imm >> 1) & 0xF
    imm_11 = (imm >> 11) & 0x1
    return (
        (imm_12 << 31)
        | (imm_10_5 << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (funct3 << 12)
        | (imm_4_1 << 8)
        | (imm_11 << 7)
        | opcode
    )


def encode_u_type(opcode, rd, imm):
    return (imm & 0xFFFFF000) | (rd << 7) | opcode


def encode_j_type(opcode, rd, imm):
    imm &= 0x1FFFFF
    imm_20 = (imm >> 20) & 0x1
    imm_10_1 = (imm >> 1) & 0x3FF
    imm_11 = (imm >> 11) & 0x1
    imm_19_12 = (imm >> 12) & 0xFF
    return (
        (imm_20 << 31)
        | (imm_19_12 << 12)
        | (imm_11 << 20)
        | (imm_10_1 << 21)
        | (rd << 7)
        | opcode
    )


def addi(rd, rs1, imm):
    return encode_i_type(0b0010011, 0b000, rd, rs1, imm)


def andi(rd, rs1, imm):
    return encode_i_type(0b0010011, 0b111, rd, rs1, imm)


def ori(rd, rs1, imm):
    return encode_i_type(0b0010011, 0b110, rd, rs1, imm)


def lw(rd, rs1, offset):
    return encode_i_type(0b0000011, 0b010, rd, rs1, offset)


def jalr(rd, rs1, imm):
    return encode_i_type(0b1100111, 0b000, rd, rs1, imm)


def lui(rd, imm):
    return encode_u_type(0b0110111, rd, imm)


def sw(rs2, rs1, offset):
    return encode_s_type(0b0100011, 0b010, rs1, rs2, offset)


def beq(rs1, rs2, offset):
    return encode_b_type(0b1100011, 0b000, rs1, rs2, offset)


def bne(rs1, rs2, offset):
    return encode_b_type(0b1100011, 0b001, rs1, rs2, offset)


def jal(rd, offset):
    return encode_j_type(0b1101111, rd, offset)


def xor_inst(rd, rs1, rs2):
    return encode_r_type(0b0110011, 0b100, 0b0000000, rd, rs1, rs2)


def or_inst(rd, rs1, rs2):
    return encode_r_type(0b0110011, 0b110, 0b0000000, rd, rs1, rs2)


def aes_load_pt(rs2, rs1):
    return encode_r_type(0b0001011, 0b000, 0b0100000, 0, rs1, rs2)


def aes_load_key(rs2, rs1):
    return encode_r_type(0b0001011, 0b000, 0b0100001, 0, rs1, rs2)


def aes_start():
    return encode_r_type(0b0001011, 0b000, 0b0100010, 0, 0, 0)


def aes_dec_load_ct(rs2, rs1):
    return encode_r_type(0b0001011, 0b000, 0b0101000, 0, rs1, rs2)


def aes_dec_load_key(rs2, rs1):
    return encode_r_type(0b0001011, 0b000, 0b0101001, 0, rs1, rs2)


def aes_dec_start():
    return encode_r_type(0b0001011, 0b000, 0b0101010, 0, 0, 0)


def aes_dec_read(rd, rs1):
    return encode_r_type(0b0001011, 0b000, 0b0101011, rd, rs1, 0)


def aes_dec_status(rd):
    return encode_r_type(0b0001011, 0b000, 0b0101100, rd, 0, 0)


def nop():
    return addi(0, 0, 0)


class ProgramBuilder:
    def __init__(self):
        self.items = []
        self.labels = {}
        self.fixups = []

    @property
    def pc(self):
        return 4 * sum(1 for item in self.items if item[0] == "insn")

    def label(self, name):
        self.labels[name] = self.pc

    def emit(self, word):
        self.items.append(("insn", word & 0xFFFFFFFF))

    def emit_fixup(self, resolver):
        idx = len(self.items)
        pc = self.pc
        self.items.append(("insn", 0))
        self.fixups.append((idx, pc, resolver))

    def branch_beq(self, rs1, rs2, target):
        self.emit_fixup(lambda pc, labels: beq(rs1, rs2, labels[target] - pc))

    def branch_bne(self, rs1, rs2, target):
        self.emit_fixup(lambda pc, labels: bne(rs1, rs2, labels[target] - pc))

    def jump(self, target, rd=0):
        self.emit_fixup(lambda pc, labels: jal(rd, labels[target] - pc))

    def resolve(self):
        words = [value for kind, value in self.items if kind == "insn"]
        for idx, pc, resolver in self.fixups:
            words[idx] = resolver(pc, self.labels) & 0xFFFFFFFF
        return words


def load_abs(builder, rd, addr):
    hi = (addr + 0x800) & 0xFFFFF000
    lo = addr - hi
    builder.emit(lui(rd, hi))
    builder.emit(addi(rd, rd, lo))


def store_stage(builder, gpio_reg, imm):
    builder.emit(addi(24, 0, imm))
    builder.emit(sw(24, gpio_reg, 4))


def emit_copy4(builder, src_reg, dst_reg):
    builder.emit(lw(25, src_reg, 0))
    builder.emit(sw(25, dst_reg, 0))
    builder.emit(lw(26, src_reg, 4))
    builder.emit(sw(26, dst_reg, 4))
    builder.emit(lw(27, src_reg, 8))
    builder.emit(sw(27, dst_reg, 8))
    builder.emit(lw(28, src_reg, 12))
    builder.emit(sw(28, dst_reg, 12))


def emit_zero_buffer(builder, buf_reg):
    loop_label = f"zero_buffer_{len(builder.items)}"
    builder.emit(addi(29, buf_reg, 0))
    load_abs(builder, 30, BUF_BASE + 512)
    builder.label(loop_label)
    builder.emit(sw(0, 29, 0))
    builder.emit(addi(29, 29, 4))
    builder.branch_bne(29, 30, loop_label)


def emit_load_enc_key(builder, key_ptr_reg):
    builder.emit(lw(25, key_ptr_reg, 0))
    builder.emit(aes_load_key(25, 20))
    builder.emit(lw(26, key_ptr_reg, 4))
    builder.emit(aes_load_key(26, 21))
    builder.emit(lw(27, key_ptr_reg, 8))
    builder.emit(aes_load_key(27, 22))
    builder.emit(lw(28, key_ptr_reg, 12))
    builder.emit(aes_load_key(28, 23))


def emit_load_dec_key(builder, key_ptr_reg):
    builder.emit(lw(25, key_ptr_reg, 0))
    builder.emit(aes_dec_load_key(25, 20))
    builder.emit(lw(26, key_ptr_reg, 4))
    builder.emit(aes_dec_load_key(26, 21))
    builder.emit(lw(27, key_ptr_reg, 8))
    builder.emit(aes_dec_load_key(27, 22))
    builder.emit(lw(28, key_ptr_reg, 12))
    builder.emit(aes_dec_load_key(28, 23))


def emit_sd_subroutines(builder, sd_reg):
    builder.label("sd_write")
    builder.emit(sw(29, sd_reg, 8))
    builder.emit(addi(30, 0, 8))
    builder.emit(sw(30, sd_reg, 0))
    builder.emit(addi(30, 0, 2))
    builder.emit(sw(30, sd_reg, 0))
    builder.label("sd_write_wait")
    builder.emit(lw(30, sd_reg, 4))
    builder.emit(andi(31, 30, 2))
    builder.branch_bne(31, 0, "fatal_error")
    builder.emit(andi(31, 30, 16))
    builder.branch_beq(31, 0, "sd_write_wait")
    builder.emit(jalr(0, 1, 0))


def generate_tx_program():
    p = ProgramBuilder()

    load_abs(p, 5, MAILBOX_BASE)
    load_abs(p, 6, IMAGE_BASE + 16)
    load_abs(p, 7, KEY_BASE)
    p.emit(addi(20, 0, 0))
    p.emit(addi(21, 0, 1))
    p.emit(addi(22, 0, 2))
    p.emit(addi(23, 0, 3))

    p.label("wait_start")
    p.emit(lw(29, 5, 0))
    p.emit(andi(30, 29, FLAG_START))
    p.branch_beq(30, 0, "wait_start")

    p.emit(addi(11, 0, IMAGE_FILE_BLOCKS))
    p.emit(addi(12, 0, 0))
    p.label("tx_loop")
    emit_load_enc_key(p, 7)
    p.emit(lw(16, 6, 0))
    p.emit(lw(17, 6, 4))
    p.emit(lw(18, 6, 8))
    p.emit(lw(19, 6, 12))
    p.emit(aes_load_pt(16, 20))
    p.emit(aes_load_pt(17, 21))
    p.emit(aes_load_pt(18, 22))
    p.emit(aes_load_pt(19, 23))
    p.emit(aes_start())

    p.emit(addi(12, 12, 1))
    p.emit(sw(12, 5, 8))
    p.label("wait_ack")
    p.emit(lw(29, 5, 12))
    p.branch_bne(29, 12, "wait_ack")
    p.emit(addi(6, 6, 16))
    p.emit(addi(11, 11, -1))
    p.branch_bne(11, 0, "tx_loop")

    p.emit(lw(29, 5, 0))
    p.emit(ori(29, 29, FLAG_TX_DONE))
    p.emit(sw(29, 5, 0))
    p.label("wait_finish")
    p.emit(lw(29, 5, 0))
    p.emit(andi(30, 29, FLAG_PASS | FLAG_FAIL))
    p.branch_beq(30, 0, "wait_finish")
    p.label("done")
    p.jump("done")

    return p.resolve()


def generate_rx_program():
    p = ProgramBuilder()

    load_abs(p, 5, SD_MMIO_BASE)
    load_abs(p, 6, GPIO_BASE)
    load_abs(p, 7, BUF_BASE)
    load_abs(p, 8, MAILBOX_BASE)
    load_abs(p, 9, RXBUF_BASE)
    load_abs(p, 10, IMAGE_BASE)
    load_abs(p, 11, KEY_BASE)
    load_abs(p, 12, IMAGE_BASE + 16)
    p.emit(addi(20, 0, 0))
    p.emit(addi(21, 0, 1))
    p.emit(addi(22, 0, 2))
    p.emit(addi(23, 0, 3))

    p.label("wait_init")
    p.emit(lw(29, 5, 4))
    p.emit(andi(30, 29, 1))
    p.branch_bne(30, 0, "idle")
    p.emit(andi(30, 29, 2))
    p.branch_beq(30, 0, "wait_init")
    store_stage(p, 6, GPIOF_FAIL | DISP_ERROR)
    p.jump("fatal_error")

    p.label("idle")
    store_stage(p, 6, DISP_IDLE)
    p.label("wait_press")
    p.emit(lw(29, 6, 0))
    p.emit(andi(30, 29, 1))
    p.branch_beq(30, 0, "wait_press")
    p.label("wait_release")
    p.emit(lw(29, 6, 0))
    p.emit(andi(30, 29, 1))
    p.branch_bne(30, 0, "wait_release")

    store_stage(p, 6, GPIOF_RUNNING | DISP_PRELOAD)
    emit_zero_buffer(p, 7)
    emit_copy4(p, 10, 7)
    p.emit(addi(29, 0, META_SECTOR))
    p.jump("sd_write", rd=1)

    emit_zero_buffer(p, 7)
    emit_copy4(p, 11, 7)
    p.emit(addi(29, 0, KEY_SECTOR))
    p.jump("sd_write", rd=1)

    emit_load_dec_key(p, 11)

    p.emit(sw(0, 8, 0))
    p.emit(addi(29, 0, IMAGE_FILE_BLOCKS))
    p.emit(sw(29, 8, 4))
    p.emit(sw(0, 8, 8))
    p.emit(sw(0, 8, 12))
    p.emit(addi(29, 0, FLAG_START))
    p.emit(sw(29, 8, 0))

    p.emit(addi(13, 0, IMAGE_FILE_BLOCKS))
    p.emit(addi(14, 0, CT_BASE_SECTOR))
    p.emit(addi(15, 0, DEC_BASE_SECTOR))
    p.emit(addi(16, 0, 0))
    p.emit(addi(17, 0, 1))
    p.label("rx_loop")
    store_stage(p, 6, GPIOF_RUNNING | GPIOF_PRELOAD_DONE | DISP_RX_WAIT)
    p.label("wait_rx")
    p.emit(lw(29, 9, 0))
    p.emit(andi(30, 29, 1))
    p.branch_beq(30, 0, "wait_rx")

    p.emit(lw(25, 9, 4))
    p.emit(lw(26, 9, 8))
    p.emit(lw(27, 9, 12))
    p.emit(lw(28, 9, 16))
    p.emit(sw(0, 9, 20))

    store_stage(p, 6, GPIOF_RUNNING | GPIOF_PRELOAD_DONE | DISP_WRITE_CT)
    emit_zero_buffer(p, 7)
    p.emit(sw(25, 7, 0))
    p.emit(sw(26, 7, 4))
    p.emit(sw(27, 7, 8))
    p.emit(sw(28, 7, 12))
    p.emit(addi(29, 14, 0))
    p.jump("sd_write", rd=1)

    p.emit(aes_dec_load_ct(25, 20))
    p.emit(aes_dec_load_ct(26, 21))
    p.emit(aes_dec_load_ct(27, 22))
    p.emit(aes_dec_load_ct(28, 23))
    p.emit(aes_dec_start())
    p.label("dec_poll")
    p.emit(aes_dec_status(29))
    p.branch_beq(29, 0, "dec_poll")
    p.emit(aes_dec_read(25, 20))
    p.emit(aes_dec_read(26, 21))
    p.emit(aes_dec_read(27, 22))
    p.emit(aes_dec_read(28, 23))

    p.emit(lw(24, 12, 0))
    p.emit(lw(29, 12, 4))
    p.emit(xor_inst(30, 25, 24))
    p.emit(xor_inst(31, 26, 29))
    p.emit(or_inst(30, 30, 31))
    p.emit(lw(24, 12, 8))
    p.emit(lw(29, 12, 12))
    p.emit(xor_inst(31, 27, 24))
    p.emit(or_inst(30, 30, 31))
    p.emit(xor_inst(31, 28, 29))
    p.emit(or_inst(30, 30, 31))
    p.branch_beq(30, 0, "match_ok")
    p.emit(addi(17, 0, 0))
    p.label("match_ok")

    store_stage(p, 6, GPIOF_RUNNING | GPIOF_PRELOAD_DONE | GPIOF_CT_DONE | DISP_WRITE_DEC)
    emit_zero_buffer(p, 7)
    p.emit(sw(25, 7, 0))
    p.emit(sw(26, 7, 4))
    p.emit(sw(27, 7, 8))
    p.emit(sw(28, 7, 12))
    p.emit(addi(29, 15, 0))
    p.jump("sd_write", rd=1)

    p.emit(addi(16, 16, 1))
    p.emit(sw(16, 8, 12))
    p.emit(addi(14, 14, 1))
    p.emit(addi(15, 15, 1))
    p.emit(addi(12, 12, 16))
    p.emit(addi(13, 13, -1))
    p.branch_bne(13, 0, "rx_loop")

    p.label("wait_tx_done")
    p.emit(lw(29, 8, 0))
    p.emit(andi(30, 29, FLAG_TX_DONE))
    p.branch_beq(30, 0, "wait_tx_done")

    p.emit(lw(29, 8, 0))
    p.emit(ori(29, 29, FLAG_RX_DONE))
    p.branch_beq(17, 0, "mark_fail")
    p.emit(ori(29, 29, FLAG_PASS))
    p.emit(sw(29, 8, 0))
    store_stage(p, 6, GPIOF_PRELOAD_DONE | GPIOF_CT_DONE | GPIOF_DEC_DONE | GPIOF_RUN_DONE | GPIOF_PASS | DISP_PASS)
    p.jump("done")

    p.label("mark_fail")
    p.emit(ori(29, 29, FLAG_FAIL))
    p.emit(sw(29, 8, 0))
    store_stage(p, 6, GPIOF_PRELOAD_DONE | GPIOF_CT_DONE | GPIOF_DEC_DONE | GPIOF_RUN_DONE | GPIOF_FAIL | DISP_FAIL)
    p.jump("done")

    p.label("fatal_error")
    store_stage(p, 6, GPIOF_FAIL | DISP_ERROR)
    p.label("done")
    p.jump("done")

    emit_sd_subroutines(p, 5)
    return p.resolve()


def parse_image_blocks():
    lines = [line.strip() for line in Path("image_input.hex").read_text().splitlines() if line.strip()]
    blocks = [bytes.fromhex(line) for line in lines]
    if len(blocks) != IMAGE_FILE_BLOCKS + 1:
        raise ValueError(f"expected {IMAGE_FILE_BLOCKS + 1} blocks, found {len(blocks)}")
    return blocks


def emit_common_data(memory):
    image_blocks = parse_image_blocks()
    for block_idx, block in enumerate(image_blocks):
        base_addr = IMAGE_BASE + block_idx * 16
        for word_idx in range(4):
            chunk = block[word_idx * 4:(word_idx + 1) * 4]
            memory[(base_addr // 4) + word_idx] = int.from_bytes(chunk, "little")

    for word_idx in range(4):
        chunk = FIXED_KEY_BYTES[word_idx * 4:(word_idx + 1) * 4]
        memory[(KEY_BASE // 4) + word_idx] = int.from_bytes(chunk, "little")


def write_hex(path, program):
    memory = [nop()] * MEM_SIZE_WORDS
    for idx, instr in enumerate(program):
        memory[idx] = instr
    emit_common_data(memory)

    with Path(path).open("w", newline="\n") as fh:
        for word in memory:
            fh.write(f"{word:08x}\n")


def main():
    tx_program = generate_tx_program()
    rx_program = generate_rx_program()

    write_hex("program_tx_bram_rxsd.hex", tx_program)
    write_hex("program_rx_bram_rxsd.hex", rx_program)

    print("Generated program_tx_bram_rxsd.hex")
    print(f"  Program size: {len(tx_program)} instructions")
    print("Generated program_rx_bram_rxsd.hex")
    print(f"  Program size: {len(rx_program)} instructions")
    print(f"  Cipher sectors : {CT_BASE_SECTOR}..{CT_BASE_SECTOR + IMAGE_FILE_BLOCKS - 1}")
    print(f"  Decrypt sectors: {DEC_BASE_SECTOR}..{DEC_BASE_SECTOR + IMAGE_FILE_BLOCKS - 1}")


if __name__ == "__main__":
    main()
