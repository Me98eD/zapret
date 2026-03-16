#!/bin/sh

set -e

REPO_OWNER="Me98eD"
REPO_NAME="zapret"
REPO_BRANCH="main"

ZAPRET_DIR="/opt/zapret"
TARGET_CONFIG="$ZAPRET_DIR/config"

TMP_BASE="/opt/zapret-github-sync.tmp"
ARCHIVE="$TMP_BASE/repo.tar.gz"

BACKUP_ROOT="/opt"
BACKUP_PREFIX="zapret.backup.sync"
BACKUP_KEEP="3"
BACKUP_DIR="${BACKUP_ROOT}/${BACKUP_PREFIX}.$(date +%Y%m%d-%H%M%S)"

IPSET_FILES="
zapret-hosts-google.txt
zapret-hosts-user.txt
zapret-hosts-user-exclude.txt
zapret-ip-exclude.txt
zapret-ip-user.txt
zapret-ip-user-exclude.txt
cust1.txt
cust2.txt
cust3.txt
cust4.txt
"

log() {
    echo "[zapret-sync] $*"
}

fail() {
    echo "[zapret-sync] ERROR: $*" >&2
    exit 1
}

cleanup() {
    rm -rf "$TMP_BASE"
}

trap cleanup EXIT INT TERM

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

download_file() {
    URL="$1"
    OUT="$2"

    if need_cmd curl; then
        curl -fsSL "$URL" -o "$OUT"
    elif need_cmd wget; then
        wget -qO "$OUT" "$URL"
    else
        fail "Не найден ни curl, ни wget"
    fi
}

replace_simple_var() {
    FILE="$1"
    VAR="$2"
    VALUE="$3"

    ESCAPED_VALUE=$(printf '%s' "$VALUE" | sed 's/[\/&]/\\&/g')

    if grep -q "^${VAR}=" "$FILE"; then
        sed -i "s/^${VAR}=.*/${VAR}=${ESCAPED_VALUE}/" "$FILE"
    else
        printf '\n%s=%s\n' "$VAR" "$VALUE" >> "$FILE"
    fi
}

replace_multiline_var() {
    FILE="$1"
    VAR="$2"
    VALUE_FILE="$3" 

    awk -v var="$VAR" -v valfile="$VALUE_FILE" '
    BEGIN {
        value = ""
        skip = 0
        inserted = 0

        while ((getline line < valfile) > 0) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line != "") {
                if (value != "") value = value " "
                value = value line
            }
        }
        close(valfile)
    }

    {
        if (skip) {
            if ($0 == "\"") {
                skip = 0
            }
            next
        }

        if ($0 ~ ("^" var "=")) {
            if (!inserted) {
                print var "=\"" value "\""
                inserted = 1
            }

            # если старое значение было многострочным:
            # VAR="
            if ($0 ~ ("^" var "=\"$")) {
                skip = 1
            }

            next
        }

        print
    }

    END {
        if (!inserted) {
            print ""
            print var "=\"" value "\""
        }
    }' "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
}

detect_custom_d_dir() {
    if [ -d "$ZAPRET_DIR/init.d/sysv/custom.d" ]; then
        echo "$ZAPRET_DIR/init.d/sysv/custom.d"
        return 0
    fi

    if [ -d "$ZAPRET_DIR/init.d/openwrt/custom.d" ]; then
        echo "$ZAPRET_DIR/init.d/openwrt/custom.d"
        return 0
    fi

    return 1
}

clean_dir_contents() {
    DIR="$1"
    mkdir -p "$DIR"
    find "$DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} \;
}

restart_zapret() {
    if [ -x /etc/init.d/zapret ]; then
        log "Перезапускаю zapret (OpenWrt)..."
        /etc/init.d/zapret restart && return 0
        return 1
    fi

    if ls /opt/etc/init.d/S*zapret >/dev/null 2>&1; then
        ZINIT=$(ls /opt/etc/init.d/S*zapret | head -n 1)
        log "Перезапускаю zapret ($ZINIT)..."
        "$ZINIT" restart && return 0
        return 1
    fi

    return 2
}

restore_full_backup() {
    log "Восстанавливаю $ZAPRET_DIR из бэкапа $BACKUP_DIR ..."

    [ -d "$BACKUP_DIR" ] || fail "Каталог бэкапа не найден: $BACKUP_DIR"

    rm -rf "$ZAPRET_DIR"
    cp -a "$BACKUP_DIR" "$ZAPRET_DIR"
    sync

    if restart_zapret; then
        fail "Новая стратегия не запустилась, zapret полностью восстановлен из бэкапа"
    else
        fail "Новая стратегия не запустилась, бэкап возвращён, но zapret после восстановления тоже не удалось перезапустить"
    fi
}

prune_old_backups() {
    KEEP="$1"
    COUNT=0

    for d in $(ls -1dt "${BACKUP_ROOT}/${BACKUP_PREFIX}".* 2>/dev/null); do
        [ -d "$d" ] || continue
        COUNT=$((COUNT + 1))
        if [ "$COUNT" -le "$KEEP" ]; then
            continue
        fi
        log "Удаляю старый бэкап: $d"
        rm -rf "$d"
    done
}

[ -d "$ZAPRET_DIR" ] || fail "Каталог $ZAPRET_DIR не найден. Сначала установите zapret."
[ -f "$TARGET_CONFIG" ] || fail "Файл $TARGET_CONFIG не найден."

