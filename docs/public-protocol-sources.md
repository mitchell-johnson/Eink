# Public Wolink protocol evidence

Research date: 2026-09-13. This note records public interoperability facts;
the connected label must still confirm its own resolution, orientation, and
successful refresh. No supplier account or web service was accessed.

## Sources and provenance

1. [TheUI/WoPda releases](https://github.com/TheUI/WoPda/releases) is the
   supplier-linked Android distribution. Its repository contains only a README,
   so it is not a public Dart source release. Repository revision inspected:
   `74db715c2a45cec1fb1cbb98261d61ab22d52b64`.
2. [zitroaen protocol reference](https://github.com/zitroaen/BLE-ESL-BWRY/blob/e6705737c63a7f61e0c7dcd26ca14585a7f6d418/docs/protocol.md)
   and [measurement record](https://github.com/zitroaen/BLE-ESL-BWRY/blob/e6705737c63a7f61e0c7dcd26ca14585a7f6d418/docs/hardware-verified-findings.md)
   are first-person hardware observations of a BLE-350BWRY. The author marks
   measured facts, vendor-document claims, and assumptions separately. The
   repository is MIT licensed; the links are pinned to the inspected revision.
3. [shorti1996 Wolink integration](https://github.com/shorti1996/zhsunyco-esl-wolink/tree/775082955d7bca8c5fb0f0c9ae7864caa6d13759)
   contains a complete direct-BLE Python implementation inside
   `zhsunyco_esl-0.2.14-py3-none-any.whl`. It independently supplies the same
   authentication, image upload and compression layout. Wheel metadata says
   MIT, but its actual bundled LICENSE and repository say GPLv3; do not assume
   copied implementation code is permissively licensed. Protocol facts below
   are also documented by source 2. Its named source monorepo returned 404.
4. [roxburghm protocol V2](https://github.com/roxburghm/zhsunyco-esl/blob/85c590882d0fa918e2731588ad74e0eab7717ed2/PROTOCOL-V2.md)
   describes a different, older easyTag family, with service UUID `00001523-...`,
   XOR and CRC framing. It does not apply to newer Wolink GATT devices. Its
   deprecated V1 document also has corrected CRC and pixel-polarity errors.

## Facts corroborated across newer Wolink implementations

All UUIDs share suffix `-4c53-4545-4c42-4b4e494c4f57`:

| UUID prefix | Purpose |
| --- | --- |
| `30323032` | Custom service |
| `31323032` | Command/data, read and write with response |
| `32323032` | Version, read and notify |
| `33323032` | Authentication, read and write with response |
| `34323032` | Status, read and notify |
| `35323032` | Battery, read and notify |

Authenticate each new connection by reading the 16-byte challenge, encrypting
one block using AES-128-ECB with the privately configured authentication key,
then writing the ciphertext back. Source 2
measured status byte 0 changing from `06` (locked) to `00` (unlocked). The key value is intentionally omitted from this repository.

Upload packets are `00 a5`, followed by a four-byte little-endian byte offset,
then image bytes. Both sources use writes with response; 180-200 data bytes
per packet and 20-30 ms spacing worked on their hardware. Refresh is `01 a5`
plus four-byte little-endian raw payload size, or `02 a5` plus compressed
payload size. Neither command includes the image width or height.

Four-color pixels are packed MSB first, four pixels per byte: black=0,
white=1, yellow=2, red=3. Uniform color bytes are respectively `00`, `55`,
`aa`, `ff`. Short panels may require transposition/rotation; 7.5-inch uses
the long axis as each wire row. See limitations below.

Block compression is raw DEFLATE, independent blocks of at most 8192 input
bytes: `a5 a6 <block-count> 02`, then, per block,
`<1-based-index> <compressed-length:uint16LE> <raw-deflate>`. The compressed
payload includes this whole wrapper. Raw mode avoids compression expansion.

## Measurement details that matter

- Source 2 reports completion notification `ff 00 00 00 00 00 00 00` after
  actual refresh. Ordinary status polling uses bit 0 of byte 0 for busy,
  bits 1/2 for locked, and byte 1 for an error code. Observe busy rising and
  falling or the explicit completion notification; an accepted GATT write
  alone is not evidence that the display changed. The wheel's implementation
  incorrectly treats any notification as enough to unblock its wait and
  only logs a timeout, so its success path should not be copied uncritically.
- Error byte codes: 0 none, 1 panel initialization, 2 panel write,
  3 decompression, 4 OTA, 5 unlock failure. A rejected command may revoke
  authentication and disconnect. Use a fresh connection after rejection.
- Source 2 used a one-second settle after connection and subscribed to
  status notifications before authentication; then verified unlocked status.
  It allows half a second after unlock and before refresh. These timings
  are working values, not proven minima.
- Advertising is sparse: active scans at 20 cm sometimes needed 90-135
  seconds, and one period after transfer exceeded 120 seconds. Their
  implementation waits up to 300 seconds for a fresh advertisement and
  connects in its short window. One active connection hides the label from
  other scanners. No remotely commanded wake/sleep-mode switch was found.
- The first eight manufacturer-data bytes under company ID `0xBBAA` are
  four little-endian uint16 values: PID, app, hardware and display versions.
  The next two bytes are battery millivolts **big endian**. In contrast,
  the battery GATT characteristic is millivolts **little endian**.

## Dimensions and orientation

Device names identify individual labels; they do not establish panel dimensions.
Version and manufacturer fields are also insufficient to infer resolution.
Choose the dimensions from the physical model and verify a border and asymmetric
corner markers across the whole panel after writing.

Source 3 provides these image orientations:

| Model | Physical dimensions | Wire layout reported |
| --- | --- | --- |
| BLE-290BWRY | 296 x 128 | column-major, clockwise rotation, horizontal mirror |
| BLE-350BWRY | 384 x 184 | column-major, counterclockwise rotation |
| BLE-750BWRY | 800 x 480 | ordinary row-major |

### 4.2-inch target: additional verified orientation report

[shorti1996 issue 3](https://github.com/shorti1996/zhsunyco-esl-wolink/issues/3)
reports a hardware-tested `420-4-BLE`: 400 × 300, ordinary row-major order,
without mirroring or rotation. Column-major upload produced sheared vertical
bands despite transport acknowledgement. The `420` profile in this repository
was also verified on a physical 4.2-inch display with four-color blocks, a border
and asymmetric corner labels. Other models still need their own verification.

The [BLE-420BWRY product page](https://ko.dyesl.com/products/ble-420bwry)
independently specifies a 400x300 black/white/red/yellow screen, but does not
document pixel transmission order.

Source 2's other model sizes are attributed to a vendor product sheet, with
orientation unverified: 1.54 inch 200x200; 2.13 inch 250x128; 2.66 inch
296x152; 3.7 inch 416x240; 4.2 inch 400x300; 5.83 inch 648x480. The 4.2-inch
orientation now has the additional first-person evidence above. No public
primary vendor SDK or directly retrievable BLE Display API rev 1.5 document
was found in this search. Source 2 references that document but is not the
vendor itself.

## Other content-related commands

Source 2 measured `08 a5` followed by R, G, B, on-ms uint16LE, off-ms
uint16LE, and work-ms uint32LE for the LED. Work-ms zero turns it off.
`04 a5` clears the panel but the vendor description also calls it unbind,
so uploading a blank bitmap has clearer scope when only blanking is wanted.

Multi-image storage `03 a5` and two-screen selection `09 a5` are vendor-doc
claims, not hardware-verified in these sources. Selection has two signed
index bytes: -2 clear, -1 unchanged, 0..10 stored slot. The six-byte slot
header syntax remains ambiguous. OTA commands `05/06/07 a5` are unrelated to
content control and unnecessary for this task.
