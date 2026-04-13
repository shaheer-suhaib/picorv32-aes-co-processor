import sys, os, struct, math

def main():
    if len(sys.argv) < 3:
        print("Usage: python prepare_tx_sd.py <image_path> <drive_path>")
        print("Example: python prepare_tx_sd.py recovered_image.bmp \\\\.\\PhysicalDrive1")
        print("Note: To find your PhysicalDrive number, use Windows Disk Management or diskpart.")
        return

    img_path = sys.argv[1]
    drive = sys.argv[2]
    
    with open(img_path, 'rb') as f:
        img_data = f.read()

    img_size = len(img_data)
    blocks_16b = math.ceil(img_size / 16)
    padded_size = blocks_16b * 16
    total_data_sectors = math.ceil(padded_size / 512)

    # Sector 0 metadata: 4 bytes size, 4 bytes blocks, 4 bytes sectors, 4 bytes padding
    metadata = struct.pack("<IIII", img_size, blocks_16b, total_data_sectors, 0)
    sector_0 = metadata + b'\x00' * (512 - len(metadata))

    # Pad image data to full sectors
    img_data_padded = img_data + b'\x00' * ((total_data_sectors * 512) - img_size)

    full_payload = sector_0 + img_data_padded

    try:
        with open(drive, 'r+b') as f:
            f.write(full_payload)
        print(f"Successfully wrote {len(full_payload)} bytes ({1 + total_data_sectors} sectors) to {drive}")
    except PermissionError:
        print("==================================================================")
        print("PermissionError: You must run this terminal as Administrator to write to physical drives on Windows.")
        print("Please open an Administrator command prompt or PowerShell and run the command again.")
        print("==================================================================")
        sys.exit(1)
    except Exception as e:
        print(f"Error writing to SD card: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()
