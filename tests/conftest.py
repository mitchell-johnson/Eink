"""Never use host credentials for tests; this key is synthetic test data."""
import pytest


@pytest.fixture(autouse=True)
def synthetic_bluetooth_key(monkeypatch):
    monkeypatch.delenv("EINK_BLE_KEY_FILE", raising=False)
    monkeypatch.setenv("EINK_BLE_KEY_HEX", bytes(range(16)).hex())
