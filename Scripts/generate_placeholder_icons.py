#!/usr/bin/env python3
"""Generate minimal geometric placeholder icons for Ahem asset catalog."""

from __future__ import annotations

import math
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "Assets.xcassets"
APP_ICON_DIR = ROOT / "AppIcon.appiconset"
MENU_BAR_DIR = ROOT / "MenuBarIcon.imageset"

APP_ICON_SIZES = [16, 32, 64, 128, 256, 512, 1024]
MENU_BAR_SIZES = [18, 36]


def write_png(path: Path, width: int, height: int, pixels: list[tuple[int, int, int, int]]) -> None:
    has_alpha = any(pixel[3] < 255 for pixel in pixels)
    color_type = 6 if has_alpha else 2
    channels = 4 if has_alpha else 3

    raw_rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            pixel = pixels[y * width + x]
            row.extend(pixel if has_alpha else pixel[:3])
        raw_rows.append(bytes(row))
    raw = b"".join(raw_rows)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def draw_app_icon(size: int) -> list[tuple[int, int, int, int]]:
    pixels = [(235, 235, 237, 255)] * (size * size)
    radius = size * 0.22
    margin = size * 0.08

    def set_pixel(x: int, y: int, color: tuple[int, int, int, int]) -> None:
        if 0 <= x < size and 0 <= y < size:
            pixels[y * size + x] = color

    def fill_rounded_rect(color: tuple[int, int, int, int]) -> None:
        left, top = margin, margin
        right, bottom = size - margin, size - margin
        for y in range(size):
            for x in range(size):
                inside = left <= x < right and top <= y < bottom
                if not inside:
                    continue
                cx = min(x - left, right - 1 - x)
                cy = min(y - top, bottom - 1 - y)
                corner = min(cx, cy)
                if corner < radius:
                    dx = radius - cx
                    dy = radius - cy
                    if math.hypot(max(dx, 0), max(dy, 0)) > radius:
                        continue
                set_pixel(x, y, color)

    fill_rounded_rect((142, 142, 147, 255))

    stroke = (255, 255, 255, 255)
    thickness = max(1, round(size * 0.07))
    apex = (size * 0.5, size * 0.28)
    left_base = (size * 0.32, size * 0.72)
    right_base = (size * 0.68, size * 0.72)
    cross_left = (size * 0.38, size * 0.54)
    cross_right = (size * 0.62, size * 0.54)

    def draw_line(p1: tuple[float, float], p2: tuple[float, float]) -> None:
        length = math.hypot(p2[0] - p1[0], p2[1] - p1[1])
        steps = max(1, int(length * 2))
        for step in range(steps + 1):
            t = step / steps
            x = lerp(p1[0], p2[0], t)
            y = lerp(p1[1], p2[1], t)
            for ox in range(-thickness, thickness + 1):
                for oy in range(-thickness, thickness + 1):
                    if ox * ox + oy * oy <= thickness * thickness:
                        set_pixel(int(x + ox), int(y + oy), stroke)

    draw_line(apex, left_base)
    draw_line(apex, right_base)
    draw_line(cross_left, cross_right)
    return pixels


def draw_menu_bar_icon(size: int) -> list[tuple[int, int, int, int]]:
    pixels = [(0, 0, 0, 0)] * (size * size)
    thickness = max(1, round(size * 0.12))
    apex = (size * 0.5, size * 0.18)
    left_base = (size * 0.22, size * 0.82)
    right_base = (size * 0.78, size * 0.82)
    cross_left = (size * 0.34, size * 0.56)
    cross_right = (size * 0.66, size * 0.56)
    stroke = (0, 0, 0, 255)

    def set_pixel(x: int, y: int, color: tuple[int, int, int, int]) -> None:
        if 0 <= x < size and 0 <= y < size:
            pixels[y * size + x] = color

    def draw_line(p1: tuple[float, float], p2: tuple[float, float]) -> None:
        length = math.hypot(p2[0] - p1[0], p2[1] - p1[1])
        steps = max(1, int(length * 2))
        for step in range(steps + 1):
            t = step / steps
            x = lerp(p1[0], p2[0], t)
            y = lerp(p1[1], p2[1], t)
            for ox in range(-thickness, thickness + 1):
                for oy in range(-thickness, thickness + 1):
                    if ox * ox + oy * oy <= thickness * thickness:
                        set_pixel(int(x + ox), int(y + oy), stroke)

    draw_line(apex, left_base)
    draw_line(apex, right_base)
    draw_line(cross_left, cross_right)
    return pixels


def main() -> None:
    for size in APP_ICON_SIZES:
        write_png(APP_ICON_DIR / f"icon_{size}.png", size, size, draw_app_icon(size))

    for size in MENU_BAR_SIZES:
        scale = "1x" if size == 18 else "2x"
        write_png(MENU_BAR_DIR / f"menubar_{scale}.png", size, size, draw_menu_bar_icon(size))

    print("Generated placeholder icons in Assets.xcassets")


if __name__ == "__main__":
    main()
