# PSK and CMAC Code Explanation

This note explains the two security parts added to the project:

- PSK-based session key exchange
- AES-CMAC integrity/authentication

The main implementation is in:

- `generate_program_dual_txbram_rxsd_hex.py`
- `picorv32.v`
- `fpga/aes_soc_top_dual_txbram_rxsd.v`
- `tb_dual_txbram_rxsd.v`

## Big picture

The design now works in this order:

1. RX generates a nonce.
2. TX generates a nonce.
3. TX and RX exchange those nonce values through the mailbox.
4. Both sides derive fresh session keys from:
   - the shared PSK
   - RX nonce
   - TX nonce
5. TX encrypts the image using the derived encryption key.
6. TX computes CMAC over the ciphertext using the derived MAC key.
7. TX sends the ciphertext and then one final CMAC tag block.
8. RX decrypts the ciphertext, recomputes CMAC, and compares the final tag.
9. PASS only happens if:
   - image decrypts correctly
   - CMAC tag matches

## 1. PSK session key exchange

### Where it is implemented

In `generate_program_dual_txbram_rxsd_hex.py`:

- `PSK_BASE`, `NONCE_RX_BASE`, `NONCE_TX_BASE`, `FLAG_KEYS_READY`
- `PSK_KEY_BYTES`
- `emit_derive_session_key(...)`
- TX firmware in `generate_tx_program()`
- RX firmware in `generate_rx_program()`

### What is stored in BRAM

The script defines these extra memory areas:

- `PSK_BASE`
  - long-term pre-shared key
- `NONCE_RX_BASE`
  - RX nonce storage
- `NONCE_TX_BASE`
  - TX nonce storage
- `KEY_BASE`
  - derived session encryption key `Kenc`
- `MAC_KEY_BASE`
  - derived session MAC key `Kmac`
- `CMAC_K1_BASE`
  - runtime-derived CMAC subkey `K1`

The PSK is preloaded in BRAM by the generator.

The session keys and nonces are generated at runtime by the firmware.

### How the nonce exchange works

This one-FPGA prototype uses the mailbox as the control plane.

RX writes:

- `nonce_rx` into mailbox `aux0`

TX writes:

- `nonce_tx` into mailbox `aux1`

So the exchange is:

- RX -> mailbox -> TX
- TX -> mailbox -> RX

No final key is ever transmitted. Only the nonce values are shared.

### How the keys are derived

Both sides use the same PSK and the same nonces to derive the same keys locally.

The derivation helper is `emit_derive_session_key(...)`.

It loads the PSK into the AES encrypt engine and encrypts a 16-byte block:

- `nonce_rx || nonce_tx || "KENC" || "PSK1"` for `Kenc`
- `nonce_rx || nonce_tx || "KMAC" || "PSK1"` for `Kmac`

So the formulas are:

- `Kenc = AES(PSK, nonce_rx || nonce_tx || "KENC" || "PSK1")`
- `Kmac = AES(PSK, nonce_rx || nonce_tx || "KMAC" || "PSK1")`

Because TX and RX use the same inputs, they get the same outputs.

### TX handshake flow

TX firmware does this:

1. Wait for RX to set `FLAG_START`.
2. Read `nonce_rx` from mailbox `aux0`.
3. Generate `nonce_tx`.
4. Store both nonces in TX BRAM.
5. Write `nonce_tx` into mailbox `aux1`.
6. Derive `Kenc`.
7. Derive `Kmac`.
8. Derive `K1` from `Kmac`.
9. Wait for RX to set `FLAG_KEYS_READY`.
10. Start the normal encrypted transfer.

### RX handshake flow

RX firmware does this:

1. Wait for SD init and button press.
2. Generate `nonce_rx`.
3. Store `nonce_rx` in RX BRAM.
4. Write `nonce_rx` into mailbox `aux0`.
5. Clear mailbox `aux1`.
6. Set `FLAG_START`.
7. Wait for TX to publish `nonce_tx`.
8. Store `nonce_tx` in RX BRAM.
9. Derive `Kenc`.
10. Derive `Kmac`.
11. Derive `K1`.
12. Load the derived keys into the AES/CMAC flow.
13. Set `FLAG_KEYS_READY`.
14. Start receiving ciphertext.

## 2. CMAC integrity/authentication

### What CMAC is doing here

This project uses AES-CMAC, not HMAC.

CMAC is a secure authentication tag built using AES.

The CMAC input in this design is:

- one fixed 16-byte header block
- followed by all ciphertext blocks

The CMAC output is:

- one final 16-byte tag

TX sends that final tag as one extra SPI block after all ciphertext blocks.

RX computes its own local tag and compares the two.

### Where it is implemented

In `generate_program_dual_txbram_rxsd_hex.py`:

- `CMAC_HEADER_BASE`
- `CMAC_K1_BASE`
- `emit_cmac_init(...)`
- `emit_cmac_update(...)`
- `emit_derive_cmac_k1(...)`

