#!/bin/bash
#
# Run the full encrypted image transfer simulation:
#   Image → hex → AES encrypt → 8-lane SPI → AES decrypt → hex → Image
#
# Usage:
#   ./run_image_transfer.sh                          # 64x64 test pattern
#   ./run_image_transfer.sh --width 32 --height 32   # Custom size test pattern
#   ./run_image_transfer.sh photo.pgm                # Use existing PGM image
#

set -e

echo "========================================"
echo "  AES Encrypted Image Transfer Pipeline"
echo "========================================"
echo ""

# Step 1: Convert image to hex
echo "Step 1: Converting image to hex..."
NUM_BLOCKS=$(python3 image_to_hex.py "$@")
echo "  NUM_BLOCKS = $NUM_BLOCKS"
echo ""

# Step 2: Compile Verilog
echo "Step 2: Compiling Verilog..."
iverilog -g2012 -DIMAGE_NUM_BLOCKS=$NUM_BLOCKS -o tb_soc_image_transfer.vvp \
    picorv32.v \
    spi_slave_8lane.v \
    spi_rx_buffer.v \
    aes_soc_device.v \
    Aes-Code/ASMD_Encryption.v \
    Aes-Code/ControlUnit_Enryption.v \
    Aes-Code/Datapath_Encryption.v \
    Aes-Code/Key_expansion.v \
    Aes-Code/S_BOX.v \
    Aes-Code/mix_cols.v \
    Aes-Code/shift_rows.v \
    Aes-Code/Sub_Bytes.v \
    Aes-Code/Counter.v \
    Aes-Code/Register.v \
    Aes-Code/function_g.v \
    Aes-Code/Aes-Decryption/ASMD_Decryption.v \
    Aes-Code/Aes-Decryption/ControlUnit_Decryption.v \
    Aes-Code/Aes-Decryption/Datapath_Decryption.v \
    Aes-Code/Aes-Decryption/Inv_Sub_Bytes.v \
    Aes-Code/Aes-Decryption/Inv_mix_cols.v \
    Aes-Code/Aes-Decryption/Inv_shift_rows.v \
    Aes-Code/Aes-Decryption/inv_S_box.v \
    tb_soc_image_transfer.v
echo "  Compilation successful"
echo ""

# Step 3: Run simulation
echo "Step 3: Running simulation..."
echo ""
vvp tb_soc_image_transfer.vvp
echo ""

# Step 4: Reconstruct image
echo "Step 4: Reconstructing decrypted image..."
python3 hex_to_image.py
echo ""

echo "========================================"
echo "  Files produced:"
echo "    original_image.pgm   - Input image"
echo "    decrypted_image.pgm  - Decrypted output"
echo "    image_data.hex       - Image as hex words"
echo "    decrypted_output.hex - Decrypted hex words"
echo "========================================"
