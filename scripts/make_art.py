#!/usr/bin/env python3
"""
Art for Animals Attack Zombies: the Workshop preview and the mod's icon, poster and thumb.
Run it from anywhere, with Project Zomboid installed:

    python scripts/make_art.py

The picture is the mod in one line: a bull, a boar and a ram closing in on a zombie, staggered
so the boar leads and the other two flank it. Every piece is a vanilla item
icon read out of the game's UI2.pack at build time, the same way TienInspectWeapon's
make_art.py does it; nothing extracted is written here, only the composites. The layout
follows the sibling animal mods: vanilla icons on a transparent background, scaled up by
whole numbers, 256 square for the preview and that same picture at 80 square for the rest.
"""

import io
import os
import re
import struct

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = os.path.join(ROOT, "Contents", "mods", "AnimalsAttackZombies", "42")

# Set PZ_HOME to point at the install if it is somewhere these do not guess.
PZ_CANDIDATES = [
    r"C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid",
    r"C:\Program Files\Steam\steamapps\common\ProjectZomboid",
    os.path.expanduser("~/.steam/steam/steamapps/common/ProjectZomboid"),
    os.path.expanduser("~/Library/Application Support/Steam/steamapps/common/ProjectZomboid"),
]

# (icon, whole-number scale, centre, flip), drawn in this order, so later ones sit in front.
# Every animal faces the zombie on the right: the bull and pig heads face left in the game
# and are flipped, the sheep head already faces right.
ANIMALS = [
    ("Item_Head_CowMale_Black", 3, (96, 82), True),    # bull, top
    ("Item_Head_Sheep_White", 3, (76, 170), False),    # ram, bottom left
    ("Item_Head_PigMale_Pink", 3, (130, 128), True),   # boar, leading in the middle
]
ZOMBIE = ("Item_DeadPerson_MaleZombie", 3, (214, 128))


def pz_home():
    env = os.environ.get("PZ_HOME")
    for path in ([env] if env else []) + PZ_CANDIDATES:
        if path and os.path.isdir(os.path.join(path, "media")):
            return path
    raise SystemExit("Could not find Project Zomboid. Set PZ_HOME to the install directory.")


_PACK = {}


def pack_index():
    """
    Every icon in UI2.pack, as name -> (page, rectangle). The pack is a run of
    length-prefixed names, each followed by eight little-endian int32s (x, y, w, h,
    offsetX, offsetY, originalW, originalH), with each atlas page's PNG after its entries.
    See TienInspectWeapon/scripts/make_art.py for the long version.
    """
    if _PACK:
        return _PACK["index"]

    blob = open(os.path.join(pz_home(), "media", "texturepacks", "UI2.pack"), "rb").read()
    pages = list(zip(
        [m.start() for m in re.finditer(rb"\x89PNG\r\n\x1a\n", blob)],
        [m.start() + 12 for m in re.finditer(rb"IEND\xaeB`\x82", blob)],
    ))

    index = {}
    for match in re.finditer(rb"[A-Za-z0-9_]{3,60}", blob):
        at, run = match.start(), match.group()
        if at < 4:
            continue
        length = struct.unpack_from("<i", blob, at - 4)[0]
        if not 3 <= length <= len(run):
            continue
        try:
            rect = struct.unpack_from("<8i", blob, at + length)
        except struct.error:
            continue
        page = next((i for i, p in enumerate(pages) if p[0] > at), None)
        if page is not None:
            index[run[:length].decode()] = (page, rect)

    _PACK.update(blob=blob, pages=pages, sheets={}, index=index)
    return index


def pack_icon(name):
    """One icon at the size the game draws it, trimmed margins put back."""
    index = pack_index()
    if name not in index:
        raise SystemExit("No icon named %s in UI2.pack" % name)
    page, (x, y, w, h, ox, oy, ow, oh) = index[name]
    if page not in _PACK["sheets"]:
        start, end = _PACK["pages"][page]
        _PACK["sheets"][page] = Image.open(io.BytesIO(_PACK["blob"][start:end])).convert("RGBA")
    icon = Image.new("RGBA", (ow, oh), (0, 0, 0, 0))
    icon.paste(_PACK["sheets"][page].crop((x, y, x + w, y + h)), (ox, oy))
    return icon


def flipped(icon):
    return icon.transpose(Image.FLIP_LEFT_RIGHT)


def paste_scaled(target, art, scale, centre):
    """Nearest-neighbour by a whole number only, or the pixel art turns to mush."""
    grown = art.resize((art.width * scale, art.height * scale), Image.NEAREST)
    target.alpha_composite(grown, (int(centre[0] - grown.width / 2), int(centre[1] - grown.height / 2)))


def preview():
    img = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
    for name, scale, centre, flip in ANIMALS:
        icon = pack_icon(name)
        paste_scaled(img, flipped(icon) if flip else icon, scale, centre)
    name, scale, centre = ZOMBIE
    paste_scaled(img, pack_icon(name), scale, centre)
    return img


def main():
    img = preview()
    img.save(os.path.join(ROOT, "preview.png"))
    small = img.resize((80, 80), Image.LANCZOS)
    for name in ("icon.png", "poster.png", "thumb.png"):
        small.save(os.path.join(MOD, name))
    print("wrote preview.png and 42/icon.png, poster.png, thumb.png")


if __name__ == "__main__":
    main()
