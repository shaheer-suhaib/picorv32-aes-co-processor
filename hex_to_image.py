#!/usr/bin/env python3
"""
Reconstruct an image from the simulation's decrypted hex output.

Usage:
    python3 hex_to_image.py

Reads:
    decrypted_output.hex  - 32-bit words from Verilog simulation
    image_meta.txt        - Image dimensions (from image_to_hex.py)

Outputs:
    decrypted_image.pgm   - Reconstructed grayscale image

Also compares with original_image.pgm byte-by-byte.
"""

import struct
import sys


def main():
    # Read metadata
    try:
        with open('image_meta.txt') as f:
            num_blocks = int(f.readline().strip())
            width = int(f.readline().strip())
            height = int(f.readline().strip())
    except FileNotFoundError:
        print("ERROR: image_meta.txt not found. Run image_to_hex.py first.")
        sys.exit(1)

    # Read decrypted hex words
    try:
        raw_bytes = bytearray()
        with open('decrypted_output.hex') as f:
            for line in f:
                line = line.strip()
                if line:
                    word = int(line, 16)
                    raw_bytes += struct.pack('<I', word)
    except FileNotFoundError:
        print("ERROR: decrypted_output.hex not found. Run the simulation first.")
        sys.exit(1)

    total_pixels = width * height
    print(f"Image dimensions: {width}x{height} ({total_pixels} pixels)")
    print(f"Decrypted data: {len(raw_bytes)} bytes ({len(raw_bytes) // 16} blocks)")

    # Truncate to original image size (remove padding)
    image_bytes = raw_bytes[:total_pixels]

    if len(image_bytes) < total_pixels:
        print(f"WARNING: Only {len(image_bytes)} bytes, expected {total_pixels}")

    # Write as PGM
    with open('decrypted_image.pgm', 'wb') as f:
        f.write(f'P5\n{width} {height}\n255\n'.encode())
        f.write(image_bytes)

    print(f"Written: decrypted_image.pgm")

    # Compare with original
    try:
        with open('original_image.pgm', 'rb') as f:
            original = f.read()

        with open('decrypted_image.pgm', 'rb') as f:
            decrypted = f.read()

        if original == decrypted:
            print(f"\nSUCCESS: Decrypted image matches original perfectly!")
            print(f"  {width}x{height} grayscale, {num_blocks} AES blocks")
            print(f"  encrypted -> SPI transferred -> decrypted")
        else:
            # Find first mismatch
            mismatches = 0
            first_mismatch = -1
            for i in range(min(len(original), len(decrypted))):
                if original[i] != decrypted[i]:
                    if first_mismatch == -1:
                        first_mismatch = i
                    mismatches += 1
            print(f"\nFAILED: {mismatches} byte mismatches")
            print(f"  First mismatch at byte offset {first_mismatch}")
            print(f"  Compare visually: original_image.pgm vs decrypted_image.pgm")
    except FileNotFoundError:
        print("\noriginal_image.pgm not found, skipping comparison")


if __name__ == '__main__':
    main()
