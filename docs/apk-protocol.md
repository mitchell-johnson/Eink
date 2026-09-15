# WoPda APK and WOLINK protocol evidence

Analysis date: 2026-09-13. This document records interoperable protocol facts from static analysis and public references. APK binaries, extracted third-party code and supplier documents are not distributed here.

## Sources and reproducibility

Scratch paths and assembly line numbers below describe the original analysis
outputs, which are not packaged. Reproduce them by analyzing the public APK.

- Supplied `wopda.apk`, SHA-256 `3373bc6450e8d3258a70464340ac215d30340c85619d2703b4d583cf0916b65f`.
- APK package: `Ld29lc2w.new_pda`, Flutter application, AOT Dart 3.9.2, arm64 Android, compressed pointers. Snapshot hash `97ff04a728735e6b6b098bdf983faaba`.
- Java decompilation: `tmp/apk-analysis/jadx/`. Six jadx decompilation errors occurred in the full application; the actual application business logic is in Flutter AOT `libapp.so`, so Java alone is insufficient.
- Extracted arm64 library and strings: `tmp/apk-analysis/libapp.so`, `tmp/apk-analysis/strings.txt`.
- Public reference implementation: <https://github.com/shorti1996/zhsunyco-esl-wolink>, commit `775082955d7bca8c5fb0f0c9ae7864caa6d13759`; contains wheel `zhsunyco_esl-0.2.14-py3-none-any.whl`. Its metadata says MIT but the bundled LICENSE is GPL v3, so no implementation code should be copied under an assumed MIT license; this document describes interoperable protocol facts.
- Wheel unpacked into `tmp/apk-analysis/wheel/`; references below are to that directory. These public implementation findings are explicitly distinguished from observations in the supplied APK.
- AOT analysis tool: <https://github.com/worawit/blutter>, built in workspace scratch with the matching Dart runtime. No package installation to the system Python was used.

## APK findings established before AOT disassembly

The APK includes Flutter Blue Plus and these WOLINK identifiers as literal strings:

| UUID | Location in extracted strings |
| --- | --- |
| `30323032-4C53-4545-4C42-4B4E494C4F57` | line 21361 |
| `32323032-4C53-4545-4C42-4B4E494C4F57` | line 22072 |
| `34323032-4C53-4545-4C42-4B4E494C4F57` | line 24981 |
| `35323032-4C53-4545-4C42-4B4E494C4F57` | line 19054 |

Application source symbols include:

- `package:new_pda/app/utils/ble.dart` (strings line 14295)
- `genBleSecret` (line 9046)
- `crc16Cal` (line 17094)
- `package:new_pda/app/modules/skyline/core/mixins/ble_mixin.dart` (line 8979)
- `package:new_pda/app/modules/skyline/ble/controllers/ble_search_ctrl.dart` (line 4035)
- `EPD_WRITE_ERROR` and `EPD_INIT_ERROR` (lines 8881 and 20612)

These names alone do not prove that image uploads use CRC, encryption, or any particular pixel format. The public implementation provides those protocol details, to be checked against AOT disassembly and hardware.

## Public implementation: Bluetooth services

All UUIDs share suffix `-4c53-4545-4c42-4b4e494c4f57`.

| Prefix | Role | Operations |
| --- | --- | --- |
| `30323032` | WOLINK service | service discovery |
| `31323032` | Image data and refresh command | write with response |
| `32323032` | Version / product / hardware / display information | read |
| `33323032` | Authentication challenge and response | read then write with response |
| `34323032` | Status | notifications |
| `35323032` | Battery voltage, reportedly two-byte millivolts | read |

Evidence: `zhsunyco_esl/client.py:12-23`, `models.py:37-50`.

The public code discovers names starting `WL` and MAC prefixes `66:66:17:`. macOS returns a CoreBluetooth UUID in place of a MAC address, so library discovery should work by name and discovered BLEDevice object. The live device may omit service UUIDs in advertisements; do not require a service advertisement to include a candidate.

## Public implementation: authentication

1. Connect to the target and read the authentication characteristic.
2. Encrypt the challenge using AES-128 ECB, without padding.
3. Write the ciphertext back to the same authentication characteristic with response.

The authentication key is supplied through private runtime configuration and is
not included in this repository.

Evidence: `client.py:96-109`. Validate that the challenge has the expected complete AES block length. The reference code logs authentication success merely when the GATT write succeeds; a robust implementation should not imply independent authentication acknowledgement unless actually observed.

