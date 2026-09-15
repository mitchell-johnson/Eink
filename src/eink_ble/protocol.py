"""Pure encoders for the WoLink BLE image-transfer wire protocol.

No Android application or web service participates in these operations.
"""

from dataclasses import dataclass
import zlib

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes


SERVICE_UUID = "30323032-4c53-4545-4c42-4b4e494c4f57"
DATA_UUID = "31323032-4c53-4545-4c42-4b4e494c4f57"
INFO_UUID = "32323032-4c53-4545-4c42-4b4e494c4f57"
AUTH_UUID = "33323032-4c53-4545-4c42-4b4e494c4f57"
STATUS_UUID = "34323032-4c53-4545-4c42-4b4e494c4f57"
BATTERY_UUID = "35323032-4c53-4545-4c42-4b4e494c4f57"

BLOCK_SIZE = 8192
MAX_IMAGE_SIZE = BLOCK_SIZE * 255


def authenticate_response(nonce: bytes, key: bytes) -> bytes:
    """Encrypt the label's 16-byte challenge using AES-128-ECB, without padding."""
    if len(nonce) != 16 or len(key) != 16:
        raise ValueError("Authentication requires a 16-byte nonce and a 16-byte key")
    encryptor = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
    return encryptor.update(nonce) + encryptor.finalize()


def data_packet(offset: int, payload: bytes) -> bytes:
    """Frame one image fragment with its byte offset in the transmitted payload."""
    if not payload:
        raise ValueError("Image fragment must not be empty")
    if not 0 <= offset <= 0xFFFFFFFF or offset + len(payload) > 0xFFFFFFFF:
        raise ValueError("Fragment falls outside the 32-bit image address space")
    return b"\x00\xa5" + offset.to_bytes(4, "little") + payload


def refresh_packet(size: int, compressed: bool = True) -> bytes:
    """Request a refresh using the transmitted size, including compression headers."""
    if not 1 <= size <= 0xFFFFFFFF:
        raise ValueError("Image size must be between 1 and 4294967295 bytes")
    return bytes((2 if compressed else 1, 0xA5)) + size.to_bytes(4, "little")


def compress_image(raw: bytes) -> bytes:
    """Encode 8192-byte blocks as independent raw-DEFLATE streams.

    The four-byte header is A5 A6, a one-byte block count, and format 02.
    Every block starts with a one-based index and a little-endian uint16
    compressed length. The last block may contain fewer than 8192 raw bytes.
    """
    if not 1 <= len(raw) <= MAX_IMAGE_SIZE:
        raise ValueError(f"Raw image must contain 1 to {MAX_IMAGE_SIZE} bytes")
    count = (len(raw) + BLOCK_SIZE - 1) // BLOCK_SIZE
    encoded = bytearray((0xA5, 0xA6, count, 2))
    for number in range(count):
        start = number * BLOCK_SIZE
        compressor = zlib.compressobj(level=9, wbits=-15)
        block = compressor.compress(raw[start : start + BLOCK_SIZE]) + compressor.flush()
        encoded.extend(bytes((number + 1,)) + len(block).to_bytes(2, "little"))
        encoded.extend(block)
    return bytes(encoded)


@dataclass(frozen=True)
class Status:
    """A status notification; an idle read alone does not prove refresh completion."""

    raw: bytes
    busy: bool
    completed: bool
    error: int


def parse_status(data: bytes) -> Status:
    """Decode busy bit 0 and the error byte, retaining firmware-specific flags.

    FF with error 0 is an observed explicit completion notification. Other
    status bits can indicate authentication state and are preserved in ``raw``.
    """
    if len(data) < 2:
        raise ValueError("A status notification must contain at least two bytes")
    flags, error = data[:2]
    return Status(
        raw=bytes(data),
        busy=flags != 0xFF and bool(flags & 1),
        completed=flags == 0xFF and error == 0,
        error=error,
    )
