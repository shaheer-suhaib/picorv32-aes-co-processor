#!/usr/bin/env python3
"""
Generate hex file for BRAM initialization with Simple AES Tx/Rx program
Output format: Verilog $readmemh compatible (one 32-bit hex value per line)

Register allocation:
  x1  = GPIO_BASE   (0x20000000)
  x2  = RXBUF_BASE  (0x30000000)
  x3  = KEY_BASE    (0x00001000)
  x4  = temp / status polling
  x5  = temp / data word
  x6  = temp / key word
  x7  = AES word index (0-3), set with addi before each AES custom instruction
"""

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

# Instruction encoders
def lui(rd, imm):
    return ((imm & 0xFFFFF) << 12) | (rd << 7) | 0b0110111

def addi(rd, rs1, imm):
    return encode_i_type(0b0010011, 0b000, rd, rs1, imm)

def lw(rd, rs1, offset):
    return encode_i_type(0b0000011, 0b010, rd, rs1, offset)

def sw(rs2, rs1, offset):
    return encode_s_type(0b0100011, 0b010, rs1, rs2, offset)

def beqz(rs1, offset):
    return encode_b_type(0b1100011, 0b000, rs1, 0, offset)

def bnez(rs1, offset):
    return encode_b_type(0b1100011, 0b001, rs1, 0, offset)

def j(offset): # jal x0, offset
    imm_20 = (offset >> 20) & 0x1
    imm_10_1 = (offset >> 1) & 0x3FF
    imm_11 = (offset >> 11) & 0x1
    imm_19_12 = (offset >> 12) & 0xFF
    return ((imm_20 << 31) | (imm_19_12 << 12) | (imm_11 << 20) | (imm_10_1 << 21) | (0 << 7) | 0b1101111) & 0xFFFFFFFF

# AES custom instructions (opcode 0x0B = 0b0001011)
# rs1 VALUE[1:0] = word index, rs2 VALUE = data word
def aes_load_pt(rs2, rs1):
    return encode_r_type(0b0001011, 0b000, 0b0100000, 0, rs1, rs2)

def aes_load_key(rs2, rs1):
    return encode_r_type(0b0001011, 0b000, 0b0100001, 0, rs1, rs2)

def aes_start():
    return encode_r_type(0b0001011, 0b000, 0b0100010, 0, 0, 0)

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

def load_const(rd, val):
    """Macro to load 32-bit constant into register using lui and addi"""
    upper = (val >> 12) & 0xFFFFF
    lower = val & 0xFFF
    if (lower & 0x800): # Sign extension compensation
        upper = (upper + 1) & 0xFFFFF
    return [lui(rd, upper), addi(rd, rd, lower | (0xFFFFF000 if lower & 0x800 else 0))]

# x7 is the dedicated index register for AES word indices
IDX_REG = 7

