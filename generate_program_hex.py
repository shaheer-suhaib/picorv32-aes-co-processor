#!/usr/bin/env python3
"""
Generate hex file for BRAM initialization with AES test program
Output format: Verilog $readmemh compatible (one 32-bit hex value per line)
"""

def encode_i_type(opcode, funct3, rd, rs1, imm):
    """Encode I-type instruction"""
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def encode_r_type(opcode, funct3, funct7, rd, rs1, rs2):
    """Encode R-type instruction"""
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def encode_s_type(opcode, funct3, rs1, rs2, imm):
    """Encode S-type instruction (STORE)"""
    imm_11_5 = (imm >> 5) & 0x7F
    imm_4_0 = imm & 0x1F
    return (imm_11_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (imm_4_0 << 7) | opcode

def encode_b_type(opcode, funct3, rs1, rs2, imm):
    """Encode B-type instruction (BRANCH)"""
    imm_12 = (imm >> 12) & 0x1
    imm_10_5 = (imm >> 5) & 0x3F
    imm_4_1 = (imm >> 1) & 0xF
    imm_11 = (imm >> 11) & 0x1
    return (imm_12 << 31) | (imm_10_5 << 25) | (rs2 << 20) | (rs1 << 15) | \
           (funct3 << 12) | (imm_4_1 << 8) | (imm_11 << 7) | opcode

# Instruction encoders
def addi(rd, rs1, imm):
    return encode_i_type(0b0010011, 0b000, rd, rs1, imm)

def lw(rd, rs1, offset):
    return encode_i_type(0b0000011, 0b010, rd, rs1, offset)

def sw(rs2, rs1, offset):
    return encode_s_type(0b0100011, 0b010, rs1, rs2, offset)

def beqz(rs1, offset):
    """Branch if equal to zero (beq rs1, x0, offset)"""
    return encode_b_type(0b1100011, 0b000, rs1, 0, offset)

# AES custom instructions (opcode 0x0B = 0b0001011)
def aes_load_pt(rs2, rs1):
    """AES_LOAD_PT: Load plaintext word"""
    return encode_r_type(0b0001011, 0b000, 0b0100000, 0, rs1, rs2)

def aes_load_key(rs2, rs1):
    """AES_LOAD_KEY: Load key word"""
    return encode_r_type(0b0001011, 0b000, 0b0100001, 0, rs1, rs2)

def aes_start():
    """AES_START: Start encryption"""
    return encode_r_type(0b0001011, 0b000, 0b0100010, 0, 0, 0)

def aes_read(rd, rs1):
    """AES_READ: Read ciphertext word"""
    return encode_r_type(0b0001011, 0b000, 0b0100011, rd, rs1, 0)

def aes_status(rd):
    """AES_STATUS: Check completion"""
    return encode_r_type(0b0001011, 0b000, 0b0100100, rd, 0, 0)

def nop():
    return addi(0, 0, 0)

# FIPS-197 Test Vector
PLAINTEXT  = 0x00112233445566778899AABBCCDDEEFF
KEY        = 0x000102030405060708090A0B0C0D0E0F

# Memory addresses
PT_ADDR     = 0x100  # Plaintext data location (word 64-67)
KEY_ADDR    = 0x200  # Key data location (word 128-131)
RESULT_ADDR = 0x300  # Result storage (word 192-195)

def generate_program():
    """Generate the complete test program"""
    program = []

    # === Initialize registers ===
    program.append(addi(1, 0, 1))           # x1 = 1
    program.append(addi(2, 0, 2))           # x2 = 2
    program.append(addi(3, 0, 3))           # x3 = 3
    program.append(addi(6, 0, 0x100))       # x6 = PT_ADDR
    program.append(addi(4, 0, 0x200))       # x4 = KEY_ADDR
    program.append(addi(12, 0, 0x300))      # x12 = RESULT_ADDR

    # === Load Plaintext into AES ===
    for i in range(4):
        program.append(lw(5, 6, i*4))       # lw x5, offset(x6)
        program.append(aes_load_pt(5, i))   # AES_LOAD_PT idx=i

    # === Load Key into AES ===
    for i in range(4):
        program.append(lw(5, 4, i*4))       # lw x5, offset(x4)
        program.append(aes_load_key(5, i))  # AES_LOAD_KEY idx=i

    # === Start encryption ===
    program.append(aes_start())

    # === Poll for completion ===
    poll_loop_start = len(program)
    program.append(aes_status(7))           # AES_STATUS x7
    program.append(beqz(7, -4))             # beqz x7, poll_loop (branch back 2 instr = -8 bytes = -4 words)

    # === Read ciphertext and store to memory ===
    for i in range(4):
        program.append(aes_read(8+i, i))    # AES_READ x(8+i), idx=i
        program.append(sw(8+i, 12, i*4))    # sw x(8+i), offset(x12)

    # === End program (infinite loop) ===
    end_loop = len(program)
    program.append(beqz(0, 0))              # beqz x0, 0 (infinite loop)

    return program

def generate_data():
    """Generate data section (plaintext and key)"""
    data = {}

    # Plaintext at address 0x100 (word 64-67)
    pt_words = [
        (PLAINTEXT >>  0) & 0xFFFFFFFF,
        (PLAINTEXT >> 32) & 0xFFFFFFFF,
        (PLAINTEXT >> 64) & 0xFFFFFFFF,
        (PLAINTEXT >> 96) & 0xFFFFFFFF,
    ]
    for i, word in enumerate(pt_words):
        data[0x40 + i] = word  # 0x100 >> 2 = 0x40

    # Key at address 0x200 (word 128-131)
    key_words = [
        (KEY >>  0) & 0xFFFFFFFF,
        (KEY >> 32) & 0xFFFFFFFF,
        (KEY >> 64) & 0xFFFFFFFF,
        (KEY >> 96) & 0xFFFFFFFF,
    ]
    for i, word in enumerate(key_words):
        data[0x80 + i] = word  # 0x200 >> 2 = 0x80

    return data

def main():
    """Generate complete memory initialization file"""
    MEM_SIZE = 2048  # 2K words = 8KB

    # Initialize all memory with NOPs
    memory = [nop()] * MEM_SIZE

    # Place program at address 0
    program = generate_program()
    for i, instr in enumerate(program):
        memory[i] = instr

    # Place data
    data = generate_data()
    for addr, value in data.items():
        memory[addr] = value

    # Write to hex file
    output_file = "program.hex"
    with open(output_file, 'w') as f:
        for word in memory:
            f.write(f"{word:08x}\n")

    print(f"Generated {output_file}")
    print(f"   Memory size: {MEM_SIZE} words ({MEM_SIZE*4} bytes)")
    print(f"   Program size: {len(program)} instructions")
    print(f"   Test Vector:")
    print(f"     Plaintext:  0x{PLAINTEXT:032x}")
    print(f"     Key:        0x{KEY:032x}")
    print(f"     Expected:   0x69c4e0d86a7b0430d8cdb78070b4c55a")

if __name__ == "__main__":
    main()
