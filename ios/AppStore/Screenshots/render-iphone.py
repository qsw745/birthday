#!/usr/bin/env python3
"""Frame genuine 6.9-inch app captures for the Simplified Chinese store page."""

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

SIZE = (1320, 2868)
CAPTURES = (
    ("01-calendar.png", "01-lunar-calendar.jpg", "重要的日子，一眼看见", "农历生日与下一次公历日期，清楚相伴"),
    ("02-list.png", "02-all-birthdays.jpg", "在意的人，都在这里", "按姓名搜索，让每一份惦念都有位置"),
    ("03-editor.png", "03-reminder-editor.jpg", "记下农历，安排提醒", "提前一天、生日当天，由你来决定"),
    ("04-settings.png", "04-local-privacy.jpg", "资料私密，提醒安心", "Face ID 保护本机资料，本地通知照常工作"),
    ("05-icloud-export.png", "05-offline-first.jpg", "私有同步，自在掌握", "iCloud 可按设备关闭，本机资料可导出"),
)


def render(source, destination, title, subtitle):
    capture = Image.open(source).convert("RGB")
    if capture.size != SIZE:
        raise ValueError(f"{source}: expected {SIZE}, got {capture.size}")
    canvas = Image.new("RGBA", SIZE, "#eef6f2")
    draw = ImageDraw.Draw(canvas)
    draw.ellipse((940, -180, 1500, 380), fill="#e3eeea")
    draw.ellipse((-230, 2370, 350, 2970), fill="#eae9d9")
    font_path = "/System/Library/Fonts/Hiragino Sans GB.ttc"
    for text, y, font_size, index, color in (
        ("岁时 · 农历生日提醒", 96, 30, 0, "#52736a"),
        (title, 176, 84, 2, "#193c38"),
        (subtitle, 298, 34, 0, "#60776f"),
    ):
        font = ImageFont.truetype(font_path, font_size, index=index)
        length = draw.textlength(text, font=font)
        if length > SIZE[0] - 100:
            raise ValueError(f"Title does not fit: {text}")
        draw.text(((SIZE[0] - length) / 2, y), text, font=font, fill=color)

    # Preserve the entire real app image, including the system status bar.
    scaled = capture.resize((1056, 2294), Image.Resampling.LANCZOS)
    frame = Image.new("RGBA", (1072, 2310), "#ffffff")
    frame.paste(scaled, (8, 8))
    mask = Image.new("L", frame.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, 1071, 2309), radius=76, fill=255)
    frame.putalpha(mask)
    position = (124, 444)
    shadow = Image.new("RGBA", SIZE)
    shadow_frame = Image.new("RGBA", frame.size, "#274b42")
    shadow_frame.putalpha(mask.point(lambda alpha: round(alpha * 0.2)))
    shadow.alpha_composite(shadow_frame, (position[0], position[1] + 18))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(30)))
    canvas.alpha_composite(frame, position)
    destination.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(destination, "JPEG", quality=94, subsampling=0, optimize=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("input_dir", type=Path)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    for source, destination, title, subtitle in CAPTURES:
        render(args.input_dir / source, args.output_dir / destination, title, subtitle)
