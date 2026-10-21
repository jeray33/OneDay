#!/usr/bin/env python3
"""Builds the bundled GeoNames resources from GeoNames cities1000.txt.

Usage:
    curl -O https://download.geonames.org/export/dump/cities1000.zip
    unzip cities1000.zip
    python3 Tools/make_geonames_index.py cities1000.txt OneDay/Resources/GeoNamesCities.dat \
        [OneDay/Resources/GeoNamesTimeZones.dat]

GeoNamesCities.dat: raw-deflate-compressed UTF-8 TSV read by
OfflinePlaceIndex, one town per line: lat, lon, country code, population,
name, Han names ("|"-joined).

GeoNamesTimeZones.dat: raw-deflate-compressed binary read by TimeZoneIndex.
The globe is split into 0.1° cells; each cell holding a town maps to the IANA
zone of its most populous town. Layout (little-endian):
    b"TZG1", u16 zoneCount, zoneCount × (u8 length, UTF-8 id),
    u32 cellCount, cellCount × (i32 cellKey, u16 zoneIndex)
with cellKey = floor((lat + 90) * 10) * 3600 + floor((lon + 180) * 10).

Data © GeoNames (https://www.geonames.org), CC BY 4.0.
"""
from __future__ import annotations

import math
import re
import struct
import sys
import zlib

# Historical, abandoned, destroyed or merely "section of" places are not towns.
SKIPPED_CODES = {"PPLH", "PPLQ", "PPLW", "PPLCH", "PPLX"}
HAN = re.compile(r"^[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff·・]+$")
KANA = re.compile(r"[\u3040-\u30ff]")


def han_names(alternates: str) -> list[str]:
    seen = []
    for name in alternates.split(","):
        name = name.strip()
        if name and HAN.match(name) and not KANA.search(name) and name not in seen:
            seen.append(name)
    return seen[:4]


def deflate(data: bytes) -> bytes:
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    return compressor.compress(data) + compressor.flush()


def main(source: str, destination: str, zones_destination: str | None) -> None:
    rows = []
    cells: dict[int, tuple[str, int]] = {}
    with open(source, encoding="utf-8") as handle:
        for line in handle:
            c = line.rstrip("\n").split("\t")
            if len(c) < 18 or c[6] != "P" or c[7] in SKIPPED_CODES:
                continue
            latitude, longitude = float(c[4]), float(c[5])
            population = int(c[14] or 0)
            rows.append("\t".join([
                f"{latitude:.4f}", f"{longitude:.4f}", c[8],
                str(population), c[1], "|".join(han_names(c[3])),
            ]))
            zone = c[17]
            if zone:
                key = (math.floor((latitude + 90) * 10) * 3600
                       + math.floor((longitude + 180) * 10))
                if key not in cells or population > cells[key][1]:
                    cells[key] = (zone, population)

    data = ("\n".join(rows) + "\n").encode("utf-8")
    packed = deflate(data)
    with open(destination, "wb") as handle:
        handle.write(packed)
    print(f"{len(rows)} towns, {len(data) / 1e6:.1f} MB raw, {len(packed) / 1e6:.1f} MB packed")

    if zones_destination:
        zones = sorted({zone for zone, _ in cells.values()})
        index = {zone: i for i, zone in enumerate(zones)}
        out = bytearray(b"TZG1")
        out += struct.pack("<H", len(zones))
        for zone in zones:
            encoded = zone.encode("utf-8")
            out += struct.pack("<B", len(encoded)) + encoded
        out += struct.pack("<I", len(cells))
        for key in sorted(cells):
            out += struct.pack("<iH", key, index[cells[key][0]])
        packed_zones = deflate(bytes(out))
        with open(zones_destination, "wb") as handle:
            handle.write(packed_zones)
        print(f"{len(cells)} cells, {len(zones)} zones, {len(packed_zones) / 1e3:.0f} KB packed")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
