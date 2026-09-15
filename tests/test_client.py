import asyncio
from types import SimpleNamespace

import pytest
from PIL import Image

from eink_ble.client import Label, LabelError, RefreshTimeout, parse_advertisement
from eink_ble.protocol import AUTH_UUID, DATA_UUID, INFO_UUID, STATUS_UUID, BATTERY_UUID, SERVICE_UUID
from eink_ble.render import DisplayProfile


class FakeDevice:
    def __init__(self, *, notifications=None, auth_status=b"\x00\x00", upload_error=False):
        self.is_connected = False
        self.mtu_size = 247
        self.services = SimpleNamespace(get_service=lambda uuid: object() if uuid == SERVICE_UUID else None)
        self.auth_status = auth_status
        self.upload_error = upload_error
        self.notifications = [bytes.fromhex("ff00000000000000")] if notifications is None else notifications
        self.writes = []
        self.reads = []
        self.stopped = False
        self.callback = None

    async def connect(self, **kwargs): self.is_connected = True
    async def disconnect(self): self.is_connected = False
    async def read_gatt_char(self, uuid):
        self.reads.append(uuid)
        return {AUTH_UUID: bytes(16), STATUS_UUID: self.auth_status,
                INFO_UUID: bytes.fromhex("3000000e03300401"), BATTERY_UUID: bytes.fromhex("0beb")}[uuid]
    async def write_gatt_char(self, uuid, value, *, response):
        assert response is True
        self.writes.append((uuid, bytes(value)))
        if uuid == DATA_UUID and value[:2] == b"\x00\xa5" and self.upload_error:
            raise OSError("link lost")
        if uuid == DATA_UUID and value[:2] in (b"\x01\xa5", b"\x02\xa5"):
            for message in self.notifications:
                self.callback(None, bytearray(message))
    async def start_notify(self, uuid, callback): self.callback = callback
    async def stop_notify(self, uuid): self.stopped = True


@pytest.mark.asyncio
async def test_upload_authenticates_and_sends_exact_four_color_frame():
    fake = FakeDevice()
    label = Label("WL00000000", client_factory=lambda _:fake)
    picture = Image.new("RGB", (4, 1))
    picture.putdata([(0,0,0),(255,255,255),(255,255,0),(255,0,0)])
    async with label:
        result = await label.display(picture, DisplayProfile(4, 1), compress=False)
    assert result.completed
    assert result.raw_bytes == 1
    assert fake.writes[0][0] == AUTH_UUID
    assert len(fake.writes[0][1]) == 16
    assert fake.writes[1:] == [(DATA_UUID, bytes.fromhex("00a5000000001b")), (DATA_UUID, bytes.fromhex("01a501000000"))]
    assert fake.stopped and not fake.is_connected


@pytest.mark.asyncio
async def test_idle_notification_does_not_claim_refresh_finished():
    fake = FakeDevice(notifications=[b"\x00\x00"])
    async with Label("WL00000000", client_factory=lambda _:fake) as label:
        with pytest.raises(RefreshTimeout):
            await label.display(Image.new("RGB", (4,1), "white"), DisplayProfile(4,1), refresh_timeout=.03)
    assert fake.stopped


@pytest.mark.asyncio
async def test_busy_then_idle_proves_refresh_cycle():
    fake = FakeDevice(notifications=[b"\x01\x00",b"\x00\x00"])
    async with Label("WL00000000", client_factory=lambda _:fake) as label:
        assert (await label.display(Image.new("RGB", (4,1)), DisplayProfile(4,1))).completed


@pytest.mark.asyncio
async def test_device_error_is_not_success():
    fake = FakeDevice(notifications=[b"\x00\x03"])
    async with Label("WL00000000", client_factory=lambda _:fake) as label:
        with pytest.raises(LabelError, match="3"):
            await label.display(Image.new("RGB", (4,1)), DisplayProfile(4,1))


@pytest.mark.asyncio
async def test_auth_lock_aborts_before_display_write_and_disconnects():
    fake = FakeDevice(auth_status=b"\x06\x00")
    with pytest.raises(LabelError, match="auth"):
        async with Label("WL00000000", client_factory=lambda _:fake): pass
    assert not fake.is_connected
    assert all(uuid != DATA_UUID for uuid,_ in fake.writes)


@pytest.mark.asyncio
async def test_failed_chunk_never_sends_refresh():
    fake = FakeDevice(upload_error=True)
    async with Label("WL00000000", client_factory=lambda _:fake) as label:
        with pytest.raises(OSError):
            await label.display(Image.new("RGB", (4,1)), DisplayProfile(4,1))
    assert not any(v[:2] in (b"\x01\xa5",b"\x02\xa5") for u,v in fake.writes if u == DATA_UUID)
    assert fake.stopped


