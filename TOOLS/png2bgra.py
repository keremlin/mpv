#!/usr/bin/env python3
"""Convert an image into the raw BGRA data mpv's overlay-add command wants.

The OSC uses this for the idle logo: drop the result into mpv's config
directory as "mpv-logo.<width>x<height>.bgra" and it is used instead of the
drawn logo. See DOCS/man/osc.rst.

mpv expects premultiplied alpha. Artwork that was drawn as light on a black
background has no alpha channel to begin with, so --alpha-from-luma derives one
from brightness: black falls away and the glow stays, which is what such an
image means anyway. Artwork that already has a real alpha channel does not need
it.

Requires Pillow (pip install pillow).

Example:
    python TOOLS/png2bgra.py logo.png ~/.config/mpv --height 427 \\
        --alpha-from-luma --feather 0.1
"""

import argparse
import os
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("this needs Pillow: pip install pillow")


def feather_factor(i, n, frac):
    """Ramp from 0 at the edge to 1 once `frac` of the way in."""
    if frac <= 0:
        return 1.0
    edge = n * frac
    d = min(i, n - 1 - i)
    return 1.0 if d >= edge else d / edge


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("image")
    p.add_argument("outdir", help="directory to write mpv-logo.<w>x<h>.bgra into")
    p.add_argument("--height", type=int, default=427,
                   help="output height in pixels, width follows the aspect (default: 427)")
    p.add_argument("--alpha-from-luma", action="store_true",
                   help="derive alpha from brightness, for art drawn on black")
    p.add_argument("--feather", type=float, default=0.0, metavar="FRAC",
                   help="fade out this fraction of each edge, to hide a glow "
                        "that runs off the frame (e.g. 0.1)")
    p.add_argument("--name", default="mpv-logo",
                   help="base name of the output file (default: mpv-logo)")
    args = p.parse_args()

    im = Image.open(args.image)
    has_alpha = im.mode in ("RGBA", "LA") or "transparency" in im.info
    im = im.convert("RGBA")
    w = max(1, round(im.width * args.height / im.height))
    im = im.resize((w, args.height), Image.LANCZOS)
    px = im.load()

    if not has_alpha and not args.alpha_from_luma:
        print("note: image has no alpha channel; without --alpha-from-luma the "
              "logo will show as a rectangle", file=sys.stderr)

    out = bytearray()
    for y in range(im.height):
        fy = feather_factor(y, im.height, args.feather)
        for x in range(im.width):
            r, g, b, a = px[x, y]
            if args.alpha_from_luma:
                a = max(r, g, b)
            a = int(a * fy * feather_factor(x, im.width, args.feather))
            # Premultiply, and never let a component exceed alpha: mpv treats
            # that as undefined and different VOs then disagree.
            out += bytes((min(b * a // 255, a), min(g * a // 255, a),
                          min(r * a // 255, a), a)) if not args.alpha_from_luma \
                else bytes((min(b, a), min(g, a), min(r, a), a))

    name = "%s.%dx%d.bgra" % (args.name, im.width, im.height)
    path = os.path.join(args.outdir, name)
    with open(path, "wb") as f:
        f.write(bytes(out))
    print("wrote %s (%d bytes)" % (path, len(out)))


if __name__ == "__main__":
    main()
