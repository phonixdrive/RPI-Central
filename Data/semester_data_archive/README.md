# Archived semester data

Course data for terms before Spring 2022 (1998–2021). The app only offers
Spring 2022 and later (the `Semester` enum), and everything in
`Data/semester_data` is copied into the app bundle, so older terms live here
to keep the download small.

The prerequisites graph can still read them:

```sh
python3 Tools/scrapers/prerequisites_graph/main.py Data/semester_data Data/prereq_graph.json --include Data/semester_data_archive
```
