from PIL import Image

from eink_ble.cli import main


def test_preview_creates_full_resolution_image_without_bluetooth(tmp_path):
    output = tmp_path / "test.png"
    assert main(["demo", "--profile", "420", "--output", str(output)]) == 0
    with Image.open(output) as image:
        assert image.size == (400, 300)
        colors = {color for _, color in image.convert("RGB").getcolors(maxcolors=400*300)}
        assert (255, 0, 0) in colors
        assert (255, 255, 0) in colors


def test_text_preview_preserves_explicit_size(tmp_path):
    output = tmp_path / "text.png"
    assert main(["text", "Hello Python", "--width", "80", "--height", "40", "--output", str(output)]) == 0
    with Image.open(output) as image:
        assert image.size == (80,40)


def test_image_preview_accepts_arbitrary_image_file(tmp_path):
    source = tmp_path / "input.png"
    output = tmp_path / "output.png"
    Image.new("RGB", (10,10), "red").save(source)
    assert main(["image", str(source), "--profile", "420", "--output", str(output)]) == 0
    with Image.open(output) as image:
        assert image.size == (400,300)


def test_incomplete_custom_size_is_rejected_before_bluetooth():
    import pytest
    with pytest.raises(SystemExit): main(["demo", "--width", "400"])


def test_scan_json_does_not_copy_native_bluetooth_handle(monkeypatch,capsys):
    from eink_ble.client import DiscoveredLabel
    class NativeHandle:
        def __deepcopy__(self,memo): raise TypeError("native handle cannot be copied")
    async def fake_scan(timeout):
        return [DiscoveredLabel("uuid","WL00000000",-40,device=NativeHandle())]
    monkeypatch.setattr("eink_ble.cli.scan",fake_scan)
    assert main(["scan","--json"]) == 0
    assert '"name": "WL00000000"' in capsys.readouterr().out
