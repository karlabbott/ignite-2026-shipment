"""Render a 24-second, sound-off LinkedIn teaser using existing distro assets."""

from __future__ import annotations

import argparse
import base64
import io
import math
import os
from functools import cache
from pathlib import Path
import shutil
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
SIZE = 1080
FPS = 30
DURATION = 24
NAVY = (9, 17, 34)
WHITE = (242, 247, 255)
MUTED = (155, 175, 198)
BLUE = (64, 173, 255)
GOLD = (255, 200, 85)
DISTROS = [
    ("RHEL", "redhat.svg"),
    ("SUSE", "suse.svg"),
    ("Ubuntu", "ubuntu.svg"),
    ("Rocky Linux", "rockylinux.svg"),
    ("Azure Linux", "azurelinux.png"),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "marketing" / "ignite-teaser-v1.mp4")
    fonts = Path(os.environ.get("WINDIR", r"C:\Windows")) / "Fonts"
    parser.add_argument("--font", type=Path, default=fonts / "seguisb.ttf")
    parser.add_argument("--regular-font", type=Path, default=fonts / "segoeui.ttf")
    args = parser.parse_args()
    encoder = shutil.which("ffmpeg")
    if encoder is None:
        raise RuntimeError("ffmpeg must be installed and available on PATH")
    for font in [args.font, args.regular_font]:
        if not font.is_file():
            raise FileNotFoundError(f"Supply the missing font using --font/--regular-font: {font}")

    @cache
    def font(size, regular=False):
        return ImageFont.truetype(str(args.regular_font if regular else args.font), size)

    logos = []
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            channel="msedge" if sys.platform == "win32" else None, headless=True,
        )
        page = browser.new_page(viewport={"width": 128, "height": 128}, device_scale_factor=2)
        for _, filename in DISTROS:
            asset = ROOT / "web" / "app" / "static" / "logos" / filename
            if asset.suffix == ".png":
                logo = Image.open(asset).convert("RGBA")
            else:
                encoded = base64.b64encode(asset.read_bytes()).decode()
                page.set_content(
                    '<body style="margin:0;background:transparent">'
                    f'<img style="width:128px;height:128px" src="data:image/svg+xml;base64,{encoded}">'
                )
                logo = Image.open(io.BytesIO(
                    page.locator("img").screenshot(omit_background=True),
                )).convert("RGBA")
            logo.thumbnail((80, 80), Image.Resampling.LANCZOS)
            logos.append(logo)
        browser.close()

    background = Image.new("RGB", (SIZE, SIZE), NAVY)
    draw = ImageDraw.Draw(background)
    for y in range(SIZE):
        brightness = int(11 * (1 - abs(y - 550) / 600))
        draw.line((0, y, SIZE, y), fill=(9, 17 + max(0, brightness), 34 + max(0, brightness)))
    for x in range(36, SIZE, 72):
        draw.line((x, 130, x, 1000), fill=(19, 33, 51), width=1)
    for y in range(160, 1000, 72):
        draw.line((45, y, 1035, y), fill=(19, 33, 51), width=1)

    def text(draw, value, y, size, color=WHITE, regular=False, x=540):
        draw.text((x, y), value, font=font(size, regular), fill=color, anchor="mm")

    def package(draw, x, y):
        draw.ellipse((x - 33, y + 35, x + 34, y + 48), fill=(5, 13, 24))
        draw.polygon([(x, y - 38), (x + 38, y - 18), (x, y + 2), (x - 38, y - 18)], fill=GOLD)
        draw.polygon([(x - 38, y - 18), (x, y + 2), (x, y + 43), (x - 38, y + 21)], fill=(212, 140, 39))
        draw.polygon([(x, y + 2), (x + 38, y - 18), (x + 38, y + 21), (x, y + 43)], fill=(243, 172, 49))
        draw.line((x - 20, y - 28, x + 17, y - 8, x + 17, y + 30), fill=(255, 226, 154), width=7)
        draw.rounded_rectangle((x - 28, y - 4, x - 7, y + 10), radius=2, fill=WHITE)

    def path_point(progress):
        return (140 + 800 * progress, 745 - 48 * math.sin(math.pi * progress))

    def frame(t):
        image = background.copy()
        draw = ImageDraw.Draw(image)
        text(draw, "ZAVA LOGISTICS  /  LIVE DEMO", 78, 24, BLUE)
        draw.line((75, 119, 1005, 119), fill=(42, 63, 84), width=2)
        text(draw, "ZAV94388224  /  SEATTLE \u2192 PARIS", 160, 22, MUTED, True)

        if t < 3:
            headline = ("Seattle to Paris.", "One golden shipment.")
        elif t < 7:
            headline = ("Five Linux distros.", "One application.")
        elif t < 12:
            headline = ("Same shipment.", "New infrastructure.")
        elif t < 17:
            headline = ("Then YOU choose", "what breaks.")
        elif t < 20:
            headline = ("Can it recover", "live?")
        else:
            headline = ("One shipment.", "Your choice of incident.")

        text(draw, headline[0], 285, 68)
        text(draw, headline[1], 371, 68, GOLD if t >= 12 else WHITE)

        progress = max(0, min(1, (t - 1.2) / 13))
        line_color = GOLD if 12 <= t < 17 else BLUE
        route = [path_point(i / 160) for i in range(161)]
        draw.line(route, fill=(45, 65, 86), width=5)
        completed = route[:max(2, int(progress * 160) + 1)]
        draw.line(completed, fill=line_color, width=5)
        for index, ((label, _), logo) in enumerate(zip(DISTROS, logos)):
            x = 140 + index * 200
            active = abs(progress - index / 4) < 0.13
            outline = GOLD if active else (54, 81, 107)
            draw.rounded_rectangle((x - 79, 494, x + 79, 648), radius=20,
                                   fill=(248, 250, 253), outline=outline, width=4)
            image.paste(logo, (int(x - logo.width / 2), int(565 - logo.height / 2)), logo)
            text(draw, label, 676, 23, WHITE, x=x)
            px, py = path_point(index / 4)
            draw.ellipse((px - 6, py - 6, px + 6, py + 6), fill=outline)

        x, y = path_point(progress)
        package(draw, x, y - 10 + math.sin(t * 4) * 3)
        text(draw, "SEATTLE", 839, 25, MUTED, x=170)
        text(draw, "PARIS", 839, 25, MUTED, x=930)
        if t < 12:
            text(draw, "DATACENTER  \u2192  AZURE", 919, 28, BLUE)
        elif t < 20:
            text(draw, "A real application. Your choice of incident.", 919, 29, BLUE)
        else:
            text(draw, "LINUX ON AZURE", 919, 30, BLUE)
        text(draw, "Microsoft Ignite 2026", 998, 28, WHITE)
        return image

    args.output.parent.mkdir(parents=True, exist_ok=True)
    command = [
        encoder, "-hide_banner", "-loglevel", "error", "-y",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{SIZE}x{SIZE}",
        "-r", str(FPS), "-i", "pipe:0", "-an",
        "-c:v", "libx264", "-preset", "medium", "-crf", "19",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart",
        "-t", str(DURATION), str(args.output),
    ]
    process = subprocess.Popen(command, stdin=subprocess.PIPE)
    try:
        for index in range(DURATION * FPS):
            process.stdin.write(frame(index / FPS).tobytes())
        process.stdin.close()
        if process.wait() != 0:
            raise RuntimeError("ffmpeg encoding failed")
    except BaseException:
        process.kill()
        process.wait()
        raise

    frame(22).save(args.output.with_suffix(".png"))
    contact = Image.new("RGB", (1080, 720), NAVY)
    for index, seconds in enumerate([1, 5, 9, 14, 18, 22]):
        thumb = frame(seconds).resize((360, 360), Image.Resampling.LANCZOS)
        contact.paste(thumb, ((index % 3) * 360, (index // 3) * 360))
    contact.save(args.output.with_name(args.output.stem + "-storyboard.jpg"), quality=92)
    print(f"Rendered {DURATION}s, {SIZE}x{SIZE}, {FPS}fps, H.264: {args.output}")


if __name__ == "__main__":
    main()