In `picorv32.v`:

- `aes_start_nospi`
- `aes_send_raw`

### CMAC running state

The current CMAC value is held in registers:

- `x13..x16`

These registers store the 128-bit running CMAC state.

### How CMAC is initialized

`emit_cmac_init(...)` does:

1. Load the MAC key `Kmac`.
2. Load the fixed 16-byte header block.
3. AES-encrypt the header block using `aes_start_nospi`.
4. Store the result in `x13..x16`.

That becomes the first CMAC state.

### How each CMAC update works

`emit_cmac_update(...)` does:

1. Load the MAC key `Kmac`.
2. XOR the next input block with the current CMAC state.
3. AES-encrypt that result using `aes_start_nospi`.
4. Write the new CMAC state back into `x13..x16`.

So conceptually:

- `state = AES(Kmac, state xor next_block)`

That is repeated for each authenticated block.

### Why `aes_start_nospi` exists

Normal AES start in this project encrypts and then transmits the result over SPI.

CMAC and key derivation do not want to transmit intermediate values.

So `aes_start_nospi` was added in `picorv32.v` to:

- run AES
- get the result
- but not send anything over SPI

### Why `aes_send_raw` exists

The final CMAC tag is already computed in firmware.

It is not another image block to encrypt.

So `aes_send_raw` was added in `picorv32.v` to:

- take a raw 128-bit value already sitting in the AES PT registers
- send it directly over SPI

That is how the final CMAC tag is transmitted.

### How `K1` is derived

CMAC uses a special final-block subkey called `K1`.

Since `Kmac` changes every session, `K1` must also be derived every session.

`emit_derive_cmac_k1(...)` does:

1. Compute `L = AES(Kmac, 0^128)`.
2. Store `L` into `CMAC_K1_BASE`.
3. Shift the whole 16-byte value left by 1 bit in firmware.
4. If the original most significant bit was `1`, XOR the last byte with `0x87`.

The result is stored as `K1`.

### TX CMAC flow

After PSK key derivation is complete, TX does:

1. Initialize CMAC from the header block.
2. For each ciphertext block except the last:
   - update CMAC immediately
3. Save the last ciphertext block in scratch
4. After all ciphertext blocks:
   - reload the last ciphertext block
   - XOR it with `K1`
   - do the final CMAC update
5. The final CMAC state in `x13..x16` is the tag
6. Send that tag with `aes_send_raw()`

So TX sends:

- 196 ciphertext blocks
- 1 final CMAC tag block

### RX CMAC flow

After PSK key derivation is complete, RX does:

1. Initialize CMAC from the same header block.
2. For each received ciphertext block except the last:
   - save ciphertext to scratch
   - decrypt it
   - reload the saved ciphertext
   - update CMAC on ciphertext
3. Receive the final extra block, which is the transmitted tag
4. Save that tag in scratch
5. Reload the saved last ciphertext block
6. XOR it with `K1`
7. Run the final CMAC update
8. Compare:
   - received tag
   - locally computed tag

If they match, RX sets the MAC-ok bit.

## 3. How PASS is decided

RX checks two things:

- image correctness
- MAC correctness

Image correctness:

- decrypted image block must match the expected image block in BRAM

MAC correctness:

- final received tag must match RX’s locally computed CMAC tag

PASS happens only if both are true.

This is reflected in:

- `AUX0_IMAGE_OK`
- `AUX0_MAC_OK`

At the end:

- `aux0 = 0x3` means image OK + MAC OK
- `aux0 = 0x1` means image OK + MAC failed
- `aux0 = 0x0` means image failed + MAC failed

## 4. How the testbench verifies it

The main testbench is `tb_dual_txbram_rxsd.v`.

It now checks:

- TX nonce equals RX nonce record
- TX `Kenc` equals RX `Kenc`
- TX `Kmac` equals RX `Kmac`
- TX `K1` equals RX `K1`
- decrypted image matches expected image
- transmitted tag matches local tag

Three cases are supported:

### Normal case

Expected:

- session keys match
- image transfer works
- CMAC matches
- PASS

### Tampered-tag case

The testbench flips one bit in the final received tag block.

Expected:

- session keys still match
- image still decrypts correctly
- CMAC comparison fails
- FAIL

### Bad-PSK case

The testbench flips one bit in RX’s PSK before reset release.

Expected:

- nonces still match
- session keys diverge
- decrypt output is wrong
- CMAC fails
- FAIL

## 5. Short summary

PSK part:

- RX sends a nonce
- TX sends a nonce back
- both sides derive fresh `Kenc` and `Kmac` locally from the PSK plus the two nonces

CMAC part:

- TX computes AES-CMAC over the ciphertext stream
- TX sends one final tag block
- RX recomputes the same CMAC and compares tags

Final rule:

- PASS only if the session keys match, the image decrypts correctly, and the CMAC tag matches
