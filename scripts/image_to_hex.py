#!/usr/bin/env python3
"""
Convert an image to hex format for Verilog $readmemh
Each line is 128 bits (16 bytes) - one AES block

Usage: python3 image_to_hex.py input_image output.hex
"""

import sys
from pathlib import Path

def image_to_hex(input_path, output_path):
    # Read raw bytes from any file (image, binary, etc.)
    with open(input_path, 'rb') as f:
        data = f.read()

    original_size = len(data)
    print(f"Input file: {input_path}")
    print(f"Original size: {original_size} bytes")

    # Pad to multiple of 16 bytes (128-bit AES block)
    padding_needed = (16 - (len(data) % 16)) % 16
    if padding_needed > 0:
        # PKCS7-style padding
        data += bytes([padding_needed] * padding_needed)

    padded_size = len(data)
    num_blocks = padded_size // 16
    print(f"Padded size: {padded_size} bytes ({num_blocks} AES blocks)")

    # Write hex file
    with open(output_path, 'w') as f:
        # First line: metadata (original size for later reconstruction)
        # Format: 8 hex digits for size + 8 zeros padding = 16 bytes
        f.write(f"{original_size:08x}{'0' * 24}\n")

        # Write each 16-byte block as 32 hex characters
        for i in range(0, len(data), 16):
            block = data[i:i+16]
            hex_str = block.hex()
            f.write(hex_str + '\n')

    print(f"Output file: {output_path}")
    print(f"Total lines: {num_blocks + 1} (1 metadata + {num_blocks} data blocks)")

    return num_blocks

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input_file> <output.hex>")
        print(f"Example: {sys.argv[0]} photo.png image_data.hex")
        sys.exit(1)

    image_to_hex(sys.argv[1], sys.argv[2])