def generate_program():
    program = []
    
    # === Setup base address registers ===
    program.extend(load_const(1, 0x20000000))  # x1 = GPIO_BASE
    program.extend(load_const(2, 0x30000000))  # x2 = RXBUF_BASE
    program.extend(load_const(3, 0x00001000))  # x3 = KEY_BASE (in BRAM)
    
    # -----------------------
    # Main Loop (Label: loop)
    # -----------------------
    loop_label = len(program)
    
    # Check BTNC: read GPIO_BASE + 0x04
    program.append(lw(4, 1, 4))
    branch_to_tx_idx = len(program)
    program.append(nop()) # placeholder for bnez -> tx_mode
    
    # Check RX_STATUS: read RXBUF_BASE + 0x00
    program.append(lw(4, 2, 0))
    branch_to_rx_idx = len(program)
    program.append(nop()) # placeholder for bnez -> rx_mode
    
    # j loop
    program.append(j((loop_label - len(program)) * 4))
    
    # ===========================
    # TX_MODE: Encrypt & Transmit
    # ===========================
    tx_mode_label = len(program)
    program[branch_to_tx_idx] = bnez(4, (tx_mode_label - branch_to_tx_idx) * 4)
    
    # Wait for button release so we don't re-trigger
    wait_btn_label = len(program)
    program.append(lw(4, 1, 4))
    program.append(bnez(4, (wait_btn_label - len(program)) * 4))
    
    # Read SW[15:0] from GPIO_BASE + 0x00
    program.append(lw(5, 1, 0))  # x5 = switch value
    
    # Load PT[0] = switch value, PT[1..3] = 0
    # Using x7 as index register, x0 as zero source
    program.append(addi(IDX_REG, 0, 0))      # x7 = 0
    program.append(aes_load_pt(5, IDX_REG))   # PT[0] = x5(switches)
    program.append(addi(IDX_REG, 0, 1))      # x7 = 1
    program.append(aes_load_pt(0, IDX_REG))   # PT[1] = 0
    program.append(addi(IDX_REG, 0, 2))      # x7 = 2
    program.append(aes_load_pt(0, IDX_REG))   # PT[2] = 0
    program.append(addi(IDX_REG, 0, 3))      # x7 = 3
    program.append(aes_load_pt(0, IDX_REG))   # PT[3] = 0
    
    # Load KEY[0..3] from BRAM
    for i in range(4):
        program.append(lw(6, 3, i*4))            # x6 = key word from memory
        program.append(addi(IDX_REG, 0, i))       # x7 = i
        program.append(aes_load_key(6, IDX_REG))  # KEY[i] = x6
    
    # Start AES encryption (triggers SPI automatically on completion)
    program.append(aes_start())
    
    # Poll for encryption completion
    tx_poll_label = len(program)
    program.append(aes_status(4))
    program.append(beqz(4, (tx_poll_label - len(program)) * 4))
    
    # Show switch value on LEDs to confirm TX
    program.append(sw(5, 1, 8))
    
    # Jump back to main loop
    program.append(j((loop_label - len(program)) * 4))
    
    # ===========================
    # RX_MODE: Receive & Decrypt
    # ===========================
    rx_mode_label = len(program)
    program[branch_to_rx_idx] = bnez(4, (rx_mode_label - branch_to_rx_idx) * 4)
    
    # Load received ciphertext CT[0..3] from RX buffer
    for i in range(4):
        program.append(lw(5, 2, 4 + i*4))            # x5 = RX_DATA_i
        program.append(addi(IDX_REG, 0, i))           # x7 = i
        program.append(aes_dec_load_ct(5, IDX_REG))   # CT[i] = x5
    
    # Load KEY[0..3] from BRAM (same key as TX side)
    for i in range(4):
        program.append(lw(6, 3, i*4))                 # x6 = key word
        program.append(addi(IDX_REG, 0, i))            # x7 = i
        program.append(aes_dec_load_key(6, IDX_REG))   # KEY[i] = x6
    
    # Start AES decryption
    program.append(aes_dec_start())
    
    # Poll for decryption completion
    rx_poll_label = len(program)
    program.append(aes_dec_status(4))
    program.append(beqz(4, (rx_poll_label - len(program)) * 4))
    
    # Read decrypted word 0 (contains the original switch value)
    program.append(addi(IDX_REG, 0, 0))           # x7 = 0
    program.append(aes_dec_read(5, IDX_REG))       # x5 = decrypted PT[0]
    
    # Show on LEDs
    program.append(sw(5, 1, 8))     # LED[15:0] = decrypted value
    
    # Show lower 4 bits on 7-segment
    program.append(sw(5, 1, 0x0C))  # SEG digit = decrypted[3:0]
    
    # Clear RX status so we can receive again
    program.append(sw(0, 2, 0x14))
    
    # Jump back to main loop
    program.append(j((loop_label - len(program)) * 4))

    return program

def main():
    MEM_SIZE = 4096
    memory = [nop()] * MEM_SIZE

    program = generate_program()
    for i, instr in enumerate(program):
        memory[i] = instr

    # 128-bit AES key stored at 0x1000 (word offset 0x400)
    KEY = 0x1234567890ABCDEF1122334455667788
    key_words = [
        (KEY >>  0) & 0xFFFFFFFF,
        (KEY >> 32) & 0xFFFFFFFF,
        (KEY >> 64) & 0xFFFFFFFF,
        (KEY >> 96) & 0xFFFFFFFF,
    ]
    for i, word in enumerate(key_words):
        memory[0x400 + i] = word

    output_file = "c:/AllData/FYPnew/cmacaddedFYP/picorv32-aes-co-processor/fpga/program_simple.hex"
    with open(output_file, 'w') as f:
        for word in memory:
            f.write(f"{word:08x}\n")

    print(f"Generated {output_file}")
    print(f"  Program size: {len(program)} instructions")
    print(f"  Key: 0x{KEY:032x}")

if __name__ == "__main__":
    main()
