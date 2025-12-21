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


