#!/usr/bin/env python3
"""Render verified Mac App Store screenshots from isolated BirthdayMac captures."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


CANVAS_SIZE = (2880, 1800)
CAPTURES = (
    ("01-calendar.png", "01-calendar.jpg", "农历生日，一眼尽览", "月历、日期与提醒集中在同一窗口"),
    ("02-list.png", "02-all-birthdays.jpg", "生日资料，快速找到", "搜索、选择与详情自然联动"),
    ("03-editor.png", "03-reminder-editor.jpg", "编辑提醒，清晰顺手", "农历日期与本地通知一次设置"),
    ("04-settings.png", "04-local-privacy.jpg", "本地隐私，安心可控", "应用锁与本地通知按设备管理"),
    ("05-icloud-export.png", "05-icloud-export.jpg", "默认 iCloud，离线照常", "私有同步可关闭，本机数据可随时导出"),
)


def centered_text(draw: ImageDraw.ImageDraw, y: int, text: str, font: ImageFont.FreeTypeFont, fill: str) -> None:
    bounds = draw.textbbox((0, 0), text, font=font)
    width = bounds[2] - bounds[0]
    draw.text(((CANVAS_SIZE[0] - width) // 2, y), text, font=font, fill=fill)


def gradient_canvas() -> Image.Image:
    top = (246, 251, 250)
    bottom = (229, 240, 241)
    canvas = Image.new("RGB", CANVAS_SIZE)
    pixels = canvas.load()
    for y in range(CANVAS_SIZE[1]):
        ratio = y / (CANVAS_SIZE[1] - 1)
        color = tuple(round(start + (end - start) * ratio) for start, end in zip(top, bottom))
        for x in range(CANVAS_SIZE[0]):
            pixels[x, y] = color
    return canvas


def rounded_capture(source: Path) -> Image.Image:
    screenshot = Image.open(source).convert("RGB")
    if screenshot.size != (1662, 1170):
        raise ValueError(f"{source.name}: expected 1662x1170, got {screenshot.size[0]}x{screenshot.size[1]}")

    screenshot = screenshot.crop((0, 56, 1662, 1170)).resize((2300, 1542), Image.Resampling.LANCZOS)
    frame = Image.new("RGBA", (2312, 1554), "white")
    frame.paste(screenshot.convert("RGBA"), (6, 6))
    mask = Image.new("L", frame.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, frame.width - 1, frame.height - 1), radius=34, fill=255)
    frame.putalpha(mask)
    return frame


def render(source: Path, destination: Path, title: str, subtitle: str) -> None:
    font_path = "/System/Library/Fonts/Hiragino Sans GB.ttc"
    title_font = ImageFont.truetype(font_path, 86, index=2)
    subtitle_font = ImageFont.truetype(font_path, 38, index=0)

    canvas = gradient_canvas().convert("RGBA")
    decoration = Image.new("RGBA", CANVAS_SIZE, (0, 0, 0, 0))
    decoration_draw = ImageDraw.Draw(decoration)
    decoration_draw.ellipse((2410, -180, 2950, 360), fill=(198, 228, 225, 145))
    decoration_draw.ellipse((-160, 1420, 470, 2050), fill=(232, 216, 168, 115))
    canvas.alpha_composite(decoration)

    draw = ImageDraw.Draw(canvas)
    centered_text(draw, 38, title, title_font, "#153438")
    centered_text(draw, 145, subtitle, subtitle_font, "#557276")

    frame = rounded_capture(source)
    position = ((CANVAS_SIZE[0] - frame.width) // 2, 230)
    shadow = Image.new("RGBA", CANVAS_SIZE, (0, 0, 0, 0))
    shadow_shape = Image.new("RGBA", frame.size, (32, 62, 67, 88))
    shadow_shape.putalpha(frame.getchannel("A"))
    shadow.alpha_composite(shadow_shape, (position[0], position[1] + 24))
    shadow = shadow.filter(ImageFilter.GaussianBlur(30))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(frame, position)

    destination.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(destination, format="JPEG", quality=94, subsampling=0, optimize=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input_dir", type=Path)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()

    for source_name, destination_name, title, subtitle in CAPTURES:
        render(args.input_dir / source_name, args.output_dir / destination_name, title, subtitle)


if __name__ == "__main__":
    main()
