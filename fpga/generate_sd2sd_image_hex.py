#!/usr/bin/env python3
"""
SD-to-SD Image Transfer Firmware Generator

TX: SD card read -> AES encrypt -> CMAC -> SPI transmit
RX: SPI receive -> AES decrypt -> CMAC verify -> SD card write

SD sector layout:
  Sector 0: metadata (4-byte LE image size + padding)
  Sectors 1-N: image data (padded to 512B boundary)

Both boards run the same firmware. Role is determined by:
  - BTNC press -> TX mode
  - SPI data arrives -> RX mode
"""

import struct, math, os

# ====================== RISC-V Instruction Encoders ======================

def encode_i_type(opcode, funct3, rd, rs1, imm):
    return (((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode) & 0xFFFFFFFF

def encode_r_type(opcode, funct3, funct7, rd, rs1, rs2):
    return ((funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode) & 0xFFFFFFFF

def encode_s_type(opcode, funct3, rs1, rs2, imm):
    return (((imm >> 5) & 0x7F) << 25 | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | ((imm & 0x1F) << 7) | opcode) & 0xFFFFFFFF

def encode_b_type(opcode, funct3, rs1, rs2, imm):
    return (((imm >> 12) & 0x1) << 31 | ((imm >> 5) & 0x3F) << 25 | (rs2 << 20) | (rs1 << 15) |
            (funct3 << 12) | ((imm >> 1) & 0xF) << 8 | ((imm >> 11) & 0x1) << 7 | opcode) & 0xFFFFFFFF

def encode_j_type(opcode, rd, imm):
    return (((imm >> 20) & 0x1) << 31 | ((imm >> 1) & 0x3FF) << 21 | ((imm >> 11) & 0x1) << 20 |
            ((imm >> 12) & 0xFF) << 12 | (rd << 7) | opcode) & 0xFFFFFFFF

def lui(rd, imm):    return ((imm & 0xFFFFF) << 12) | (rd << 7) | 0b0110111
def addi(rd, rs1, imm): return encode_i_type(0b0010011, 0b000, rd, rs1, imm)
def andi(rd, rs1, imm): return encode_i_type(0b0010011, 0b111, rd, rs1, imm)
def slli(rd, rs1, sh):  return encode_i_type(0b0010011, 0b001, rd, rs1, sh)
def lw(rd, rs1, off):   return encode_i_type(0b0000011, 0b010, rd, rs1, off)
def sw(rs2, rs1, off):  return encode_s_type(0b0100011, 0b010, rs1, rs2, off)
def beq(rs1, rs2, off): return encode_b_type(0b1100011, 0b000, rs1, rs2, off)
def bne(rs1, rs2, off): return encode_b_type(0b1100011, 0b001, rs1, rs2, off)
def jal(rd, off):       return encode_j_type(0b1101111, rd, off)
def jalr(rd, rs1, imm): return encode_i_type(0b1100111, 0b000, rd, rs1, imm)
def add(rd, rs1, rs2):  return encode_r_type(0b0110011, 0b000, 0b0000000, rd, rs1, rs2)
def xor_r(rd, rs1, rs2):return encode_r_type(0b0110011, 0b100, 0b0000000, rd, rs1, rs2)
def or_r(rd, rs1, rs2): return encode_r_type(0b0110011, 0b110, 0b0000000, rd, rs1, rs2)
def nop(): return addi(0, 0, 0)

# AES custom instructions
def aes_load_pt(rs2, rs1):   return encode_r_type(0b0001011, 0b000, 0b0100000, 0, rs1, rs2)
def aes_load_key(rs2, rs1):  return encode_r_type(0b0001011, 0b000, 0b0100001, 0, rs1, rs2)
def aes_start_nospi():       return encode_r_type(0b0001011, 0b000, 0b0100101, 0, 0, 0)
def aes_status(rd):          return encode_r_type(0b0001011, 0b000, 0b0100100, rd, 0, 0)
def aes_read(rd, rs1):       return encode_r_type(0b0001011, 0b000, 0b0100011, rd, rs1, 0)
def aes_send_raw():          return encode_r_type(0b0001011, 0b000, 0b0100110, 0, 0, 0)
def aes_dec_load_ct(rs2, rs1): return encode_r_type(0b0001011, 0b000, 0b0101000, 0, rs1, rs2)
def aes_dec_load_key(rs2, rs1):return encode_r_type(0b0001011, 0b000, 0b0101001, 0, rs1, rs2)
def aes_dec_start():         return encode_r_type(0b0001011, 0b000, 0b0101010, 0, 0, 0)
def aes_dec_read(rd, rs1):   return encode_r_type(0b0001011, 0b000, 0b0101011, rd, rs1, 0)
def aes_dec_status(rd):      return encode_r_type(0b0001011, 0b000, 0b0101100, rd, 0, 0)

# ====================== Program Builder ======================

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
        self.emit_fixup(lambda pc, L: beq(rs1, rs2, L[target] - pc))

    def branch_bne(self, rs1, rs2, target):
        self.emit_fixup(lambda pc, L: bne(rs1, rs2, L[target] - pc))

    def jump(self, target, rd=0):
        self.emit_fixup(lambda pc, L: jal(rd, L[target] - pc))

    def resolve(self):
        words = [v for k, v in self.items if k == "insn"]
        for idx, pc, resolver in self.fixups:
            words[idx] = resolver(pc, self.labels) & 0xFFFFFFFF
        return words

# ====================== Helper: load 32-bit constant ======================

def load_abs(p, rd, addr):
    hi = (addr + 0x800) & 0xFFFFF000
    lo = addr - hi
    p.emit(lui(rd, hi >> 12))
    p.emit(addi(rd, rd, lo))

# ====================== Register Allocation ======================
# x0  = zero
# x1  = SD_BASE (0x02000000)
# x2  = RXBUF_BASE (0x30000000)
# x3  = BUF_PTR (SD_BASE + 0x200, sector buffer base)
# x4  = temp/status
# x5  = temp/data
# x6  = ENC_KEY_BRAM_ADDR
# x7  = IDX_REG (always used for AES word index)
# x8  = temp (key loading)
# x9  = temp
# x10-x13 = temp for CMAC XOR / AES PT loading
# x14 = MAC_KEY_BRAM_ADDR
# x15 = CMAC_K1_BRAM_ADDR
# x16-x19 = CMAC state (C0-C3)
# x20-x23 = current data block (CT or PT)
# x24 = remaining_blocks counter
# x25 = current_sector number
# x26 = block_within_sector (0-31)
# x27 = buf_offset_reg (byte offset within sector_buf)
# x28 = temp (pointer computation)
# x29 = temp
# x30 = return address for subroutines
# x31 = temp

SD_BASE    = 0x02000000
RXBUF_BASE = 0x30000000
BUF_OFFSET = 0x200   # sector_buf at SD_BASE + 0x200

# SD MMIO offsets from SD_BASE
SD_CTRL   = 0x000
SD_STATUS = 0x004
SD_SECTOR = 0x008
GPIO_STAT = 0x100   # bit0 = BTNC
GPIO_OUT  = 0x104   # LED/7seg control

# BRAM data layout
ENC_KEY_ADDR   = 0x1000
MAC_KEY_ADDR   = 0x1010
CMAC_K1_ADDR   = 0x1020
CMAC_HDR_ADDR  = 0x1030
META_ADDR      = 0x1040   # {image_size, total_blocks, total_data_sectors, 0}
IMAGE_BUF_ADDR = 0x1100   # RX image buffer in BRAM (up to ~14KB free)

IDX = 7  # x7 = index register for AES instructions

# ====================== Firmware Emitters ======================

def emit_load_enc_key(p, key_base_reg):
    """Load encryption key from BRAM into AES engine."""
    for i in range(4):
        p.emit(lw(8, key_base_reg, i*4))
        p.emit(addi(IDX, 0, i))
        p.emit(aes_load_key(8, IDX))

def emit_load_dec_key(p, key_base_reg):
    """Load decryption key from BRAM into AES dec engine."""
    for i in range(4):
        p.emit(lw(8, key_base_reg, i*4))
        p.emit(addi(IDX, 0, i))
        p.emit(aes_dec_load_key(8, IDX))

_enc_counter = [0]

def emit_aes_enc(p, d0, d1, d2, d3):
    """Encrypt data in registers d0-d3 using already-loaded key. Result stays in AES engine."""
    c = _enc_counter[0]
    _enc_counter[0] += 1
    lbl = f"_enc_poll_{c}"
    p.emit(addi(IDX, 0, 0)); p.emit(aes_load_pt(d0, IDX))
    p.emit(addi(IDX, 0, 1)); p.emit(aes_load_pt(d1, IDX))
    p.emit(addi(IDX, 0, 2)); p.emit(aes_load_pt(d2, IDX))
    p.emit(addi(IDX, 0, 3)); p.emit(aes_load_pt(d3, IDX))
    p.emit(aes_start_nospi())
    p.label(lbl)
    p.emit(aes_status(4))
    p.branch_beq(4, 0, lbl)

def emit_aes_read_result(p, r0, r1, r2, r3):
    """Read 4 result words from AES into registers."""
    p.emit(addi(IDX, 0, 0)); p.emit(aes_read(r0, IDX))
    p.emit(addi(IDX, 0, 1)); p.emit(aes_read(r1, IDX))
    p.emit(addi(IDX, 0, 2)); p.emit(aes_read(r2, IDX))
    p.emit(addi(IDX, 0, 3)); p.emit(aes_read(r3, IDX))

def emit_send_raw(p, r0, r1, r2, r3):
    """Load regs into AES PT and send via SPI (proven working path)."""
    p.emit(addi(IDX, 0, 0)); p.emit(aes_load_pt(r0, IDX))
    p.emit(addi(IDX, 0, 1)); p.emit(aes_load_pt(r1, IDX))
    p.emit(addi(IDX, 0, 2)); p.emit(aes_load_pt(r2, IDX))
    p.emit(addi(IDX, 0, 3)); p.emit(aes_load_pt(r3, IDX))
    p.emit(aes_send_raw())

def emit_cmac_update(p, in0, in1, in2, in3):
    """CMAC update: C = AES_ENC(in XOR C, K_mac). Uses x10-x13 as temps.
    CMAC state in x16-x19, MAC key base in x14."""
    p.emit(xor_r(10, in0, 16))
    p.emit(xor_r(11, in1, 17))
    p.emit(xor_r(12, in2, 18))
    p.emit(xor_r(13, in3, 19))
    emit_load_enc_key(p, 14)  # Load MAC key
    emit_aes_enc(p, 10, 11, 12, 13)
    emit_aes_read_result(p, 16, 17, 18, 19)

def emit_cmac_init(p):
    """CMAC init: C = AES_ENC(header, K_mac). Loads header from x15 ptr."""
    for i in range(4):
        p.emit(lw(10+i, 15, i*4))  # Load CMAC header
    emit_load_enc_key(p, 14)       # Load MAC key
    emit_aes_enc(p, 10, 11, 12, 13)
    emit_aes_read_result(p, 16, 17, 18, 19)

# ====================== Main Firmware ======================

def generate_firmware():
    p = ProgramBuilder()

    # === Setup constants ===
    load_abs(p, 1, SD_BASE)
    load_abs(p, 2, RXBUF_BASE)
    load_abs(p, 3, SD_BASE + BUF_OFFSET)  # sector_buf base
    load_abs(p, 6, ENC_KEY_ADDR)
    load_abs(p, 14, MAC_KEY_ADDR)
    load_abs(p, 15, CMAC_HDR_ADDR)

    # === Power-up delay (~100ms) for SD card to stabilize ===
    p.emit(lui(4, 0x200))           # x4 = 0x200000 (~2M)
    p.label("powerup_delay")
    p.emit(addi(4, 4, -1))
    p.branch_bne(4, 0, "powerup_delay")

    # === Wait for SD card initialization ===
    p.label("wait_sd_init")
    p.emit(lw(4, 1, SD_STATUS))
    p.emit(andi(4, 4, 1))  # bit0 = init_done
    p.branch_beq(4, 0, "wait_sd_init")

    # Show 0x1 on display (SD ready)
    p.emit(addi(4, 0, 1))
    p.emit(sw(4, 1, GPIO_OUT))

    # === Main loop: check BTNC or RX ===
    p.label("main_loop")
    p.emit(lw(4, 1, GPIO_STAT))   # bit0 = BTNC
    p.emit(andi(4, 4, 1))
    p.branch_bne(4, 0, "tx_mode")

    p.emit(lw(4, 2, 0))           # RXBUF STATUS bit0 = data ready
    p.emit(andi(4, 4, 1))
    p.branch_bne(4, 0, "rx_mode")

    p.jump("main_loop")

    # =========================================================
    # TX MODE: Read SD -> Encrypt -> CMAC -> Send via SPI
    # =========================================================
    p.label("tx_mode")

    # Wait for button release
    p.label("tx_wait_release")
    p.emit(lw(4, 1, GPIO_STAT))
    p.emit(andi(4, 4, 1))
    p.branch_bne(4, 0, "tx_wait_release")

    # Show 0x2 (transmitting)
    p.emit(addi(4, 0, 0x12))  # bit4 = LED[1] on, digit = 2
    p.emit(sw(4, 1, GPIO_OUT))

    # Load metadata from BRAM
    load_abs(p, 28, META_ADDR)
    p.emit(lw(24, 28, 4))   # x24 = total_blocks
    p.emit(lw(25, 28, 8))   # temp = total_data_sectors (not used directly, we loop on blocks)
    p.emit(addi(25, 0, 1))  # x25 = current sector = 1 (first data sector)

    # Send unencrypted header: {total_blocks, image_size, 0, 0}
    p.emit(lw(20, 28, 4))   # total_blocks
    p.emit(lw(21, 28, 0))   # image_size
    p.emit(addi(22, 0, 0))
    p.emit(addi(23, 0, 0))
    emit_send_raw(p, 20, 21, 22, 23)
    # Delay
    p.emit(addi(30, 0, 2000))
    p.label("tx_header_delay")
    p.emit(addi(30, 30, -1))
    p.branch_bne(30, 0, "tx_header_delay")

    # Initialize CMAC
    emit_cmac_init(p)

    # === TX sector loop ===
    p.label("tx_sector_loop")
    # SD Read current sector
    p.emit(sw(25, 1, SD_SECTOR))       # set sector address
    p.emit(addi(4, 0, 4))              # clear rd_done
    p.emit(sw(4, 1, SD_CTRL))
    p.emit(addi(4, 0, 1))              # rd_start
    p.emit(sw(4, 1, SD_CTRL))
    p.label("tx_sd_read_wait")
    p.emit(lw(4, 1, SD_STATUS))
    p.emit(andi(4, 4, 8))              # bit3 = rd_done
    p.branch_beq(4, 0, "tx_sd_read_wait")

    # Reset block-within-sector counter
    p.emit(addi(26, 0, 0))             # x26 = 0

    # === TX block loop (inner) ===
    p.label("tx_block_loop")

    # Compute buffer offset: x27 = x26 * 16
    p.emit(slli(27, 26, 4))
    # x28 = buf_base + offset
    p.emit(add(28, 3, 27))

    # Load 4 words from sector_buf
    p.emit(lw(20, 28, 0))
    p.emit(lw(21, 28, 4))
    p.emit(lw(22, 28, 8))
    p.emit(lw(23, 28, 12))

    # AES Encrypt PT -> CT
    emit_load_enc_key(p, 6)
    emit_aes_enc(p, 20, 21, 22, 23)
    emit_aes_read_result(p, 20, 21, 22, 23)  # x20-x23 = ciphertext

    # Check if this is the LAST block
    p.emit(addi(29, 0, 1))
    p.branch_bne(24, 29, "tx_cmac_nonfinal")

    # === CMAC finalize: XOR CT with K1, then update ===
    load_abs(p, 28, CMAC_K1_ADDR)
    p.emit(lw(9, 28, 0));  p.emit(xor_r(10, 20, 9))
    p.emit(lw(9, 28, 4));  p.emit(xor_r(11, 21, 9))
    p.emit(lw(9, 28, 8));  p.emit(xor_r(12, 22, 9))
    p.emit(lw(9, 28, 12)); p.emit(xor_r(13, 23, 9))
    # XOR with CMAC state
    p.emit(xor_r(10, 10, 16))
    p.emit(xor_r(11, 11, 17))
    p.emit(xor_r(12, 12, 18))
    p.emit(xor_r(13, 13, 19))
    emit_load_enc_key(p, 14)
    emit_aes_enc(p, 10, 11, 12, 13)
    emit_aes_read_result(p, 16, 17, 18, 19)
    p.jump("tx_cmac_done")

    p.label("tx_cmac_nonfinal")
    # Standard CMAC update
    emit_cmac_update(p, 20, 21, 22, 23)

    p.label("tx_cmac_done")

    # Send ciphertext via SPI
    emit_send_raw(p, 20, 21, 22, 23)
    # Robust delay between transfers to let RX board catch up
    # RX needs ~500+ cycles for AES decrypt + CMAC update per block
    p.emit(addi(30, 0, 2000))
    p.label("tx_interblock_delay")
    p.emit(addi(30, 30, -1))
    p.branch_bne(30, 0, "tx_interblock_delay")

    # Decrement remaining blocks
    p.emit(addi(24, 24, -1))
    p.branch_beq(24, 0, "tx_data_done")

    # Increment block-within-sector
    p.emit(addi(26, 26, 1))
    p.emit(addi(29, 0, 32))
    p.branch_bne(26, 29, "tx_block_loop")

    # Move to next sector
    p.emit(addi(25, 25, 1))
    p.jump("tx_sector_loop")

    # === TX data done: send CMAC tag ===
    p.label("tx_data_done")
    # Delay before tag
    for _ in range(10): p.emit(nop())

    emit_send_raw(p, 16, 17, 18, 19)  # Send CMAC tag

    # Show 0xA (done, pass)
    p.emit(addi(4, 0, 0x1A))  # bit4=1, digit=A
    p.emit(sw(4, 1, GPIO_OUT))

    p.label("tx_halt")
    p.jump("tx_halt")

    # =========================================================
    # RX MODE: Buffer all data in BRAM, then write to SD at end
    # NEW APPROACH: No SD writes during SPI reception.
    # All decrypted blocks go into BRAM IMAGE_BUF_ADDR first.
    # Only after all blocks received + CMAC verified -> write SD.
    # This eliminates all TX/RX timing races completely.
    # =========================================================
    p.label("rx_mode")

    # Show 3 on display (receiving)
    p.emit(addi(4, 0, 0x13))
    p.emit(sw(4, 1, GPIO_OUT))

    # --- Read header block (already in RXBUF, triggered rx_mode) ---
    p.emit(lw(24, 2, 4))    # x24 = total_blocks
    p.emit(lw(29, 2, 8))    # x29 = image_size (save for SD write phase)
    p.emit(sw(0, 2, 0x14))  # Clear RX status

    # Initialize CMAC
    emit_cmac_init(p)

    # Load decryption key base into x6
    emit_load_dec_key(p, 6)

    # x25 = BRAM write pointer = IMAGE_BUF_ADDR
    load_abs(p, 25, IMAGE_BUF_ADDR)

    # === RX data loop: receive -> decrypt -> store in BRAM ===
    p.label("rx_data_loop")

    # Wait for next SPI block
    p.label("rx_wait_spi")
    p.emit(lw(4, 2, 0))
    p.emit(andi(4, 4, 1))
    p.branch_beq(4, 0, "rx_wait_spi")

    # Read received ciphertext -> x20-x23
    p.emit(lw(20, 2, 4))
    p.emit(lw(21, 2, 8))
    p.emit(lw(22, 2, 12))
    p.emit(lw(23, 2, 16))
    p.emit(sw(0, 2, 0x14))  # Clear RX status immediately

    # --- CMAC update on ciphertext (before decryption) ---
    p.emit(addi(29, 0, 1))
    p.branch_bne(24, 29, "rx_cmac_nonfinal")

    # Last block: CMAC finalize with K1
    load_abs(p, 28, CMAC_K1_ADDR)
    p.emit(lw(9, 28, 0));  p.emit(xor_r(10, 20, 9))
    p.emit(lw(9, 28, 4));  p.emit(xor_r(11, 21, 9))
    p.emit(lw(9, 28, 8));  p.emit(xor_r(12, 22, 9))
    p.emit(lw(9, 28, 12)); p.emit(xor_r(13, 23, 9))
    p.emit(xor_r(10, 10, 16))
    p.emit(xor_r(11, 11, 17))
    p.emit(xor_r(12, 12, 18))
    p.emit(xor_r(13, 13, 19))
    emit_load_enc_key(p, 14)
    emit_aes_enc(p, 10, 11, 12, 13)
    emit_aes_read_result(p, 16, 17, 18, 19)
    p.jump("rx_cmac_update_done")

    p.label("rx_cmac_nonfinal")
    emit_cmac_update(p, 20, 21, 22, 23)

    p.label("rx_cmac_update_done")

    # --- AES Decrypt ciphertext -> plaintext in x20-x23 ---
    for i in range(4):
        p.emit(addi(IDX, 0, i))
        p.emit(aes_dec_load_ct(20+i, IDX))
    emit_load_dec_key(p, 6)
    p.emit(aes_dec_start())
    p.label("rx_dec_poll")
    p.emit(aes_dec_status(4))
    p.branch_beq(4, 0, "rx_dec_poll")
    for i in range(4):
        p.emit(addi(IDX, 0, i))
        p.emit(aes_dec_read(20+i, IDX))

    # --- Store plaintext directly into BRAM at x25 ---
    p.emit(sw(20, 25, 0))
    p.emit(sw(21, 25, 4))
    p.emit(sw(22, 25, 8))
    p.emit(sw(23, 25, 12))
    p.emit(addi(25, 25, 16))   # advance BRAM write pointer

    # Decrement block counter
    p.emit(addi(24, 24, -1))
    p.branch_bne(24, 0, "rx_data_loop")

    # === All blocks received. Now wait for CMAC tag from TX ===
    p.label("rx_wait_tag")
    p.emit(lw(4, 2, 0))
    p.emit(andi(4, 4, 1))
    p.branch_beq(4, 0, "rx_wait_tag")

    # Read received CMAC tag -> x20-x23
    p.emit(lw(20, 2, 4))
    p.emit(lw(21, 2, 8))
    p.emit(lw(22, 2, 12))
    p.emit(lw(23, 2, 16))
    p.emit(sw(0, 2, 0x14))

    # --- Verify CMAC: x20-x23 (received) vs x16-x19 (computed) ---
    p.emit(xor_r(4, 16, 20))
    p.emit(xor_r(9, 17, 21))
    p.emit(or_r(4, 4, 9))
    p.emit(xor_r(9, 18, 22))
    p.emit(or_r(4, 4, 9))
    p.emit(xor_r(9, 19, 23))
    p.emit(or_r(4, 4, 9))

    p.branch_bne(4, 0, "rx_cmac_fail")

    # =========================================================
    # CMAC PASSED: Now write image from BRAM to SD card
    # =========================================================
    # Show 5 on display (writing to SD)
    p.emit(addi(4, 0, 0x15))
    p.emit(sw(4, 1, GPIO_OUT))

    # Write metadata to SD sector 0:
    # Reload image_size and total_blocks from BRAM META_ADDR
    load_abs(p, 28, META_ADDR)
    p.emit(lw(29, 28, 0))   # x29 = image_size
    p.emit(lw(24, 28, 4))   # x24 = total_blocks
    p.emit(lw(26, 28, 8))   # x26 = total_data_sectors

    p.emit(sw(29, 3, 0))    # sector_buf[0] = image_size
    p.emit(sw(24, 3, 4))    # sector_buf[4] = total_blocks
    p.emit(sw(0, 3, 8))
    p.emit(sw(0, 3, 12))
    p.emit(sw(0, 1, SD_SECTOR))
    p.emit(addi(4, 0, 8))
    p.emit(sw(4, 1, SD_CTRL))
    p.emit(addi(4, 0, 2))
    p.emit(sw(4, 1, SD_CTRL))
    p.label("rx_meta_wr_wait")
    p.emit(lw(4, 1, SD_STATUS))
    p.emit(andi(4, 4, 16))
    p.branch_beq(4, 0, "rx_meta_wr_wait")

    # === Write image sectors from BRAM to SD ===
    # x25 = BRAM read pointer (start = IMAGE_BUF_ADDR)
    # x26 = remaining sectors
    # x27 = current SD sector number (start = 1)
    load_abs(p, 25, IMAGE_BUF_ADDR)
    p.emit(addi(27, 0, 1))

    p.label("rx_sd_write_loop")

    # Copy 512 bytes (128 words) from BRAM into SD sector_buf via MMIO
    # x28 = MMIO sector_buf write pointer (= x3 = SD_BASE + BUF_OFFSET)
    p.emit(add(28, 3, 0))   # x28 = x3 (sector_buf base)
    p.emit(addi(31, 0, 128)) # x31 = word count
    p.emit(addi(30, 0, 0))   # x30 = word index
    p.label("rx_copy_loop")
    p.emit(lw(4, 25, 0))     # read word from BRAM
    p.emit(sw(4, 28, 0))     # write word to MMIO sector_buf
    p.emit(addi(25, 25, 4))  # advance BRAM ptr
    p.emit(addi(28, 28, 4))  # advance MMIO ptr
    p.emit(addi(30, 30, 1))  # word_index++
    p.branch_bne(30, 31, "rx_copy_loop")

    # Write sector to SD
    p.emit(sw(27, 1, SD_SECTOR))
    p.emit(addi(4, 0, 8))
    p.emit(sw(4, 1, SD_CTRL))
    p.emit(addi(4, 0, 2))
    p.emit(sw(4, 1, SD_CTRL))
    p.label("rx_wr_wait")
    p.emit(lw(4, 1, SD_STATUS))
    p.emit(andi(4, 4, 16))
    p.branch_beq(4, 0, "rx_wr_wait")

    # Next sector
    p.emit(addi(27, 27, 1))
    p.emit(addi(26, 26, -1))
    p.branch_bne(26, 0, "rx_sd_write_loop")

    # === Done! Show 9 (pass) ===
    p.emit(addi(4, 0, 0x19))  # digit=9, LED[1] on
    p.emit(sw(4, 1, GPIO_OUT))
    p.label("rx_done")
    p.jump("rx_done")

    p.label("rx_cmac_fail")
    # CMAC FAIL - show E on display
    p.emit(addi(4, 0, 0x2E))  # digit=E, LED[2] on
    p.emit(sw(4, 1, GPIO_OUT))
    p.label("rx_fail_halt")
    p.jump("rx_fail_halt")

    return p.resolve()

# ====================== CMAC K1 Pre-computation ======================

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
    t=col[0]^col[1]^col[2]^col[3]; u=col[0]
    col[0]^=t^_xtime(col[0]^col[1]); col[1]^=t^_xtime(col[1]^col[2])
    col[2]^=t^_xtime(col[2]^col[3]); col[3]^=t^_xtime(col[3]^u)

def aes128_encrypt_block(block, key):
    s=list(block)
    w=[list(key[i:i+4]) for i in range(0,16,4)]
    for i in range(4,44):
        t=w[i-1][:]
        if i%4==0: t=[AES_SBOX[b] for b in t[1:]+t[:1]]; t[0]^=AES_RCON[(i//4)-1]
        w.append([w[i-4][j]^t[j] for j in range(4)])
    rks=[]
    for r in range(11):
        rk=[]
        for ww in w[r*4:(r+1)*4]: rk.extend(ww)
        rks.append(rk)
    for i in range(16): s[i]^=rks[0][i]
    for rnd in range(1,10):
        s=[AES_SBOX[b] for b in s]
        rows=[[s[j*4+i] for j in range(4)] for i in range(4)]
        for i in range(1,4): rows[i]=rows[i][i:]+rows[i][:i]
        s=[rows[i][j] for j in range(4) for i in range(4)]
        for c in range(4):
            col=[s[c*4+i] for i in range(4)]; _mix_col(col)
            for i in range(4): s[c*4+i]=col[i]
        for i in range(16): s[i]^=rks[rnd][i]
    s=[AES_SBOX[b] for b in s]
    rows=[[s[j*4+i] for j in range(4)] for i in range(4)]
    for i in range(1,4): rows[i]=rows[i][i:]+rows[i][:i]
    s=[rows[i][j] for j in range(4) for i in range(4)]
    for i in range(16): s[i]^=rks[10][i]
    return bytes(s)

def cmac_subkey_k1(key_bytes):
    L = aes128_encrypt_block(bytes(16), key_bytes)
    val = int.from_bytes(L, "big")
    msb = (val >> 127) & 1
    val = ((val << 1) & ((1 << 128) - 1))
    if msb: val ^= 0x87
    return val.to_bytes(16, "big")

# ====================== Keys ======================
ENC_KEY = 0x1234567890ABCDEF1122334455667788
MAC_KEY = 0xA659590B72D24F3891C8E7A1115FB32C

def int128_to_le_words(val):
    return [(val >> (32*i)) & 0xFFFFFFFF for i in range(4)]

def int128_to_bytes_le(val):
    return val.to_bytes(16, "little")

# ====================== Main ======================

def main():
    # Read image file
    img_path = os.path.join(os.path.dirname(__file__), "..", "recovered_image.bmp")
    img_path = os.path.abspath(img_path)
    if not os.path.exists(img_path):
        img_path = "C:/AllData/FYPnew/cmacaddedFYP/picorv32-aes-co-processor/recovered_image.bmp"
    with open(img_path, "rb") as f:
        image_data = f.read()

    image_size = len(image_data)
    total_blocks = math.ceil(image_size / 16)
    padded_size = total_blocks * 16
    total_data_sectors = math.ceil(padded_size / 512)

    print(f"Image: {img_path}")
    print(f"  Size: {image_size} bytes")
    print(f"  AES blocks: {total_blocks}")
    print(f"  SD sectors: {total_data_sectors}")

    MEM_SIZE = 4096
    memory = [nop()] * MEM_SIZE

    # Generate firmware
    firmware = generate_firmware()
    print(f"  Firmware: {len(firmware)} instructions")
    if len(firmware) > 0x400:
        raise ValueError(f"Firmware too large: {len(firmware)} > 1024 words")
    for i, w in enumerate(firmware):
        memory[i] = w

    # Store encryption key at 0x1000 (word 0x400)
    for i, w in enumerate(int128_to_le_words(ENC_KEY)):
        memory[0x400 + i] = w

    # Store MAC key at 0x1010 (word 0x404)
    for i, w in enumerate(int128_to_le_words(MAC_KEY)):
        memory[0x404 + i] = w

    # Pre-compute CMAC K1 and store at 0x1020 (word 0x408)
    mac_key_bytes = int128_to_bytes_le(MAC_KEY)
    k1_bytes = cmac_subkey_k1(mac_key_bytes)
    for i in range(4):
        memory[0x408 + i] = struct.unpack_from("<I", k1_bytes, i*4)[0]

    # CMAC header at 0x1030 (word 0x40C)
    header = b"AES-CMAC-IMG\x00\x00\x00\x00"
    for i in range(4):
        memory[0x40C + i] = struct.unpack_from("<I", header, i*4)[0]

    # Metadata at 0x1040 (word 0x410): {image_size, total_blocks, total_data_sectors, 0}
    memory[0x410] = image_size
    memory[0x411] = total_blocks
    memory[0x412] = total_data_sectors
    memory[0x413] = 0

    # Write hex file
    out_dir = os.path.dirname(os.path.abspath(__file__))
    output_file = os.path.join(out_dir, "program_sd2sd.hex")
    with open(output_file, 'w') as f:
        for word in memory:
            f.write(f"{word:08x}\n")

    print(f"  Output: {output_file}")
    print(f"  MODE: SD-to-SD Image Transfer with AES + CMAC")
    print()
    print("Next steps:")
    print("  1. Run prepare_tx_sd.py to write image to TX SD card")
    print("  2. Synthesize with aes_soc_top_sd2sd_spi.v as top module")
    print("  3. Flash both boards, press BTNC on TX board")
    print("  4. Run read_rx_sd.py to recover image from RX SD card")

if __name__ == "__main__":
    main()
