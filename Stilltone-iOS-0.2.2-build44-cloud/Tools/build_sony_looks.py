"""Build the two display-referred Sony LUTs. Run with the folder containing FL2.dcp and FL3.dcp."""
import argparse
import base64
import colorsys
import hashlib
import itertools
import json
import math
import re
import struct
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LUMA = (0.2126, 0.7152, 0.0722)
TO_PROPHOTO = ((.529345, .330073, .140582), (.098374, .873462, .028164), (.016883, .117672, .865445))
TO_SRGB = ((2.034075, -.727335, -.306740), (-.228813, 1.231730, -.002917), (-.008570, -.153286, 1.161856))
# Previous release's encoded neutral midpoint, before the requested 30% linear-light reduction.
MIDPOINT = {"FL2": 165.6 / 255, "FL3": 164.0 / 255}


def decode(x):
    return x / 12.92 if x <= .04045 else ((x + .055) / 1.055) ** 2.4


def encode(x):
    return 12.92 * x if x <= .0031308 else 1.055 * x ** (1 / 2.4) - .055


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def read_profile(path):
    data = path.read_bytes()
    if data[:4] != b"II\x52\x43":
        raise ValueError(f"Expected a little-endian DCP in {path}")
    offset, = struct.unpack_from("<I", data, 4)
    count, = struct.unpack_from("<H", data, offset)
    tags = {}
    for i in range(count):
        entry = offset + 2 + i * 12
        tag, kind, n, address = struct.unpack_from("<HHII", data, entry)
        if tag not in (50981, 50982, 51108):
            continue
        fmt = {4: "I", 11: "f"}[kind]
        tags[tag] = struct.unpack_from(f"<{n}{fmt}", data, address if n > 1 else entry + 8)
    dims, table = tags[50981], tags[50982]
    if len(dims) != 3 or min(dims) < 2 or len(table) != 3 * math.prod(dims) or tags[51108] != (1,):
        raise ValueError(f"Invalid sRGB-encoded DCP look table in {path}")
    return dims, table


def sample(profile, h, s, v):
    (nh, ns, nv), table = profile
    points = (h * nh, s * (ns - 1), min(1., v) * (nv - 1))
    base = tuple(math.floor(x) for x in points)
    frac = tuple(x - i for x, i in zip(points, base))
    out = [0., 0., 0.]
    # DNG LookTableData stores saturation fastest, hue next, and value slowest.
    for dh, ds, dv in itertools.product((0, 1), repeat=3):
        hue = (base[0] + dh) % nh
        sat = min(ns - 1, base[1] + ds)
        val = min(nv - 1, base[2] + dv)
        p = 3 * ((val * nh + hue) * ns + sat)
        w = (frac[0] if dh else 1 - frac[0]) * (frac[1] if ds else 1 - frac[1]) * (frac[2] if dv else 1 - frac[2])
        for c in range(3):
            out[c] += table[p + c] * w
    return out


def render(rgb, profile, mid):
    linear = tuple(map(decode, rgb))
    y = dot(linear, LUMA)
    if y == 0:
        return (0., 0., 0.)
    h, s, v = colorsys.rgb_to_hsv(*(dot(row, linear) for row in TO_PROPHOTO))
    hue_shift, sat_scale, val_scale = sample(profile, h, s, encode(v))
    wide = colorsys.hsv_to_rgb((h + hue_shift / 360.) % 1., min(1., s * sat_scale), v)
    color = tuple(dot(row, wide) for row in TO_SRGB)
    color_y = dot(color, LUMA)

    # Camera frames already carry a display tone curve. Preserve the DCP's colour
    # differences without applying its RAW tone curve or sensor calibration twice.
    x = encode(y)
    white = .985
    lift = mid - .5 + (1. - white) * .25
    tone = x + lift * 4 * x * (1 - x) - (1 - white) * x * x
    target = decode(tone)
    # Value scaling belongs to the DCP's RAW exposure. Retain relative differences
    # between colours, diminishing this contribution towards the display white point.
    neutral_scale = sample(profile, h, 0., encode(v))[2]
    relative = val_scale / max(1e-8, neutral_scale) - 1.
    target *= 1 + .30 * min(.5, max(-.5, relative)) * (1 - x) ** 2
    # The near-white rows of these camera profiles almost remove pale colours.
    # Bring the display colour back gradually so warm light stays distinct from cool light.
    t = min(1., max(0., (x - .63) / .32))
    retain = .65 * t * t * (3 - 2 * t)
    chroma = tuple(((1 - retain) * (c / color_y - 1.) + retain * (original / y - 1.)) * target
                   for c, original in zip(color, linear))

    # Roll chroma into the sRGB gamut around fixed luminance; clipping individual
    # channels would flatten detail and turn bright colours into uniform patches.
    occupancy = max(max(chroma) / (1. - target), -min(chroma) / target)
    factor = 1.
    if occupancy > .9:
        factor = (1. - .1 / (1. + (occupancy - .9) / .1)) / occupancy
    return tuple(encode(target + factor * component) for component in chroma)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profiles", type=Path)
    args = parser.parse_args()
    entries = {}
    for name, old_mid in MIDPOINT.items():
        profile = read_profile(args.profiles / (name + ".dcp"))
        mid = encode(.70 * decode(old_mid))
        data = bytearray()
        for blue, green, red in itertools.product(range(33), repeat=3):
            out = render((red / 32, green / 32, blue / 32), profile, mid)
            if not all(0 <= c <= 1 for c in out):
                raise ValueError(f"{name} produced invalid colour {out}")
            data.extend(struct.pack("<4f", *out, 1.))
        (ROOT / (name + ".rgba")).write_bytes(data)
        entries[name] = {"size": 33, "sha256": hashlib.sha256(data).hexdigest(),
                         "data": base64.b64encode(data).decode("ascii")}
    for page in ("FL-Camera-Review.html", "Stilltone-Album.html"):
        path = ROOT / page
        original = path.read_bytes()
        html = original
        for name, entry in entries.items():
            pattern = rb'(<script id="lut-' + name.encode() + rb'" type="application/json">)[^<]+(</script>)'
            payload = json.dumps(entry, separators=(",", ":")).encode("ascii")
            html, count = re.subn(pattern, lambda match: match[1] + payload + match[2], html)
            if count != 1:
                raise ValueError(f"Expected exactly one {name} entry in {page}")
        if path.read_bytes() != original:
            raise RuntimeError(f"Concurrent edit in {page}")
        path.write_bytes(html)


if __name__ == "__main__":
    main()
