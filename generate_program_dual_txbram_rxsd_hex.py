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
MAILBOX_AUX0 = MAILBOX_BASE + 0x10
MAILBOX_AUX1 = MAILBOX_BASE + 0x14

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
MAC_KEY_BASE = 0x1C70
CMAC_K1_BASE = 0x1C80
CMAC_HEADER_BASE = 0x1C90
SCRATCH_LAST_CT_BASE = 0x1CA0
SCRATCH_RX_TAG_BASE = 0x1CB0
SCRATCH_DEC_PT_BASE = 0x1CC0
PSK_BASE = 0x1CD0
NONCE_RX_BASE = 0x1CE0
NONCE_TX_BASE = 0x1CF0
TAG_SECTOR = DEC_BASE_SECTOR + IMAGE_FILE_BLOCKS
LOCAL_TAG_SECTOR = TAG_SECTOR + 1
TOTAL_TRANSFER_BLOCKS = IMAGE_FILE_BLOCKS + 1

FLAG_START = 1 << 0
FLAG_TX_DONE = 1 << 1
FLAG_RX_DONE = 1 << 2
FLAG_PASS = 1 << 3
FLAG_FAIL = 1 << 4
FLAG_KEYS_READY = 1 << 5

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

PSK_KEY_BYTES = bytes([
    0x31, 0xA2, 0x7C, 0x4D,
    0x95, 0x16, 0xE8, 0x0F,
    0x62, 0xB1, 0x49, 0xD3,
    0x7A, 0x2C, 0x55, 0x90,
])

CMAC_KEY_BYTES = bytes([
    0xA6, 0x59, 0x59, 0x0B,
    0x72, 0xD2, 0x4F, 0x38,
    0x91, 0xC8, 0xE7, 0xA1,
    0x11, 0x5F, 0xB3, 0x2C,
])

AUX0_IMAGE_OK = 1 << 0
AUX0_MAC_OK = 1 << 1

KDF_LABEL_KENC = int.from_bytes(b"KENC", "little")
KDF_LABEL_KMAC = int.from_bytes(b"KMAC", "little")
KDF_CONTEXT = int.from_bytes(b"PSK1", "little")


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


def slli(rd, rs1, shamt):
    return encode_i_type(0b0010011, 0b001, rd, rs1, shamt)


def srli(rd, rs1, shamt):
    return encode_i_type(0b0010011, 0b101, rd, rs1, shamt)


def lw(rd, rs1, offset):
    return encode_i_type(0b0000011, 0b010, rd, rs1, offset)


def lbu(rd, rs1, offset):
    return encode_i_type(0b0000011, 0b100, rd, rs1, offset)


def jalr(rd, rs1, imm):
    return encode_i_type(0b1100111, 0b000, rd, rs1, imm)


def lui(rd, imm):
    return encode_u_type(0b0110111, rd, imm)


def sw(rs2, rs1, offset):
    return encode_s_type(0b0100011, 0b010, rs1, rs2, offset)


def sb(rs2, rs1, offset):
    return encode_s_type(0b0100011, 0b000, rs1, rs2, offset)


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


def aes_read(rd, rs1):
    return encode_r_type(0b0001011, 0b000, 0b0100011, rd, rs1, 0)


def aes_status(rd):
    return encode_r_type(0b0001011, 0b000, 0b0100100, rd, 0, 0)


def aes_start_nospi():
    return encode_r_type(0b0001011, 0b000, 0b0100101, 0, 0, 0)


def aes_send_raw():
    return encode_r_type(0b0001011, 0b000, 0b0100110, 0, 0, 0)


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


AES_SBOX = [
    0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,
    0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0, 0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,
    0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
    0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,
    0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0, 0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,
    0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
    0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,
    0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5, 0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,
    0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
    0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,
    0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C, 0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,
    0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
    0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,
    0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E, 0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,
    0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
    0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16,
]

AES_RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36]


def _xtime(byte):
    byte <<= 1
    if byte & 0x100:
        byte ^= 0x11B
    return byte & 0xFF


