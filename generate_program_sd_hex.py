#!/usr/bin/env python3
"""
Generate program_sd.hex for the PicoRV32 SD image AES Phase 1 design.

This uses a pure-Python machine-code generator so no RISC-V GCC toolchain
is required. The generated BRAM image contains:
- PicoRV32 firmware
- embedded image blocks from image_input.hex
- fixed AES key block
"""

from pathlib import Path


MEM_SIZE_WORDS = 4096

MMIO_BASE = 0x0200_0000
GPIO_BASE = 0x0200_0100
BUF_BASE = 0x0200_0200

META_SECTOR = 20
KEY_SECTOR = 21
PLAIN_BASE_SECTOR = 22
IMAGE_FILE_BLOCKS = 196
CT_BASE_SECTOR = PLAIN_BASE_SECTOR + IMAGE_FILE_BLOCKS
DEC_BASE_SECTOR = CT_BASE_SECTOR + IMAGE_FILE_BLOCKS

GPIOF_PRELOAD_DONE = 1 << 4
GPIOF_CT_OK = 1 << 5
GPIOF_DEC_OK = 1 << 6
GPIOF_RUN_DONE = 1 << 7
GPIOF_PASS = 1 << 8
GPIOF_FAIL = 1 << 9
GPIOF_RUNNING = 1 << 10

DISP_IDLE = 0
DISP_PRELOAD = 1
DISP_READ_ORIG = 2
DISP_ENCRYPT = 3
DISP_WRITE_CT = 4
DISP_READ_CT = 5
DISP_DECRYPT = 6
DISP_WRITE_DEC = 7
DISP_PASS = 9
DISP_FAIL = 10
DISP_ERROR = 14

IMAGE_BASE = 0x1000
KEY_BASE = 0x1C60

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


def and_inst(rd, rs1, rs2):
    return encode_r_type(0b0110011, 0b111, 0b0000000, rd, rs1, rs2)


def aes_load_pt(rs2, rs1):
    return encode_r_type(0b0001011, 0b000, 0b0100000, 0, rs1, rs2)


def aes_load_key(rs2, rs1):
    return encode_r_type(0b0001011, 0b000, 0b0100001, 0, rs1, rs2)


def aes_start():
    return encode_r_type(0b0001011, 0b000, 0b0100010, 0, 0, 0)


def aes_read(rd, rs1):
    return encode_r_type(0b0001011, 0b000, 0b0100011, rd, rs1, 0)


def aes_status(rd):
    return encode_r_type(0b0001011, 0b000, 0b0100100, rd, 0, 0)


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


def store_stage(builder, imm):
    builder.emit(addi(24, 0, imm))
    builder.emit(sw(24, 6, 4))


def emit_copy4(builder, src_reg, dst_reg):
    builder.emit(lw(25, src_reg, 0))
    builder.emit(sw(25, dst_reg, 0))
    builder.emit(lw(26, src_reg, 4))
    builder.emit(sw(26, dst_reg, 4))
    builder.emit(lw(27, src_reg, 8))
    builder.emit(sw(27, dst_reg, 8))
    builder.emit(lw(28, src_reg, 12))
    builder.emit(sw(28, dst_reg, 12))


def emit_load_key_once(builder):
    builder.emit(lw(25, 9, 0))
    builder.emit(aes_load_key(25, 20))
    builder.emit(aes_dec_load_key(25, 20))
    builder.emit(lw(26, 9, 4))
    builder.emit(aes_load_key(26, 21))
    builder.emit(aes_dec_load_key(26, 21))
    builder.emit(lw(27, 9, 8))
    builder.emit(aes_load_key(27, 22))
    builder.emit(aes_dec_load_key(27, 22))
    builder.emit(lw(28, 9, 12))
    builder.emit(aes_load_key(28, 23))
    builder.emit(aes_dec_load_key(28, 23))


def emit_zero_buffer(builder):
    loop_label = f"zero_buffer_loop_{len(builder.items)}"
    builder.emit(addi(29, 7, 0))
    load_abs(builder, 30, BUF_BASE + 512)
    builder.label(loop_label)
    builder.emit(sw(0, 29, 0))
    builder.emit(addi(29, 29, 4))
    builder.branch_bne(29, 30, loop_label)


