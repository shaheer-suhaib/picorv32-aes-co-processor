#!/usr/bin/env python3
"""
Create a simple test image (gradient pattern) for AES encryption testing.
This creates a small BMP image that's easy to verify visually.

Usage: python3 create_test_image.py [size]
  size: 16, 32, 64, or 128 (pixels, default 64)
"""

import sys
import struct

def create_bmp(width, height, filename):
    """Create a simple 24-bit BMP with a gradient pattern"""

    # BMP files have rows padded to 4-byte boundaries
    row_padding = (4 - (width * 3) % 4) % 4
    row_size = width * 3 + row_padding
    pixel_data_size = row_size * height

    # File header (14 bytes)
    file_size = 54 + pixel_data_size
    file_header = struct.pack('<2sIHHI',
        b'BM',           # Signature
        file_size,       # File size
        0,               # Reserved
        0,               # Reserved
        54               # Pixel data offset
    )

    # DIB header (40 bytes - BITMAPINFOHEADER)
    dib_header = struct.pack('<IIIHHIIIIII',
        40,              # Header size
        width,           # Width
        height,          # Height
        1,               # Color planes
        24,              # Bits per pixel
        0,               # Compression (none)
        pixel_data_size, # Image size
        2835,            # X pixels per meter
        2835,            # Y pixels per meter
        0,               # Colors in color table
        0                # Important colors
    )

    # Generate pixel data (gradient pattern)
    # BMP stores rows bottom-to-top, BGR order
    pixel_data = bytearray()
    for y in range(height):
        for x in range(width):
            # Create a recognizable gradient pattern
            r = (x * 255) // (width - 1) if width > 1 else 128
            g = (y * 255) // (height - 1) if height > 1 else 128
            b = ((x + y) * 255) // (width + height - 2) if (width + height) > 2 else 128

            # BMP uses BGR order
            pixel_data.extend([b, g, r])

        # Add row padding
        pixel_data.extend([0] * row_padding)

    # Write BMP file
    with open(filename, 'wb') as f:
        f.write(file_header)
        f.write(dib_header)
        f.write(pixel_data)

    print(f"Created: {filename}")
    print(f"  Size: {width}x{height} pixels")
    print(f"  File size: {file_size} bytes")
    print(f"  AES blocks needed: {(file_size + 15) // 16}")

def main():
    size = 64
    if len(sys.argv) > 1:
        try:
            size = int(sys.argv[1])
            if size not in [16, 32, 64, 128, 256]:
                print("Warning: Recommended sizes are 16, 32, 64, 128, or 256")
        except ValueError:
            print(f"Usage: {sys.argv[0]} [size]")
            sys.exit(1)

    filename = f"test_image_{size}x{size}.bmp"
    create_bmp(size, size, filename)

    print(f"\nNext steps:")
    print(f"  1. python3 scripts/image_to_hex.py {filename} image_input.hex")
    print(f"  2. Run simulation (see below)")
    print(f"  3. python3 scripts/hex_to_image.py image_decrypted.hex recovered.bmp")
    print(f"  4. Compare {filename} with recovered.bmp")

if __name__ == "__main__":
    main()
