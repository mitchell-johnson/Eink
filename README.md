# Eink

Control WoLink Bluetooth e-paper labels from Python or the Label Studio iOS app.
The Python library renders complete images locally and sends them directly over
Bluetooth. The iOS app can also generate artwork using GPT Image 2.5 through a
private Cloudflare backend, preview it, and write it to the label.

The verified display profile is **4.2 inches, 400 × 300 pixels**, using black,
white, yellow and red. Every update replaces the full display. The repository
contains source and synthetic test fixtures; credentials, device identities,
private deployment records and supplier files are excluded.

- [Python example](examples/custom_image.py)
- [iOS app setup](ios/README.md)
- [Private image service setup](backend/README.md)
- [Protocol evidence](docs/apk-protocol.md) and [public references](docs/public-protocol-sources.md)

## Python setup

Python 3.11 or newer:

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e '.[test]'
```

On macOS, allow Bluetooth access for your terminal or application when prompted.
macOS uses a local UUID for Bluetooth devices; a discovered WoLink name also works.

Bluetooth connections require the label's 16-byte authentication key. Obtain the
correct key from your supplier or authorized device configuration. Save its 32
hexadecimal characters in a private file outside this repository, restrict that
file to your user, then configure its path:

```sh
export EINK_BLE_KEY_FILE="$HOME/.config/eink/label-key.hex"
chmod 600 "$EINK_BLE_KEY_FILE"
```

Alternatively, supply `EINK_BLE_KEY_HEX` through your secret manager, or pass
`authentication_key` as 16 bytes to `Label`. An explicit key takes precedence,
then the key file, then the environment value. Key contents are never included
in configuration errors. No authentication key is distributed with this code.
Scanning and offline rendering do not require a key.

## Command line

Discover the label, then set `LABEL_DEVICE` to the name or address from the scan:

```sh
eink-ble scan --timeout 300
export LABEL_DEVICE='WL00000000'  # Replace this synthetic example with your scan result.
eink-ble info --device "$LABEL_DEVICE"
eink-ble demo --profile 420 --output demo.png
eink-ble demo --profile 420 --device "$LABEL_DEVICE"
eink-ble image picture.png --profile 420 --device "$LABEL_DEVICE"
eink-ble text 'Hello from Python' --profile 420 --device "$LABEL_DEVICE"
eink-ble clear --profile 420 --device "$LABEL_DEVICE"
```

`--profile 420` selects 400 × 300 pixels in ordinary row-major order.
`--layout row`, `--layout columns-reversed-x`, `--layout columns-reversed-y`,
and `--mirror` allow different panel orientations. Other dimensions require both
`--width` and `--height`; verify them on the physical panel.

Use `--output preview.png` without `--device` for an offline preview. Image fitting
defaults to containing the whole image on white; `--fit cover` crops to fill and
`--fit stretch` resizes to exact dimensions. Optional `--dither`,
`--colors BW|BWR|BWRY`, `--rotate`, and `--font /path/to/font.ttf` control rendering.
BW and BWR restrict the palette on a four-color panel; native one-bit-only panel
protocols are not implemented.

## Python API

```python
import asyncio
import os
from PIL import Image, ImageDraw
from eink_ble import DisplayProfile, Label

async def main():
    profile = DisplayProfile(400, 300)
    image = Image.new("RGB", (400, 300), "white")
    draw = ImageDraw.Draw(image)
    draw.text((20, 20), "Made entirely in Python", fill="black")
    draw.rectangle((20, 70, 180, 140), fill="red")
    draw.ellipse((220, 70, 300, 150), fill="yellow")
    async with Label(os.environ["LABEL_DEVICE"]) as label:
        print(await label.info())
        print(await label.display(image, profile))

asyncio.run(main())
```

Any Pillow image works: text, drawings, photographs, charts, or barcodes generated
by your preferred library. RGB input is quantized to the four panel colors.
`clear()` sends a white image without issuing the vendor's unbind command.

## Connection and refresh handling

Labels advertise intermittently; allow up to five minutes for discovery. A new
connection waits for a fresh advertisement and keeps scanning active through
authentication. Keep other apps disconnected from the label.

Transfers validate authentication, use writes with response, and wait for an
explicit refresh-complete notification or an observed BUSY-to-idle transition.
A disconnect or timeout after upload raises `RefreshTimeout`: the panel may still
change, but completion could not be confirmed. Inspect it before retrying. Async
context managers clean up Bluetooth connections on errors and cancellation.

Only the original WoLink service `30323032-4c53-4545-4c42-4b4e494c4f57` is supported.
Other Zhsunyco/easyTag firmware families may be incompatible. This protocol does
not report display resolution. Firmware flashing and unverified multi-screen
commands are outside the library's scope.

## Verification and public configuration

```sh
python -m pytest -q
```

Backend and iOS test instructions are in their respective READMEs. Tests use
synthetic credentials and public cryptographic test vectors, with no paid API
calls. Public Bluetooth service UUIDs and wire-protocol constants are required
for interoperability; they are not identifiers for a particular device or account.

Keep keys, signing material, device IDs and service URLs in private local
configuration. The ignore rules exclude common secret files, local Xcode
configuration, build products and downloaded supplier artifacts. Inspect staged
changes and run a secret scanner before publishing future changes.
