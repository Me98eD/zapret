#!/bin/sh

REPO_DIR="/opt/zapret"

cd "$REPO_DIR" || exit 1

# гарантируем наличие git
command -v git >/dev/null || {
    echo "[git] git not installed"
    exit 1
}

# задаём identity если не задан
git config user.name >/dev/null 2>&1 || git config user.name "Me98eD"
git config user.email >/dev/null 2>&1 || git config user.email "fmi8@yandex.ru"

git add -A

if ! git diff --cached --quiet; then

    MSG="zapret update $(date '+%Y-%m-%d %H:%M:%S')"

    echo "[git] commit: $MSG"

    git commit -m "$MSG"

    echo "[git] push"

    git push origin main

else

    echo "[git] No changes to push"

fi