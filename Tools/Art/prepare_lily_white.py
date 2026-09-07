"""Build dairi Lily White's expression atlas and non-destructive motion assets.

Requires Pillow. Usage: python prepare_lily_white.py SOURCE_DIRECTORY
The original 22 RGBA images are never modified. Channels in motion.png encode
wings (R), loose hair (G), and skirt (B), not colors to display on the portrait.
"""

import argparse
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter


FACE_BOX = (80, 200, 240, 360)
CANVAS_SIZE = (650, 990)


def region_mask(polygons, blur=5):
    mask = Image.new("L", CANVAS_SIZE, 0)
    drawing = ImageDraw.Draw(mask)
    for polygon in polygons:
        drawing.polygon(polygon, fill=255)
    return mask.filter(ImageFilter.GaussianBlur(blur))


def build_assets(source_directory, output_directory):
    frames = []
    for index in range(22):
        with Image.open(source_directory / f"48553357_p{index}.png") as image:
            if image.size != CANVAS_SIZE or image.mode != "RGBA":
                raise ValueError(f"Unexpected source format: frame {index}")
            frames.append(image.copy())

    atlas = Image.new("RGBA", (800, 800))
    for index, frame in enumerate(frames[1:]):
        reconstructed = frames[0].copy()
        face = frame.crop(FACE_BOX)
        reconstructed.paste(face, FACE_BOX[:2])
        if ImageChops.difference(reconstructed, frame).getbbox(alpha_only=False):
            raise ValueError(f"Expression {index + 1} changes pixels outside FACE_BOX")
        atlas.paste(face, ((index % 5) * 160, (index // 5) * 160))

    wings = region_mask([
        [(290, 171), (418, 84), (572, 19), (549, 86), (511, 187),
         (474, 276), (409, 329), (362, 357), (346, 324), (416, 283),
         (445, 247), (446, 214), (426, 166), (401, 148), (365, 155),
         (337, 191), (315, 224)],
        [(158, 115), (208, 22), (269, 154), (257, 154), (223, 130)],
    ])
    hair = region_mask([
        [(242, 225), (286, 243), (316, 227), (332, 198), (349, 158),
         (375, 141), (406, 139), (437, 157), (451, 188), (477, 214),
         (445, 213), (414, 202), (392, 216), (377, 247), (402, 255),
         (432, 274), (416, 296), (363, 315), (346, 347), (370, 360),
         (339, 381), (320, 354), (324, 323), (287, 333), (262, 349),
         (253, 329), (266, 306), (239, 316), (216, 299)],
        [(69, 292), (83, 311), (79, 346), (101, 368), (88, 380),
         (68, 351), (65, 330)],
    ], blur=8)
    skirt = region_mask([
        [(163, 491), (230, 489), (295, 528), (341, 526), (363, 469),
         (405, 441), (466, 448), (562, 424), (586, 461), (621, 467),
         (630, 540), (600, 574), (559, 571), (549, 611), (584, 630),
         (574, 699), (535, 722), (492, 718), (455, 761), (352, 774),
         (280, 746), (231, 710), (210, 701), (167, 711), (145, 663),
         (143, 620), (173, 591), (147, 562), (133, 540)],
    ], blur=16)
    for vertical in range(CANVAS_SIZE[1]):
        for horizontal in range(CANVAS_SIZE[0]):
            distance = ((horizontal - 316) ** 2 + (vertical - 353) ** 2) ** 0.5
            strength = min(1.0, max(0.0, (distance - 30) / 310))
            wings.putpixel((horizontal, vertical), round(wings.getpixel((horizontal, vertical)) * strength))
    motion = Image.merge("RGB", (wings, hair, skirt))

    eyes = region_mask([
        [(100, 257), (109, 255), (121, 267), (126, 284),
         (125, 304), (111, 308), (100, 286)],
        [(147, 239), (169, 237), (190, 243), (203, 257),
         (201, 282), (186, 290), (153, 287), (145, 266)],
    ], blur=1.2)
    blink = Image.new("RGBA", CANVAS_SIZE)
    eyes_box = eyes.getbbox()
    blink.paste(frames[5].crop(eyes_box), eyes_box[:2])
    blink.putalpha(ImageChops.multiply(eyes, frames[5].getchannel("A")))

    output_directory.mkdir(parents=True, exist_ok=True)
    frames[0].save(output_directory / "lily-white-stand.png", optimize=True)
    atlas.save(output_directory / "emos.png", optimize=True)
    motion.save(output_directory / "motion.png", optimize=True)
    blink.save(output_directory / "blink.png", optimize=True)
    print(f"Built {output_directory}: 21 exact expressions, blink overlay, RGB motion weights")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_directory", type=Path)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[2] / "Resources/Charas/lily-white-stand")
    arguments = parser.parse_args()
    build_assets(arguments.source_directory, arguments.output)
