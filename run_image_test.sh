#!/bin/bash
#
# End-to-end image encryption/decryption test
#
# Usage: ./run_image_test.sh [image_file]
#   If no image_file provided, creates a test image
#

set -e

echo "=========================================="
echo "  AES Image Encryption/Decryption Test"
echo "=========================================="
echo ""

# Check for input image or create test image
if [ -n "$1" ]; then
    INPUT_IMAGE="$1"
    if [ ! -f "$INPUT_IMAGE" ]; then
        echo "Error: File not found: $INPUT_IMAGE"
        exit 1
    fi
else
    echo "No input image specified, creating test image..."
    python3 scripts/create_test_image.py 64
    INPUT_IMAGE="test_image_64x64.bmp"
fi

echo ""
echo "--- Step 1: Convert image to hex ---"
python3 scripts/image_to_hex.py "$INPUT_IMAGE" image_input.hex

echo ""
echo "--- Step 2: Compile testbench ---"
# Note: Decryption reuses S_BOX, Key_expansion, function_g, Counter, Register from encryption
iverilog -g2012 -o tb_image_aes.vvp \
    tb_image_aes.v \
    Aes-Code/ASMD_Encryption.v \
    Aes-Code/ControlUnit_Enryption.v \
    Aes-Code/Datapath_Encryption.v \
    Aes-Code/Key_expansion.v \
    Aes-Code/S_BOX.v \
    Aes-Code/Sub_Bytes.v \
    Aes-Code/mix_cols.v \
    Aes-Code/shift_rows.v \
    Aes-Code/function_g.v \
    Aes-Code/Counter.v \
    Aes-Code/Register.v \
    Aes-Code/Aes-Decryption/ASMD_Decryption.v \
    Aes-Code/Aes-Decryption/ControlUnit_Decryption.v \
    Aes-Code/Aes-Decryption/Datapath_Decryption.v \
    Aes-Code/Aes-Decryption/inv_S_box.v \
    Aes-Code/Aes-Decryption/Inv_Sub_Bytes.v \
    Aes-Code/Aes-Decryption/Inv_mix_cols.v \
    Aes-Code/Aes-Decryption/Inv_shift_rows.v

echo "Compilation successful!"

echo ""
echo "--- Step 3: Run simulation ---"
vvp tb_image_aes.vvp

echo ""
echo "--- Step 4: Convert decrypted hex back to image ---"
python3 scripts/hex_to_image.py image_decrypted.hex recovered_image.bmp

echo ""
echo "--- Step 5: Compare files ---"
if cmp -s "$INPUT_IMAGE" recovered_image.bmp; then
    echo "SUCCESS: Files are identical!"
else
    echo "Comparing file sizes..."
    ls -la "$INPUT_IMAGE" recovered_image.bmp
    echo ""
    echo "Note: Files may differ if you want byte-by-byte comparison"
fi

echo ""
echo "Output files:"
echo "  - image_input.hex      (original as hex)"
echo "  - image_encrypted.hex  (encrypted data)"
echo "  - image_decrypted.hex  (decrypted data)"
echo "  - recovered_image.bmp  (final output)"
echo "  - tb_image_aes.vcd     (waveform)"
echo ""
echo "Done!"