## Public implementation: image upload and refresh

Upload command bytes:

```text
00 A5 <offset_u32_le> <payload bytes>
```

The offset addresses the overall payload, which is either raw packed image bytes or the complete compressed container. The reference implementation uses 200 payload bytes per command (206 bytes total), write with response, and 30 ms spacing. Offset advances by payload length, excluding the six-byte command header. Chunk retries repeat the same offset.

Refresh command:

```text
01 A5 <total_raw_payload_length_u32_le>         # raw pixels
02 A5 <total_compressed_payload_length_u32_le>  # block compression
```

Evidence: `client.py:201-211`, `client.py:234-270`.

There is no explicit image CRC in this public upload implementation. BLE supplies link-layer integrity. AOT analysis below confirms `crc16Cal` belongs to a different transfer branch; do not add a checksum to WOLINK image commands.

The reference docstring at `client.py:129` incorrectly claims image data is written to `35323032`. The actual constants and writes consistently use `31323032`; `35323032` is the battery characteristic. Follow code and live GATT properties, not that stale comment.

## Public implementation: packed pixels and orientation

Every byte contains four pixels, most-significant pair first:

| Color | Two-bit code |
| --- | --- |
| Black | `00` |
| White | `01` |
| Yellow | `10` |
| Red | `11` |

Example black / white / yellow / red encodes as `0x1b`. An entirely white raw buffer contains `0x55` bytes.

Evidence: `client.py:138-196`.

Public profiles (not inferred automatically from live label):

| Profile | Logical size | Wire orientation |
| --- | --- | --- |
| BLE-290BWRY | 296 × 128 | column major with profile mirror + rotation |
| BLE-350BWRY | 384 × 184 | column major with vertical reversal |
| BLE-750BWRY | 800 × 480 | ordinary row major |

Evidence: `models.py:5-35`. For the 750 profile, bytes advance left to right across a row, then down. Raw buffer length is `width * height / 4`. Model identification and orientation require confirmation on the actual device; dimensions should not be guessed solely from name `WL...`.

## Public implementation: block compression

Partition raw pixels into consecutive blocks of at most 8192 bytes. Independently compress each block as raw DEFLATE (`wbits=-15`, reference uses compression level 9).

Container:

```text
A5 A6 <number_of_blocks_u8> 02
<block_index_u8> <compressed_length_u16_le> <raw_deflate_data>
<block_index_u8> <compressed_length_u16_le> <raw_deflate_data>
...
```

Block indices begin at 1. Length describes only the compressed data for that block. The number of blocks includes the final short block. There is no zlib header, footer, or CRC field. Payload length in the refresh command includes the four-byte container header and all three-byte per-block headers.

Evidence: `protocol.py:1-29`.

## Status and correctness cautions in the public implementation

The reference comments say byte 0 is BUSY and byte 1 is ERR, and it treats `ff 00 00 00 00 00 00 00` as refresh completion. However its callback sets the completion event on *every* status notification and only logs timeouts. It can therefore return apparent success on intermediate state or no refresh acknowledgement.

A new implementation should subscribe before refresh, preserve the actual status bytes, require a specifically recognized successful terminal status, raise on nonzero error or timeout, and clean up notification subscriptions on failure. A GATT upload acknowledgement alone does not prove that the physical panel has refreshed. Empty and truncated notifications must be handled without indexing errors.

Evidence: `client.py:215-229`, `client.py:273-285`.

## APK AOT verification (completed)

Blutter successfully generated annotated AOT assembly in `tmp/apk-analysis/aot/asm/`, plus `pp.txt` and `objs.txt`. A loader path issue was fixed locally by pointing the analysis executable at its workspace Capstone library. The supplied application was parsed and disassembled, not executed as an Android app.

### Exact characteristic selection and authentication

`asm/new_pda/app/utils/ble.dart`, closure at address `0x6cd9c0` (file line 2573), selects service 30323032 and all five characteristics by their full UUID. This independently confirms every role listed above, including 31323032 for data and 33323032 for auth.

`transceive` at `0x6cba7c` reads the 33323032 nonce at `0x6cbe38`, calls `genBleSecret` at `0x6cbe88`, and writes the result at `0x6cbe98` (file lines 472-515).

