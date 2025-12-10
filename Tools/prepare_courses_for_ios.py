# prepare_courses_for_ios.py
# Convert QuACS data -> compact JSON for your iOS app.
# Run from the folder that contains `quacs-data/`:
#   cd ~/Documents/quacs-shit
#   python3 prepare_courses_for_ios.py

import json
from pathlib import Path

# ----- CONFIG -----
TERM = "202509"   # change to the term you want, e.g. 202501(spring 2025), 202509(Fall 2025), 202609(Spring 2026), etc.

DATA_ROOT = Path("quacs-data") / "semester_data" / TERM

catalog_path = DATA_ROOT / "catalog.json"
courses_path = DATA_ROOT / "courses.json"

print(f"Using catalog: {catalog_path}")
print(f"Using courses: {courses_path}")

# ----- LOAD SOURCE FILES -----

with catalog_path.open() as f:
    catalog = json.load(f)

with courses_path.open() as f:
    schools = json.load(f)

# ----- HELPERS -----

def military_to_str(t: int) -> str:
    """930 -> '09:30', 1430 -> '14:30'"""
    if t is None or t < 0:
        return ""
    h = t // 100
    m = t % 100
    return f"{h:02d}:{m:02d}"

# ----- BUILD COURSE MAP -----

courses_by_key = {}  # "CSCI-2300" -> {...}

# Base info from catalog (nice titles + descriptions)
for key, item in catalog.items():
    subj = item.get("subj", "")
    crse = item.get("crse", "")
    courses_by_key[key] = {
        "subject": subj,
        "number": crse,
        "title": item.get("name", f"{subj} {crse}").strip(),
        "description": item.get("description", "").strip(),
        "sections": [],
    }

# Merge in SIS course/section/timeslot info
for school in schools:
    for course in school.get("courses", []):
        subj = course.get("subj", "")
        crse = course.get("crse", "")
        # some entries don't have name → fall back gracefully
        name = (course.get("name") or f"{subj} {crse}").strip()
        key = f"{subj}-{crse}"

        if key not in courses_by_key:
            courses_by_key[key] = {
                "subject": subj,
                "number": crse,
                "title": name,
                "description": "",
                "sections": [],
            }

        for section in course.get("sections", []):
            meetings = []
            for ts in section.get("timeslots", []):
                days = ts.get("days") or []
                start = military_to_str(ts.get("timeStart", -1))
                end = military_to_str(ts.get("timeEnd", -1))
                location = ts.get("location", "").strip()

                if not days or not start or not end:
                    continue

                meetings.append(
                    {
                        "days": days,      # e.g. ["M", "R"]
                        "start": start,    # "09:30"
                        "end": end,        # "10:50"
                        "location": location,
                    }
                )

            courses_by_key[key]["sections"].append(
                {
                    "crn": section.get("crn"),
                    "section": section.get("section", "").strip(),
                    "instructor": section.get("instructor", "").strip(),
                    "meetings": meetings,
                }
            )

output = {
    "term": TERM,
    "courses": list(courses_by_key.values()),
}

out_path = Path(f"rpi_courses_{TERM}.json")
with out_path.open("w") as f:
    json.dump(output, f, indent=2)

print(f"Wrote {out_path.resolve()}")