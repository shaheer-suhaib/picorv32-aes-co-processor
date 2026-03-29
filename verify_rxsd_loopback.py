"""
Verify the TX-BRAM / RX-SD loopback demo output on the receiver SD card.

Layout:
  sector 20: metadata
  sector 21: AES key
  sectors 22..217: ciphertext
  sectors 218..413: decrypted image
"""
import math
import os
import struct
import sys
from pathlib import Path


META_SECTOR = 20
KEY_SECTOR = 21
CT_BASE_SECTOR = 22
IMAGE_FILE_BLOCKS = 196
DEC_BASE_SECTOR = CT_BASE_SECTOR + IMAGE_FILE_BLOCKS
FIXED_KEY_BYTES = bytes([
    0x0F, 0x0E, 0x0D, 0x0C,
    0x0B, 0x0A, 0x09, 0x08,
    0x07, 0x06, 0x05, 0x04,
    0x03, 0x02, 0x01, 0x00,
])


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


def fmt_bytes(data):
    return " ".join(f"{b:02X}" for b in data)


def read_sector(fh, sector):
    fh.seek(sector * 512)
    data = fh.read(512)
    if len(data) != 512:
        raise OSError(f"short read at sector {sector}")
    return data


def load_expected():
    path = Path(__file__).with_name("image_input.hex")
    lines = [line.strip() for line in path.read_text().splitlines() if line.strip()]
    blocks = [bytes.fromhex(line) for line in lines]
    meta = blocks[0]
    image_size = int.from_bytes(meta[0:4], "big")
    original = b"".join(blocks[1:])[:image_size]
    return meta, original


def first_mismatch(lhs, rhs):
    limit = min(len(lhs), len(rhs))
    for idx in range(limit):
        if lhs[idx] != rhs[idx]:
            return idx, lhs[idx], rhs[idx]
    if len(lhs) != len(rhs):
        lhs_byte = lhs[limit] if limit < len(lhs) else None
        rhs_byte = rhs[limit] if limit < len(rhs) else None
        return limit, lhs_byte, rhs_byte
    return None


def detect_file_ext(data):
    if data.startswith(b"BM"):
        return ".bmp"
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png"
    return ".bin"


def maybe_write_outputs(decrypted_bytes, ciphertext_bytes, original_bytes):
    out_dir = Path(__file__).with_name("verify_outputs")
    out_dir.mkdir(exist_ok=True)
    ext = detect_file_ext(original_bytes)
    dec_path = out_dir / f"loopback_decrypted{ext}"
    ct_path = out_dir / f"loopback_ciphertext.bin"
    orig_path = out_dir / f"loopback_expected{ext}"
    dec_path.write_bytes(decrypted_bytes)
    ct_path.write_bytes(ciphertext_bytes)
    orig_path.write_bytes(original_bytes)
    print("\n=== Output Files ===")
    print(f"  Expected : {orig_path}")
    print(f"  Cipher   : {ct_path}")
    print(f"  Decrypted: {dec_path}")


DEVICE = parse_args(sys.argv)

try:
    expected_meta, expected_plain = load_expected()
    image_size = len(expected_plain)
    block_count = int(math.ceil(image_size / 16.0))

    with open_raw_device(DEVICE, "rb") as f:
        meta_sector = read_sector(f, META_SECTOR)
        key_sector = read_sector(f, KEY_SECTOR)
        meta = meta_sector[:16]
        key = key_sector[:16]

        ct_payload = bytearray()
        dec_payload = bytearray()
        ct_tail_clean = True
        dec_tail_clean = True
        first_ct = None
        first_dec = None

        for idx in range(block_count):
            ct_sec = read_sector(f, CT_BASE_SECTOR + idx)
            dec_sec = read_sector(f, DEC_BASE_SECTOR + idx)
            if idx == 0:
                first_ct = ct_sec[:32]
                first_dec = dec_sec[:32]
            ct_payload.extend(ct_sec[:16])
            dec_payload.extend(dec_sec[:16])
            if any(b != 0 for b in ct_sec[16:]):
                ct_tail_clean = False
            if any(b != 0 for b in dec_sec[16:]):
                dec_tail_clean = False

        ct_bytes = bytes(ct_payload[:image_size])
        dec_bytes = bytes(dec_payload[:image_size])

        dec_match = dec_bytes == expected_plain
        ct_diff = ct_bytes != expected_plain
        dec_mismatch = first_mismatch(dec_bytes, expected_plain)

        print("=== RX-SD Loopback Layout ===")
        print(f"  Metadata sector : {META_SECTOR}")
        print(f"  Key sector      : {KEY_SECTOR}")
        print(f"  Cipher sectors  : {CT_BASE_SECTOR}..{CT_BASE_SECTOR + block_count - 1}")
        print(f"  Decrypt sectors : {DEC_BASE_SECTOR}..{DEC_BASE_SECTOR + block_count - 1}")
        print(f"  Image bytes     : {image_size}")
        print(f"  AES blocks      : {block_count}")
        print(f"  Metadata block  : {fmt_bytes(meta)}")
        print(f"  Key block       : {fmt_bytes(key)}")

        print("\n=== Payload Checks ===")
        print(f"  Cipher sector[0] first 32 bytes  : {fmt_bytes(first_ct)}")
        print(f"  Decrypt sector[0] first 32 bytes : {fmt_bytes(first_dec)}")
        print(f"  Cipher tails zero                : {'YES' if ct_tail_clean else 'NO'}")
        print(f"  Decrypt tails zero               : {'YES' if dec_tail_clean else 'NO'}")

        print("\n=== Validation ===")
        print(f"  Metadata vs image_input : {'MATCH' if meta == expected_meta else 'DIFFER'}")
        print(f"  Key vs fixed key        : {'MATCH' if key == FIXED_KEY_BYTES else 'DIFFER'}")
        print(f"  Cipher vs plaintext     : {'DIFFER' if ct_diff else 'IDENTICAL'}")
        print(f"  Decrypted vs expected   : {'MATCH' if dec_match else 'DIFFER'}")
        if dec_mismatch is not None:
            idx, got, exp = dec_mismatch
            print(f"  First decrypt mismatch  : byte {idx} got {got:02X} expected {exp:02X}")
        print(f"  Overall                 : {'PASS' if dec_match else 'FAIL'}")

        maybe_write_outputs(dec_bytes, ct_bytes, expected_plain)
        print("\nDone.")

except PermissionError:
    print("ERROR: Run as Administrator.")
except FileNotFoundError:
    print(f"ERROR: Device {DEVICE!r} not found.")
except OSError as exc:
    print(f"ERROR: Raw device access failed: {exc}")