`asm/new_pda/app/utils/tools.dart`, `genBleSecret` at `0x6cd628` (line 770), constructs a 16-element integer key. The recovered key value is intentionally omitted from this public documentation.

The APK uses AES-CBC with an all-zero 16-byte IV and padding explicitly disabled. Evidence: `genBleSecret` constructs the zero IV at `0x6cd734-0x6cd748`, sets padding to null at `0x6cd754`, and the compiled AES constructor at `asm/encrypt/encrypt.dart:810` selects object `AESMode@87dc11`; `pp.txt:17973` identifies that object as `cbc`. For the actual **single 16-byte challenge**, CBC with zero IV produces exactly the same ciphertext as AES-ECB. Reject non-16-byte challenges rather than generalizing the ECB shortcut to arbitrary multi-block input.

### APK image transport

Immediately after authentication the APK sets upload payload capacity to `mtuNow - 9` (`ble.dart:517`, address `0x6cbeb0`). This subtracts the three-byte ATT write header and six-byte WOLINK command header. At observed MTU 247, that is 238 payload bytes; using a conservative 200 is also within the same limit.

The APK receives a list of prebuilt jobs. For job type strings `01-00-00-03`, `01-00-00-06`, and `01-00-00-0C`, it base64-decodes the supplied payload, sends sequential `00 A5 <offset_u32_le> <chunk>` commands, and finally sends `02 A5 <length_u32_le>`.

Evidence: `ble.dart`:

- job type recognition: lines 610-676, addresses `0x6cbfac-0x6cc050`;
- upload packet header and data concatenation: lines 761-839, addresses `0x6cc148-0x6cc20c`;
- refresh header `02 A5` and byte count: lines 898-962, addresses `0x6cc2b8-0x6cc358`.

There is no image pixel encoder or block compressor in this transport path: these bytes arrive prebuilt from the app's service/job flow. Consequently, APK transport analysis by itself cannot establish every model's resolution or orientation. The independent public protocol and physical display verification remain necessary for those details.

### Other job types and CRC scope

The APK does use `crc16Cal`, but only in its separate `01-00-00-01` job branch. That branch emits `07 A5`, delays, uploads with `05 A5 <offset_u32_le>`, and concludes with `06 A5 <length_u32_le> <crc_u16_le>`. This is consistent with a firmware transfer path, but its user-facing meaning was not conclusively established from these methods, and these commands should not be used for ordinary image updates.

`crc16Cal` uses the standard Modbus-style 0xA001 lookup tables, starts at 0xffff, and returns the two-byte CRC. No such call is made in the image branch. Evidence: `ble.dart:1455-1908`; `tools.dart:635-769`.

Other recovered transport branches include `01-00-00-09` → `04 A5`, `01-00-00-07` → a structured `08 A5` payload, `01-00-00-12` → `03 A5` transfer, and `01-00-00-13` → `09 A5` plus two payload bytes. Meanings remain unverified; do not expose these as named display actions based only on opcode guesses.

### Discovery and metadata, not resolution inference

The APK's `BleSearchCtrl::onBleScan` at `0x786e14`, file `asm/new_pda/app/modules/skyline/ble/controllers/ble_search_ctrl.dart:1352`, requires manufacturer ID 0xbbaa and a name beginning `WL`. The raw tagged map key is 96084, or actual integer 48042 (`0xbbaa`). It strips `WL` to obtain the label identifier. It formats manufacturer bytes 0-1 as a hex PID, bytes 2-7 as three hex byte-pairs separated by `/`, and collects battery information; it does not map those bytes to width and height in this method.

The info characteristic is likewise rendered as version information in `transceive`. Preserve the raw information instead of using it as an unsupported resolution lookup; similar version fields can occur across different panel sizes.

### APK error names

The application's `BleError` objects establish these error number labels (`ble.dart:2860`, `pp.txt:25264` onward):

| Code | Label |
| --- | --- |
| 0 | OK |
| 1 | EPD_INIT_ERROR |
| 2 | EPD_WRITE_ERROR |
| 3 | DECOMPRESS_ERROR |
| 4 | OTA_ERROR |
| 5 | UNLOCK ERROR |

Higher application errors include 50 connection, 51 missing device, 52 missing service, 100 acknowledgement, 999 retry, and 1100 no value. These are application labels, not proof that every value can occur in every status field. The APK transport's stored status characteristic is not used to validate an image refresh before it disconnects; robust client verification should rely on measured device status behaviour.
