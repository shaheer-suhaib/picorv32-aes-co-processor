#!/usr/bin/env python3
"""
FULL PIPELINE WITH CMAC:
TX: Read switches -> AES Encrypt -> Compute CMAC tag -> Send ciphertext via SPI -> Send CMAC tag via SPI
RX: Receive ciphertext -> Receive tag -> AES Decrypt -> Recompute CMAC -> Verify tag -> Display result

CMAC is computed using AES-128-CMAC (RFC 4493) over a header block + the ciphertext block.
The CMAC tag is sent as a separate 16-byte SPI transfer after the ciphertext.

If CMAC verification fails on receiver, LEDs blink to indicate tampering.
"""

import struct

# ====================== Instruction Encoders ======================

def encode_i_type(opcode, funct3, rd, rs1, imm):
    return (((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode) & 0xFFFFFFFF

def encode_r_type(opcode, funct3, funct7, rd, rs1, rs2):
    return ((funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode) & 0xFFFFFFFF

def encode_s_type(opcode, funct3, rs1, rs2, imm):
    imm_11_5 = (imm >> 5) & 0x7F
    imm_4_0 = imm & 0x1F
    return ((imm_11_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (imm_4_0 << 7) | opcode) & 0xFFFFFFFF

def encode_b_type(opcode, funct3, rs1, rs2, imm):
    imm_12 = (imm >> 12) & 0x1
    imm_10_5 = (imm >> 5) & 0x3F
    imm_4_1 = (imm >> 1) & 0xF
    imm_11 = (imm >> 11) & 0x1
    return ((imm_12 << 31) | (imm_10_5 << 25) | (rs2 << 20) | (rs1 << 15) | \
           (funct3 << 12) | (imm_4_1 << 8) | (imm_11 << 7) | opcode) & 0xFFFFFFFF

def lui(rd, imm):
    return ((imm & 0xFFFFF) << 12) | (rd << 7) | 0b0110111

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

def xor_inst(rd, rs1, rs2):
    return encode_r_type(0b0110011, 0b100, 0b0000000, rd, rs1, rs2)

def or_inst(rd, rs1, rs2):
    return encode_r_type(0b0110011, 0b110, 0b0000000, rd, rs1, rs2)

def lw(rd, rs1, offset):
    return encode_i_type(0b0000011, 0b010, rd, rs1, offset)

def lbu(rd, rs1, offset):
    return encode_i_type(0b0000011, 0b100, rd, rs1, offset)

def sw(rs2, rs1, offset):
    return encode_s_type(0b0100011, 0b010, rs1, rs2, offset)

def sb(rs2, rs1, offset):
    return encode_s_type(0b0100011, 0b000, rs1, rs2, offset)

def beqz(rs1, offset):
    return encode_b_type(0b1100011, 0b000, rs1, 0, offset)

def bnez(rs1, offset):
    return encode_b_type(0b1100011, 0b001, rs1, 0, offset)

def beq(rs1, rs2, offset):
    return encode_b_type(0b1100011, 0b000, rs1, rs2, offset)

def bne(rs1, rs2, offset):
    return encode_b_type(0b1100011, 0b001, rs1, rs2, offset)

def j(offset):
    imm_20 = (offset >> 20) & 0x1
    imm_10_1 = (offset >> 1) & 0x3FF
    imm_11 = (offset >> 11) & 0x1
    imm_19_12 = (offset >> 12) & 0xFF
    return ((imm_20 << 31) | (imm_19_12 << 12) | (imm_11 << 20) | (imm_10_1 << 21) | (0 << 7) | 0b1101111) & 0xFFFFFFFF

def nop():
    return addi(0, 0, 0)

# ====================== AES Custom Instructions ======================
IDX_REG = 7  # x7 used as index register

# Encryption
def aes_load_pt(rs2, rs1):
    return encode_r_type(0b0001011, 0b000, 0b0100000, 0, rs1, rs2)

def aes_load_key(rs2, rs1):
    return encode_r_type(0b0001011, 0b000, 0b0100001, 0, rs1, rs2)

def aes_start_nospi():
    return encode_r_type(0b0001011, 0b000, 0b0100101, 0, 0, 0)

def aes_status(rd):
    return encode_r_type(0b0001011, 0b000, 0b0100100, rd, 0, 0)

def aes_read(rd, rs1):
    return encode_r_type(0b0001011, 0b000, 0b0100011, rd, rs1, 0)

def aes_send_raw():
    return encode_r_type(0b0001011, 0b000, 0b0100110, 0, 0, 0)

# Decryption
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

# ====================== Helper Functions ======================

def load_const(rd, val):
    """Load a 32-bit constant into register rd (2 instructions: LUI + ADDI)"""
    upper = (val >> 12) & 0xFFFFF
    lower = val & 0xFFF
    if (lower & 0x800):
        upper = (upper + 1) & 0xFFFFF
    return [lui(rd, upper), addi(rd, rd, lower | (0xFFFFF000 if lower & 0x800 else 0))]

def emit_aes_enc_block(program, data_regs, enc_key_base_reg):
    """Encrypt a 128-bit block: data_regs = [r0,r1,r2,r3] contain plaintext words.
    enc_key_base_reg points to BRAM holding 4 key words.
    After this, call aes_read to get ciphertext."""
    d0, d1, d2, d3 = data_regs
    # Load key
    for i in range(4):
        program.append(lw(8, enc_key_base_reg, i*4))
        program.append(addi(IDX_REG, 0, i))
        program.append(aes_load_key(8, IDX_REG))
    # Load plaintext
    program.append(addi(IDX_REG, 0, 0))
    program.append(aes_load_pt(d0, IDX_REG))
    program.append(addi(IDX_REG, 0, 1))
    program.append(aes_load_pt(d1, IDX_REG))
    program.append(addi(IDX_REG, 0, 2))
    program.append(aes_load_pt(d2, IDX_REG))
    program.append(addi(IDX_REG, 0, 3))
    program.append(aes_load_pt(d3, IDX_REG))
    # Encrypt (no SPI)
    program.append(aes_start_nospi())
    # Poll status
    poll_label = len(program)
    program.append(aes_status(4))
    program.append(beqz(4, (poll_label - len(program)) * 4))

def emit_aes_read_result(program, out_regs):
    """Read 4 result words from AES engine into out_regs."""
    for i, r in enumerate(out_regs):
        program.append(addi(IDX_REG, 0, i))
        program.append(aes_read(r, IDX_REG))

def emit_send_raw_from_regs(program, data_regs):
    """Load data_regs into PT and send over SPI using SEND_RAW."""
    for i, r in enumerate(data_regs):
        program.append(addi(IDX_REG, 0, i))
        program.append(aes_load_pt(r, IDX_REG))
    program.append(aes_send_raw())

def emit_cmac_block(program, in_regs, c_regs, mac_key_base_reg):
    """CMAC update: C = AES_ENC(in XOR C, K_mac)
    in_regs = [r_in0..3], c_regs = [r_c0..3] (state), mac_key_base_reg = key pointer.
    After: c_regs hold new CMAC state."""
    i0, i1, i2, i3 = in_regs
    c0, c1, c2, c3 = c_regs
    # XOR input with running CMAC state
    program.append(xor_inst(10, i0, c0))
    program.append(xor_inst(11, i1, c1))
    program.append(xor_inst(12, i2, c2))
    program.append(xor_inst(13, i3, c3))
    # Encrypt the XOR result
    emit_aes_enc_block(program, [10, 11, 12, 13], mac_key_base_reg)
    # Read result into CMAC state registers
    emit_aes_read_result(program, [c0, c1, c2, c3])

# ====================== CMAC K1 Subkey Derivation (Python) ======================
AES_SBOX = [
    0x63,0x7C,0x77,0x7B,0xF2,0x6B,0x6F,0xC5,0x30,0x01,0x67,0x2B,0xFE,0xD7,0xAB,0x76,
    0xCA,0x82,0xC9,0x7D,0xFA,0x59,0x47,0xF0,0xAD,0xD4,0xA2,0xAF,0x9C,0xA4,0x72,0xC0,
    0xB7,0xFD,0x93,0x26,0x36,0x3F,0xF7,0xCC,0x34,0xA5,0xE5,0xF1,0x71,0xD8,0x31,0x15,
    0x04,0xC7,0x23,0xC3,0x18,0x96,0x05,0x9A,0x07,0x12,0x80,0xE2,0xEB,0x27,0xB2,0x75,
    0x09,0x83,0x2C,0x1A,0x1B,0x6E,0x5A,0xA0,0x52,0x3B,0xD6,0xB3,0x29,0xE3,0x2F,0x84,
    0x53,0xD1,0x00,0xED,0x20,0xFC,0xB1,0x5B,0x6A,0xCB,0xBE,0x39,0x4A,0x4C,0x58,0xCF,
    0xD0,0xEF,0xAA,0xFB,0x43,0x4D,0x33,0x85,0x45,0xF9,0x02,0x7F,0x50,0x3C,0x9F,0xA8,
    0x51,0xA3,0x40,0x8F,0x92,0x9D,0x38,0xF5,0xBC,0xB6,0xDA,0x21,0x10,0xFF,0xF3,0xD2,
    0xCD,0x0C,0x13,0xEC,0x5F,0x97,0x44,0x17,0xC4,0xA7,0x7E,0x3D,0x64,0x5D,0x19,0x73,
    0x60,0x81,0x4F,0xDC,0x22,0x2A,0x90,0x88,0x46,0xEE,0xB8,0x14,0xDE,0x5E,0x0B,0xDB,
    0xE0,0x32,0x3A,0x0A,0x49,0x06,0x24,0x5C,0xC2,0xD3,0xAC,0x62,0x91,0x95,0xE4,0x79,
    0xE7,0xC8,0x37,0x6D,0x8D,0xD5,0x4E,0xA9,0x6C,0x56,0xF4,0xEA,0x65,0x7A,0xAE,0x08,
    0xBA,0x78,0x25,0x2E,0x1C,0xA6,0xB4,0xC6,0xE8,0xDD,0x74,0x1F,0x4B,0xBD,0x8B,0x8A,
    0x70,0x3E,0xB5,0x66,0x48,0x03,0xF6,0x0E,0x61,0x35,0x57,0xB9,0x86,0xC1,0x1D,0x9E,
    0xE1,0xF8,0x98,0x11,0x69,0xD9,0x8E,0x94,0x9B,0x1E,0x87,0xE9,0xCE,0x55,0x28,0xDF,
    0x8C,0xA1,0x89,0x0D,0xBF,0xE6,0x42,0x68,0x41,0x99,0x2D,0x0F,0xB0,0x54,0xBB,0x16,
]
AES_RCON = [0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1B,0x36]

def _xtime(b):
    b <<= 1
    if b & 0x100: b ^= 0x11B
    return b & 0xFF

def _mix_col(col):
    t = col[0]^col[1]^col[2]^col[3]; u = col[0]
    col[0] ^= t^_xtime(col[0]^col[1]); col[1] ^= t^_xtime(col[1]^col[2])
    col[2] ^= t^_xtime(col[2]^col[3]); col[3] ^= t^_xtime(col[3]^u)

def aes128_encrypt_block(block, key):
    state = list(block)
    words = [list(key[i:i+4]) for i in range(0,16,4)]
    w = words[:]
    for i in range(4,44):
        t = w[i-1][:]
        if i%4==0:
            t = [AES_SBOX[b] for b in t[1:]+t[:1]]
            t[0] ^= AES_RCON[(i//4)-1]
        w.append([w[i-4][j]^t[j] for j in range(4)])
    rks = []
    for r in range(11):
        rk = []
        for ww in w[r*4:(r+1)*4]: rk.extend(ww)
        rks.append(rk)
    for i in range(16): state[i] ^= rks[0][i]
    for rnd in range(1,10):
        state = [AES_SBOX[b] for b in state]
        rows = [[state[j*4+i] for j in range(4)] for i in range(4)]
        for i in range(1,4): rows[i] = rows[i][i:]+rows[i][:i]
        state = [rows[i][j] for j in range(4) for i in range(4)]
        for c in range(4):
            col = [state[c*4+i] for i in range(4)]
            _mix_col(col)
            for i in range(4): state[c*4+i] = col[i]
        for i in range(16): state[i] ^= rks[rnd][i]
    state = [AES_SBOX[b] for b in state]
    rows = [[state[j*4+i] for j in range(4)] for i in range(4)]
    for i in range(1,4): rows[i] = rows[i][i:]+rows[i][:i]
    state = [rows[i][j] for j in range(4) for i in range(4)]
    for i in range(16): state[i] ^= rks[10][i]
    return bytes(state)

def cmac_subkey_k1(key_bytes):
    L = aes128_encrypt_block(bytes(16), key_bytes)
    val = int.from_bytes(L, "big")
    msb = (val >> 127) & 1
    val = ((val << 1) & ((1 << 128) - 1))
    if msb: val ^= 0x87
    return val.to_bytes(16, "big")

# ====================== Memory Layout ======================
#   0x0000 - 0x0FFF: Program code (4096 words = 16KB)
#   0x1000 - 0x100F: AES encryption key (4 words)
#   0x1010 - 0x101F: CMAC/MAC key (4 words)
#   0x1020 - 0x102F: CMAC K1 subkey (4 words, pre-computed)
#   0x1030 - 0x103F: CMAC header block (4 words)
#   0x1040 - 0x104F: Scratch: last ciphertext (4 words)

ENC_KEY_ADDR   = 0x1000
MAC_KEY_ADDR   = 0x1010
CMAC_K1_ADDR   = 0x1020
CMAC_HDR_ADDR  = 0x1030
SCRATCH_CT_ADDR = 0x1040

GPIO_BASE = 0x20000000
RXBUF_BASE = 0x30000000

def generate_program():
    program = []

    # ===================== Register Setup =====================
    # x1 = GPIO_BASE,  x2 = RXBUF_BASE,  x3 = ENC_KEY_ADDR
    # x6 = MAC_KEY_ADDR
    # x14 = CMAC_K1_ADDR,  x15 = CMAC_HDR_ADDR
    # CMAC state: x16, x17, x18, x19
    # Ciphertext: x20, x21, x22, x23
    # Temp: x4, x5, x8, x9, x10, x11, x12, x13
    # IDX: x7

    program.extend(load_const(1, GPIO_BASE))
    program.extend(load_const(2, RXBUF_BASE))
    program.extend(load_const(3, ENC_KEY_ADDR))
    program.extend(load_const(6, MAC_KEY_ADDR))
    program.extend(load_const(14, CMAC_K1_ADDR))
    program.extend(load_const(15, CMAC_HDR_ADDR))

    # ===================== Main Loop =====================
    loop_label = len(program)

    # Check BTNC
    program.append(lw(4, 1, 4))
    branch_to_tx_idx = len(program)
    program.append(nop())  # placeholder for bnez

    # Check RX_STATUS
    program.append(lw(4, 2, 0))
    branch_to_rx_idx = len(program)
    program.append(nop())  # placeholder for bnez

    program.append(j((loop_label - len(program)) * 4))

    # =====================================================================
    # TX MODE: Encrypt -> Compute CMAC -> Send ciphertext -> Send CMAC tag
    # =====================================================================
    tx_mode_label = len(program)
    program[branch_to_tx_idx] = bnez(4, (tx_mode_label - branch_to_tx_idx) * 4)

    # Wait for button release
    wait_btn_label = len(program)
    program.append(lw(4, 1, 4))
    program.append(bnez(4, (wait_btn_label - len(program)) * 4))

    # Read switches -> x5
    program.append(lw(5, 1, 0))

    # --- Step 1: AES Encrypt the switch value ---
    # PT = {SW, 0, 0, 0}
    program.append(addi(IDX_REG, 0, 0))
    program.append(aes_load_pt(5, IDX_REG))
    program.append(addi(IDX_REG, 0, 1))
    program.append(aes_load_pt(0, IDX_REG))
    program.append(addi(IDX_REG, 0, 2))
    program.append(aes_load_pt(0, IDX_REG))
    program.append(addi(IDX_REG, 0, 3))
    program.append(aes_load_pt(0, IDX_REG))
    # Load encryption key
    for i in range(4):
        program.append(lw(8, 3, i*4))
        program.append(addi(IDX_REG, 0, i))
        program.append(aes_load_key(8, IDX_REG))
    # Encrypt (no SPI)
    program.append(aes_start_nospi())
    enc_poll = len(program)
    program.append(aes_status(4))
    program.append(beqz(4, (enc_poll - len(program)) * 4))

    # Read ciphertext into x20-x23
    for i in range(4):
        program.append(addi(IDX_REG, 0, i))
        program.append(aes_read(20+i, IDX_REG))

    # --- Step 2: Compute CMAC tag ---
    # CMAC = AES_ENC(header, K_mac)  (init with header block)
    # Load CMAC header into x10-x13
    for i in range(4):
        program.append(lw(10+i, 15, i*4))
    # Encrypt header with MAC key -> CMAC state x16-x19
    emit_aes_enc_block(program, [10, 11, 12, 13], 6)
    emit_aes_read_result(program, [16, 17, 18, 19])

    # CMAC update with ciphertext: C = AES_ENC(CT XOR C, K_mac)
    # For the final (and only data) block, XOR with K1 first
    program.append(lw(9, 14, 0))   # K1 word 0
    program.append(xor_inst(10, 20, 9))
    program.append(lw(9, 14, 4))
    program.append(xor_inst(11, 21, 9))
    program.append(lw(9, 14, 8))
    program.append(xor_inst(12, 22, 9))
    program.append(lw(9, 14, 12))
    program.append(xor_inst(13, 23, 9))
    # XOR with CMAC state
    program.append(xor_inst(10, 10, 16))
    program.append(xor_inst(11, 11, 17))
    program.append(xor_inst(12, 12, 18))
    program.append(xor_inst(13, 13, 19))
    # Encrypt -> final CMAC tag in x16-x19
    emit_aes_enc_block(program, [10, 11, 12, 13], 6)
    emit_aes_read_result(program, [16, 17, 18, 19])

    # --- Step 3: Send ciphertext via SPI (SEND_RAW) ---
    emit_send_raw_from_regs(program, [20, 21, 22, 23])

    # Small delay between SPI transfers (let receiver process)
    for _ in range(20):
        program.append(nop())

    # --- Step 4: Send CMAC tag via SPI ---
    emit_send_raw_from_regs(program, [16, 17, 18, 19])

    # Show original switch value on TX LEDs
    program.append(sw(5, 1, 8))

    # Jump back to main loop
    program.append(j((loop_label - len(program)) * 4))

    # =====================================================================
    # RX MODE: Receive ciphertext -> Receive tag -> Decrypt -> Verify CMAC
    # =====================================================================
    rx_mode_label = len(program)
    program[branch_to_rx_idx] = bnez(4, (rx_mode_label - branch_to_rx_idx) * 4)

    # --- Step 1: Read received ciphertext ---
    for i in range(4):
        program.append(lw(20+i, 2, 4 + i*4))  # x20-x23 = RX_DATA
    # Clear RX status
    program.append(sw(0, 2, 0x14))

    # --- Step 2: AES Decrypt the ciphertext ---
    for i in range(4):
        program.append(addi(IDX_REG, 0, i))
        program.append(aes_dec_load_ct(20+i, IDX_REG))
    # Load decryption key
    for i in range(4):
        program.append(lw(8, 3, i*4))
        program.append(addi(IDX_REG, 0, i))
        program.append(aes_dec_load_key(8, IDX_REG))
    # Decrypt
    program.append(aes_dec_start())
    dec_poll = len(program)
    program.append(aes_dec_status(4))
    program.append(beqz(4, (dec_poll - len(program)) * 4))
    # Read decrypted word 0 -> x5
    program.append(addi(IDX_REG, 0, 0))
    program.append(aes_dec_read(5, IDX_REG))

    # --- Step 3: Recompute CMAC locally on the received ciphertext ---
    # CMAC init with header
    for i in range(4):
        program.append(lw(10+i, 15, i*4))
    emit_aes_enc_block(program, [10, 11, 12, 13], 6)
    emit_aes_read_result(program, [16, 17, 18, 19])

    # CMAC final block: CT XOR K1 XOR C
    program.append(lw(9, 14, 0))
    program.append(xor_inst(10, 20, 9))
    program.append(lw(9, 14, 4))
    program.append(xor_inst(11, 21, 9))
    program.append(lw(9, 14, 8))
    program.append(xor_inst(12, 22, 9))
    program.append(lw(9, 14, 12))
    program.append(xor_inst(13, 23, 9))
    program.append(xor_inst(10, 10, 16))
    program.append(xor_inst(11, 11, 17))
    program.append(xor_inst(12, 12, 18))
    program.append(xor_inst(13, 13, 19))
    emit_aes_enc_block(program, [10, 11, 12, 13], 6)
    emit_aes_read_result(program, [16, 17, 18, 19])
    # x16-x19 = locally computed CMAC tag

    # --- Step 4: Wait for CMAC tag to arrive via SPI ---
    rx_tag_poll = len(program)
    program.append(lw(4, 2, 0))
    program.append(beqz(4, (rx_tag_poll - len(program)) * 4))
    # Read received tag -> x24-x27
    for i in range(4):
        program.append(lw(24+i, 2, 4 + i*4))
    # Clear RX status
    program.append(sw(0, 2, 0x14))

    # --- Step 5: Compare tags ---
    # XOR all words and OR together -> x4
    program.append(xor_inst(4, 16, 24))
    program.append(xor_inst(9, 17, 25))
    program.append(or_inst(4, 4, 9))
    program.append(xor_inst(9, 18, 26))
    program.append(or_inst(4, 4, 9))
    program.append(xor_inst(9, 19, 27))
    program.append(or_inst(4, 4, 9))
    # x4 = 0 if tags match, nonzero if mismatch

    # --- Step 6: Display result ---
    # If CMAC OK: show decrypted value on LEDs and 7-seg
    # If CMAC FAIL: show 0xFFFF on LEDs (all on = error indicator)
    cmac_fail_idx = len(program)
    program.append(nop())  # placeholder for bnez

    # CMAC PASS: show decrypted value
    program.append(sw(5, 1, 8))      # LEDs = decrypted value
    program.append(sw(5, 1, 0x0C))   # 7-seg = decrypted value
    program.append(j((loop_label - len(program)) * 4))

    # CMAC FAIL: show error
    cmac_fail_label = len(program)
    program[cmac_fail_idx] = bnez(4, (cmac_fail_label - cmac_fail_idx) * 4)
    program.extend(load_const(9, 0xFFFF))
    program.append(sw(9, 1, 8))      # LEDs = all on (error)
    program.extend(load_const(9, 0xEEEE))
    program.append(sw(9, 1, 0x0C))   # 7-seg = "EEEE" (error)
    program.append(j((loop_label - len(program)) * 4))

    return program

# ====================== Pre-compute CMAC K1 in Python ======================

# Keys stored as little-endian words in BRAM
ENC_KEY = 0x1234567890ABCDEF1122334455667788
MAC_KEY = 0xA659590B72D24F3891C8E7A1115FB32C

def int128_to_le_words(val):
    return [
        (val >>  0) & 0xFFFFFFFF,
        (val >> 32) & 0xFFFFFFFF,
        (val >> 64) & 0xFFFFFFFF,
        (val >> 96) & 0xFFFFFFFF,
    ]

def int128_to_bytes_le(val):
    return val.to_bytes(16, "little")

def main():
    MEM_SIZE = 4096
    memory = [nop()] * MEM_SIZE

    program = generate_program()
    if len(program) > 0x400:
        raise ValueError(f"Program too large: {len(program)} instructions (max {0x400})")
    for i, instr in enumerate(program):
        memory[i] = instr

    # Store encryption key at 0x1000 (word offset 0x400)
    enc_key_words = int128_to_le_words(ENC_KEY)
    for i, w in enumerate(enc_key_words):
        memory[0x400 + i] = w

    # Store MAC key at 0x1010 (word offset 0x404)
    mac_key_words = int128_to_le_words(MAC_KEY)
    for i, w in enumerate(mac_key_words):
        memory[0x404 + i] = w

    # Pre-compute CMAC K1 subkey and store at 0x1020 (word offset 0x408)
    mac_key_bytes = int128_to_bytes_le(MAC_KEY)
    k1_bytes = cmac_subkey_k1(mac_key_bytes)
    for i in range(4):
        word = struct.unpack_from("<I", k1_bytes, i*4)[0]
        memory[0x408 + i] = word

    # CMAC header block at 0x1030 (word offset 0x40C)
    # "AES-CMAC-DEMO\x00\x00\x00" = 16 bytes
    header = b"AES-CMAC-DEMO\x00\x00\x00"
    assert len(header) == 16
    for i in range(4):
        word = struct.unpack_from("<I", header, i*4)[0]
        memory[0x40C + i] = word

    output_file = "c:/AllData/FYPnew/cmacaddedFYP/picorv32-aes-co-processor/fpga/program_simple.hex"
    with open(output_file, 'w') as f:
        for word in memory:
            f.write(f"{word:08x}\n")

    print(f"Generated {output_file}")
    print(f"  Program size: {len(program)} instructions")
    print(f"  MODE: FULL PIPELINE WITH CMAC")
    print(f"  TX: SW -> AES_ENC -> CMAC_TAG -> SPI(ciphertext) -> SPI(tag)")
    print(f"  RX: SPI -> AES_DEC -> recompute CMAC -> verify tag -> display")
    print(f"  CMAC OK: LEDs/7seg show decrypted value")
    print(f"  CMAC FAIL: LEDs = 0xFFFF, 7seg = EEEE")

if __name__ == "__main__":
    main()
