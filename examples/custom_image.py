"""Draw your own full display in Python; run from the project environment."""
import asyncio
import os

from PIL import Image, ImageDraw, ImageFont

from eink_ble import DisplayProfile, Label


async def main():
    profile = DisplayProfile(400, 300)
    image = Image.new("RGB", (profile.width, profile.height), "white")
    draw = ImageDraw.Draw(image)
    heading = ImageFont.load_default(size=34)
    body = ImageFont.load_default(size=22)
    draw.rectangle((0, 0, 399, 64), fill="black")
    draw.text((20, 12), "YOUR DISPLAY", fill="white", font=heading)
    draw.text((20, 95), "Any text, image or drawing", fill="black", font=body)
    draw.text((20, 135), "Created locally with Python", fill="red", font=body)
    draw.rectangle((20, 200, 190, 279), fill="yellow", outline="black", width=2)
    draw.ellipse((240, 195, 330, 285), fill="red")
    image.save("custom-preview.png")
    async with Label(os.environ["LABEL_DEVICE"]) as label:
        print(await label.info())
        print(await label.display(image, profile))


if __name__ == "__main__":
    asyncio.run(main())
