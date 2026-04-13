import sys, os, struct, math

def main():
    if len(sys.argv) < 3:
        print("Usage: python read_rx_sd.py <drive_path> <output_image_path>")
        print("Example: python read_rx_sd.py \\\\.\\PhysicalDrive1 restored_image.bmp")
        return

    drive = sys.argv[1]
    out_path = sys.argv[2]

    try:
        with open(drive, 'rb') as f:
            sector_0 = f.read(512)
            if len(sector_0) != 512:
                print("Failed to read sector 0")
                return

            img_size, total_blocks, total_sectors, _ = struct.unpack("<IIII", sector_0[:16])
            
            if img_size == 0 or img_size > 50 * 1024 * 1024:
                print(f"Invalid image size read: {img_size} bytes. SD card might be empty or corrupt.")
                return

            # Firmware uses total_blocks to determine how many 16B blocks to rx/tx
            # RX receives block by block and writes sector by sector
            rx_data_sectors = math.ceil((total_blocks * 16) / 512.0)
            
            print(f"Metadata read: Size={img_size}, Blocks={total_blocks}, Sectors={rx_data_sectors}")

            img_data_padded = f.read(rx_data_sectors * 512)
            if len(img_data_padded) != rx_data_sectors * 512:
                print(f"Warning: Only read {len(img_data_padded)} bytes, expected {rx_data_sectors * 512}")
            
            img_data = img_data_padded[:img_size]

        with open(out_path, 'wb') as out_f:
            out_f.write(img_data)
            
        print(f"Successfully recovered image ({img_size} bytes) to {out_path}")
            
    except PermissionError:
        print("==================================================================")
        print("PermissionError: You must run this terminal as Administrator to read from physical drives on Windows.")
        print("Please open an Administrator command prompt or PowerShell and run the command again.")
        print("==================================================================")
        sys.exit(1)
    except Exception as e:
        print(f"Error reading from SD card: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()
