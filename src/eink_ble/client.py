"""Direct WoLink BLE discovery, authentication and acknowledged image transfers."""
from __future__ import annotations

import asyncio
import logging
import math
import re
import struct
from dataclasses import dataclass, field
from typing import Any, Callable

from bleak import BleakClient, BleakScanner
from PIL import Image

from .configuration import load_authentication_key

from .protocol import (
    AUTH_UUID, BATTERY_UUID, DATA_UUID, INFO_UUID, SERVICE_UUID, STATUS_UUID,
    authenticate_response, compress_image, data_packet, parse_status, refresh_packet,
)
from .render import DisplayProfile, pack_image, prepare_image

log = logging.getLogger(__name__)


class LabelError(RuntimeError):
    """The label rejected an operation or cannot safely perform it."""


class RefreshTimeout(LabelError):
    """The image was sent, but physical refresh completion was not confirmed."""


@dataclass(frozen=True)
class DiscoveredLabel:
    address: str
    name: str
    rssi: int
    product_id: int | None = None
    application_version: int | None = None
    hardware_version: int | None = None
    display_id: int | None = None
    battery_mv: int | None = None
    device: Any = field(default=None, repr=False, compare=False)


@dataclass(frozen=True)
class DeviceInfo:
    product_id: int
    application_version: int
    hardware_version: int
    display_id: int
    battery_mv: int
    raw_version: bytes
    raw_status: bytes


@dataclass(frozen=True)
class TransferResult:
    raw_bytes: int
    transmitted_bytes: int
    compressed: bool
    completed: bool
    confirmation: str


def _positive(value: float, name: str) -> float:
    if not math.isfinite(value) or value <= 0:
        raise ValueError(f"{name} must be positive and finite")
    return value


def parse_advertisement(device: Any, advertisement: Any) -> DiscoveredLabel | None:
    """Recognise WoLink advertisements without probing unrelated peripherals."""
    name = advertisement.local_name or device.name or ""
    uuids = {u.lower() for u in advertisement.service_uuids}
    manufacturer = advertisement.manufacturer_data.get(0xBBAA, b"")
    if not (re.fullmatch(r"WL[0-9a-fA-F]{8}", name) or SERVICE_UUID in uuids):
        return None
    values: tuple = (None,) * 5
    if len(manufacturer) >= 10:
        values = (*struct.unpack("<4H", manufacturer[:8]), int.from_bytes(manufacturer[8:10], "big"))
    return DiscoveredLabel(device.address, name, advertisement.rssi, *values, device=device)


async def scan(timeout: float = 30) -> list[DiscoveredLabel]:
    """List nearby WoLink labels. Sparse advertising may require 300 seconds."""
    _positive(timeout, "timeout")
    found = await BleakScanner.discover(timeout=timeout, return_adv=True)
    labels = [label for device, adv in found.values() if (label := parse_advertisement(device, adv))]
    return sorted(labels, key=lambda label: label.rssi, reverse=True)


def _matches(identifier: str, device: Any, adv: Any) -> bool:
    target = identifier.casefold()
    label = parse_advertisement(device, adv)
    return label is not None and target in (device.address.casefold(), label.name.casefold(), label.name[2:].casefold())


