#!/usr/bin/env python3
"""
Convert an image to hex format for AES SoC image transfer testbench.

Usage:
    python3 image_to_hex.py                          # Generate 64x64 test pattern
    python3 image_to_hex.py --width 32 --height 32   # Custom size test pattern
    python3 image_to_hex.py photo.pgm                # Use existing PGM image

Outputs:
    image_data.hex       - 32-bit words in hex (for Verilog $readmemh)
    original_image.pgm   - Original image as PGM (for visual reference)
    image_meta.txt       - Metadata: num_blocks, width, height

Prints NUM_BLOCKS to stdout (for shell scripting / iverilog -D flag).
"""

import sys
import struct
import math


def generate_test_pattern(width, height):
    """Generate a recognizable grayscale test pattern.

    Pattern includes:
    - Checkerboard background (8x8 pixel squares)
    - White border
    - Diagonal cross
    - Center circle
    - Gradient band at bottom
    """
    pixels = bytearray(width * height)

    cx, cy = width // 2, height // 2
    radius = min(width, height) // 4

    for y in range(height):
        for x in range(width):
            # Checkerboard background
            check = ((x // 8) + (y // 8)) % 2
            val = 200 if check else 55

            # Gradient band in bottom 1/8
            if y >= height - height // 8:
                val = int(255 * x / (width - 1))

            # Diagonal cross (2 pixels wide)
            if abs(x - y) <= 1 or abs(x - (width - 1 - y)) <= 1:
                val = 128

            # Center circle (ring, 2 pixels thick)
            dx = x - cx
            dy = y - cy
            dist = math.sqrt(dx * dx + dy * dy)
            if abs(dist - radius) < 2.0:
                val = 0

            # White border
            if x == 0 or y == 0 or x == width - 1 or y == height - 1:
                val = 255

            pixels[y * width + x] = val

    return bytes(pixels)


def read_pgm(filename):
    """Read a PGM (P5 binary) image file. Returns (width, height, bytes)."""
    with open(filename, 'rb') as f:
        # Read magic number
        magic = f.readline().strip()
        if magic not in (b'P5', b'P2'):
            raise ValueError(f"Not a PGM file (magic: {magic})")

        # Skip comments
        line = f.readline()
        while line.startswith(b'#'):
            line = f.readline()

        # Read dimensions
        parts = line.split()
        w, h = int(parts[0]), int(parts[1])

        # Read max value
        maxval = int(f.readline().strip())
        if maxval != 255:
            raise ValueError(f"Unsupported max value: {maxval}")

        if magic == b'P5':
            # Binary format
            data = f.read(w * h)
        else:
            # ASCII format
            data = bytearray()
            for val in f.read().split():
                data.append(int(val))
            data = bytes(data)

    return w, h, data


def main():
    width = 64
    height = 64
    image_file = None

    # Parse arguments
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == '--width' and i + 1 < len(args):
            width = int(args[i + 1])
            i += 2
        elif args[i] == '--height' and i + 1 < len(args):
            height = int(args[i + 1])
            i += 2
        elif args[i] in ('-h', '--help'):
            print(__doc__)
            sys.exit(0)
        elif not args[i].startswith('-'):
            image_file = args[i]
            i += 1
        else:
            print(f"Unknown argument: {args[i]}", file=sys.stderr)
            i += 1

    # Get image data
    if image_file:
        try:
            width, height, raw_bytes = read_pgm(image_file)
            print(f"Loaded PGM image: {image_file} ({width}x{height})", file=sys.stderr)
        except Exception as e:
            print(f"Error loading image: {e}", file=sys.stderr)
            print("Generating test pattern instead...", file=sys.stderr)
            raw_bytes = generate_test_pattern(width, height)
    else:
        raw_bytes = generate_test_pattern(width, height)
        print(f"Generated test pattern: {width}x{height} grayscale", file=sys.stderr)

    total_pixels = width * height
    print(f"Image size: {total_pixels} bytes ({total_pixels / 1024:.1f} KB)", file=sys.stderr)

    # Pad to 16-byte boundary (AES block size)
    pad_len = (16 - len(raw_bytes) % 16) % 16
    if pad_len:
        raw_bytes += b'\x00' * pad_len
        print(f"Padded {pad_len} bytes to align to 16-byte AES blocks", file=sys.stderr)

    num_blocks = len(raw_bytes) // 16
    total_words = len(raw_bytes) // 4

    # Write hex file (32-bit little-endian words, one per line)
    with open('image_data.hex', 'w') as f:
        for j in range(0, len(raw_bytes), 4):
            word = struct.unpack('<I', raw_bytes[j:j + 4])[0]
            f.write(f'{word:08x}\n')

    # Write original image as PGM for reference
    with open('original_image.pgm', 'wb') as f:
        f.write(f'P5\n{width} {height}\n255\n'.encode())
        f.write(raw_bytes[:total_pixels])  # exclude padding

    # Write metadata
    with open('image_meta.txt', 'w') as f:
        f.write(f'{num_blocks}\n')
        f.write(f'{width}\n')
        f.write(f'{height}\n')

    print(f"Output: {num_blocks} blocks ({num_blocks * 16} bytes, {total_words} words)", file=sys.stderr)
    print(f"Files: image_data.hex, original_image.pgm, image_meta.txt", file=sys.stderr)

    # Print ONLY num_blocks to stdout (for shell scripting)
    print(num_blocks)


if __name__ == '__main__':
    main()