def generate_program():
    p = ProgramBuilder()

    # x5  = MMIO base
    # x6  = GPIO base
    # x7  = sector buffer base
    # x8  = image block pointer
    # x9  = key block pointer
    # x10 = plain sector
    # x11 = block count
    # x12 = ct sector
    # x13 = dec sector
    # x14 = ct_ok
    # x15 = dec_ok
    # x16..x19 = original block words
    # x20..x23 = indices 0..3
    # x24 = gpio shadow/stage
    # x25..x28 = result block words
    # x29..x31 = scratch / sector arg

    load_abs(p, 5, MMIO_BASE)
    load_abs(p, 6, GPIO_BASE)
    load_abs(p, 7, BUF_BASE)
    load_abs(p, 8, IMAGE_BASE)
    load_abs(p, 9, KEY_BASE)
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
    store_stage(p, GPIOF_FAIL | DISP_ERROR)
    p.jump("fatal_error")

    p.label("idle")
    p.label("wait_press")
    p.emit(lw(29, 6, 0))
    p.emit(andi(30, 29, 1))
    p.branch_beq(30, 0, "wait_press")

    p.label("wait_release")
    p.emit(lw(29, 6, 0))
    p.emit(andi(30, 29, 1))
    p.branch_bne(30, 0, "wait_release")

    store_stage(p, DISP_IDLE)
    store_stage(p, GPIOF_RUNNING | DISP_PRELOAD)
    emit_zero_buffer(p)
    emit_copy4(p, 8, 7)
    p.emit(addi(29, 0, META_SECTOR))
    p.jump("sd_write", rd=1)

    emit_zero_buffer(p)
    emit_copy4(p, 9, 7)
    p.emit(addi(29, 0, KEY_SECTOR))
    p.jump("sd_write", rd=1)

    p.emit(addi(8, 8, 16))
    p.emit(addi(29, 0, PLAIN_BASE_SECTOR))
    p.emit(addi(11, 0, IMAGE_FILE_BLOCKS))
    p.label("preload_loop")
    emit_zero_buffer(p)
    emit_copy4(p, 8, 7)
    p.jump("sd_write", rd=1)
    p.emit(addi(8, 8, 16))
    p.emit(addi(29, 29, 1))
    p.emit(addi(11, 11, -1))
    p.branch_bne(11, 0, "preload_loop")

    emit_load_key_once(p)

    p.emit(addi(14, 0, 1))
    p.emit(addi(15, 0, 1))
    p.emit(addi(10, 0, PLAIN_BASE_SECTOR))
    p.emit(addi(12, 0, CT_BASE_SECTOR))
    p.emit(addi(13, 0, DEC_BASE_SECTOR))
    p.emit(addi(11, 0, IMAGE_FILE_BLOCKS))

    p.label("block_loop")
    store_stage(p, GPIOF_RUNNING | GPIOF_PRELOAD_DONE | DISP_READ_ORIG)
    p.emit(addi(29, 10, 0))
    p.jump("sd_read", rd=1)

    p.emit(lw(16, 7, 0))
    p.emit(lw(17, 7, 4))
    p.emit(lw(18, 7, 8))
    p.emit(lw(19, 7, 12))

    store_stage(p, GPIOF_RUNNING | GPIOF_PRELOAD_DONE | DISP_ENCRYPT)
    p.emit(aes_load_pt(16, 20))
    p.emit(aes_load_pt(17, 21))
    p.emit(aes_load_pt(18, 22))
    p.emit(aes_load_pt(19, 23))
    p.emit(aes_start())
    p.label("enc_poll")
    p.emit(aes_status(29))
    p.branch_beq(29, 0, "enc_poll")
    p.emit(aes_read(25, 20))
    p.emit(aes_read(26, 21))
    p.emit(aes_read(27, 22))
    p.emit(aes_read(28, 23))

    store_stage(p, GPIOF_RUNNING | GPIOF_PRELOAD_DONE | DISP_WRITE_CT)
    emit_zero_buffer(p)
    p.emit(sw(25, 7, 0))
    p.emit(sw(26, 7, 4))
    p.emit(sw(27, 7, 8))
    p.emit(sw(28, 7, 12))
    p.emit(addi(29, 12, 0))
    p.jump("sd_write", rd=1)

    store_stage(p, GPIOF_RUNNING | GPIOF_PRELOAD_DONE | DISP_READ_CT)
    p.emit(addi(29, 12, 0))
    p.jump("sd_read", rd=1)

    p.emit(lw(1, 7, 0))
    p.emit(lw(2, 7, 4))
    p.emit(lw(3, 7, 8))
    p.emit(lw(4, 7, 12))

    p.emit(xor_inst(30, 25, 1))
    p.emit(xor_inst(31, 26, 2))
    p.emit(or_inst(30, 30, 31))
    p.emit(xor_inst(31, 27, 3))
    p.emit(or_inst(30, 30, 31))
    p.emit(xor_inst(31, 28, 4))
    p.emit(or_inst(30, 30, 31))
    p.branch_beq(30, 0, "ct_match")
    p.emit(addi(14, 0, 0))
    p.label("ct_match")

    store_stage(p, GPIOF_RUNNING | GPIOF_PRELOAD_DONE | DISP_DECRYPT)
    p.emit(aes_dec_load_ct(1, 20))
    p.emit(aes_dec_load_ct(2, 21))
    p.emit(aes_dec_load_ct(3, 22))
    p.emit(aes_dec_load_ct(4, 23))
    p.emit(aes_dec_start())
    p.label("dec_poll")
    p.emit(aes_dec_status(29))
    p.branch_beq(29, 0, "dec_poll")
    p.emit(aes_dec_read(25, 20))
    p.emit(aes_dec_read(26, 21))
    p.emit(aes_dec_read(27, 22))
    p.emit(aes_dec_read(28, 23))

    p.emit(xor_inst(30, 25, 16))
    p.emit(xor_inst(31, 26, 17))
    p.emit(or_inst(30, 30, 31))
    p.emit(xor_inst(31, 27, 18))
    p.emit(or_inst(30, 30, 31))
    p.emit(xor_inst(31, 28, 19))
    p.emit(or_inst(30, 30, 31))
    p.branch_beq(30, 0, "dec_match")
    p.emit(addi(15, 0, 0))
    p.label("dec_match")

    store_stage(p, GPIOF_RUNNING | GPIOF_PRELOAD_DONE | DISP_WRITE_DEC)
    emit_zero_buffer(p)
    p.emit(sw(25, 7, 0))
    p.emit(sw(26, 7, 4))
    p.emit(sw(27, 7, 8))
    p.emit(sw(28, 7, 12))
    p.emit(addi(29, 13, 0))
    p.jump("sd_write", rd=1)

    p.emit(addi(10, 10, 1))
    p.emit(addi(12, 12, 1))
    p.emit(addi(13, 13, 1))
    p.emit(addi(11, 11, -1))
    p.branch_bne(11, 0, "block_loop")

    store_stage(p, GPIOF_RUNNING | GPIOF_PRELOAD_DONE | DISP_PRELOAD)
    load_abs(p, 8, IMAGE_BASE)
    emit_zero_buffer(p)
    emit_copy4(p, 8, 7)
    p.emit(addi(29, 0, META_SECTOR))
    p.jump("sd_write", rd=1)

    emit_zero_buffer(p)
    emit_copy4(p, 9, 7)
    p.emit(addi(29, 0, KEY_SECTOR))
    p.jump("sd_write", rd=1)

    p.emit(addi(8, 8, 16))
    p.emit(addi(10, 0, PLAIN_BASE_SECTOR))
    p.emit(addi(11, 0, IMAGE_FILE_BLOCKS))
    p.label("restore_plain_loop")
    emit_zero_buffer(p)
    emit_copy4(p, 8, 7)
    p.emit(addi(29, 10, 0))
    p.jump("sd_write", rd=1)
    p.emit(addi(8, 8, 16))
    p.emit(addi(10, 10, 1))
    p.emit(addi(11, 11, -1))
    p.branch_bne(11, 0, "restore_plain_loop")

    p.emit(addi(24, 0, GPIOF_PRELOAD_DONE | GPIOF_RUN_DONE))
    p.branch_beq(14, 0, "skip_ct_ok")
    p.emit(ori(24, 24, GPIOF_CT_OK))
    p.label("skip_ct_ok")
    p.branch_beq(15, 0, "skip_dec_ok")
    p.emit(ori(24, 24, GPIOF_DEC_OK))
    p.label("skip_dec_ok")
    p.emit(and_inst(29, 14, 15))
    p.branch_beq(29, 0, "final_fail")
    p.emit(ori(24, 24, GPIOF_PASS | DISP_PASS))
    p.emit(sw(24, 6, 4))
    p.jump("idle")

    p.label("final_fail")
    p.emit(ori(24, 24, GPIOF_FAIL | DISP_FAIL))
    p.emit(sw(24, 6, 4))
    p.jump("idle")

    p.label("sd_write")
    p.emit(sw(29, 5, 8))
    p.emit(addi(30, 0, 8))
    p.emit(sw(30, 5, 0))
    p.emit(addi(30, 0, 2))
    p.emit(sw(30, 5, 0))
    p.label("sd_write_wait")
    p.emit(lw(30, 5, 4))
    p.emit(andi(31, 30, 2))
    p.branch_bne(31, 0, "fatal_error")
    p.emit(andi(31, 30, 16))
    p.branch_beq(31, 0, "sd_write_wait")
    p.emit(jalr(0, 1, 0))

    p.label("sd_read")
    p.emit(sw(29, 5, 8))
    p.emit(addi(30, 0, 4))
    p.emit(sw(30, 5, 0))
    p.emit(addi(30, 0, 1))
    p.emit(sw(30, 5, 0))
    p.label("sd_read_wait")
    p.emit(lw(30, 5, 4))
    p.emit(andi(31, 30, 2))
    p.branch_bne(31, 0, "fatal_error")
    p.emit(andi(31, 30, 8))
    p.branch_beq(31, 0, "sd_read_wait")
    p.emit(jalr(0, 1, 0))

    p.label("fatal_error")
    store_stage(p, GPIOF_FAIL | DISP_ERROR)
    p.label("fatal_error_loop")
    p.jump("fatal_error_loop")

    return p.resolve()


