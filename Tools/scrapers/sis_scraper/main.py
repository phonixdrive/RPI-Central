#!/usr/bin/env python3

# Python standard library
import asyncio
from operator import itemgetter
import os
import re
import json
import sys
from datetime import datetime

# External dependnecies
import aiohttp
import bs4
import requests

# Project
import util
import conflict_logic
import prerequisites

# Wrapper for BeautifulSoup that specifies a specific parser
BeautifulSoup = lambda data: bs4.BeautifulSoup(data, features="lxml")
# ClientSession for aiohttp
session = None


async def get_section_information(section_url):
    global session
    section_dict = {}
    async with session.get(section_url) as data:
        soup = BeautifulSoup(await data.text())
        # Parse any prereqs
        try:
            section_dict["prereqs"] = prerequisites.get_prereq_string(soup)
        except:
            pass

        # Get credit amount
        credit_data = (
            re.search(r"<br/>\n(.*?) Credits\n<br/>", str(soup)).group(1).strip()
        )

        credit_data = list(map(float, re.split("TO|OR", credit_data)))
        credit_min = min(credit_data)
        credit_max = max(credit_data)

        section_dict["credMin"] = credit_min
        section_dict["credMax"] = credit_max

        # Unfortantely, it isn't as simple as split by "-" to retrieve all the data
        # Some classes actually have the dash in their title
        # Thus we need to locate the CRN and make everything before it be the title
        crn = section_url.split("&crn_in=")[1]
        raw_data = soup.find("th", {"class": "ddlabel"}).text
        index = raw_data.find(crn)
        raw_title = raw_data[:index][:-3]
        raw_section_data = raw_data[index:]
        # Get section metadata (name, CRN, subject, etc)
        # Remove excess whitespace
        section_data = tuple(x.strip() for x in raw_section_data.split("-"))

        subject_name, crse = section_data[1].split(" ")
        section_number = section_data[2]
        section_dict["crn"] = int(crn)
        section_dict["crse"] = int(crse)
        section_dict["subj"] = subject_name
        section_dict["sec"] = section_number
        section_dict["title"] = util.normalize_class_name(raw_title)

        # Get seat data
        seating = soup.find(
            "table",
            {"summary": "This layout table is used to present the seating numbers."},
        ).findAll("tr")

        for seat_type in seating[1:]:
            kind = seat_type.find("th").text
            capacity, actual, remaining = tuple(
                int(x.text.replace("\xa0", "0")) for x in seat_type.findAll("td")
            )

            if kind == "Seats":
                section_dict["cap"] = capacity
                section_dict["act"] = actual
                section_dict["rem"] = remaining
            elif kind == "Cross List Seats":
                section_dict["xl_rem"] = remaining

            # NOTE: Can implement logic for Waitlists / Crosslists here
    return section_dict


async def get_class_information(class_url):
    global session

    sections = []
    course_data = {}
    registration_dates = ()

    async with session.get(class_url) as data:
        data = BeautifulSoup(await data.text())

        # Iterate through each section in the course and retrieve appropriate data
        section_data = data.findAll("th", {"class": "ddtitle", "scope": "colgroup"})

        # Get registration start and end dates, unless they don't exist/are hidden for
        # some reason (this happened with arch planning course)
        dates_rgx = re.search(r"Registration Dates: </span>(.*?)\n", str(data))
        if dates_rgx:
            registration_dates = tuple(
                datetime.strptime(d.strip(), "%b %d, %Y")
                for d in (dates_rgx.group(1).split(" to "))
            )

        meeting_times = data.findAll(
            "table",
            {
                "class": "datadisplaytable",
                "summary": "This table lists the scheduled meeting times and assigned instructors for this class..",
            },
        )

        # Pad out meeting times for classes with no meeting times
        # This is pretty much just for independent study courses
        while len(meeting_times) < len(section_data):
            meeting_times.append(None)

        for section, time in zip(section_data, meeting_times):
            section_url = section.find("a")["href"]
            section_data = await get_section_information(
                f"https://sis.rpi.edu{section_url}"
            )
            sections.append(section_data)
            # Parse attributes (if applicable)
            # This is really hacky (but so is the rest of the code)
            # But I found this was the best way to approach it
            # This also makes an assumption that attributes apply across the whole
            # class and not per-section, which would be terrible (but fixable)
            search = r"""<span class="fieldlabeltext">Attributes: </span>(.*?)\n<br/>"""
            attribute = re.search(search, str(data))
            section_data["attribute"] = (
                attribute.group(1).strip() if attribute != None else ""
            )

            # We need to parse section time information here
            # As it isn't present on the per-section advanced page
            timeslots = section_data["timeslots"] = []

            if time == None:
                # Append an empty timeslot to make QuACS display the CRN
                timeslots.append(
                    {
                        "days": [],
                        "timeStart": -1,
                        "timeEnd": -1,
                        "instructor": "",
                        "location": "",
                        "dateStart": None,
                        "dateEnd": None,
                    }
                )
                continue
            for meeting in time.findAll("tr")[
                1:
            ]:  # skip the first entry as its just the elabels
                meeting_data = [x.text for x in meeting.findAll("td")]
                timeStart, timeEnd = util.time_to_military(meeting_data[1])
                days = list(meeting_data[2])
                # Empty days comes up as '\xa0', so remove that if applicable
                if len(days) > 0 and days[0] == "\xa0":
                    days = []
                location = meeting_data[3].strip()
                date = meeting_data[4].split(" - ")
                instructor = util.get_instructor_string(meeting_data[-1])

                timeslots.append(
                    {
                        "days": days,
                        "timeStart": timeStart,
                        "timeEnd": timeEnd,
                        "instructor": instructor,
                        "location": location,
                        "dateStart": util.get_date(date[0]),
                        "dateEnd": util.get_date(date[1]),
                    }
                )

        # Add main course data from first section
        if len(sections) == 0:
            print(f"=== ERROR: {class_url} has no sections!")
            return None
        course_data["title"] = sections[0]["title"]
        course_data["subj"] = sections[0]["subj"]
        course_data["crse"] = sections[0]["crse"]
        course_data["id"] = f"{course_data['subj']}-{str(course_data['crse']).zfill(4)}"
        course_data["sections"] = sections
    return course_data, registration_dates


