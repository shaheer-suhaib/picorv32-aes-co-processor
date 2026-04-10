#!/usr/bin/env python3
"""
Extract the raw image stored on SD card (Phase-1 layout) into a file.

Layout:
  sector 20: metadata (image size in bytes, little endian)
  sector 21: reserved
  sector 22..: image data blocks (16 bytes payload per sector)

Usage:
  python scripts/extract_sd_image.py <physical_drive|img_file> <output_file>
Example:
  python scripts/extract_sd_image.py \\\\.\\PhysicalDrive1 recovered.jpeg
  python scripts/extract_sd_image.py sd_payload.img recovered.jpeg
"""

import os
import sys
import ctypes

SECTOR_SIZE = 512
META_SECTOR = 20
DATA_BASE_SECTOR = 22


class RawDeviceReader:
    def __init__(self, path):
        self.path = path
        self.handle = None

    def __enter__(self):
        if os.name != "nt":
            raise OSError("RawDeviceReader only supported on Windows")
        kernel32 = ctypes.windll.kernel32
        GENERIC_READ = 0x80000000
        FILE_SHARE_READ = 0x00000001
        FILE_SHARE_WRITE = 0x00000002
        OPEN_EXISTING = 3
        self.handle = kernel32.CreateFileW(
            self.path,
            GENERIC_READ,
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

    def read_sector(self, sector):
        kernel32 = ctypes.windll.kernel32
        offset = ctypes.c_longlong(sector * SECTOR_SIZE)
        if kernel32.SetFilePointerEx(self.handle, offset, None, 0) == 0:
            raise OSError("SetFilePointerEx failed")
        buf = ctypes.create_string_buffer(SECTOR_SIZE)
        read = ctypes.c_ulong(0)
        if kernel32.ReadFile(self.handle, buf, SECTOR_SIZE, ctypes.byref(read), None) == 0:
            err = ctypes.windll.kernel32.GetLastError()
            raise OSError(f"ReadFile failed (error {err})")
        if read.value != SECTOR_SIZE:
            raise OSError("Short read from raw device")
        return buf.raw


def open_reader(path):
    if os.name == "nt" and path.startswith(r"\\.\PhysicalDrive"):
        return RawDeviceReader(path)
    return open(path, "rb")


def read_sector(fh, sector):
    fh.seek(sector * SECTOR_SIZE)
    data = fh.read(SECTOR_SIZE)
    if len(data) != SECTOR_SIZE:
        raise OSError("Short read")
    return data


def main():
    if len(sys.argv) != 3:
        print("Usage: python scripts/extract_sd_image.py <physical_drive|img_file> <output_file>")
        sys.exit(1)

    src = sys.argv[1]
    out_path = sys.argv[2]

    with open_reader(src) as fh:
        if isinstance(fh, RawDeviceReader):
            meta = fh.read_sector(META_SECTOR)
        else:
            meta = read_sector(fh, META_SECTOR)

        size = int.from_bytes(meta[0:4], "little")
        if size <= 0:
            raise ValueError("Invalid size in metadata sector (sector 20)")

        blocks = (size + 15) // 16
        output = bytearray()
        for i in range(blocks):
            sector = DATA_BASE_SECTOR + i
            if isinstance(fh, RawDeviceReader):
                data = fh.read_sector(sector)
            else:
                data = read_sector(fh, sector)
            output.extend(data[:16])

    output = output[:size]
    with open(out_path, "wb") as out_f:
        out_f.write(output)

    print(f"Extracted {len(output)} bytes to {out_path}")


if __name__ == "__main__":
    main()

