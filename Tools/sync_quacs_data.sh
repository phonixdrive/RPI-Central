#!/bin/bash
# Pull the latest QuACS course data into Data/semester_data and push it.
# Only terms the app already ships are updated; new upstream terms are reported
# (they also need a case in Courses/Semester.swift before the app can use them).
# One commit per changed term. Uses the git credentials already on this Mac.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${HOME}/Library/Caches/rpi-central-quacs-data"
DEST="$REPO/Data/semester_data"

if [ -d "$CACHE/.git" ]; then
    git -C "$CACHE" fetch -q --depth 1 origin HEAD
    git -C "$CACHE" reset -q --hard FETCH_HEAD
else
    git clone -q --depth 1 https://github.com/quacs/quacs-data "$CACHE"
fi
UPSTREAM_DATE="$(git -C "$CACHE" log -1 --format=%cs)"

cd "$REPO"
git pull -q --rebase --autostash origin main

committed=0
for dir in "$DEST"/*/; do
    term="$(basename "$dir")"
    src="$CACHE/semester_data/$term"
    [ -d "$src" ] || continue
    rsync -a --delete "$src/" "$dir"
    if [ -n "$(git status --porcelain -- "$dir")" ]; then
        git add -A -- "$dir"
        git commit -q -m "Sync $term course data from QuACS ($UPSTREAM_DATE)" -- "$dir"
        committed=$((committed + 1))
    fi
done

for src in "$CACHE"/semester_data/*/; do
    term="$(basename "$src")"
    if [[ "$term" > "$(ls "$DEST" | sort | tail -1)" ]]; then
        echo "New upstream term not in the app yet: $term"
    fi
done

if [ "$committed" -gt 0 ]; then
    git push -q origin main
    echo "Pushed $committed term update(s)."
else
    echo "No course data changes."
fi
