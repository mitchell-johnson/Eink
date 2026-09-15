"""Load device credentials from the caller or private local configuration."""
import os
from pathlib import Path
import re


def load_authentication_key(explicit: bytes | None = None) -> bytes:
    """Resolve an AES-128 key without embedding a supplier/device default.

    Explicit bytes take precedence, then EINK_BLE_KEY_FILE (32 hex characters),
    then EINK_BLE_KEY_HEX. Nothing in this function logs credential values.
    """
    if explicit is not None:
        if not isinstance(explicit, bytes) or len(explicit) != 16:
            raise ValueError("The Bluetooth authentication key must be exactly 16 bytes")
        return explicit
    filename = os.environ.get("EINK_BLE_KEY_FILE")
    if filename:
        try:
            value = Path(filename).read_text(encoding="ascii").strip()
        except (OSError, UnicodeError):
            raise ValueError("Unable to read the private EINK_BLE_KEY_FILE") from None
    else:
        value = os.environ.get("EINK_BLE_KEY_HEX")
        if value is None:
            raise ValueError("Configure EINK_BLE_KEY_FILE or EINK_BLE_KEY_HEX, or pass authentication_key, before connecting")
        value = value.strip()
    if re.fullmatch(r"[0-9a-fA-F]{32}", value) is None:
        raise ValueError("The Bluetooth authentication key must contain exactly 32 hexadecimal characters")
    return bytes.fromhex(value)
