"""Command-line image preparation and direct Bluetooth updates."""
from __future__ import annotations

import argparse
import asyncio
from dataclasses import asdict, fields
import json
import logging
from pathlib import Path
import sys

from PIL import Image, ImageDraw, ImageFont

from .client import Label, scan
from .render import DisplayProfile, prepare_image


def demo_image(width: int, height: int) -> Image.Image:
    """Asymmetric full-frame diagnostic for orientation and all four colours."""
    image = Image.new("RGB", (width, height), "white")
    draw = ImageDraw.Draw(image)
    scale = min(width / 400, height / 300)
    font = ImageFont.load_default(size=max(10, round(17 * scale)))
    title = ImageFont.load_default(size=max(14, round(36 * scale)))
    small = ImageFont.load_default(size=max(8, round(12 * scale)))
    margin = max(3, round(12 * scale))
    draw.rectangle((0, 0, width-1, height-1), outline="black", width=max(1,round(3*scale)))
    draw.text((margin, margin), "TOP LEFT  1", font=font, fill="black")
    draw.text((width-margin, margin), "2  TOP RIGHT", anchor="ra", font=font, fill="red")
    draw.text((width//2, round(height*.24)), "PYTHON", anchor="mm", font=title, fill="black")
    draw.text((width//2, round(height*.39)), "DIRECT BLUETOOTH", anchor="mm", font=font, fill="red")
    swatch_y = round(height*.50)
    swatch_h = round(height*.21)
    for i,(color,label) in enumerate((("black","BLACK"),("white","WHITE"),("yellow","YELLOW"),("red","RED"))):
        x0 = margin + i * (width-2*margin)//4
        x1 = margin + (i+1) * (width-2*margin)//4 - 2
        draw.rectangle((x0,swatch_y,x1,swatch_y+swatch_h),fill=color,outline="black")
        draw.text(((x0+x1)//2, swatch_y+swatch_h+5),label,anchor="ma",fill="black",font=small)
    draw.text((width//2,round(height*.87)),f"{width} x {height}   /   13 SEPT 2026",anchor="mm",font=small,fill="black")
    draw.text((margin,height-margin),"3  BOTTOM LEFT",anchor="ld",font=small,fill="red")
    draw.text((width-margin,height-margin),"BOTTOM RIGHT  4",anchor="rd",font=small,fill="black")
    return image


def text_image(text: str, width: int, height: int, font_size: int = 32,
               font_path: str | None = None, color: str = "black") -> Image.Image:
    image = Image.new("RGB", (width,height), "white")
    draw = ImageDraw.Draw(image)
    font = ImageFont.truetype(font_path,font_size) if font_path else ImageFont.load_default(size=font_size)
    # Preserve explicit newlines and wrap words to the available canvas.
    lines = []
    limit = max(1,width-16)
    for paragraph in text.splitlines() or [""]:
        line = ""
        for word in paragraph.split():
            candidate = f"{line} {word}".strip()
            if line and draw.textlength(candidate,font=font) > limit:
                lines.append(line)
                line = word
            else:
                line = candidate
        lines.append(line)
    draw.multiline_text((width/2,height/2),"\n".join(lines),font=font,fill=color,anchor="mm",align="center",spacing=6)
    return image


def _parser():
    parser = argparse.ArgumentParser(description="Set WoLink e-ink content directly over Bluetooth")
    parser.add_argument("--verbose", action="store_true")
    commands = parser.add_subparsers(dest="command",required=True)
    scanning = commands.add_parser("scan",help="find nearby WoLink labels")
    scanning.add_argument("--timeout",type=float,default=30)
    scanning.add_argument("--json",action="store_true")
    info = commands.add_parser("info",help="read label identity, firmware fields and battery voltage")
    info.add_argument("--device",required=True)
    info.add_argument("--scan-timeout",type=float,default=300)
    for name,help_text in (("demo","orientation and colour test"),("text","display text"),("image","display any image file"),("clear","display a white image")):
        command = commands.add_parser(name,help=help_text)
        if name in ("text","image"):
            command.add_argument("content")
        if name == "text":
            command.add_argument("--font-size",type=int,default=32)
            command.add_argument("--font",help="path to a TrueType font for Unicode or custom lettering")
            command.add_argument("--color",choices=["black","red","yellow"],default="black")
        command.add_argument("--device",help="label name/ID or Bluetooth address; omit to save a preview only")
        command.add_argument("--scan-timeout",type=float,default=300)
        command.add_argument("--profile",choices=["420"],help="4.2-inch 400 x 300 four-colour label")
        command.add_argument("--width",type=int)
        command.add_argument("--height",type=int)
        command.add_argument("--layout",choices=["row","columns-reversed-x","columns-reversed-y"],help="panel pixel scan order")
        command.add_argument("--mirror",action="store_true",help="mirror the physical panel mapping")
        command.add_argument("--rotate",type=int,choices=[0,90,180,270],default=0,help="rotate input clockwise before fitting")
        command.add_argument("--colors",choices=["BW","BWR","BWRY"],default="BWRY")
        command.add_argument("--fit",choices=["contain","cover","stretch"],default="contain")
        command.add_argument("--dither",action="store_true")
        command.add_argument("--raw",action="store_true",help="disable compression")
        command.add_argument("--refresh-timeout",type=float,default=60)
        command.add_argument("--output",type=Path,help="save the quantized image preview")
    return parser


def _profile(args, parser):
    if args.profile and (args.width is not None or args.height is not None):
        parser.error("Use --profile or --width and --height")
    if args.profile == "420":
        width,height = 400,300
    elif args.width is not None and args.height is not None:
        width,height = args.width,args.height
    else:
        parser.error("Choose --profile 420 or provide both --width and --height")
    layout = args.layout or "row"
    return DisplayProfile(width,height,layout=layout,color_mode=args.colors,mirror=args.mirror,rotation=args.rotate)


async def _run(args, parser):
    if args.command == "scan":
        found = await scan(args.timeout)
        records = [{item.name:getattr(label,item.name) for item in fields(label) if item.name != "device"} for label in found]
        if args.json:
            print(json.dumps(records,indent=2))
        else:
            for label in found:
                print(f"{label.name:12}  {label.address}  {label.rssi} dBm  {label.battery_mv or '?'} mV")
            if not found:
                print("No labels seen. WoLink advertising is intermittent; try --timeout 300.")
        return
    if args.command == "info":
        async with Label(args.device,scan_timeout=args.scan_timeout) as label:
            print(json.dumps(asdict(await label.info()),indent=2,default=lambda value:value.hex()))
        return
    profile = _profile(args,parser)
    if not args.device and not args.output:
        parser.error("Provide --device to update the label, or --output to save a preview")
    if args.command == "demo":
        image = demo_image(profile.width,profile.height)
    elif args.command == "text":
        if args.font_size <= 0: parser.error("--font-size must be positive")
        image = text_image(args.content,profile.width,profile.height,args.font_size,args.font,args.color)
    elif args.command == "image":
        with Image.open(args.content) as source:
            image = source.copy()
    else:
        image = Image.new("RGB",(profile.width,profile.height),"white")
    if args.output:
        prepared = prepare_image(image,profile,fit=args.fit,dither=args.dither)
        prepared.save(args.output)
        print(f"Preview saved: {args.output.resolve()}")
    if args.device:
        print(f"Waiting for {args.device} to advertise; this can take a few minutes.",flush=True)
        async with Label(args.device,scan_timeout=args.scan_timeout) as label:
            print("Connected. Uploading image…",flush=True)
            result = await label.display(image,profile,fit=args.fit,dither=args.dither,compress=not args.raw,refresh_timeout=args.refresh_timeout)
            print(f"Display refresh confirmed ({result.confirmation}); {result.transmitted_bytes} bytes sent.")


def main(argv=None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.WARNING)
    try:
        asyncio.run(_run(args,parser))
    except KeyboardInterrupt:
        print("Cancelled.",file=sys.stderr)
        return 130
    except Exception as exc:
        print(f"Error: {exc}",file=sys.stderr)
        if "Bluetooth" in str(exc):
            print("On macOS, allow your terminal/app under System Settings > Privacy & Security > Bluetooth.",file=sys.stderr)
        return 1
    return 0
