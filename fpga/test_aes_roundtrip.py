from Crypto.Cipher import AES
import struct

# Key as stored in BRAM (little-endian word order)
KEY_INT = 0x1234567890ABCDEF1122334455667788
key_words = [
    (KEY_INT >>  0) & 0xFFFFFFFF,
    (KEY_INT >> 32) & 0xFFFFFFFF,
    (KEY_INT >> 64) & 0xFFFFFFFF,
    (KEY_INT >> 96) & 0xFFFFFFFF,
]
# The AES module loads KEY[31:0]=word0, KEY[63:32]=word1, etc.
# So the 128-bit key register = word3 || word2 || word1 || word0
# In bytes (big-endian AES standard): key_bytes[0..15]
key_bytes = b""
for w in key_words:
    key_bytes += struct.pack("<I", w)

print(f"Key words: {[hex(w) for w in key_words]}")
print(f"Key bytes: {key_bytes.hex()}")
print()

for sw_val in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 255]:
    # PT[31:0] = sw_val, PT[127:32] = 0
    pt_bytes = struct.pack("<I", sw_val) + b"\x00" * 12

    cipher = AES.new(key_bytes, AES.MODE_ECB)
    ct = cipher.encrypt(pt_bytes)
    pt_dec = cipher.decrypt(ct)
    recovered = struct.unpack("<I", pt_dec[0:4])[0]

    print(f"SW={sw_val:3d}  PT={pt_bytes.hex()}  CT={ct.hex()}  DEC={pt_dec.hex()}  recovered={recovered}")
