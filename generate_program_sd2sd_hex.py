#!/usr/bin/env python3
"""
Generate program_sd2sd.hex for two-FPGA SD-to-SD transfer.

Behavior (same bitstream on both boards):
- If BTNC is pressed: read image from local SD (Phase-1 layout) and send
  16-byte blocks over SPI.
- Otherwise: wait for SPI blocks and write them to local SD.

SPI transfer sends raw 128-bit blocks using aes_send_raw (no encryption).
"""

from pathlib import Path


MEM_SIZE_WORDS = 4096

SD_MMIO_BASE = 0x0200_0000
GPIO_BASE = 0x0200_0100
BUF_BASE = 0x0200_0200
RXBUF_BASE = 0x3000_0000

RX_STATUS = RXBUF_BASE + 0x00
RX_DATA0 = RXBUF_BASE + 0x04
RX_DATA1 = RXBUF_BASE + 0x08
RX_DATA2 = RXBUF_BASE + 0x0C
RX_DATA3 = RXBUF_BASE + 0x10
RX_CLEAR = RXBUF_BASE + 0x14

META_SECTOR = 20
PLAIN_BASE_SECTOR = 22

GPIOF_RUNNING = 1 << 10
GPIOF_RUN_DONE = 1 << 7
GPIOF_FAIL = 1 << 9
GPIOF_PASS = 1 << 8

DISP_IDLE = 0
DISP_TX = 2
DISP_RX = 3
DISP_DONE = 9
DISP_ERROR = 14


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


def srli(rd, rs1, shamt):
    return encode_i_type(0b0010011, 0b101, rd, rs1, shamt)


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


def or_inst(rd, rs1, rs2):
    return encode_r_type(0b0110011, 0b110, 0b0000000, rd, rs1, rs2)


def aes_load_pt(rs2, rs1):
    return encode_r_type(0b0001011, 0b000, 0b0100000, 0, rs1, rs2)


def aes_send_raw():
    return encode_r_type(0b0001011, 0b000, 0b0100110, 0, 0, 0)


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
    builder.emit(addi(31, 0, imm))
    builder.emit(sw(31, gpio_reg, 4))


def emit_zero_buffer(builder, buf_reg):
    loop_label = f"zero_buffer_{len(builder.items)}"
    builder.emit(addi(29, buf_reg, 0))
    load_abs(builder, 30, BUF_BASE + 512)
    builder.label(loop_label)
    builder.emit(sw(0, 29, 0))
    builder.emit(addi(29, 29, 4))
    builder.branch_bne(29, 30, loop_label)


def emit_sd_read(builder, sd_reg):
    builder.label("sd_read")
    builder.emit(sw(29, sd_reg, 8))
    builder.emit(addi(30, 0, 4))
    builder.emit(sw(30, sd_reg, 0))
    builder.emit(addi(30, 0, 1))
    builder.emit(sw(30, sd_reg, 0))
    builder.label("sd_read_wait")
    builder.emit(lw(30, sd_reg, 4))
    builder.emit(andi(31, 30, 2))
    builder.branch_bne(31, 0, "fatal_error")
    builder.emit(andi(31, 30, 8))
    builder.branch_beq(31, 0, "sd_read_wait")
    builder.emit(jalr(0, 1, 0))


def emit_sd_write(builder, sd_reg):
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