def parse_image_blocks():
    lines = [line.strip() for line in Path("image_input.hex").read_text().splitlines() if line.strip()]
    blocks = [bytes.fromhex(line) for line in lines]
    if len(blocks) != IMAGE_FILE_BLOCKS + 1:
        raise ValueError(f"expected {IMAGE_FILE_BLOCKS + 1} blocks, found {len(blocks)}")
    return blocks


def emit_data(memory):
    image_blocks = parse_image_blocks()
    for block_idx, block in enumerate(image_blocks):
        base_addr = IMAGE_BASE + block_idx * 16
        for word_idx in range(4):
            chunk = block[word_idx * 4:(word_idx + 1) * 4]
            memory[(base_addr // 4) + word_idx] = int.from_bytes(chunk, "little")

    for word_idx in range(4):
        chunk = FIXED_KEY_BYTES[word_idx * 4:(word_idx + 1) * 4]
        memory[(KEY_BASE // 4) + word_idx] = int.from_bytes(chunk, "little")


def main():
    memory = [nop()] * MEM_SIZE_WORDS
    program = generate_program()
    for idx, instr in enumerate(program):
        memory[idx] = instr

    emit_data(memory)

    out_path = Path("program_sd.hex")
    with out_path.open("w", newline="\n") as fh:
        for word in memory:
            fh.write(f"{word:08x}\n")

    print(f"Generated {out_path}")
    print(f"  Memory size : {MEM_SIZE_WORDS} words ({MEM_SIZE_WORDS * 4} bytes)")
    print(f"  Program size: {len(program)} instructions")
    print(f"  Image blocks: {IMAGE_FILE_BLOCKS + 1}")
    print(f"  Sector map  : meta={META_SECTOR}, key={KEY_SECTOR}, plain={PLAIN_BASE_SECTOR}..{PLAIN_BASE_SECTOR + IMAGE_FILE_BLOCKS - 1}, ct={CT_BASE_SECTOR}..{CT_BASE_SECTOR + IMAGE_FILE_BLOCKS - 1}, dec={DEC_BASE_SECTOR}..{DEC_BASE_SECTOR + IMAGE_FILE_BLOCKS - 1}")


if __name__ == "__main__":
    main()
