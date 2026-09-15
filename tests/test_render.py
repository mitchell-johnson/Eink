import pytest
from PIL import Image

from eink_ble.render import DisplayProfile, pack_image, prepare_image


COLORS = [(0, 0, 0), (255, 255, 255), (255, 255, 0), (255, 0, 0)]


def color_image(width, values):
    image = Image.new("RGB", (width, len(values) // width))
    image.putdata([COLORS[value] for value in values])
    return image


def pixel_values(image):
    return [image.getpixel((x, y)) for y in range(image.height) for x in range(image.width)]


def test_row_pixel_order_and_color_codes():
    image = color_image(4, [0, 1, 2, 3, 3, 2, 1, 0])
    assert pack_image(image, DisplayProfile(4, 2)) == b"\x1b\xe4"


@pytest.mark.parametrize(
    "layout,mirror,expected",
    [
        ("row", False, "1b e4 55 aa"),
        ("row", True, "e4 1b 55 aa"),
        ("columns-reversed-x", False, "c6 96 66 36"),
        ("columns-reversed-x", True, "36 66 96 c6"),
        ("columns-reversed-y", False, "9c 99 96 93"),
        ("columns-reversed-y", True, "93 96 99 9c"),
    ],
)
def test_hardware_layout_coordinates(layout, mirror, expected):
    # Rows B W Y R / R Y W B / W W W W / Y Y Y Y.
    image = color_image(4, [0, 1, 2, 3, 3, 2, 1, 0, 1, 1, 1, 1, 2, 2, 2, 2])
    profile = DisplayProfile(4, 4, layout=layout, mirror=mirror)
    assert pack_image(image, profile) == bytes.fromhex(expected)


def test_column_layout_allows_width_not_divisible_by_four():
    image = color_image(3, [0, 1, 2] * 4)
    profile = DisplayProfile(3, 4, layout="columns-reversed-x")
    assert profile.raw_size == 3
    assert pack_image(image, profile) == b"\xaa\x55\x00"


def test_42_inch_display_buffer_has_exact_dimensions_and_length():
    profile = DisplayProfile(400, 300, layout="columns-reversed-y")
    image = prepare_image(Image.new("RGB", (400, 300), "white"), profile)
    assert profile.raw_size == 30000
    assert pack_image(image, profile) == b"\x55" * 30000


@pytest.mark.parametrize("kwargs", [{"width": 0, "height": 4}, {"width": 4, "height": -4}, {"width": 3, "height": 4}, {"width": 4, "height": 3, "layout": "columns-reversed-x"}, {"width": 4, "height": 4, "layout": "unknown"}, {"width": 4, "height": 4, "color_mode": "RGB"}, {"width": 4, "height": 4, "rotation": 45}])
def test_profile_rejects_invalid_geometry_and_settings(kwargs):
    with pytest.raises(ValueError):
        DisplayProfile(**kwargs)


def test_prepare_returns_exact_palette_at_display_dimensions():
    prepared = prepare_image(color_image(4, [0, 1, 2, 3]), DisplayProfile(4, 1))
    assert prepared.mode == "RGB"
    assert prepared.size == (4, 1)
    assert pixel_values(prepared) == COLORS


def test_prepare_contain_centers_and_pads_white():
    prepared = prepare_image(Image.new("RGB", (8, 4), "black"), DisplayProfile(4, 4))
    assert [prepared.getpixel((0, y)) for y in range(4)] == [COLORS[1], COLORS[0], COLORS[0], COLORS[1]]


@pytest.mark.parametrize("fit", ["cover", "stretch"])
def test_prepare_cover_and_stretch_fill_canvas(fit):
    prepared = prepare_image(Image.new("RGB", (8, 4), "black"), DisplayProfile(4, 4), fit=fit)
    assert set(pixel_values(prepared)) == {COLORS[0]}


def test_prepare_composites_transparency_on_white():
    image = Image.new("RGBA", (4, 1), (0, 0, 0, 0))
    image.putpixel((1, 0), (255, 0, 0, 255))
    prepared = prepare_image(image, DisplayProfile(4, 1))
    assert pixel_values(prepared) == [COLORS[1], COLORS[3], COLORS[1], COLORS[1]]


def test_prepare_rotation_is_clockwise_and_does_not_mirror_preview():
    image = color_image(1, [0, 1, 2, 3])
    profile = DisplayProfile(4, 1, rotation=90, mirror=True)
    assert pixel_values(prepare_image(image, profile)) == list(reversed(COLORS))


@pytest.mark.parametrize("mode,allowed", [("BW", {COLORS[0], COLORS[1]}), ("BWR", {COLORS[0], COLORS[1], COLORS[3]}), ("BWRY", set(COLORS))])
@pytest.mark.parametrize("dither", [False, True])
def test_prepare_obeys_available_ink_colors(mode, allowed, dither):
    image = Image.new("RGB", (16, 4))
    image.putdata([(x * 4, (x * 37) % 256, (x * 83) % 256) for x in range(64)])
    assert set(pixel_values(prepare_image(image, DisplayProfile(16, 4, color_mode=mode), dither=dither))) <= allowed


def test_dithering_preserves_gray_coverage_in_black_white_mode():
    prepared = prepare_image(Image.new("RGB", (32, 16), (128, 128, 128)), DisplayProfile(32, 16, color_mode="BW"), dither=True)
    whites = pixel_values(prepared).count(COLORS[1])
    assert 220 <= whites <= 292


def test_prepare_rejects_unknown_fit():
    with pytest.raises(ValueError):
        prepare_image(Image.new("RGB", (4, 4)), DisplayProfile(4, 4), fit="bad")


def test_pack_rejects_wrong_size_without_silently_resizing():
    with pytest.raises(ValueError):
        pack_image(Image.new("RGB", (8, 4)), DisplayProfile(4, 4))


def test_pack_rejects_unquantized_colors():
    with pytest.raises(ValueError, match="prepare_image"):
        pack_image(Image.new("RGB", (4, 1), (128, 128, 128)), DisplayProfile(4, 1))


def test_pack_rejects_color_not_supported_by_profile():
    with pytest.raises(ValueError):
        pack_image(Image.new("RGB", (4, 1), "red"), DisplayProfile(4, 1, color_mode="BW"))
