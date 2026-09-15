"""Configuration tests use synthetic keys and never contact real hardware."""
import pytest

from eink_ble.client import Label
from eink_ble.configuration import load_authentication_key


@pytest.fixture(autouse=True)
def no_real_configuration(monkeypatch):
    monkeypatch.delenv("EINK_BLE_KEY_HEX", raising=False)
    monkeypatch.delenv("EINK_BLE_KEY_FILE", raising=False)


def test_missing_key_has_actionable_error():
    with pytest.raises(ValueError, match="EINK_BLE_KEY_FILE"):
        load_authentication_key()


def test_key_file_is_read_without_exposing_contents(tmp_path, monkeypatch):
    path = tmp_path / "label.key"
    path.write_text(bytes(range(16)).hex() + "\n")
    monkeypatch.setenv("EINK_BLE_KEY_FILE", str(path))
    assert load_authentication_key() == bytes(range(16))


def test_explicit_key_overrides_environment(monkeypatch):
    monkeypatch.setenv("EINK_BLE_KEY_HEX", "invalid")
    assert load_authentication_key(bytes(range(16))) == bytes(range(16))


@pytest.mark.parametrize("value", ["", "1234", "xx" * 16, "0 " * 16, "0" * 64])
def test_invalid_configuration_is_redacted(value, monkeypatch):
    monkeypatch.setenv("EINK_BLE_KEY_HEX", value)
    with pytest.raises(ValueError, match="32 hexadecimal") as error:
        load_authentication_key()
    assert str(error.value) == "The Bluetooth authentication key must contain exactly 32 hexadecimal characters"


@pytest.mark.asyncio
async def test_missing_key_fails_before_bluetooth():
    def unexpected_client(_):
        pytest.fail("Bluetooth must not be contacted without an authentication key")
    with pytest.raises(ValueError, match="EINK_BLE_KEY_FILE"):
        await Label("WL00000000", client_factory=unexpected_client).connect()
