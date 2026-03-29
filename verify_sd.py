r"""
verify_sd.py -- Read back SD card and check the SD image AES pipeline.
Run as Administrator on Windows.

Usage:
    python verify_sd.py
    python verify_sd.py \\.\PhysicalDrive1
    python verify_sd.py \\.\PhysicalDrive1 --no-open
"""
import math
import os
from pathlib import Path
import struct
import sys


FIXED_KEY_BYTES = bytes([
    0x0F, 0x0E, 0x0D, 0x0C,
    0x0B, 0x0A, 0x09, 0x08,
    0x07, 0x06, 0x05, 0x04,
    0x03, 0x02, 0x01, 0x00,
])

EXPECTED_DATA_BASE_SECTOR = 20


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
    auto_open = True

    for arg in argv[1:]:
        if arg == "--no-open":
            auto_open = False
        elif arg.startswith("\\\\.\\") or arg.startswith("/dev/"):
            device = arg

    return device, auto_open


def fmt_bytes(data):
    return " ".join(f"{b:02X}" for b in data)


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


def load_expected_phase1_image():
    image_hex_path = Path(__file__).with_name("image_input.hex")
    if not image_hex_path.exists():
        return None

    lines = [line.strip() for line in image_hex_path.read_text().splitlines() if line.strip()]
    try:
        blocks = [bytes.fromhex(line) for line in lines]
    except ValueError:
        return None

    if not blocks:
        return None

    meta_block = blocks[0]
    image_size = int.from_bytes(meta_block[0:4], "big")
    original_bytes = b"".join(blocks[1:])[:image_size] if image_size > 0 else b""

    return {
        "path": str(image_hex_path),
        "blocks": blocks,
        "meta_block": meta_block,
        "image_size": image_size,
        "original_bytes": original_bytes,
    }


def parse_boot_sector(boot):
    bytes_per_sector = struct.unpack_from("<H", boot, 11)[0]
    sectors_per_cluster = boot[13]
    reserved_sectors = struct.unpack_from("<H", boot, 14)[0]
    num_fats = boot[16]
    root_entries = struct.unpack_from("<H", boot, 17)[0]
    total_sectors_16 = struct.unpack_from("<H", boot, 19)[0]
    fat_sectors = struct.unpack_from("<H", boot, 22)[0]
    total_sectors_32 = struct.unpack_from("<L", boot, 32)[0]
    root_sectors = ((root_entries * 32) + (bytes_per_sector - 1)) // bytes_per_sector
    data_start_sector = reserved_sectors + (num_fats * fat_sectors) + root_sectors
    total_sectors = total_sectors_16 or total_sectors_32

    return {
        "bytes_per_sector": bytes_per_sector,
        "sectors_per_cluster": sectors_per_cluster,
        "reserved_sectors": reserved_sectors,
        "num_fats": num_fats,
        "root_entries": root_entries,
        "fat_sectors": fat_sectors,
        "root_sectors": root_sectors,
        "data_start_sector": data_start_sector,
        "total_sectors": total_sectors,
    }


def find_data_bin_entry(root_dir, root_entries):
    for idx in range(root_entries):
        entry = root_dir[idx * 32:(idx + 1) * 32]
        if len(entry) < 32 or entry[0] in (0x00, 0xE5):
            continue
        if entry[0:11] == b"DATA    BIN":
            return idx, entry
    return None, None


def read_sector_block(fh, sector, bytes_per_sector):
    fh.seek(sector * bytes_per_sector)
    data = fh.read(bytes_per_sector)
    if len(data) != bytes_per_sector:
        raise OSError(f"short read at sector {sector}")
    return data


def detect_file_ext(data):
    if data.startswith(b"BM"):
        return ".bmp"
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png"
    if data.startswith(b"P5") or data.startswith(b"P2"):
        return ".pgm"
    return ".bin"


def parse_bmp_info(data):
    if len(data) < 54 or data[0:2] != b"BM":
        return None

    return {
        "file_size": struct.unpack_from("<I", data, 2)[0],
        "pixel_offset": struct.unpack_from("<I", data, 10)[0],
        "dib_size": struct.unpack_from("<I", data, 14)[0],
        "width": struct.unpack_from("<i", data, 18)[0],
        "height": struct.unpack_from("<i", data, 22)[0],
        "bpp": struct.unpack_from("<H", data, 28)[0],
        "image_size": struct.unpack_from("<I", data, 34)[0],
    }


