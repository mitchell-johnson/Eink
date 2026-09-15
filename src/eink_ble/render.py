"""Render arbitrary Pillow images to a label's ink palette and pixel ordering."""

from dataclasses import dataclass
from typing import Literal

from PIL import Image, ImageOps


Layout = Literal["row", "columns-reversed-x", "columns-reversed-y"]
ColorMode = Literal["BW", "BWR", "BWRY"]
Fit = Literal["contain", "cover", "stretch"]

# The tuple position is the two-bit wire value, not a Pillow palette index.
INK_COLORS = ((0, 0, 0), (255, 255, 255), (255, 255, 0), (255, 0, 0))
_MODE_CODES = {"BW": (0, 1), "BWR": (0, 1, 3), "BWRY": (0, 1, 2, 3)}


@dataclass(frozen=True)
class DisplayProfile:
    """Physical image size and the panel's storage layout.

    ``row`` scans left to right, top to bottom. ``columns-reversed-x`` scans
    top to bottom starting with the rightmost column. ``columns-reversed-y``
    scans bottom to top starting with the leftmost column. ``mirror`` flips
    physical x coordinates before storage; it does not alter the preview.
    ``rotation`` rotates source content clockwise before fitting it to the
    display. Dimensions always describe the final, physical preview.
    """

    width: int
    height: int
    layout: Layout = "row"
    color_mode: ColorMode = "BWRY"
    mirror: bool = False
    rotation: int = 0
    name: str | None = None

    def __post_init__(self) -> None:
        if any(type(size) is not int or size <= 0 for size in (self.width, self.height)):
            raise ValueError("Display width and height must be positive integers")
        if self.layout not in ("row", "columns-reversed-x", "columns-reversed-y"):
            raise ValueError(f"Unknown pixel layout: {self.layout}")
        if self.color_mode not in _MODE_CODES:
            raise ValueError(f"Unknown color mode: {self.color_mode}")
        if self.rotation not in (0, 90, 180, 270):
            raise ValueError("Rotation must be 0, 90, 180, or 270 degrees clockwise")
        scanline = self.width if self.layout == "row" else self.height
        if scanline % 4:
            raise ValueError("The packed scanline dimension must be divisible by four")

    @property
    def raw_size(self) -> int:
        """Exact byte length of the uncompressed two-bit image."""
        return self.width * self.height // 4


def prepare_image(
    image: Image.Image,
    profile: DisplayProfile,
    fit: Fit = "contain",
    dither: bool = False,
) -> Image.Image:
    """Return an RGB preview at the exact display size, containing only ink colors.

    ``contain`` centers the whole image with white padding. ``cover`` crops
    the center to fill the display, and ``stretch`` changes the aspect ratio.
    Transparency is composited on white. Dithering uses Floyd-Steinberg.
    The source image is never modified.
    """
    if fit not in ("contain", "cover", "stretch"):
        raise ValueError(f"Unknown fit mode: {fit}")
    source = ImageOps.exif_transpose(image).convert("RGBA")
    if profile.rotation:
        source = source.rotate(-profile.rotation, expand=True)
    background = Image.new("RGBA", source.size, "white")
    source = Image.alpha_composite(background, source).convert("RGB")
    size = (profile.width, profile.height)
    if fit == "contain":
        fitted = ImageOps.contain(source, size, Image.Resampling.LANCZOS)
        source = Image.new("RGB", size, "white")
        source.paste(fitted, ((size[0] - fitted.width) // 2, (size[1] - fitted.height) // 2))
    elif fit == "cover":
        source = ImageOps.fit(source, size, Image.Resampling.LANCZOS)
    else:
        source = source.resize(size, Image.Resampling.LANCZOS)

    palette = Image.new("P", (1, 1))
    colors = [INK_COLORS[index] for index in _MODE_CODES[profile.color_mode]]
    colors.extend([INK_COLORS[1]] * (256 - len(colors)))
    palette.putpalette([component for color in colors for component in color])
    method = Image.Dither.FLOYDSTEINBERG if dither else Image.Dither.NONE
    return source.quantize(palette=palette, dither=method).convert("RGB")


def pack_image(image: Image.Image, profile: DisplayProfile) -> bytes:
    """Pack a prepared image as four two-bit pixels per byte, most significant first.

    Dimensions and colors must already match the profile; use ``prepare_image``
    first to resize or quantize a source image. Storage transforms are applied
    exactly once here, independently of the physical preview.
    """
    if image.size != (profile.width, profile.height):
        raise ValueError("Image dimensions do not match the display; use prepare_image first")
    pixels = image.convert("RGB").load()
    color_codes = {INK_COLORS[code]: code for code in _MODE_CODES[profile.color_mode]}
    width, height = profile.width, profile.height
    if profile.layout == "row":
        coordinates = ((x, y) for y in range(height) for x in range(width))
    elif profile.layout == "columns-reversed-x":
        coordinates = ((x, y) for x in range(width - 1, -1, -1) for y in range(height))
    else:
        coordinates = ((x, y) for x in range(width) for y in range(height - 1, -1, -1))
    packed = bytearray(profile.raw_size)
    for index, (x, y) in enumerate(coordinates):
        color = pixels[width - 1 - x if profile.mirror else x, y]
        try:
            code = color_codes[color]
        except KeyError:
            raise ValueError(f"Image contains unsupported color {color}; use prepare_image first") from None
        packed[index // 4] |= code << (6 - 2 * (index % 4))
    return bytes(packed)
