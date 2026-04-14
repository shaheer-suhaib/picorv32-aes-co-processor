#!/usr/bin/env python3
"""
Convert hex file back to original image/binary format
Reverses the output of image_to_hex.py

Usage: python3 hex_to_image.py input.hex output_image
"""

import sys
from pathlib import Path

def hex_to_image(input_path, output_path):
    with open(input_path, 'r') as f:
        # Skip comment lines (// ...) that Verilog $writememh adds
        lines = [line.strip() for line in f if line.strip() and not line.strip().startswith('//')]

    if not lines:
        print("Error: Empty hex file")
        sys.exit(1)

    # First line contains metadata (original size)
    metadata = lines[0]
    original_size = int(metadata[:8], 16)
    print(f"Original size from metadata: {original_size} bytes")

    # Remaining lines are data blocks
    data_blocks = lines[1:]
    print(f"Data blocks: {len(data_blocks)}")

    # Convert hex strings to bytes
    all_bytes = bytearray()
    for i, hex_line in enumerate(data_blocks):
        if len(hex_line) != 32:
            print(f"Warning: Block {i} has {len(hex_line)} hex chars (expected 32)")
        block_bytes = bytes.fromhex(hex_line)
        all_bytes.extend(block_bytes)

    print(f"Total bytes read: {len(all_bytes)}")

    # Trim to original size (remove padding)
    output_bytes = bytes(all_bytes[:original_size])

    # Write output file
    with open(output_path, 'wb') as f:
        f.write(output_bytes)

    print(f"Output file: {output_path} ({len(output_bytes)} bytes)")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input.hex> <output_file>")
        print(f"Example: {sys.argv[0]} decrypted.hex recovered_photo.png")
        sys.exit(1)

    hex_to_image(sys.argv[1], sys.argv[2])
