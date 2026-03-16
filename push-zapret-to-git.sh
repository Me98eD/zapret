#!/bin/sh

cd /opt/zapret || exit 1

git add .

if ! git diff --cached --quiet; then
    git commit -m "zapret update $(date '+%Y-%m-%d %H:%M:%S')"
    git push
else
    echo "No changes to push"
fi