def _mix_single_column(col):
    t = col[0] ^ col[1] ^ col[2] ^ col[3]
    u = col[0]
    col[0] ^= t ^ _xtime(col[0] ^ col[1])
    col[1] ^= t ^ _xtime(col[1] ^ col[2])
    col[2] ^= t ^ _xtime(col[2] ^ col[3])
    col[3] ^= t ^ _xtime(col[3] ^ u)


def _sub_word(word):
    return [AES_SBOX[b] for b in word]


def _rot_word(word):
    return word[1:] + word[:1]


def aes128_expand_key(key_bytes):
    key_words = [list(key_bytes[i:i + 4]) for i in range(0, 16, 4)]
    words = key_words[:]
    for i in range(4, 44):
        temp = words[i - 1][:]
        if i % 4 == 0:
            temp = _sub_word(_rot_word(temp))
            temp[0] ^= AES_RCON[(i // 4) - 1]
        words.append([words[i - 4][j] ^ temp[j] for j in range(4)])
    round_keys = []
    for round_idx in range(11):
        rk = []
        for word in words[round_idx * 4:(round_idx + 1) * 4]:
            rk.extend(word)
        round_keys.append(rk)
    return round_keys


def aes128_encrypt_block(block_bytes, key_bytes):
    state = list(block_bytes)
    round_keys = aes128_expand_key(key_bytes)

    def add_round_key(rk):
        for i in range(16):
            state[i] ^= rk[i]

    def sub_bytes():
        for i in range(16):
            state[i] = AES_SBOX[state[i]]

    def shift_rows():
        rows = [
            [state[0], state[4], state[8], state[12]],
            [state[1], state[5], state[9], state[13]],
            [state[2], state[6], state[10], state[14]],
            [state[3], state[7], state[11], state[15]],
        ]
        rows[1] = rows[1][1:] + rows[1][:1]
        rows[2] = rows[2][2:] + rows[2][:2]
        rows[3] = rows[3][3:] + rows[3][:3]
        state[:] = [
            rows[0][0], rows[1][0], rows[2][0], rows[3][0],
            rows[0][1], rows[1][1], rows[2][1], rows[3][1],
            rows[0][2], rows[1][2], rows[2][2], rows[3][2],
            rows[0][3], rows[1][3], rows[2][3], rows[3][3],
        ]

    def mix_columns():
        for col in range(4):
            column = [state[col * 4 + i] for i in range(4)]
            _mix_single_column(column)
            for i in range(4):
                state[col * 4 + i] = column[i]

    add_round_key(round_keys[0])
    for round_idx in range(1, 10):
        sub_bytes()
        shift_rows()
        mix_columns()
        add_round_key(round_keys[round_idx])
    sub_bytes()
    shift_rows()
    add_round_key(round_keys[10])
    return bytes(state)


def cmac_subkey_k1(key_bytes):
    l_block = aes128_encrypt_block(bytes(16), key_bytes)
    value = int.from_bytes(l_block, "big")
    msb = (value >> 127) & 1
    value = ((value << 1) & ((1 << 128) - 1))
    if msb:
        value ^= 0x87
    return value.to_bytes(16, "big")


def load_abs(builder, rd, addr):
    hi = (addr + 0x800) & 0xFFFFF000
    lo = addr - hi
    builder.emit(lui(rd, hi))
    builder.emit(addi(rd, rd, lo))


def store_stage(builder, gpio_reg, imm):
    builder.emit(addi(31, 0, imm))
    builder.emit(sw(31, gpio_reg, 4))


def emit_copy4(builder, src_reg, dst_reg):
    builder.emit(lw(25, src_reg, 0))
    builder.emit(sw(25, dst_reg, 0))
    builder.emit(lw(26, src_reg, 4))
    builder.emit(sw(26, dst_reg, 4))
    builder.emit(lw(27, src_reg, 8))
    builder.emit(sw(27, dst_reg, 8))
    builder.emit(lw(28, src_reg, 12))
    builder.emit(sw(28, dst_reg, 12))


def emit_load4(builder, base_reg, r0, r1, r2, r3):
    builder.emit(lw(r0, base_reg, 0))
    builder.emit(lw(r1, base_reg, 4))
    builder.emit(lw(r2, base_reg, 8))
    builder.emit(lw(r3, base_reg, 12))


def emit_store4(builder, base_reg, r0, r1, r2, r3):
    builder.emit(sw(r0, base_reg, 0))
    builder.emit(sw(r1, base_reg, 4))
    builder.emit(sw(r2, base_reg, 8))
    builder.emit(sw(r3, base_reg, 12))


def emit_zero_buffer(builder, buf_reg):
    loop_label = f"zero_buffer_{len(builder.items)}"
    builder.emit(addi(29, buf_reg, 0))
    load_abs(builder, 30, BUF_BASE + 512)
    builder.label(loop_label)
    builder.emit(sw(0, 29, 0))
    builder.emit(addi(29, 29, 4))
    builder.branch_bne(29, 30, loop_label)


def emit_load_enc_key_regs(builder, key_ptr_reg, r0, r1, r2, r3):
    builder.emit(lw(r0, key_ptr_reg, 0))
    builder.emit(aes_load_key(r0, 20))
    builder.emit(lw(r1, key_ptr_reg, 4))
    builder.emit(aes_load_key(r1, 21))
    builder.emit(lw(r2, key_ptr_reg, 8))
    builder.emit(aes_load_key(r2, 22))
    builder.emit(lw(r3, key_ptr_reg, 12))
    builder.emit(aes_load_key(r3, 23))


def emit_load_enc_key(builder, key_ptr_reg):
    emit_load_enc_key_regs(builder, key_ptr_reg, 25, 26, 27, 28)


def emit_read_enc_result(builder, r0, r1, r2, r3):
    builder.emit(aes_read(r0, 20))
    builder.emit(aes_read(r1, 21))
    builder.emit(aes_read(r2, 22))
    builder.emit(aes_read(r3, 23))


def emit_load_dec_key(builder, key_ptr_reg):
    builder.emit(lw(25, key_ptr_reg, 0))
    builder.emit(aes_dec_load_key(25, 20))
    builder.emit(lw(26, key_ptr_reg, 4))
    builder.emit(aes_dec_load_key(26, 21))
    builder.emit(lw(27, key_ptr_reg, 8))
    builder.emit(aes_dec_load_key(27, 22))
    builder.emit(lw(28, key_ptr_reg, 12))
    builder.emit(aes_dec_load_key(28, 23))


def emit_nonce_step(builder, state_reg, temp_reg, delta):
    builder.emit(addi(state_reg, state_reg, delta))
    builder.emit(slli(temp_reg, state_reg, 5))
    builder.emit(xor_inst(state_reg, state_reg, temp_reg))


def emit_store_nonce32(builder, base_reg, nonce_reg):
    builder.emit(sw(nonce_reg, base_reg, 0))
    builder.emit(sw(0, base_reg, 4))
    builder.emit(sw(0, base_reg, 8))
    builder.emit(sw(0, base_reg, 12))


def emit_derive_session_key(builder, psk_ptr_reg, nonce_rx_reg, nonce_tx_reg,
                            label_word, context_word, out_ptr_reg, out0, out1, out2, out3):
    emit_load_enc_key_regs(builder, psk_ptr_reg, 28, 29, 30, 31)
    builder.emit(addi(24, nonce_rx_reg, 0))
    builder.emit(addi(25, nonce_tx_reg, 0))
    load_abs(builder, 26, label_word)
    load_abs(builder, 27, context_word)
    builder.emit(aes_load_pt(24, 20))
    builder.emit(aes_load_pt(25, 21))
    builder.emit(aes_load_pt(26, 22))
    builder.emit(aes_load_pt(27, 23))
    builder.emit(aes_start_nospi())
    emit_read_enc_result(builder, out0, out1, out2, out3)
    emit_store4(builder, out_ptr_reg, out0, out1, out2, out3)


def emit_derive_cmac_k1(builder, kmac_ptr_reg, out_ptr_reg):
    shift_loop = f"k1_shift_loop_{len(builder.items)}"
    shift_done = f"k1_shift_done_{len(builder.items)}"
    k1_done = f"k1_done_{len(builder.items)}"
    emit_load_enc_key_regs(builder, kmac_ptr_reg, 28, 29, 30, 31)
    builder.emit(addi(24, 0, 0))
    builder.emit(addi(25, 0, 0))
    builder.emit(addi(26, 0, 0))
    builder.emit(addi(27, 0, 0))
    builder.emit(aes_load_pt(24, 20))
    builder.emit(aes_load_pt(25, 21))
    builder.emit(aes_load_pt(26, 22))
    builder.emit(aes_load_pt(27, 23))
    builder.emit(aes_start_nospi())
    emit_read_enc_result(builder, 24, 25, 26, 27)
    emit_store4(builder, out_ptr_reg, 24, 25, 26, 27)

    builder.emit(lbu(24, out_ptr_reg, 0))
    builder.emit(srli(24, 24, 7))
    builder.emit(addi(25, 0, 0))
    builder.emit(addi(26, out_ptr_reg, 15))
    builder.label(shift_loop)
    builder.emit(lbu(27, 26, 0))
    builder.emit(srli(28, 27, 7))
    builder.emit(slli(29, 27, 1))
    builder.emit(andi(29, 29, 0xFF))
    builder.emit(or_inst(29, 29, 25))
    builder.emit(sb(29, 26, 0))
    builder.emit(addi(25, 28, 0))
    builder.branch_beq(26, out_ptr_reg, shift_done)
    builder.emit(addi(26, 26, -1))
    builder.jump(shift_loop)
    builder.label(shift_done)
    builder.branch_beq(24, 0, k1_done)
    load_abs(builder, 28, 0x87)
    builder.emit(lbu(29, out_ptr_reg, 15))
    builder.emit(xor_inst(29, 29, 28))
    builder.emit(sb(29, out_ptr_reg, 15))
    builder.label(k1_done)


def emit_cmac_init(builder, kmac_ptr_reg, header_ptr_reg, c0, c1, c2, c3):
    emit_load_enc_key_regs(builder, kmac_ptr_reg, 28, 29, 30, 31)
    emit_load4(builder, header_ptr_reg, 24, 25, 26, 27)
    builder.emit(aes_load_pt(24, 20))
    builder.emit(aes_load_pt(25, 21))
    builder.emit(aes_load_pt(26, 22))
    builder.emit(aes_load_pt(27, 23))
    builder.emit(aes_start_nospi())
    emit_read_enc_result(builder, c0, c1, c2, c3)


def emit_cmac_update(builder, kmac_ptr_reg, in0, in1, in2, in3, c0, c1, c2, c3):
    emit_load_enc_key_regs(builder, kmac_ptr_reg, 28, 29, 30, 31)
    builder.emit(xor_inst(24, in0, c0))
    builder.emit(xor_inst(25, in1, c1))
    builder.emit(xor_inst(26, in2, c2))
    builder.emit(xor_inst(27, in3, c3))
    builder.emit(aes_load_pt(24, 20))
    builder.emit(aes_load_pt(25, 21))
    builder.emit(aes_load_pt(26, 22))
    builder.emit(aes_load_pt(27, 23))
    builder.emit(aes_start_nospi())
    emit_read_enc_result(builder, c0, c1, c2, c3)


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
    load_abs(p, 8, MAC_KEY_BASE)
    load_abs(p, 9, CMAC_K1_BASE)
    load_abs(p, 10, CMAC_HEADER_BASE)
    load_abs(p, 11, SCRATCH_LAST_CT_BASE)
    load_abs(p, 17, PSK_BASE)
    p.emit(addi(18, 0, 0x155))
    p.emit(addi(20, 0, 0))
    p.emit(addi(21, 0, 1))
    p.emit(addi(22, 0, 2))
    p.emit(addi(23, 0, 3))

    p.label("wait_start")
    emit_nonce_step(p, 18, 30, 13)
    p.emit(lw(29, 5, 0))
    p.emit(andi(30, 29, FLAG_START))
    p.branch_beq(30, 0, "wait_start")
    p.emit(lw(19, 5, 16))
    load_abs(p, 30, NONCE_RX_BASE)
    emit_store_nonce32(p, 30, 19)
    load_abs(p, 30, NONCE_TX_BASE)
    emit_store_nonce32(p, 30, 18)
    p.emit(sw(18, 5, 20))

    emit_derive_session_key(p, 17, 19, 18, KDF_LABEL_KENC, KDF_CONTEXT, 7, 24, 25, 26, 27)
    emit_derive_session_key(p, 17, 19, 18, KDF_LABEL_KMAC, KDF_CONTEXT, 8, 24, 25, 26, 27)
    emit_derive_cmac_k1(p, 8, 9)

    p.label("wait_keys_ready")
    p.emit(lw(29, 5, 0))
    p.emit(andi(30, 29, FLAG_KEYS_READY))
    p.branch_beq(30, 0, "wait_keys_ready")

    emit_cmac_init(p, 8, 10, 13, 14, 15, 16)

    p.emit(addi(17, 0, IMAGE_FILE_BLOCKS))
    p.emit(addi(12, 0, 0))
    p.label("tx_loop")
    emit_load_enc_key(p, 7)
    emit_load4(p, 6, 24, 25, 26, 27)
    p.emit(aes_load_pt(24, 20))
    p.emit(aes_load_pt(25, 21))
    p.emit(aes_load_pt(26, 22))
    p.emit(aes_load_pt(27, 23))
    p.emit(aes_start())
    emit_read_enc_result(p, 24, 25, 26, 27)

    p.emit(addi(12, 12, 1))
    p.emit(sw(12, 5, 8))
    p.emit(addi(29, 0, 1))
    p.branch_bne(17, 29, "tx_nonfinal")

    emit_store4(p, 11, 24, 25, 26, 27)
    p.jump("tx_wait_ack")

    p.label("tx_nonfinal")
    emit_cmac_update(p, 8, 24, 25, 26, 27, 13, 14, 15, 16)

    p.label("tx_wait_ack")
    p.label("wait_ack")
    p.emit(lw(29, 5, 12))
    p.branch_bne(29, 12, "wait_ack")
    p.emit(addi(6, 6, 16))
    p.emit(addi(17, 17, -1))
    p.branch_bne(17, 0, "tx_loop")

    emit_load4(p, 11, 24, 25, 26, 27)
    p.emit(lw(29, 9, 0))
    p.emit(xor_inst(24, 24, 29))
    p.emit(lw(29, 9, 4))
    p.emit(xor_inst(25, 25, 29))
    p.emit(lw(29, 9, 8))
    p.emit(xor_inst(26, 26, 29))
    p.emit(lw(29, 9, 12))
    p.emit(xor_inst(27, 27, 29))
    emit_cmac_update(p, 8, 24, 25, 26, 27, 13, 14, 15, 16)

    p.emit(aes_load_pt(13, 20))
    p.emit(aes_load_pt(14, 21))
    p.emit(aes_load_pt(15, 22))
    p.emit(aes_load_pt(16, 23))
    p.emit(aes_send_raw())
    p.emit(addi(12, 12, 1))
    p.emit(sw(12, 5, 8))
    p.label("wait_tag_ack")
    p.emit(lw(29, 5, 12))
    p.branch_bne(29, 12, "wait_tag_ack")

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

    p.emit(addi(2, 0, 1))
    load_abs(p, 3, MAC_KEY_BASE)
    load_abs(p, 4, CMAC_K1_BASE)
    load_abs(p, 5, SD_MMIO_BASE)
    load_abs(p, 6, GPIO_BASE)
    load_abs(p, 7, BUF_BASE)
    load_abs(p, 8, MAILBOX_BASE)
    load_abs(p, 9, RXBUF_BASE)
    load_abs(p, 10, IMAGE_BASE)
    load_abs(p, 11, KEY_BASE)
    load_abs(p, 12, IMAGE_BASE + 16)
    load_abs(p, 17, CMAC_HEADER_BASE)
    load_abs(p, 15, PSK_BASE)
    p.emit(addi(18, 0, 0x2A3))
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
    emit_nonce_step(p, 18, 30, 9)
    p.emit(lw(29, 6, 0))
    p.emit(andi(30, 29, 1))
    p.branch_beq(30, 0, "wait_press")
    p.label("wait_release")
    emit_nonce_step(p, 18, 30, 5)
    p.emit(lw(29, 6, 0))
    p.emit(andi(30, 29, 1))
    p.branch_bne(30, 0, "wait_release")

    store_stage(p, 6, GPIOF_RUNNING | DISP_PRELOAD)
    load_abs(p, 30, NONCE_RX_BASE)
    emit_store_nonce32(p, 30, 18)
    p.emit(sw(18, 8, 16))
    p.emit(sw(0, 8, 20))
    p.emit(sw(0, 8, 0))
    p.emit(addi(29, 0, TOTAL_TRANSFER_BLOCKS))
    p.emit(sw(29, 8, 4))
    p.emit(sw(0, 8, 8))
    p.emit(sw(0, 8, 12))
    p.emit(addi(29, 0, FLAG_START))
    p.emit(sw(29, 8, 0))
    p.label("wait_nonce_tx")
    p.emit(lw(19, 8, 20))
    p.branch_beq(19, 0, "wait_nonce_tx")
    load_abs(p, 30, NONCE_TX_BASE)
    emit_store_nonce32(p, 30, 19)
    emit_derive_session_key(p, 15, 18, 19, KDF_LABEL_KENC, KDF_CONTEXT, 11, 24, 25, 26, 27)
    emit_derive_session_key(p, 15, 18, 19, KDF_LABEL_KMAC, KDF_CONTEXT, 3, 24, 25, 26, 27)
    emit_derive_cmac_k1(p, 3, 4)

    emit_zero_buffer(p, 7)
    emit_copy4(p, 10, 7)
    p.emit(addi(29, 0, META_SECTOR))
    p.jump("sd_write", rd=1)

    emit_zero_buffer(p, 7)
    emit_copy4(p, 11, 7)
    p.emit(addi(29, 0, KEY_SECTOR))
    p.jump("sd_write", rd=1)

    emit_cmac_init(p, 3, 17, 13, 14, 15, 16)
    emit_load_dec_key(p, 11)
    p.emit(lw(29, 8, 0))
    p.emit(ori(29, 29, FLAG_KEYS_READY))
    p.emit(sw(29, 8, 0))

    p.emit(addi(17, 0, IMAGE_FILE_BLOCKS))
    p.emit(addi(18, 0, CT_BASE_SECTOR))
    p.emit(addi(19, 0, DEC_BASE_SECTOR))
    p.label("rx_loop")
    store_stage(p, 6, GPIOF_RUNNING | GPIOF_PRELOAD_DONE | DISP_RX_WAIT)
    p.label("wait_rx")
    p.emit(lw(29, 9, 0))
    p.emit(andi(30, 29, 1))
    p.branch_beq(30, 0, "wait_rx")

    p.emit(lw(24, 9, 4))
    p.emit(lw(25, 9, 8))
    p.emit(lw(26, 9, 12))
    p.emit(lw(27, 9, 16))
    p.emit(sw(0, 9, 20))
    load_abs(p, 30, SCRATCH_LAST_CT_BASE)
    emit_store4(p, 30, 24, 25, 26, 27)

    store_stage(p, 6, GPIOF_RUNNING | GPIOF_PRELOAD_DONE | DISP_WRITE_CT)
    emit_zero_buffer(p, 7)
    p.emit(sw(24, 7, 0))
    p.emit(sw(25, 7, 4))
    p.emit(sw(26, 7, 8))
    p.emit(sw(27, 7, 12))
    p.emit(addi(29, 18, 0))
    p.jump("sd_write", rd=1)

    p.emit(aes_dec_load_ct(24, 20))
    p.emit(aes_dec_load_ct(25, 21))
    p.emit(aes_dec_load_ct(26, 22))
    p.emit(aes_dec_load_ct(27, 23))
    p.emit(aes_dec_start())
    p.label("dec_poll")
    p.emit(aes_dec_status(29))
    p.branch_beq(29, 0, "dec_poll")
    p.emit(aes_dec_read(25, 20))
    p.emit(aes_dec_read(26, 21))
    p.emit(aes_dec_read(27, 22))
    p.emit(aes_dec_read(28, 23))
    load_abs(p, 30, SCRATCH_DEC_PT_BASE)
    emit_store4(p, 30, 25, 26, 27, 28)

    p.emit(addi(29, 0, 1))
    p.branch_bne(17, 29, "rx_cmac_nonfinal")
    p.jump("rx_cmac_done")
    p.label("rx_cmac_nonfinal")
    load_abs(p, 30, SCRATCH_LAST_CT_BASE)
    emit_load4(p, 30, 24, 25, 26, 27)
    emit_cmac_update(p, 3, 24, 25, 26, 27, 13, 14, 15, 16)
    p.label("rx_cmac_done")

    load_abs(p, 30, SCRATCH_DEC_PT_BASE)
    emit_load4(p, 30, 25, 26, 27, 28)

    p.emit(lw(29, 12, 0))
    p.emit(lw(30, 12, 4))
    p.emit(lw(31, 12, 8))
    p.emit(lw(24, 12, 12))
    p.emit(xor_inst(29, 25, 29))
    p.emit(xor_inst(30, 26, 30))
    p.emit(or_inst(29, 29, 30))
    p.emit(xor_inst(30, 27, 31))
    p.emit(or_inst(29, 29, 30))
    p.emit(xor_inst(30, 28, 24))
    p.emit(or_inst(29, 29, 30))
    p.branch_beq(29, 0, "match_ok")
    p.emit(addi(2, 0, 0))
    p.label("match_ok")

    store_stage(p, 6, GPIOF_RUNNING | GPIOF_PRELOAD_DONE | GPIOF_CT_DONE | DISP_WRITE_DEC)
    emit_zero_buffer(p, 7)
    p.emit(sw(25, 7, 0))
    p.emit(sw(26, 7, 4))
    p.emit(sw(27, 7, 8))
    p.emit(sw(28, 7, 12))
    p.emit(addi(29, 19, 0))
    p.jump("sd_write", rd=1)

    p.emit(lw(29, 8, 12))
    p.emit(addi(29, 29, 1))
    p.emit(sw(29, 8, 12))
    p.emit(addi(18, 18, 1))
    p.emit(addi(19, 19, 1))
    p.emit(addi(12, 12, 16))
    p.emit(addi(17, 17, -1))
    p.branch_bne(17, 0, "rx_loop")

    store_stage(p, 6, GPIOF_RUNNING | GPIOF_PRELOAD_DONE | GPIOF_CT_DONE | DISP_TRANSFER)
    p.label("wait_tag")
    p.emit(lw(29, 9, 0))
    p.emit(andi(30, 29, 1))
    p.branch_beq(30, 0, "wait_tag")
    p.emit(lw(24, 9, 4))
    p.emit(lw(25, 9, 8))
    p.emit(lw(26, 9, 12))
    p.emit(lw(27, 9, 16))
    p.emit(sw(0, 9, 20))
    load_abs(p, 30, SCRATCH_RX_TAG_BASE)
    emit_store4(p, 30, 24, 25, 26, 27)

    emit_zero_buffer(p, 7)
    emit_store4(p, 7, 24, 25, 26, 27)
    p.emit(addi(29, 0, TAG_SECTOR))
    p.jump("sd_write", rd=1)

    load_abs(p, 30, SCRATCH_LAST_CT_BASE)
    emit_load4(p, 30, 24, 25, 26, 27)
    p.emit(lw(29, 4, 0))
    p.emit(xor_inst(24, 24, 29))
    p.emit(lw(29, 4, 4))
    p.emit(xor_inst(25, 25, 29))
    p.emit(lw(29, 4, 8))
    p.emit(xor_inst(26, 26, 29))
    p.emit(lw(29, 4, 12))
    p.emit(xor_inst(27, 27, 29))
    emit_cmac_update(p, 3, 24, 25, 26, 27, 13, 14, 15, 16)

    emit_zero_buffer(p, 7)
    p.emit(sw(13, 7, 0))
    p.emit(sw(14, 7, 4))
    p.emit(sw(15, 7, 8))
    p.emit(sw(16, 7, 12))
    p.emit(addi(29, 0, LOCAL_TAG_SECTOR))
    p.jump("sd_write", rd=1)

    load_abs(p, 30, SCRATCH_RX_TAG_BASE)
    emit_load4(p, 30, 24, 25, 26, 27)
    p.emit(xor_inst(29, 13, 24))
    p.emit(xor_inst(30, 14, 25))
    p.emit(or_inst(29, 29, 30))
    p.emit(xor_inst(30, 15, 26))
    p.emit(or_inst(29, 29, 30))
    p.emit(xor_inst(30, 16, 27))
    p.emit(or_inst(29, 29, 30))
    p.branch_beq(29, 0, "mac_ok")
    p.emit(addi(29, 0, 0))
    p.jump("mac_done")
    p.label("mac_ok")
    p.emit(addi(29, 0, 1))
    p.label("mac_done")
    p.emit(sw(29, 8, 16))
    p.emit(lw(30, 8, 12))
    p.emit(addi(30, 30, 1))
    p.emit(sw(30, 8, 12))

    p.label("wait_tx_done")
    p.emit(lw(29, 8, 0))
    p.emit(andi(30, 29, FLAG_TX_DONE))
    p.branch_beq(30, 0, "wait_tx_done")

    p.emit(addi(30, 0, 0))
    p.branch_beq(2, 0, "aux_after_img")
    p.emit(ori(30, 30, AUX0_IMAGE_OK))
    p.label("aux_after_img")
    p.emit(lw(31, 8, 16))
    p.branch_beq(31, 0, "aux_done")
    p.emit(ori(30, 30, AUX0_MAC_OK))
    p.label("aux_done")
    p.emit(sw(30, 8, 16))

    p.emit(lw(29, 8, 0))
    p.emit(ori(29, 29, FLAG_RX_DONE))
    p.branch_beq(2, 0, "mark_fail")
    p.emit(lw(30, 8, 16))
    p.emit(andi(30, 30, AUX0_MAC_OK))
    p.branch_beq(30, 0, "mark_fail")
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
    header_block = (
        IMAGE_FILE_BLOCKS.to_bytes(4, "little")
        + (IMAGE_FILE_BLOCKS * 16).to_bytes(4, "little")
        + b"CMACDEMO"
    )
    if len(header_block) != 16:
        raise ValueError("CMAC header block must be exactly 16 bytes")
    for block_idx, block in enumerate(image_blocks):
        base_addr = IMAGE_BASE + block_idx * 16
        for word_idx in range(4):
            chunk = block[word_idx * 4:(word_idx + 1) * 4]
            memory[(base_addr // 4) + word_idx] = int.from_bytes(chunk, "little")

    for word_idx in range(4):
        memory[(KEY_BASE // 4) + word_idx] = 0
        memory[(MAC_KEY_BASE // 4) + word_idx] = 0
        memory[(CMAC_K1_BASE // 4) + word_idx] = 0
        memory[(NONCE_RX_BASE // 4) + word_idx] = 0
        memory[(NONCE_TX_BASE // 4) + word_idx] = 0
        psk_chunk = PSK_KEY_BYTES[word_idx * 4:(word_idx + 1) * 4]
        memory[(PSK_BASE // 4) + word_idx] = int.from_bytes(psk_chunk, "little")
        header_chunk = header_block[word_idx * 4:(word_idx + 1) * 4]
        memory[(CMAC_HEADER_BASE // 4) + word_idx] = int.from_bytes(header_chunk, "little")


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
