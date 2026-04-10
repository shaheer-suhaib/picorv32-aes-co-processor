#!/usr/bin/env python3
"""
Write a raw image file to an SD card using the Phase-1 sector layout.

Layout (512-byte sectors, payload in first 16 bytes only):
  sector 20: metadata (image size in bytes, little endian)
  sector 21: reserved (zeros)
  sector 22..: image data blocks (16 bytes each, padded)

WARNING: This overwrites raw sectors on the target device.
"""

import math
import os
import ctypes
import sys
from pathlib import Path


META_SECTOR = 20
KEY_SECTOR = 21
DATA_BASE_SECTOR = 22
SECTOR_SIZE = 512


def build_sector(payload16):
    if len(payload16) != 16:
        raise ValueError("payload must be exactly 16 bytes")
    return payload16 + bytes(SECTOR_SIZE - 16)


def write_sector(fh, sector, data):
    if len(data) != SECTOR_SIZE:
        raise ValueError("sector data must be 512 bytes")
    fh.seek(sector * SECTOR_SIZE)
    fh.write(data)


class RawDevice:
    def __init__(self, path):
        self.path = path
        self.handle = None

    def __enter__(self):
        if os.name != "nt":
            raise OSError("RawDevice only supported on Windows")
        kernel32 = ctypes.windll.kernel32
        GENERIC_READ = 0x80000000
        GENERIC_WRITE = 0x40000000
        FILE_SHARE_READ = 0x00000001
        FILE_SHARE_WRITE = 0x00000002
        OPEN_EXISTING = 3
        self.handle = kernel32.CreateFileW(
            self.path,
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            None,
            OPEN_EXISTING,
            0,
            None,
        )
        if self.handle == ctypes.c_void_p(-1).value:
            raise OSError("CreateFileW failed for raw device")
        return self

    def __exit__(self, exc_type, exc, tb):
        if self.handle is not None:
            ctypes.windll.kernel32.CloseHandle(self.handle)
            self.handle = None

    def write_sector(self, sector, data):
        if len(data) != SECTOR_SIZE:
            raise ValueError("sector data must be 512 bytes")
        kernel32 = ctypes.windll.kernel32
        offset = ctypes.c_longlong(sector * SECTOR_SIZE)
        if kernel32.SetFilePointerEx(self.handle, offset, None, 0) == 0:
            raise OSError("SetFilePointerEx failed")
        written = ctypes.c_ulong(0)
        buf = ctypes.create_string_buffer(data)
        if kernel32.WriteFile(self.handle, buf, SECTOR_SIZE, ctypes.byref(written), None) == 0:
            err = ctypes.windll.kernel32.GetLastError()
            raise OSError(f"WriteFile failed (error {err})")
        if written.value != SECTOR_SIZE:
            raise OSError("Short write to raw device")


def open_raw_device(path):
    """
    Open a raw device path on Windows using low-level os.open.
    This is more reliable than built-in open() for PhysicalDrive access.
    """
    if os.name == "nt" and path.startswith(r"\\.\PhysicalDrive"):
        return RawDevice(path)
    return open(path, "r+b")


def main():
    if len(sys.argv) != 3:
        print("Usage: python scripts/write_sd_image.py <image_file> <physical_drive|output_img>")
        print(r"Example (raw): python scripts/write_sd_image.py my.png \\.\PhysicalDrive1")
        print(r"Example (img): python scripts/write_sd_image.py my.png sd_payload.img")
        sys.exit(1)

    image_path = Path(sys.argv[1])
    drive_path = sys.argv[2]

    data = image_path.read_bytes()
    size = len(data)
    block_count = int(math.ceil(size / 16.0)) if size > 0 else 0

    meta = size.to_bytes(4, "little") + bytes(12)
    meta_sector = build_sector(meta)
    key_sector = build_sector(bytes(16))

    is_img = drive_path.lower().endswith(".img")
    try:
        if is_img:
            total_sectors = DATA_BASE_SECTOR + block_count
            image_size = total_sectors * SECTOR_SIZE
            with open(drive_path, "wb") as fh:
                fh.truncate(image_size)
                write_sector(fh, META_SECTOR, meta_sector)
                write_sector(fh, KEY_SECTOR, key_sector)
                for idx in range(block_count):
                    block = data[idx * 16:(idx + 1) * 16]
                    if len(block) < 16:
                        block = block + bytes(16 - len(block))
                    sector_data = build_sector(block)
                    write_sector(fh, DATA_BASE_SECTOR + idx, sector_data)
        else:
            with open_raw_device(drive_path) as fh:
                if isinstance(fh, RawDevice):
                    fh.write_sector(META_SECTOR, meta_sector)
                    fh.write_sector(KEY_SECTOR, key_sector)
                    for idx in range(block_count):
                        block = data[idx * 16:(idx + 1) * 16]
                        if len(block) < 16:
                            block = block + bytes(16 - len(block))
                        sector_data = build_sector(block)
                        fh.write_sector(DATA_BASE_SECTOR + idx, sector_data)
                else:
                    write_sector(fh, META_SECTOR, meta_sector)
                    write_sector(fh, KEY_SECTOR, key_sector)
                    for idx in range(block_count):
                        block = data[idx * 16:(idx + 1) * 16]
                        if len(block) < 16:
                            block = block + bytes(16 - len(block))
                        sector_data = build_sector(block)
                        write_sector(fh, DATA_BASE_SECTOR + idx, sector_data)
    except PermissionError:
        print("Permission denied. Please run this command from an Administrator shell.")
        raise
    except OSError:
        if not is_img:
            print("Raw device write failed. Ensure:")
            print("  1) You are running as Administrator")
            print("  2) The SD card is not open in File Explorer")
            print("  3) The correct PhysicalDrive is selected")
        raise

    print(f"Wrote {size} bytes as {block_count} block(s) to {drive_path}")
    print(f"  meta sector : {META_SECTOR}")
    print(f"  data sectors: {DATA_BASE_SECTOR}..{DATA_BASE_SECTOR + max(block_count - 1, 0)}")


if __name__ == "__main__":
    main()
