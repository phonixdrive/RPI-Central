#!/usr/bin/env python3
"""Build the bundled RPI campus building footprints used by friend locations.

The app resolves a shared GPS fix to "In DCC" / "Near Folsom Library" and maps
schedule rooms such as "Darrin Communications Center 308" to a building. The
footprints come from OpenStreetMap (ODbL). Re-run this script when campus
buildings change:

    python3 Tools/campus_buildings/build_campus_buildings.py --fetch

or, with a saved Overpass response:

    python3 Tools/campus_buildings/build_campus_buildings.py --input rpi_osm.json
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import sys
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
OUTPUT_PATH = REPO_ROOT / "RPI Central" / "Location" / "CampusBuildings.json"

# South, west, north, east. Covers the main campus, downtown Troy housing,
# East Campus athletics, and the RAHP/Colonie/Bryckwyck apartments.
BOUNDING_BOX = (42.7200, -73.6950, 42.7400, -73.6580)

OVERPASS_URL = "https://overpass-api.de/api/interpreter"
OVERPASS_QUERY = (
    "[out:json][timeout:60];"
    "(way[\"building\"]({s},{w},{n},{e});relation[\"building\"]({s},{w},{n},{e}););"
    "out body geom;"
).format(s=BOUNDING_BOX[0], w=BOUNDING_BOX[1], n=BOUNDING_BOX[2], e=BOUNDING_BOX[3])

# id, display name, short label, category, OSM names, extra aliases.
# Aliases include the exact building prefixes used in SIS room strings.
BUILDINGS = [
    # Academic
    ("sage", "Russell Sage Laboratory", "Sage Lab", "academic", ["Russell Sage Laboratory"], ["Sage Lab", "SAGE"]),
    ("dcc", "Darrin Communications Center", "DCC", "academic", ["Darrin Communications Center"], ["DCC"]),
    ("jec", "Jonsson Engineering Center", "JEC", "academic", ["J Erik Jonsson Engineering Center"], ["JEC", "Jonsson Engineering Center"]),
    ("low", "Low Center for Industrial Innovation", "Low / CII", "academic", ["Low Center For Industrial Innovation"], ["Low Center for Industrial Inn.", "Low Center", "CII", "LOW"]),
    ("jrsc", "Jonsson-Rowland Science Center", "JRSC", "academic", ["Jonsson-Rowland Science Center"], ["JROWL", "JRSC", "Jonsson Rowland"]),
    ("carnegie", "Carnegie Building", "Carnegie", "academic", ["Carnegie Building"], ["CARNEG"]),
    ("ricketts", "Ricketts Building", "Ricketts", "academic", ["Ricketts Building"], ["RICKETTS"]),
    ("pittsburgh", "Pittsburgh Building", "Pitt", "academic", ["Pittsburgh Building"], ["PITTS"]),
    ("amos-eaton", "Amos Eaton Hall", "Amos Eaton", "academic", ["Amos Eaton Hall"], ["AE"]),
    ("greene", "Greene Building", "Greene", "academic", ["Greene Building"], ["GREENE"]),
    ("west-hall", "West Hall", "West Hall", "academic", ["West Hall"], []),
    ("troy-building", "Troy Building", "Troy Bldg", "academic", ["Troy Building"], ["TROY"]),
    ("walker", "Walker Laboratory", "Walker Lab", "academic", ["Walker Laboratory"], ["WL"]),
    ("lally", "Lally Hall", "Lally", "academic", ["Lally Hall"], ["LALLY"]),
    ("academy-hall", "Academy Hall", "Academy Hall", "academic", ["Academy Hall"], ["ACADMY"]),
    ("mrc", "Materials Research Center", "MRC", "academic", ["Materials Research Center"], ["MRC"]),
    ("vcc", "Voorhees Computing Center", "VCC", "academic", ["Voorhees Computing Center"], ["VCC"]),
    ("folsom", "Folsom Library", "Folsom", "library", ["Folsom Library"], ["Library"]),
    ("cogswell", "Cogswell Laboratory", "Cogswell", "academic", ["Cogswell Laboratory"], []),
    ("winslow", "Winslow Building", "Winslow", "academic", ["Winslow Building"], ["WINSLW"]),
    ("empire-state", "Empire State Hall", "Empire State", "academic", ["Empire State Hall"], []),
    ("cbis", "Center for Biotechnology and Interdisciplinary Studies", "CBIS", "academic", ["Center for Biotechnology and Interdisciplinary Studies"], ["CBIS", "Biotech"]),
    ("empac", "EMPAC", "EMPAC", "arts", ["Experimental Media and Performing Arts Center (EMPAC)"], ["Experimental Media and Performing Arts Center"]),
    ("nes", "Nuclear Engineering and Science Building", "NES", "academic", ["Nuclear Engineering and Science Building (NES)"], ["Nuclear Eng. And Sci. Bldg", "NES"]),
    ("gurley", "Gurley Building", "Gurley", "academic", ["W. & L. E. Gurley Building"], ["Gurley Building"]),
    ("h-building", "H Building", "H Bldg", "academic", ["H Building"], ["Peoples Ave Complex H"]),
    ("j-building", "J Building", "J Bldg", "academic", ["J Building - Incubator Centre"], ["Peoples Ave Complex J", "Incubator Center"]),
    # Student life, dining, and admin
    ("union", "Rensselaer Student Union", "The Union", "studentLife", ["Rensselaer Student Union"], ["Student Union", "Union"]),
    ("commons", "Commons Dining Hall", "Commons", "dining", ["Commons Dining Hall"], ["Commons"]),
    ("sage-dining", "Russell Sage Dining Hall", "Sage Dining", "dining", ["Russell Sage Dining Hall"], ["Sage Dining Hall"]),
    ("playhouse", "RPI Playhouse", "Playhouse", "arts", ["RPI Playhouse"], []),
    ("chapel", "RPI Chapel and Cultural Center", "Chapel", "studentLife", ["RPI Chapel and Cultural Center"], ["Chapel + Cultural Center"]),
    ("admissions", "Admissions", "Admissions", "admin", ["Admissions"], []),
    ("heffner", "Heffner Alumni House", "Heffner", "admin", ["Heffner Alumni House"], []),
    ("off-campus-commons", "Off-Campus Commons", "Off-Campus Commons", "studentLife", ["RPI Off-Campus Commons"], []),
    # Athletics
    ("87-gym", "'87 Gymnasium", "'87 Gym", "athletics", ["'87 Gymnasium"], ["87 Gym"]),
    ("arc", "Alumni Sports and Recreation Center", "ARC", "athletics", ["Alumni Sports And Recreation Center"], ["Alumni Sports and Rec Center", "ARC"]),
    ("mueller", "Mueller Center", "Mueller", "athletics", ["Mueller Center"], []),
    ("robison-pool", "Robison Pool", "Robison Pool", "athletics", ["Robison Pool"], []),
    ("ecav", "East Campus Athletic Village", "ECAV", "athletics", ["East Campus Athletic Village Arena & Stadium"], ["ECAV"]),
    ("houston", "Houston Field House", "Houston", "athletics", ["Houston Field House"], []),
    # Residence halls
    ("barh", "Burdett Avenue Residence Hall", "BARH", "residence", ["Burdett Avenue Residence Hall"], ["BARH"]),
    ("quad", "Quadrangle Complex", "The Quad", "residence", ["Quadrangle Complex"], ["Quad"]),
    ("north-hall", "North Hall", "North Hall", "residence", ["North Hall"], []),
    ("blitman", "Blitman Residence Commons", "Blitman", "residence", ["Blitman Residence Commons (RPI)"], ["Blitman"]),
    ("polytechnic", "Polytechnic Residence Commons", "Polytech", "residence", ["Polytechnic Residence Commons"], ["Polytechnic"]),
    ("city-station", "City Station", "City Station", "residence", ["City Station East", "City Station South", "City Station West"], []),
    ("barton", "Barton Hall", "Barton", "residence", ["Barton Hall"], []),
    ("bray", "Bray Hall", "Bray", "residence", ["Bray Hall"], []),
    ("cary", "Cary Hall", "Cary", "residence", ["Cary Hall"], []),
    ("crockett", "Crockett Hall", "Crockett", "residence", ["Crockett Hall"], []),
    ("davison", "Davison Hall", "Davison", "residence", ["Davison Hall"], []),
    ("hall-hall", "Hall Hall", "Hall Hall", "residence", ["Hall Hall"], []),
    ("nason", "Nason Hall", "Nason", "residence", ["Nason Hall"], []),
    ("nugent", "Nugent Hall", "Nugent", "residence", ["Nugent Hall"], []),
    ("sharp", "Sharp Hall", "Sharp", "residence", ["Sharp Hall"], []),
    ("warren", "Warren Hall", "Warren", "residence", ["Warren Hall"], []),
    ("colonie", "Colonie Apartments", "Colonie", "residence", ["Colonie Apartments A", "Colonie Apartments B", "Colonie Apartments C", "Colonie Apartments D"], ["Colonie"]),
    ("bryckwyck", "Bryckwyck", "Bryckwyck", "residence", ["Bryckwyck (A-E)", "Bryckwyck (F-G)"], []),
    ("rahp-a", "RAHP A", "RAHP A", "residence", [
        "RAHP A (Albright 71-76)", "RAHP A (Albright 81-88)", "RAHP A (Albright 91-98)",
        "RAHP A (Colvin 11-16)", "RAHP A (Colvin 21-30)", "RAHP A (Colvin 31-36)",
        "RAHP A (Colvin 41-44)", "RAHP A (Colvin 51-56)", "RAHP A (Colvin 61-66)",
    ], ["Albright", "Colvin"]),
    ("rahp-b", "RAHP B", "RAHP B", "residence", [
        "RAHP B (Beman 11-18)", "RAHP B (Beman 21-28)", "RAHP B (Brinsmade 11-16)",
        "RAHP B (Brinsmade 21-26)", "RAHP B (Brinsmade 31-36)", "RAHP B (Brinsmade 41-46)",
    ], ["Beman", "Brinsmade"]),
]

# Roughly 1.5 m. Keeps outlines recognizable while shrinking the file.
SIMPLIFY_TOLERANCE_METERS = 1.5


def fetch_overpass() -> dict:
    body = urllib.parse.urlencode({"data": OVERPASS_QUERY}).encode()
    request = urllib.request.Request(
        OVERPASS_URL,
        data=body,
        headers={
            "User-Agent": "RPICentral-building-builder/1.0",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=90) as response:
        return json.load(response)


def to_local_meters(lat: float, lon: float, origin_lat: float) -> tuple[float, float]:
    return (lon * 111_320.0 * math.cos(math.radians(origin_lat)), lat * 110_574.0)


def perpendicular_distance(point, start, end) -> float:
    (px, py), (sx, sy), (ex, ey) = point, start, end
    dx, dy = ex - sx, ey - sy
    if dx == 0 and dy == 0:
        return math.hypot(px - sx, py - sy)
    t = max(0.0, min(1.0, ((px - sx) * dx + (py - sy) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (sx + t * dx), py - (sy + t * dy))


def simplify(ring: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """Douglas-Peucker on a closed ring expressed as (lat, lon)."""
    if len(ring) <= 4:
        return ring
    origin_lat = ring[0][0]
    projected = [to_local_meters(lat, lon, origin_lat) for lat, lon in ring]

    keep = [False] * len(ring)
    keep[0] = keep[-1] = True
    stack = [(0, len(ring) - 1)]
    while stack:
        first, last = stack.pop()
        max_distance, index = 0.0, None
        for i in range(first + 1, last):
            distance = perpendicular_distance(projected[i], projected[first], projected[last])
            if distance > max_distance:
                max_distance, index = distance, i
        if index is not None and max_distance > SIMPLIFY_TOLERANCE_METERS:
            keep[index] = True
            stack.append((first, index))
            stack.append((index, last))

    simplified = [point for point, kept in zip(ring, keep) if kept]
    return simplified if len(simplified) >= 4 else ring


def outer_rings(element: dict) -> list[list[tuple[float, float]]]:
    if element["type"] == "way":
        geometry = element.get("geometry") or []
        return [[(p["lat"], p["lon"]) for p in geometry]] if len(geometry) >= 4 else []

    rings = []
    for member in element.get("members", []):
        if member.get("role") != "outer":
            continue
        geometry = member.get("geometry") or []
        if len(geometry) >= 4:
            rings.append([(p["lat"], p["lon"]) for p in geometry])
    return rings


def ring_area_and_centroid(ring):
    origin_lat = ring[0][0]
    points = [to_local_meters(lat, lon, origin_lat) for lat, lon in ring]
    area = cx = cy = 0.0
    for (x0, y0), (x1, y1) in zip(points, points[1:] + points[:1]):
        cross = x0 * y1 - x1 * y0
        area += cross
        cx += (x0 + x1) * cross
        cy += (y0 + y1) * cross
    area *= 0.5
    if abs(area) < 1e-9:
        lat = sum(p[0] for p in ring) / len(ring)
        lon = sum(p[1] for p in ring) / len(ring)
        return 0.0, (lat, lon)
    cx /= 6 * area
    cy /= 6 * area
    lon = cx / (111_320.0 * math.cos(math.radians(origin_lat)))
    lat = cy / 110_574.0
    return abs(area), (lat, lon)


def build(overpass: dict) -> dict:
    by_name: dict[str, list[dict]] = {}
    for element in overpass.get("elements", []):
        name = element.get("tags", {}).get("name")
        if name:
            by_name.setdefault(name, []).append(element)

    buildings = []
    missing = []
    for building_id, name, short_name, category, osm_names, aliases in BUILDINGS:
        polygons = []
        for osm_name in osm_names:
            for element in by_name.get(osm_name, []):
                polygons.extend(outer_rings(element))
        if not polygons:
            missing.append(name)
            continue

        weighted = [ring_area_and_centroid(ring) for ring in polygons]
        total_area = sum(area for area, _ in weighted) or 1.0
        center_lat = sum(area * c[0] for area, c in weighted) / total_area
        center_lon = sum(area * c[1] for area, c in weighted) / total_area

        buildings.append({
            "id": building_id,
            "name": name,
            "shortName": short_name,
            "category": category,
            "aliases": sorted(set(aliases + [name] + osm_names), key=str.lower),
            "center": [round(center_lat, 6), round(center_lon, 6)],
            "polygons": [
                [[round(lat, 6), round(lon, 6)] for lat, lon in simplify(ring)]
                for ring in polygons
            ],
        })

    if missing:
        print("warning: no OpenStreetMap footprint for: " + ", ".join(missing), file=sys.stderr)

    return {
        "source": "OpenStreetMap",
        "attribution": "Building footprints © OpenStreetMap contributors, available under the ODbL.",
        "generatedAt": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "campusBounds": {
            "south": BOUNDING_BOX[0],
            "west": BOUNDING_BOX[1],
            "north": BOUNDING_BOX[2],
            "east": BOUNDING_BOX[3],
        },
        "buildings": buildings,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--input", type=Path, help="Saved Overpass JSON response")
    group.add_argument("--fetch", action="store_true", help="Download fresh data from Overpass")
    parser.add_argument("--output", type=Path, default=OUTPUT_PATH)
    args = parser.parse_args()

    overpass = fetch_overpass() if args.fetch else json.loads(args.input.read_text())
    result = build(overpass)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, separators=(",", ":"), ensure_ascii=False) + "\n")
    print(f"Wrote {len(result['buildings'])} buildings to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