class Label:
    """An async connection to one label; always use ``async with Label(...)``.

    Pass a name returned by scan(), its eight-digit ID, a macOS Bluetooth
    UUID or a Linux/Windows Bluetooth MAC. A fresh advertisement is used for
    every connection, because these labels have short connection windows.
    """

    def __init__(self, address: str | DiscoveredLabel, *, scan_timeout: float = 300,
                 connect_timeout: float = 30, operation_timeout: float = 15,
                 client_factory: Callable | None = None,
                 authentication_key: bytes | None = None):
        self.address = address.address if isinstance(address, DiscoveredLabel) else address
        if not isinstance(self.address, str) or not self.address.strip():
            raise ValueError("A label name or address is required")
        self.scan_timeout = _positive(scan_timeout, "scan_timeout")
        self.connect_timeout = _positive(connect_timeout, "connect_timeout")
        self.operation_timeout = _positive(operation_timeout, "operation_timeout")
        self._factory = client_factory
        self._authentication_key = authentication_key
        self._client = None
        self._lock = asyncio.Lock()

    async def _op(self, awaitable):
        return await asyncio.wait_for(awaitable, self.operation_timeout)

    async def __aenter__(self):
        await self.connect()
        return self

    async def __aexit__(self, exc_type, exc, traceback):
        await self.disconnect()

    async def connect(self):
        if self._client is not None:
            raise LabelError("This Label already has a connection; use a separate context after disconnecting")
        self._authentication_key = load_authentication_key(self._authentication_key)
        if self._factory:
            client = self._factory(self.address)
            await self._open(client)
        else:
            log.info("Waiting for %s to advertise (up to %gs)", self.address, self.scan_timeout)
            found = asyncio.get_running_loop().create_future()

            def discovered(device, adv):
                if not found.done() and _matches(self.address, device, adv):
                    platform_data = getattr(adv, "platform_data", ())
                    if len(platform_data) > 1 and hasattr(platform_data[1], "get"):
                        if platform_data[1].get("kCBAdvDataIsConnectable") == 0:
                            return
                    found.set_result(device)

            # On the tested label, stopping discovery before connecting often
            # misses its short connection window. Keep it active through auth.
            try:
                async with BleakScanner(detection_callback=discovered):
                    try:
                        device = await asyncio.wait_for(found, self.scan_timeout)
                    except TimeoutError as exc:
                        raise LabelError(f"Label {self.address} did not advertise within {self.scan_timeout:g}s; keep it nearby and disconnect other apps") from exc
                    await self._open(BleakClient(device))
            except BaseException:
                # __aenter__ on Label has not completed, so its __aexit__ will
                # not run if stopping the scanner fails after we connected.
                await self.disconnect()
                raise

    async def _open(self, client):
        self._client = client
        try:
            await asyncio.wait_for(client.connect(timeout=self.connect_timeout), self.connect_timeout + 1)
            if client.services.get_service(SERVICE_UUID) is None:
                raise LabelError("Device does not expose the supported WoLink service")
            nonce = bytes(await self._op(client.read_gatt_char(AUTH_UUID)))
            await self._op(client.write_gatt_char(AUTH_UUID, authenticate_response(nonce, self._authentication_key), response=True))
            status = bytes(await self._op(client.read_gatt_char(STATUS_UUID)))
            parsed = parse_status(status)
            if (status[0] != 0xFF and status[0] & 0x06) or parsed.error:
                raise LabelError(f"Label authentication failed (status {status[:2].hex()})")
            await asyncio.sleep(0.5)
            log.info("Connected and authenticated")
        except TimeoutError as exc:
            await self.disconnect()
            raise LabelError(f"Bluetooth connection or authentication timed out for {self.address}; no image was sent") from exc
        except BaseException:
            await self.disconnect()
            raise

    async def disconnect(self):
        client, self._client = self._client, None
        if client is not None:
            try:
                await asyncio.wait_for(client.disconnect(), self.operation_timeout)
            except Exception:
                log.debug("Disconnect cleanup failed", exc_info=True)

    def _connected(self):
        if self._client is None or not self._client.is_connected:
            raise LabelError("Label is disconnected; open it with 'async with Label(...)'")
        return self._client

    async def info(self) -> DeviceInfo:
        async with self._lock:
            client = self._connected()
            version = bytes(await self._op(client.read_gatt_char(INFO_UUID)))
            battery = bytes(await self._op(client.read_gatt_char(BATTERY_UUID)))
            status = bytes(await self._op(client.read_gatt_char(STATUS_UUID)))
            if len(version) != 8 or len(battery) != 2:
                raise LabelError("Unexpected device information length")
            return DeviceInfo(*struct.unpack("<4H", version), int.from_bytes(battery, "little"), version, status)

    async def display(self, image: Image.Image, profile: DisplayProfile, *, fit: str = "contain",
                      dither: bool = False, compress: bool = True, refresh_timeout: float = 60,
                      progress: Callable[[int, int], None] | None = None) -> TransferResult:
        """Replace every pixel; require a completion notification or BUSY cycle.

        A disconnect or timeout after the refresh command leaves the physical
        outcome uncertain and raises an error, even if the display later updates.
        ``progress(sent, total)`` describes bytes uploaded, not physical refresh.
        """
        _positive(refresh_timeout, "refresh_timeout")
        prepared = prepare_image(image, profile, fit=fit, dither=dither)
        raw = pack_image(prepared, profile)
        encoded = compress_image(raw) if compress else raw
        compressed = compress and len(encoded) < len(raw)
        payload = encoded if compressed else raw
        async with self._lock:
            client = self._connected()
            before = parse_status(bytes(await self._op(client.read_gatt_char(STATUS_UUID))))
            if before.error or before.busy:
                raise LabelError(f"Label is busy or has an error ({before.error}); wait before uploading")
            events: asyncio.Queue[bytes] = asyncio.Queue()
            armed = False

            def notification(_characteristic, data):
                if armed:
                    events.put_nowait(bytes(data))

            await self._op(client.start_notify(STATUS_UUID, notification))
            try:
                # 180-byte payloads have been measured reliable at MTU 247.
                # Keep the whole ATT write within the negotiated MTU.
                chunk_size = min(180, client.mtu_size - 3 - 6)
                if chunk_size <= 0:
                    raise LabelError("Bluetooth MTU is too small for the image command")
                for offset in range(0, len(payload), chunk_size):
                    chunk = payload[offset:offset + chunk_size]
                    await self._op(client.write_gatt_char(DATA_UUID, data_packet(offset, chunk), response=True))
                    if progress:
                        progress(offset + len(chunk), len(payload))
                    await asyncio.sleep(0.02)
                await asyncio.sleep(0.5)
                armed = True
                try:
                    await self._op(client.write_gatt_char(DATA_UUID, refresh_packet(len(payload), compressed=compressed), response=True))
                except Exception as exc:
                    raise RefreshTimeout("Refresh command may have reached the label, but its acknowledgement was lost; inspect the panel before retrying") from exc
                confirmation = await self._wait_refresh(client, events, refresh_timeout)
                return TransferResult(len(raw), len(payload), compressed, True, confirmation)
            finally:
                if client.is_connected:
                    try:
                        await self._op(client.stop_notify(STATUS_UUID))
                    except Exception:
                        log.debug("Notification cleanup failed", exc_info=True)

    async def _wait_refresh(self, client, events: asyncio.Queue, timeout: float) -> str:
        deadline = asyncio.get_running_loop().time() + timeout
        saw_busy = False
        while True:
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0 and events.empty():
                raise RefreshTimeout("Image uploaded, but display refresh completion was not confirmed; inspect the panel before retrying")
            try:
                if events.empty():
                    data = await asyncio.wait_for(events.get(), min(0.3, remaining))
                else:
                    data = events.get_nowait()
                from_notification = True
            except TimeoutError:
                if not client.is_connected:
                    raise RefreshTimeout("Label disconnected after upload; display refresh completion is unconfirmed")
                remaining = deadline - asyncio.get_running_loop().time()
                if remaining <= 0:
                    continue
                try:
                    data = bytes(await asyncio.wait_for(client.read_gatt_char(STATUS_UUID), min(self.operation_timeout, remaining)))
                    from_notification = False
                except Exception as exc:
                    if events.empty():
                        raise RefreshTimeout("Cannot read refresh status; the display may still update") from exc
                    # A completion can arrive while the read fails/disconnects.
                    # Examine that evidence before declaring the result unknown.
                    data = events.get_nowait()
                    from_notification = True
            try:
                status = parse_status(data)
            except ValueError:
                log.debug("Ignoring malformed status: %s", data.hex())
                continue
            if status.error:
                raise LabelError(f"Label reported error {status.error} during refresh")
            if status.completed:
                if from_notification:
                    return "completion notification"
                # FF is only established as a terminal *notification*. A stale
                # read cannot prove this upload was acted upon.
                continue
            if data[0] & 0x06:
                raise LabelError("Label authentication was revoked during refresh")
            if status.busy:
                saw_busy = True
            elif saw_busy:
                return "busy-to-idle status transition"

    async def clear(self, profile: DisplayProfile, **kwargs) -> TransferResult:
        """Display a white image without changing device binding/settings."""
        return await self.display(Image.new("RGB", (profile.width, profile.height), "white"), profile, **kwargs)