def test_live_advertisement_decodes_without_inventing_dimensions():
    device = SimpleNamespace(address="uuid",name="WL00000000")
    adv = SimpleNamespace(local_name="WL00000000",rssi=-44,manufacturer_data={0xbbaa:bytes.fromhex("3000000e033004010beb3000000e033004010beb")},service_uuids=[])
    result = parse_advertisement(device, adv)
    assert result.name == "WL00000000"
    assert result.battery_mv == 3051
    assert result.product_id == 0x30
    assert result.display_id == 0x0104
    assert not hasattr(result, "width")


def test_unrelated_advertisements_are_excluded():
    assert parse_advertisement(SimpleNamespace(address="uuid",name="AirPods"),SimpleNamespace(local_name=None,rssi=-30,manufacturer_data={76:b"anything"},service_uuids=[])) is None


@pytest.mark.asyncio
async def test_polled_completion_marker_is_not_a_new_completion_notification():
    fake = FakeDevice(notifications=[], auth_status=b"\xff\x00")
    async with Label("WL00000000", client_factory=lambda _:fake) as label:
        with pytest.raises(RefreshTimeout):
            await label.display(Image.new("RGB", (4,1)), DisplayProfile(4,1), refresh_timeout=.4)


@pytest.mark.asyncio
async def test_completion_queued_during_failed_poll_is_honoured():
    class CompletedWhilePolling(FakeDevice):
        async def read_gatt_char(self, uuid):
            if uuid == STATUS_UUID and any(u == DATA_UUID and v[0] in (1,2) for u,v in self.writes):
                self.callback(None, bytes.fromhex("ff00000000000000"))
                self.is_connected = False
                raise OSError("disconnect after physical completion")
            return await super().read_gatt_char(uuid)
    fake = CompletedWhilePolling(notifications=[])
    async with Label("WL00000000", client_factory=lambda _:fake) as label:
        result = await label.display(Image.new("RGB", (4,1)), DisplayProfile(4,1), refresh_timeout=1)
    assert result.completed


@pytest.mark.asyncio
async def test_lost_refresh_acknowledgement_reports_uncertain_outcome():
    class LostAck(FakeDevice):
        async def write_gatt_char(self, uuid, value, *, response):
            if uuid == DATA_UUID and value[0] in (1,2):
                self.is_connected = False
                raise OSError("lost write acknowledgement")
            return await super().write_gatt_char(uuid,value,response=response)
    fake = LostAck()
    async with Label("WL00000000", client_factory=lambda _:fake) as label:
        with pytest.raises(RefreshTimeout) as caught:
            await label.display(Image.new("RGB", (4,1)), DisplayProfile(4,1))
    assert isinstance(caught.value.__cause__, OSError)


@pytest.mark.asyncio
async def test_completion_already_received_at_poll_deadline_is_processed():
    queue = asyncio.Queue()
    class SlowPoll:
        is_connected = True
        async def read_gatt_char(self, uuid):
            queue.put_nowait(b"\x01\x00")
            queue.put_nowait(bytes.fromhex("ff00000000000000"))
            await asyncio.sleep(1)
    label = Label("WL00000000")
    assert await label._wait_refresh(SlowPoll(), queue, .35) == "completion notification"


@pytest.mark.asyncio
async def test_real_connection_path_keeps_scanner_active_until_connected(monkeypatch):
    state = {"scanning":False}
    device = SimpleNamespace(address="uuid",name="WL00000000")
    advertisement = SimpleNamespace(local_name="WL00000000",rssi=-40,manufacturer_data={},service_uuids=[])
    class Scanner:
        def __init__(self, detection_callback): self.callback = detection_callback
        async def __aenter__(self):
            state["scanning"] = True
            self.callback(device,advertisement)
            return self
        async def __aexit__(self,*args): state["scanning"] = False
        @classmethod
        async def find_device_by_filter(cls,predicate,timeout): return device
    class WindowedDevice(FakeDevice):
        async def connect(self,**kwargs):
            assert state["scanning"], "The label connection window is lost when scanning stops first"
            await super().connect(**kwargs)
    fake = WindowedDevice()
    monkeypatch.setattr("eink_ble.client.BleakScanner",Scanner)
    monkeypatch.setattr("eink_ble.client.BleakClient",lambda device:fake)
    async with Label("WL00000000"):
        assert fake.is_connected
    assert not state["scanning"]
    assert not fake.is_connected


@pytest.mark.asyncio
async def test_scanner_cleanup_failure_cannot_leave_an_open_label(monkeypatch):
    fake = FakeDevice()
    device = SimpleNamespace(address="uuid",name="WL00000000")
    advertisement = SimpleNamespace(local_name="WL00000000",rssi=-40,manufacturer_data={},service_uuids=[])
    class Scanner:
        def __init__(self,detection_callback): self.callback=detection_callback
        async def __aenter__(self):
            self.callback(device,advertisement)
            return self
        async def __aexit__(self,*args): raise OSError("scanner stop failed")
    monkeypatch.setattr("eink_ble.client.BleakScanner",Scanner)
    monkeypatch.setattr("eink_ble.client.BleakClient",lambda device:fake)
    with pytest.raises(OSError,match="scanner stop"):
        async with Label("WL00000000"): pass
    assert not fake.is_connected
