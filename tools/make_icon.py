"""Generates the vibetube icon set.

Run with any Python 3 that has Pillow:

    python tools/make_icon.py

Writes:
    assets/vibetube.png   256x256, used for the window/taskbar icon
    assets/vibetube.ico   multi-size, embedded as the executable's icon

The mark is drawn at 1024px and downsampled with LANCZOS so the small sizes
stay clean. It is an original mark: a red rounded tile with a white inverted
pyramid, reading as a "V" for vibetube rather than a play button.
"""

import os

from PIL import Image, ImageDraw

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets")

S = 1024
RADIUS = int(S * 0.225)
RED = (255, 0, 0, 255)
WHITE = (255, 255, 255, 255)


def draw_mark() -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    d.rounded_rectangle([0, 0, S - 1, S - 1], radius=RADIUS, fill=RED)

    # Inverted pyramid: base along the top, apex at the bottom.
    w = int(S * 0.52)
    h = int(S * 0.46)
    cx = S / 2
    # A downward triangle carries its visual mass near the base, so nudging it
    # down slightly makes it look centred inside the tile.
    y0 = (S - h) / 2 + S * 0.015
    x0 = cx - w / 2
    x1 = cx + w / 2
    d.polygon([(x0, y0), (x1, y0), (cx, y0 + h)], fill=WHITE)

    return img


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    mark = draw_mark()

    png_path = os.path.join(OUT_DIR, "vibetube.png")
    mark.resize((256, 256), Image.LANCZOS).save(png_path, "PNG")

    # Separate PNGs so the app can hand raylib/GLFW a real image per context
    # instead of one bitmap that the OS has to rescale badly.
    for size in (16, 24, 32, 48, 64):
        path = os.path.join(OUT_DIR, "icon%d.png" % size)
        mark.resize((size, size), Image.LANCZOS).save(path, "PNG")
        print("wrote", path)

    ico_path = os.path.join(OUT_DIR, "vibetube.ico")
    mark.save(
        ico_path,
        format="ICO",
        sizes=[(16, 16), (20, 20), (24, 24), (32, 32), (40, 40), (48, 48), (64, 64), (128, 128), (256, 256)],
    )

    print("wrote", png_path)
    print("wrote", ico_path)


if __name__ == "__main__":
    main()
