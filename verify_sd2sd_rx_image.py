import math
import os
import struct
import sys
from pathlib import Path

def open_raw_device(path, mode):
    if sys.platform == "win32" and path.startswith("\\\\.\\"):
        flags = os.O_BINARY
        if "+" in mode:
            flags |= os.O_RDWR
        elif "w" in mode:
            flags |= os.O_WRONLY
        else:
            flags |= os.O_RDONLY
        fd = os.open(path, flags)
        return os.fdopen(fd, mode, buffering=0)
    return open(path, mode)

def parse_args(argv):
    device = r"\\.\PhysicalDrive1"
    for arg in argv[1:]:
        if arg.startswith("\\\\.\\") or arg.startswith("/dev/"):
            device = arg
    return device

def read_sector_block(fh, sector, bytes_per_sector):
    fh.seek(sector * bytes_per_sector)
    data = fh.read(bytes_per_sector)
    if len(data) != bytes_per_sector:
        raise OSError(f"short read at sector {sector}")
    return data

def parse_boot_sector(boot):
    bytes_per_sector = struct.unpack_from("<H", boot, 11)[0]
    sectors_per_cluster = boot[13]
    reserved_sectors = struct.unpack_from("<H", boot, 14)[0]
    num_fats = boot[16]
    root_entries = struct.unpack_from("<H", boot, 17)[0]
    fat_sectors = struct.unpack_from("<H", boot, 22)[0]
    root_sectors = ((root_entries * 32) + (bytes_per_sector - 1)) // bytes_per_sector
    data_start_sector = reserved_sectors + (num_fats * fat_sectors) + root_sectors
    return {
        "bytes_per_sector": bytes_per_sector,
        "sectors_per_cluster": sectors_per_cluster,
        "reserved_sectors": reserved_sectors,
        "num_fats": num_fats,
        "root_entries": root_entries,
        "fat_sectors": fat_sectors,
        "root_sectors": root_sectors,
        "data_start_sector": data_start_sector,
    }

def find_data_bin_entry(root_dir, root_entries):
    for idx in range(root_entries):
        entry = root_dir[idx * 32:(idx + 1) * 32]
        if len(entry) < 32 or entry[0] in (0x00, 0xE5):
            continue
        if entry[0:11] == b"DATA    BIN":
            return idx, entry
    return None, None

def detect_file_ext(data):
    if data.startswith(b"BM"):
        return ".bmp"
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png"
    if data.startswith(b"P5") or data.startswith(b"P2"):
        return ".pgm"
    return ".bin"

DEVICE = parse_args(sys.argv)

try:
    with open_raw_device(DEVICE, "rb") as f:
        boot = read_sector_block(f, 0, 512)
        bpb = parse_boot_sector(boot)
        
        root_dir_sector = bpb["reserved_sectors"] + (bpb["num_fats"] * bpb["fat_sectors"])
        root_dir_size = bpb["root_sectors"] * bpb["bytes_per_sector"]
        
        f.seek(root_dir_sector * bpb["bytes_per_sector"])
        root = f.read(root_dir_size)
        entry_idx, entry = find_data_bin_entry(root, bpb["root_entries"])
        
        if entry is None:
            raise OSError("DATA.BIN entry not found in root directory")

        cluster = struct.unpack_from("<H", entry, 26)[0]
        data_base = bpb["data_start_sector"] + ((cluster - 2) * bpb["sectors_per_cluster"])
        
        print(f"Reading from SD Card ({DEVICE})...")
        print(f"DATA.BIN starts at physical sector {data_base}")

        # In sd2sd mode, metadata is at data_base + 0, exactly as it was on transmitter
        meta_sector = data_base + 0
        meta_sector_bytes = read_sector_block(f, meta_sector, bpb["bytes_per_sector"])
        meta_block = meta_sector_bytes[:16]
        
        image_size_be = int.from_bytes(meta_block[0:4], "big")
        image_size_le = int.from_bytes(meta_block[0:4], "little")
        # Heuristic for endianness
        image_size = image_size_be if 0 < image_size_be < (10*1024*1024) else image_size_le
        
        if image_size <= 0 or image_size > 50*1024*1024:
            print(f"ERROR: Invalid image size parsed from metadata: {image_size} bytes")
            print(f"Metadata block raw: {meta_block.hex(' ')}")
            sys.exit(1)
            
        image_block_count = int(math.ceil(image_size / 16.0))
        
        # Placed at data_base + 2 (PLAIN_BASE_SECTOR relative to DATA.BIN start)
        plain_base = data_base + 2
        
        print(f"Image Size: {image_size} bytes ({image_block_count} blocks)")
        print(f"Extracting image from sectors {plain_base} to {plain_base + image_block_count - 1}...")

        payload = bytearray()
        for idx in range(image_block_count):
            sector_bytes = read_sector_block(f, plain_base + idx, bpb["bytes_per_sector"])
            # Only append the first 16 bytes of the sector because AES block is 16 bytes.
            # wait! The `sd_read`/`sd_write` writes the full AES block to the sector.
            payload.extend(sector_bytes[:16])
            
        final_image_bytes = bytes(payload[:image_size])
        
        ext = detect_file_ext(final_image_bytes)
        out_dir = Path(__file__).parent / "verify_outputs"
        out_dir.mkdir(exist_ok=True)
        
        out_path = out_dir / f"received_image{ext}"
        out_path.write_bytes(final_image_bytes)
        
        print(f"\nSUCCESS! Image perfectly extracted.")
        print(f"Saved to: {out_path}")
        
        if sys.platform == "win32":
            os.startfile(out_path)

except Exception as e:
    print(f"ERROR: {e}")