rm -rf "$TMP_BASE"
mkdir -p "$TMP_BASE"

ARCHIVE_URL="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${REPO_BRANCH}"

log "Скачиваю архив репозитория..."
download_file "$ARCHIVE_URL" "$ARCHIVE"

log "Проверяю архив..."
tar -tzf "$ARCHIVE" >/dev/null 2>&1 || fail "Архив GitHub повреждён или скачан не полностью"

SRC_ROOT_NAME=$(tar -tzf "$ARCHIVE" 2>/dev/null | head -n 1 | cut -d/ -f1)
[ -n "$SRC_ROOT_NAME" ] || fail "Не удалось определить корневой каталог архива"

log "Распаковываю..."
tar -xzf "$ARCHIVE" -C "$TMP_BASE"

SRC_ROOT="$TMP_BASE/$SRC_ROOT_NAME"
[ -d "$SRC_ROOT" ] || fail "Не найден распакованный каталог репозитория: $SRC_ROOT"

[ -r "$SRC_ROOT/config" ] || fail "В репозитории нет читаемого файла config"
[ -d "$SRC_ROOT/ipset" ] || fail "В репозитории нет папки ipset"
[ -d "$SRC_ROOT/files/fake" ] || fail "В репозитории нет папки files/fake"
[ -d "$SRC_ROOT/init.d/openwrt/custom.d" ] || fail "В репозитории нет папки init.d/openwrt/custom.d"

CUSTOM_D_TARGET=""
if CUSTOM_D_TARGET=$(detect_custom_d_dir); then
    log "Найдена целевая папка custom.d: $CUSTOM_D_TARGET"
else
    fail "На целевой установке не найдена папка custom.d"
fi

# shellcheck disable=SC1090
. "$SRC_ROOT/config"

: "${NFQWS_PORTS_TCP:=}"
: "${NFQWS_PORTS_UDP:=}"
: "${NFQWS_TCP_PKT_OUT:=}"
: "${NFQWS_TCP_PKT_IN:=}"
: "${NFQWS_UDP_PKT_OUT:=}"
: "${NFQWS_UDP_PKT_IN:=}"
: "${NFQWS_OPT:=}"
: "${DISABLE_IPV6:=}"
: "${DISABLE_CUSTOM:=}"

log "Создаю полный бэкап $ZAPRET_DIR -> $BACKUP_DIR"
rm -rf "$BACKUP_DIR"
cp -a "$ZAPRET_DIR" "$BACKUP_DIR"

log "Очищаю и обновляю $ZAPRET_DIR/files/fake ..."
clean_dir_contents "$ZAPRET_DIR/files/fake"
cp -a "$SRC_ROOT/files/fake/." "$ZAPRET_DIR/files/fake/"

log "Очищаю и обновляю выбранные файлы ipset ..."
mkdir -p "$ZAPRET_DIR/ipset"

for f in $IPSET_FILES; do
    rm -f "$ZAPRET_DIR/ipset/$f"
done

for f in $IPSET_FILES; do
    if [ -f "$SRC_ROOT/ipset/$f" ]; then
        cp -a "$SRC_ROOT/ipset/$f" "$ZAPRET_DIR/ipset/$f"
        log "ipset: $f"
    else
        log "ipset: $f отсутствует в репозитории, пропущен"
    fi
done

log "Очищаю и обновляю custom.d из init.d/openwrt/custom.d ..."
clean_dir_contents "$CUSTOM_D_TARGET"
cp -a "$SRC_ROOT/init.d/openwrt/custom.d/." "$CUSTOM_D_TARGET/"
find "$CUSTOM_D_TARGET" -type f -name '*.sh' -exec chmod 755 {} \;

log "Обновляю параметры config ..."
replace_simple_var "$TARGET_CONFIG" "NFQWS_PORTS_TCP" "$NFQWS_PORTS_TCP"
replace_simple_var "$TARGET_CONFIG" "NFQWS_PORTS_UDP" "$NFQWS_PORTS_UDP"
replace_simple_var "$TARGET_CONFIG" "NFQWS_TCP_PKT_OUT" "$NFQWS_TCP_PKT_OUT"
replace_simple_var "$TARGET_CONFIG" "NFQWS_TCP_PKT_IN" "$NFQWS_TCP_PKT_IN"
replace_simple_var "$TARGET_CONFIG" "NFQWS_UDP_PKT_OUT" "$NFQWS_UDP_PKT_OUT"
replace_simple_var "$TARGET_CONFIG" "NFQWS_UDP_PKT_IN" "$NFQWS_UDP_PKT_IN"
replace_simple_var "$TARGET_CONFIG" "DISABLE_IPV6" "$DISABLE_IPV6"
replace_simple_var "$TARGET_CONFIG" "DISABLE_CUSTOM" "$DISABLE_CUSTOM"

printf '%s\n' "$NFQWS_OPT" > "$TMP_BASE/NFQWS_OPT.value"
replace_multiline_var "$TARGET_CONFIG" "NFQWS_OPT" "$TMP_BASE/NFQWS_OPT.value"

sync

if ! restart_zapret; then
    restore_full_backup
fi

prune_old_backups "$BACKUP_KEEP"

log "Готово."
log "Текущий бэкап сохранён: $BACKUP_DIR"
log "Храним последних бэкапов: $BACKUP_KEEP"