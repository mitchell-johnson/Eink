"""Wire-format fixtures, independent of any existing client implementation."""

import zlib

import pytest

from eink_ble import protocol


def test_characteristic_uuids():
    suffix = "-4c53-4545-4c42-4b4e494c4f57"
    for prefix, name in enumerate(
        ["SERVICE_UUID", "DATA_UUID", "INFO_UUID", "AUTH_UUID", "STATUS_UUID", "BATTERY_UUID"]
    ):
        assert getattr(protocol, name) == f"3{prefix}323032{suffix}"


def test_aes_authentication_matches_nist_aes128_vector():
    # FIPS 197 Appendix C.1; verifies mode, padding and byte ordering.
    nonce = bytes.fromhex("00112233445566778899aabbccddeeff")
    key = bytes.fromhex("000102030405060708090a0b0c0d0e0f")
    assert protocol.authenticate_response(nonce, key) == bytes.fromhex(
        "69c4e0d86a7b0430d8cdb78070b4c55a"
    )


def test_authentication_requires_an_explicit_key():
    with pytest.raises(TypeError):
        protocol.authenticate_response(bytes(16))


@pytest.mark.parametrize("nonce,key", [(b"", b"x" * 16), (b"x" * 15, b"x" * 16), (b"x" * 32, b"x" * 16), (b"x" * 16, b"x" * 32)])
def test_authentication_rejects_incorrect_block_or_key_size(nonce, key):
    with pytest.raises(ValueError):
        protocol.authenticate_response(nonce, key)


def test_data_packet_uses_byte_offset_little_endian():
    assert protocol.data_packet(0x12345678, b"\xab\xcd") == bytes.fromhex(
        "00 a5 78 56 34 12 ab cd"
    )


@pytest.mark.parametrize("offset,payload", [(-1, b"a"), (2**32, b"a"), (2**32 - 1, b"a"), (0, b"")])
def test_data_packet_rejects_unrepresentable_or_empty_write(offset, payload):
    with pytest.raises(ValueError):
        protocol.data_packet(offset, payload)


def test_refresh_packet_uses_transmitted_length_and_compression_opcode():
    assert protocol.refresh_packet(0x12345678) == bytes.fromhex("02 a5 78 56 34 12")
    assert protocol.refresh_packet(513, compressed=False) == bytes.fromhex("01 a5 01 02 00 00")


@pytest.mark.parametrize("size", [-1, 0, 2**32])
def test_refresh_rejects_invalid_size(size):
    with pytest.raises(ValueError):
        protocol.refresh_packet(size)


def _independent_unpack_blocks(wire):
    assert wire[:2] == b"\xa5\xa6"
    assert wire[3] == 2
    cursor, blocks = 4, []
    for expected_index in range(1, wire[2] + 1):
        assert wire[cursor] == expected_index
        length = wire[cursor + 1] + 256 * wire[cursor + 2]
        cursor += 3
        inflater = zlib.decompressobj(wbits=-15)
        block = inflater.decompress(wire[cursor : cursor + length])
        assert inflater.eof
        assert not inflater.unused_data
        blocks.append(block)
        cursor += length
    assert cursor == len(wire)
    return blocks


@pytest.mark.parametrize("size", [1, 8191, 8192, 8193, 16384, 16385])
def test_block_compression_can_be_independently_decoded(size):
    original = bytes((n * 19 + n // 256) % 256 for n in range(size))
    wire = protocol.compress_image(original)
    blocks = _independent_unpack_blocks(wire)
    assert b"".join(blocks) == original
    assert all(len(block) == 8192 for block in blocks[:-1])
    assert len(blocks[-1]) == (size - 1) % 8192 + 1


@pytest.mark.parametrize("size", [0, 8192 * 255 + 1])
def test_compression_rejects_empty_and_unrepresentable_block_count(size):
    with pytest.raises(ValueError):
        protocol.compress_image(b"x" * size)


@pytest.mark.parametrize(
    "wire,busy,completed,error",
    [(b"\x00\x00", False, False, 0), (b"\x01\x00", True, False, 0), (b"\x06\x00", False, False, 0), (b"\x07\x00", True, False, 0), (b"\xff\x00\x00", False, True, 0), (b"\x00\x03", False, False, 3), (b"\xff\x03", False, False, 3)],
)
def test_status_distinguishes_busy_idle_success_and_error(wire, busy, completed, error):
    status = protocol.parse_status(wire)
    assert status.raw == wire
    assert (status.busy, status.completed, status.error) == (busy, completed, error)


@pytest.mark.parametrize("wire", [b"", b"\x00", b"\x01", b"\xff"])
def test_status_rejects_truncated_state(wire):
    with pytest.raises(ValueError):
        protocol.parse_status(wire)
