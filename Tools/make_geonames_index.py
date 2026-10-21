#!/usr/bin/env python3
"""Builds OneDay/Resources/GeoNamesCities.dat from GeoNames cities1000.txt.

Usage:
    curl -O https://download.geonames.org/export/dump/cities1000.zip
    unzip cities1000.zip
    python3 Tools/make_geonames_index.py cities1000.txt OneDay/Resources/GeoNamesCities.dat

Output: raw-deflate-compressed UTF-8 TSV read by OfflinePlaceIndex, one town
per line: lat, lon, country code, population, name, Han names ("|"-joined).
Data © GeoNames (https://www.geonames.org), CC BY 4.0.
"""
import re
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


def main(source: str, destination: str) -> None:
    rows = []
    with open(source, encoding="utf-8") as handle:
        for line in handle:
            c = line.rstrip("\n").split("\t")
            if len(c) < 15 or c[6] != "P" or c[7] in SKIPPED_CODES:
                continue
            rows.append("\t".join([
                f"{float(c[4]):.4f}", f"{float(c[5]):.4f}", c[8],
                c[14] or "0", c[1], "|".join(han_names(c[3])),
            ]))
    data = ("\n".join(rows) + "\n").encode("utf-8")
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    packed = compressor.compress(data) + compressor.flush()
    with open(destination, "wb") as handle:
        handle.write(packed)
    print(f"{len(rows)} towns, {len(data) / 1e6:.1f} MB raw, {len(packed) / 1e6:.1f} MB packed")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