def generate_program():
    p = ProgramBuilder()

    # x5 = SD MMIO base
    # x6 = GPIO base
    # x7 = SD buffer base
    # x8 = RX buffer base
    # x10 = block count
    # x11 = sector index
    # x16..x19 temp/meta words
    load_abs(p, 5, SD_MMIO_BASE)
    load_abs(p, 6, GPIO_BASE)
    load_abs(p, 7, BUF_BASE)
    load_abs(p, 8, RXBUF_BASE)

    # VERY IMPORTANT: Initialize x20..x23 to 0..3 for AES word indexes!
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

    # if BTNC pressed -> TX mode, else RX mode
    p.label("idle_poll")
    p.emit(lw(29, 6, 0))
    p.emit(andi(30, 29, 1))
    p.branch_beq(30, 0, "rx_wait_meta")
    p.jump("tx_start")

    # ---------- TX MODE ----------
    p.label("tx_start")
    # wait for button release
    p.label("tx_wait_release")
    p.emit(lw(29, 6, 0))
    p.emit(andi(30, 29, 1))
    p.branch_bne(30, 0, "tx_wait_release")

    store_stage(p, 6, GPIOF_RUNNING | DISP_TX)

    # read meta sector
    p.emit(addi(29, 0, META_SECTOR))
    p.jump("sd_read", rd=1)
    p.emit(lw(16, 7, 0))
    p.emit(lw(17, 7, 4))
    p.emit(lw(18, 7, 8))
    p.emit(lw(19, 7, 12))

    # send meta
    p.emit(aes_load_pt(16, 20))
    p.emit(aes_load_pt(17, 21))
    p.emit(aes_load_pt(18, 22))
    p.emit(aes_load_pt(19, 23))
    p.emit(aes_send_raw())

    # ADD A DELAY HERE TOO (For the Meta block)!
    p.emit(lui(25, 150))
    p.label("tx_delay_meta")
    p.emit(addi(25, 25, -1))
    p.branch_bne(25, 0, "tx_delay_meta")

    # block_count = (size + 15) >> 4 ; size = word0 (little endian)
    p.emit(addi(10, 16, 15))
    p.emit(srli(10, 10, 4))
    p.branch_beq(10, 0, "tx_done")

    p.emit(addi(11, 0, PLAIN_BASE_SECTOR))
    p.label("tx_loop")
    p.emit(addi(29, 11, 0))
    p.jump("sd_read", rd=1)
    p.emit(lw(16, 7, 0))
    p.emit(lw(17, 7, 4))
    p.emit(lw(18, 7, 8))
    p.emit(lw(19, 7, 12))
    p.emit(aes_load_pt(16, 20))
    p.emit(aes_load_pt(17, 21))
    p.emit(aes_load_pt(18, 22))
    p.emit(aes_load_pt(19, 23))
    p.emit(aes_send_raw())

    # ADD A DELAY! The receiver's sd_write() takes longer than our sd_read(). 
    # Give the receiver enough time before we blast the next SPI packet to avoid packet drop.
    p.emit(lui(25, 150)) # load ~600k into x25
    p.label("tx_delay_loop")
    p.emit(addi(25, 25, -1))
    p.branch_bne(25, 0, "tx_delay_loop")
    p.emit(addi(11, 11, 1))
    p.emit(addi(10, 10, -1))
    p.branch_bne(10, 0, "tx_loop")

    p.label("tx_done")
    store_stage(p, 6, GPIOF_RUN_DONE | GPIOF_PASS | DISP_DONE)
    p.jump("idle")

    # ---------- RX MODE ----------
    p.label("rx_wait_meta")
    store_stage(p, 6, GPIOF_RUNNING | DISP_RX)
    p.label("rx_meta_wait")
    p.emit(lw(29, 8, 0))
    p.emit(andi(30, 29, 1))
    p.branch_beq(30, 0, "rx_meta_wait")
    p.emit(lw(16, 8, 4))
    p.emit(lw(17, 8, 8))
    p.emit(lw(18, 8, 12))
    p.emit(lw(19, 8, 16))
    p.emit(sw(0, 8, 20))  # clear RX

    # write meta sector
    emit_zero_buffer(p, 7)
    p.emit(sw(16, 7, 0))
    p.emit(sw(17, 7, 4))
    p.emit(sw(18, 7, 8))
    p.emit(sw(19, 7, 12))
    p.emit(addi(29, 0, META_SECTOR))
    p.jump("sd_write", rd=1)

    p.emit(addi(10, 16, 15))
    p.emit(srli(10, 10, 4))
    p.branch_beq(10, 0, "rx_done")
    p.emit(addi(11, 0, PLAIN_BASE_SECTOR))

    p.label("rx_loop")
    p.label("rx_wait")
    p.emit(lw(29, 8, 0))
    p.emit(andi(30, 29, 1))
    p.branch_beq(30, 0, "rx_wait")
    p.emit(lw(16, 8, 4))
    p.emit(lw(17, 8, 8))
    p.emit(lw(18, 8, 12))
    p.emit(lw(19, 8, 16))
    p.emit(sw(0, 8, 20))

    emit_zero_buffer(p, 7)
    p.emit(sw(16, 7, 0))
    p.emit(sw(17, 7, 4))
    p.emit(sw(18, 7, 8))
    p.emit(sw(19, 7, 12))
    p.emit(addi(29, 11, 0))
    p.jump("sd_write", rd=1)
    p.emit(addi(11, 11, 1))
    p.emit(addi(10, 10, -1))
    p.branch_bne(10, 0, "rx_loop")

    p.label("rx_done")
    store_stage(p, 6, GPIOF_RUN_DONE | GPIOF_PASS | DISP_DONE)
    p.jump("idle")

    p.label("fatal_error")
    store_stage(p, 6, GPIOF_FAIL | DISP_ERROR)
    p.label("fatal_loop")
    p.jump("fatal_loop")

    emit_sd_read(p, 5)
    emit_sd_write(p, 5)
    return p.resolve()


def write_hex(path, program):
    memory = [nop()] * MEM_SIZE_WORDS
    for idx, instr in enumerate(program):
        memory[idx] = instr
    with Path(path).open("w", newline="\n") as fh:
        for word in memory:
            fh.write(f"{word:08x}\n")


def main():
    program = generate_program()
    write_hex("program_sd2sd.hex", program)
    print("Generated program_sd2sd.hex")
    print(f"  Program size: {len(program)} instructions")


if __name__ == "__main__":
    main()

