#!/usr/bin/env python3
"""
rpi_academic_calendar_scraper.py

Scrapes RPI Registrar Academic Calendar and emits a normalized JSON:
{
  "source": "...",
  "academicYear": "2025",
  "generatedAt": "ISO8601",
  "terms": { "fall": {...}, "spring": {...} },
  "events": [ ... ]
}

Usage:
  python3 Tools/scrapers/rpi_academic_calendar_scraper.py --academic-year 25 --debug --out Data/Academic_calendar_25.json

If --out is omitted, it defaults to <repo_root>/Data/Academic_calendar_<yy>.json
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass, asdict
from datetime import datetime, date
from pathlib import Path
from typing import Optional, Tuple, List, Dict

import requests
from bs4 import BeautifulSoup


SOURCE_URL = "https://registrar.rpi.edu/academic-calendar"

MONTHS = {
    "Jan": 1, "January": 1,
    "Feb": 2, "February": 2,
    "Mar": 3, "March": 3,
    "Apr": 4, "April": 4,
    "May": 5,
    "Jun": 6, "June": 6,
    "Jul": 7, "July": 7,
    "Aug": 8, "August": 8,
    "Sep": 9, "Sept": 9, "September": 9,
    "Oct": 10, "October": 10,
    "Nov": 11, "November": 11,
    "Dec": 12, "December": 12,
}


@dataclass
class Tags:
    noClasses: bool = False
    holiday: bool = False
    followDay: bool = False
    finals: bool = False
    readingDays: bool = False
    break_: bool = False  # internal name, map to "break" in output

    def to_json(self) -> Dict[str, bool]:
        return {
            "noClasses": self.noClasses,
            "holiday": self.holiday,
            "followDay": self.followDay,
            "finals": self.finals,
            "readingDays": self.readingDays,
            "break": self.break_,
        }


@dataclass
class Event:
    title: str
    startDate: str
    endDate: str
    dow: Optional[str]
    tags: Tags

    def to_json(self) -> Dict:
        return {
            "title": self.title,
            "startDate": self.startDate,
            "endDate": self.endDate,
            "dow": self.dow,
            "tags": self.tags.to_json(),
        }


def repo_root_from_this_file() -> Path:
    # .../Tools/scrapers/rpi_academic_calendar_scraper.py -> repo root is 2 levels up
    return Path(__file__).resolve().parents[2]


def academic_year_to_years(yy: int) -> Tuple[int, int]:
    """
    academic_year=25 means Fall year 2025, Spring/Summer year 2026.
    """
    fall_year = 2000 + yy
    spring_year = fall_year + 1
    return fall_year, spring_year


def month_to_year(month_num: int, fall_year: int, spring_year: int) -> int:
    # Aug-Dec are fall_year, Jan-Jul are spring_year
    return fall_year if month_num >= 8 else spring_year


def normalize_ws(s: str) -> str:
    return re.sub(r"\s+", " ", s).strip()


def parse_month_name_to_num(s: str) -> Optional[int]:
    s = s.strip()
    if not s:
        return None
    # Allow "Sep" or "September"
    key = s[:3].title() if len(s) >= 3 else s.title()
    if key in MONTHS:
        return MONTHS[key]
    # Try full word
    return MONTHS.get(s.title())


DATE_SINGLE_RE = re.compile(r"^(?P<mon>[A-Za-z]{3,9})\s+(?P<day>\d{1,2})$")
DATE_RANGE_SAME_MON_RE = re.compile(r"^(?P<mon>[A-Za-z]{3,9})\s+(?P<d1>\d{1,2})\s*-\s*(?P<d2>\d{1,2})$")
DATE_RANGE_CROSS_MON_RE = re.compile(
    r"^(?P<m1>[A-Za-z]{3,9})\s+(?P<d1>\d{1,2})\s*-\s*(?P<m2>[A-Za-z]{3,9})\s+(?P<d2>\d{1,2})$"
)


def to_iso(d: date) -> str:
    return d.isoformat()


def infer_tags(title: str) -> Tags:
    t = title.lower()
    tags = Tags()

    # no classes
    if "no classes" in t:
        tags.noClasses = True

    # holiday heuristic
    if "staff holiday" in t or "holiday" in t:
        tags.holiday = True

    # follow-day
    if "follow a " in t and " class schedule" in t:
        tags.followDay = True

    # finals / reading / breaks
    if "final exams" in t:
        tags.finals = True
    if "reading/study" in t or "reading day" in t or "study day" in t:
        tags.readingDays = True
    if "break-no classes" in t or ("break" in t and "no classes" in t):
        tags.break_ = True
        tags.noClasses = True

    return tags


def parse_date_cell(date_cell: str, current_month_num: Optional[int], fall_year: int, spring_year: int) -> Tuple[date, date, Optional[int]]:
    """
    Returns (start_date, end_date, new_current_month_num)
    Handles:
      - "Sep 1"
      - "Sep 25 - Sep 26"
      - "Dec 23 - Jan 9"
    current_month_num is used only if the cell is missing a month (rare); we try not to rely on it.
    """
    s = normalize_ws(date_cell)

    # Some rows may show like "Sep 25 - Sep 26" with month repeated or not.
    m = DATE_RANGE_CROSS_MON_RE.match(s)
    if m:
        m1 = parse_month_name_to_num(m.group("m1"))
        m2 = parse_month_name_to_num(m.group("m2"))
        d1 = int(m.group("d1"))
        d2 = int(m.group("d2"))
        if not m1 or not m2:
            raise ValueError(f"Unrecognized month in date range: {s}")

        y1 = month_to_year(m1, fall_year, spring_year)
        y2 = month_to_year(m2, fall_year, spring_year)
        return date(y1, m1, d1), date(y2, m2, d2), m2

    m = DATE_RANGE_SAME_MON_RE.match(s)
    if m:
        mon = parse_month_name_to_num(m.group("mon"))
        d1 = int(m.group("d1"))
        d2 = int(m.group("d2"))
        if not mon:
            raise ValueError(f"Unrecognized month in date range: {s}")
        y = month_to_year(mon, fall_year, spring_year)
        return date(y, mon, d1), date(y, mon, d2), mon

    m = DATE_SINGLE_RE.match(s)
    if m:
        mon = parse_month_name_to_num(m.group("mon"))
        d1 = int(m.group("day"))
        if not mon:
            raise ValueError(f"Unrecognized month in date: {s}")
        y = month_to_year(mon, fall_year, spring_year)
        return date(y, mon, d1), date(y, mon, d1), mon

    # Fallback: if the cell is just a day number (rare), use current_month_num
    if re.fullmatch(r"\d{1,2}", s) and current_month_num is not None:
        d1 = int(s)
        y = month_to_year(current_month_num, fall_year, spring_year)
        return date(y, current_month_num, d1), date(y, current_month_num, d1), current_month_num

    raise ValueError(f"Could not parse date cell: {date_cell!r}")


def scrape(yy: int, debug: bool = False) -> Dict:
    fall_year, spring_year = academic_year_to_years(yy)

    resp = requests.get(SOURCE_URL, params={"academic_year": f"{yy:02d}"}, timeout=30)
    resp.raise_for_status()

    soup = BeautifulSoup(resp.text, "html.parser")

    # Find the academic calendar tables. The page is Drupal and often has multiple tables.
    # We pick tables that have headers containing Date/Day/Event.
    tables = []
    for tbl in soup.find_all("table"):
        th_text = " ".join(normalize_ws(th.get_text(" ", strip=True)) for th in tbl.find_all("th"))
        if "Date" in th_text and "Day" in th_text and "Event" in th_text:
            tables.append(tbl)

    if not tables:
        # Debug dump if needed
        if debug:
            print("DEBUG: No matching tables found. HTML title:", soup.title.get_text(strip=True) if soup.title else "N/A")
        return {
            "source": SOURCE_URL,
            "academicYear": str(fall_year),
            "generatedAt": datetime.utcnow().replace(microsecond=0).isoformat() + "+00:00",
            "terms": {"fall": {"classesBegin": None, "classesEnd": None}, "spring": {"classesBegin": None, "classesEnd": None}},
            "events": [],
        }

    events: List[Event] = []
    current_month_num: Optional[int] = None

    for tbl in tables:
        # each row should be Date | Day | Event (but ranges often have blank Day)
        for tr in tbl.find_all("tr"):
            tds = tr.find_all("td")
            if len(tds) < 2:
                continue

            # Some tables may have 3 columns; if only 2, it might be a malformed row; skip.
            if len(tds) < 3:
                continue

            date_txt = normalize_ws(tds[0].get_text(" ", strip=True))
            day_txt = normalize_ws(tds[1].get_text(" ", strip=True)) or None
            event_txt = normalize_ws(tds[2].get_text(" ", strip=True))

            # Skip empties / header-ish rows
            if not date_txt or not event_txt:
                continue

            # Parse date(s)
            try:
                start_d, end_d, current_month_num = parse_date_cell(date_txt, current_month_num, fall_year, spring_year)
            except Exception as e:
                if debug:
                    print(f"DEBUG: Skipping row due to date parse error: {e} | date={date_txt!r} event={event_txt!r}")
                continue

            # Normalize DOW
            if day_txt:
                # Day sometimes contains things like "Fri" or is blank for ranges
                # Keep as 3-letter if it looks like that; else null
                if not re.fullmatch(r"[A-Za-z]{3}", day_txt):
                    day_txt = None
                else:
                    day_txt = day_txt.title()

            ev = Event(
                title=event_txt,
                startDate=to_iso(start_d),
                endDate=to_iso(end_d),
                dow=day_txt,
                tags=infer_tags(event_txt),
            )
            events.append(ev)

    # Term inference from event titles
    def find_first_date_containing(substr: str) -> Optional[str]:
        s = substr.lower()
        for ev in events:
            if s in ev.title.lower():
                return ev.startDate
        return None

    def find_last_date_containing(substr: str) -> Optional[str]:
        s = substr.lower()
        for ev in reversed(events):
            if s in ev.title.lower():
                return ev.startDate
        return None

    # Fall classes begin often includes "Fall 20XX Classes Begin"
    fall_begin = find_first_date_containing("fall") if find_first_date_containing("classes begin") else None
    # Better: specifically match "Fall" and "Classes Begin"
    for ev in events:
        t = ev.title.lower()
        if "fall" in t and "classes begin" in t:
            fall_begin = ev.startDate
            break

    fall_end = None
    for ev in events:
        t = ev.title.lower()
        if "last day of fall" in t and "classes" in t:
            fall_end = ev.startDate
            break

    spring_begin = None
    for ev in events:
        t = ev.title.lower()
        if "spring" in t and "classes begin" in t:
            spring_begin = ev.startDate
            break

    spring_end = None
    for ev in events:
        t = ev.title.lower()
        if "last day of spring" in t and "classes" in t:
            spring_end = ev.startDate
            break

    out = {
        "source": SOURCE_URL,
        "academicYear": str(fall_year),
        "generatedAt": datetime.utcnow().replace(microsecond=0).isoformat() + "+00:00",
        "terms": {
            "fall": {"classesBegin": fall_begin, "classesEnd": fall_end},
            "spring": {"classesBegin": spring_begin, "classesEnd": spring_end},
        },
        "events": [ev.to_json() for ev in events],
    }

    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--academic-year", type=int, required=True, help="Two-digit academic year, e.g. 25 for 2025-2026")
    ap.add_argument("--out", type=str, default=None, help="Output JSON path. Default: <repo_root>/Data/Academic_calendar_<yy>.json")
    ap.add_argument("--debug", action="store_true", help="Print debug info")
    args = ap.parse_args()

    repo_root = repo_root_from_this_file()
    default_out = repo_root / "Data" / f"Academic_calendar_{args.academic_year:02d}.json"
    out_path = Path(args.out).expanduser().resolve() if args.out else default_out

    data = scrape(args.academic_year, debug=args.debug)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(data, indent=2), encoding="utf-8")

    if args.debug:
        print(f"DEBUG: wrote {out_path}")
        # sanity check: show a few known spring items if present
        for key in ["Spring Break-no classes", "GM Week", "Final Exams", "Reading/Study days"]:
            hits = [e for e in data["events"] if key.lower() in e["title"].lower()]
            for h in hits[:2]:
                print("DEBUG:", h["title"], h["startDate"], "->", h["endDate"])


if __name__ == "__main__":
    main()
