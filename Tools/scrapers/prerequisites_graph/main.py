"""
This script builds a graph of prerequisites in the form of an adjacency list.
It assumes that courses.json and prerequisites.json already exist for all semesters,
and it stores its output in prereq_graph.json.
"""

import json
import os
import functools
import operator
import argparse
from typing import Dict, List, TypedDict


class CoursePrereqs(TypedDict):
    title: str
    prereqs: List[str]


def sem_add_courses(
    sem_dir: str,
    adj_list: Dict[str, CoursePrereqs],
    most_recent_catalog: Dict[str, Dict],
):
    """
    Using the semester in the `sem_dir` directory,
    update the graph in `adj_list`.
    """

    # Load the JSONs
    try:
        with open(f"{sem_dir}/catalog.json", "r") as f:
            sem_catalog = json.load(f)
        with open(f"{sem_dir}/courses.json", "r") as f:
            sem_courses = json.load(f)
        with open(f"{sem_dir}/prerequisites.json", "r") as f:
            sem_prereqs = json.load(f)
    except FileNotFoundError as e:
        print(f"Skipping prereqs for term {sem_dir}", e)
        return

    # Populate `courses`
    for dept in sem_courses:
        for course in dept["courses"]:
            course_id = course["id"].replace("-", " ")
            prereqs = get_prereq_course_ids(
                sem_prereqs[str(course["sections"][0]["crn"])]
            )

            adj_list[course_id] = {
                "title": most_recent_catalog.get(
                    course["id"],
                    sem_catalog.get(course["id"], {"name": course["title"]}),
                )["name"],
                "prereqs": prereqs,
            }


def get_prereq_course_ids(prereqs) -> List[str]:
    """
    Given the `prereqs` of a course in the format of the courses.json file,
    return a list of all prerequisite courses mentioned.
    Boolean operators like "and" and "or" are ignored for now.
    """

    prereqs = prereqs.get("prerequisites", prereqs)
    try:
        typ: str = prereqs["type"]
    except KeyError:
        return []
    if typ == "course":
        return [prereqs["course"]]
    if typ in ["and", "or"]:
        return sorted(
            set(
                functools.reduce(
                    operator.add, map(get_prereq_course_ids, prereqs["nested"]), []
                )
            )
        )
    return []


def generate(semester_data_paths):
    """
    Generate the prerequisite graph adjacency list.
    `semester_data_paths` is a path (or list of paths) containing one folder
    per term, e.g. Data/semester_data and Data/semester_data_archive.
    """
    if isinstance(semester_data_paths, str):
        semester_data_paths = [semester_data_paths]

    # Map from course ID to title and prereqs.
    # This is an adjacency list.
    adj_list: Dict[str, CoursePrereqs] = dict()

    # Semester folders from every path, sorted by term code so newer
    # semester data replaces older data.
    sem_dirs = sorted(
        (
            os.path.join(data_path, sem_dir)
            for data_path in semester_data_paths
            for sem_dir in os.listdir(data_path)
            if os.path.isdir(os.path.join(data_path, sem_dir))
        ),
        key=os.path.basename,
    )

    most_recent_catalog = {}
    for sem_dir in reversed(sem_dirs):
        try:
            with open(f"{sem_dir}/catalog.json", "r") as f:
                print(f"Trying to load catalog for {sem_dir}...")
                most_recent_catalog = json.load(f)
                break
        except FileNotFoundError:
            continue
    for sem_dir in sem_dirs:
        sem_add_courses(sem_dir, adj_list, most_recent_catalog)

    return adj_list


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("semester_data_path")
    parser.add_argument("output_path")
    parser.add_argument(
        "--include",
        action="append",
        default=[],
        help="Additional term folders to read, e.g. Data/semester_data_archive (older terms kept out of the app bundle)",
    )
    args = parser.parse_args()

    graph = generate([args.semester_data_path, *args.include])

    with open(args.output_path, "w") as f:
        json.dump(graph, f, indent=2)