def make_viewable_encrypted_bmp(original_bytes, encrypted_bytes):
    bmp = parse_bmp_info(original_bytes)
    if not bmp:
        return None

    pixel_offset = bmp["pixel_offset"]
    if len(original_bytes) < pixel_offset:
        return None

    rebuilt = bytearray(original_bytes[:pixel_offset])
    rebuilt.extend(encrypted_bytes[pixel_offset:len(original_bytes)])
    if len(rebuilt) < len(original_bytes):
        rebuilt.extend(b"\x00" * (len(original_bytes) - len(rebuilt)))
    return bytes(rebuilt[:len(original_bytes)])


def write_output(path, data):
    with open(path, "wb") as fh:
        fh.write(data)


def maybe_open(paths, auto_open):
    if not auto_open or sys.platform != "win32":
        return

    for path in paths:
        try:
            os.startfile(path)
        except OSError:
            pass


DEVICE, AUTO_OPEN = parse_args(sys.argv)
EXPECTED_IMAGE = load_expected_phase1_image()

try:
    with open_raw_device(DEVICE, "rb") as f:
        boot = read_sector_block(f, 0, 512)
        bpb = parse_boot_sector(boot)
        sig_ok = boot[510:512] == b"\x55\xAA"
        fs_type = boot[54:62].decode("ascii", errors="replace").strip()
        vol_label = boot[43:54].decode("ascii", errors="replace").strip()

        print("=== Boot Sector ===")
        print(f"  Signature  : {'OK (55 AA)' if sig_ok else 'BAD - FAT not written!'}")
        print(f"  FS type    : {fs_type!r}")
        print(f"  Volume     : {vol_label!r}")
        print(f"  Sector size: {bpb['bytes_per_sector']} bytes")
        print(f"  FAT copies : {bpb['num_fats']}")
        print(f"  FAT size   : {bpb['fat_sectors']} sectors each")
        print(f"  Root dir   : {bpb['root_sectors']} sector(s)")
        print(f"  Data start : sector {bpb['data_start_sector']}")

        root_dir_sector = bpb["reserved_sectors"] + (bpb["num_fats"] * bpb["fat_sectors"])
        root_dir_size = bpb["root_sectors"] * bpb["bytes_per_sector"]
        f.seek(root_dir_sector * bpb["bytes_per_sector"])
        root = f.read(root_dir_size)
        entry_idx, entry = find_data_bin_entry(root, bpb["root_entries"])
        if entry is None:
            raise OSError("DATA.BIN entry not found in root directory")

        cluster = struct.unpack_from("<H", entry, 26)[0]
        file_size = struct.unpack_from("<L", entry, 28)[0]
        data_base = bpb["data_start_sector"] + ((cluster - 2) * bpb["sectors_per_cluster"])

        print("\n=== Root Directory Entry ===")
        print(f"  Entry index : {entry_idx}")
        print(f"  Filename    : {entry[0:8].decode('ascii', errors='replace').rstrip()}.{entry[8:11].decode('ascii', errors='replace').rstrip()}")
        print(f"  1st cluster : {cluster}")
        print(f"  File size   : {file_size} bytes")
        print(f"  DATA.BIN    : starts at physical sector {data_base}")
        if data_base != EXPECTED_DATA_BASE_SECTOR:
            print(f"  Warning     : Phase 1 firmware writes fixed sectors starting at {EXPECTED_DATA_BASE_SECTOR}, not {data_base}")

        meta_sector = data_base + 0
        key_sector = data_base + 1
        meta_sector_bytes = read_sector_block(f, meta_sector, bpb["bytes_per_sector"])
        key_sector_bytes = read_sector_block(f, key_sector, bpb["bytes_per_sector"])
        meta_block = meta_sector_bytes[:16]
        key_block = key_sector_bytes[:16]
        meta_tail_zero = not any(b != 0 for b in meta_sector_bytes[16:])
        key_tail_zero = not any(b != 0 for b in key_sector_bytes[16:])

        image_size_be = int.from_bytes(meta_block[0:4], "big")
        image_size_le = int.from_bytes(meta_block[0:4], "little")
        image_file_size = image_size_be if 0 < image_size_be < file_size else image_size_le
        image_block_count = int(math.ceil(image_file_size / 16.0)) if image_file_size > 0 else 0

        plain_base = data_base + 2
        ct_base = plain_base + image_block_count
        dec_base = ct_base + image_block_count

        print("\n=== Image Layout ===")
        print(f"  Metadata sector  : {meta_sector}")
        print(f"  Key sector       : {key_sector}")
        if image_block_count > 0:
            print(f"  Original sectors : {plain_base}..{plain_base + image_block_count - 1}")
            print(f"  Cipher sectors   : {ct_base}..{ct_base + image_block_count - 1}")
            print(f"  Decrypt sectors  : {dec_base}..{dec_base + image_block_count - 1}")
        else:
            print(f"  Original sectors : not available")
            print(f"  Cipher sectors   : not available")
            print(f"  Decrypt sectors  : not available")
        print(f"  Image bytes      : {image_file_size}")
        print(f"  AES blocks       : {image_block_count}")
        print(f"  Last block valid : {image_file_size - ((image_block_count - 1) * 16) if image_block_count > 0 else 0} bytes")
        print(f"  Metadata block   : {fmt_bytes(meta_block)}")
        print(f"  Key block        : {fmt_bytes(key_block)}")
        print(f"  Metadata tail    : {'ZERO' if meta_tail_zero else 'NONZERO DATA PRESENT'}")
        print(f"  Key tail         : {'ZERO' if key_tail_zero else 'NONZERO DATA PRESENT'}")

        if image_block_count == 0:
            print("\n=== Checks ===")
            print("  Overall               : FAIL")
            print("  Reason                : metadata sector is empty or invalid")
            print("  Interpretation        : the Phase 1 PicoRV32 pipeline has not written the SD image layout yet")
            print(f"  Hint                  : sector 20 should contain non-zero metadata, not {fmt_bytes(meta_block)}")
            print(f"  Hint                  : sector 21 should contain the fixed AES key block, not {fmt_bytes(key_block)}")
            print("\nDone.")
            raise SystemExit(1)

        def read_payload_range(base_sector, block_count):
            payload = bytearray()
            nonzero_tail = False
            first_sector_preview = None

            for idx in range(block_count):
                sector = base_sector + idx
                sector_bytes = read_sector_block(f, sector, bpb["bytes_per_sector"])
                payload.extend(sector_bytes[:16])
                if any(b != 0 for b in sector_bytes[16:]):
                    nonzero_tail = True
                if idx == 0:
                    first_sector_preview = sector_bytes[:32]

            return bytes(payload[:image_file_size]), nonzero_tail, first_sector_preview

        original_bytes, plain_nonzero_tail, plain_preview = read_payload_range(plain_base, image_block_count)
        encrypted_bytes, ct_nonzero_tail, ct_preview = read_payload_range(ct_base, image_block_count)
        decrypted_bytes, dec_nonzero_tail, dec_preview = read_payload_range(dec_base, image_block_count)

        original_ext = detect_file_ext(original_bytes)
        bmp_info = parse_bmp_info(original_bytes)
        meta_matches_expected = None
        plain_matches_expected = None
        key_matches_expected = key_block == FIXED_KEY_BYTES

        if EXPECTED_IMAGE is not None:
            meta_matches_expected = meta_block == EXPECTED_IMAGE["meta_block"]
            if image_file_size == EXPECTED_IMAGE["image_size"]:
                plain_matches_expected = original_bytes == EXPECTED_IMAGE["original_bytes"]
            else:
                plain_matches_expected = False

        expected_plain_mismatch = None
        if EXPECTED_IMAGE is not None:
            expected_plain_mismatch = first_mismatch(original_bytes, EXPECTED_IMAGE["original_bytes"])

        dec_mismatch = first_mismatch(decrypted_bytes, original_bytes)

        print("\n=== Sector Payload Checks ===")
        print(f"  Original sector[0] first 32 bytes : {fmt_bytes(plain_preview)}")
        print(f"  Cipher sector[0]  first 32 bytes  : {fmt_bytes(ct_preview)}")
        print(f"  Decrypt sector[0] first 32 bytes  : {fmt_bytes(dec_preview)}")
        print(f"  Original bytes[16:512] zero in every sector : {'YES' if not plain_nonzero_tail else 'NO'}")
        print(f"  Cipher bytes[16:512] zero in every sector   : {'YES' if not ct_nonzero_tail else 'NO'}")
        print(f"  Decrypt bytes[16:512] zero in every sector  : {'YES' if not dec_nonzero_tail else 'NO'}")

        if EXPECTED_IMAGE is not None:
            print("\n=== Phase 1 Expected Data ===")
            print(f"  Source file             : {EXPECTED_IMAGE['path']}")
            print(f"  Metadata vs image_input : {'MATCH' if meta_matches_expected else 'DIFFER'}")
            print(f"  Key vs fixed key        : {'MATCH' if key_matches_expected else 'DIFFER'}")
            print(f"  Plaintext vs image_input: {'MATCH' if plain_matches_expected else 'DIFFER'}")
            if expected_plain_mismatch is not None:
                mismatch_idx, got_byte, exp_byte = expected_plain_mismatch
                block_idx = mismatch_idx // 16
                byte_in_block = mismatch_idx % 16
                print(
                    f"  First plaintext mismatch: byte {mismatch_idx} "
                    f"(sector {plain_base + block_idx}, block byte {byte_in_block}) "
                    f"got {got_byte:02X} expected {exp_byte:02X}"
                )
        else:
            print("\n=== Phase 1 Expected Data ===")
            print("  image_input.hex         : not found, skipping metadata/plaintext source check")
            print(f"  Key vs fixed key        : {'MATCH' if key_matches_expected else 'DIFFER'}")

        if bmp_info:
            print("\n=== BMP Info ===")
            print(f"  Width       : {bmp_info['width']}")
            print(f"  Height      : {bmp_info['height']}")
            print(f"  Bits/pixel  : {bmp_info['bpp']}")
            print(f"  Pixel offset: {bmp_info['pixel_offset']}")
            print(f"  Image bytes : {bmp_info['image_size']}")

        dec_ok = decrypted_bytes == original_bytes
        ct_differs = encrypted_bytes != original_bytes

        print("\n=== Checks ===")
        print("  Metadata tail zero      : " + ("YES" if meta_tail_zero else "NO"))
        print("  Key tail zero           : " + ("YES" if key_tail_zero else "NO"))
        print("  Decrypted vs Original : " + ("MATCH" if dec_ok else "DIFFER"))
        print("  Encrypted vs Original : " + ("DIFFER" if ct_differs else "IDENTICAL"))
        print("  Overall               : " + ("PASS" if dec_ok else "FAIL"))
        if dec_mismatch is not None:
            mismatch_idx, dec_byte, orig_byte = dec_mismatch
            block_idx = mismatch_idx // 16
            byte_in_block = mismatch_idx % 16
            print(
                f"  First decrypt mismatch : byte {mismatch_idx} "
                f"(sector {dec_base + block_idx}, block byte {byte_in_block}) "
                f"got {dec_byte:02X} expected {orig_byte:02X}"
            )

        out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "verify_outputs")
        os.makedirs(out_dir, exist_ok=True)

        original_path = os.path.join(out_dir, "original_from_sd" + original_ext)
        decrypted_path = os.path.join(out_dir, "decrypted_from_sd" + original_ext)
        write_output(original_path, original_bytes)
        write_output(decrypted_path, decrypted_bytes)

        open_paths = [original_path, decrypted_path]

        if bmp_info:
            encrypted_view = make_viewable_encrypted_bmp(original_bytes, encrypted_bytes)
            encrypted_path = os.path.join(out_dir, "encrypted_view.bmp")
            write_output(encrypted_path, encrypted_view if encrypted_view is not None else encrypted_bytes)
            open_paths.insert(1, encrypted_path)
        else:
            encrypted_path = os.path.join(out_dir, "encrypted_from_sd" + original_ext)
            write_output(encrypted_path, encrypted_bytes)
            open_paths.insert(1, encrypted_path)

        print("\n=== Output Files ===")
        print(f"  Original : {original_path}")
        print(f"  Encrypted: {encrypted_path}")
        print(f"  Decrypted: {decrypted_path}")

        maybe_open(open_paths, AUTO_OPEN)
        print("\nDone.")

except PermissionError:
    print("ERROR: Run as Administrator.")
except FileNotFoundError:
    print(f"ERROR: Device {DEVICE!r} not found.")
except OSError as exc:
    print(f"ERROR: Raw device access failed: {exc}")
