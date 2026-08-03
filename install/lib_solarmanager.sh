#!/bin/bash
# =============================================================================
# Solarmanager - Shared Library
# Gemeinsame Funktionen fuer Setup- und Update-Scripts
# =============================================================================

GITHUB_RELEASE_REPO="BBessler/Solarmanager"

# GitHub API einmal abrufen, Ergebnis in $SM_RELEASES
sm_fetch_releases() {
    SM_RELEASES=$(curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$GITHUB_RELEASE_REPO/releases")

    if [ -z "$SM_RELEASES" ] || echo "$SM_RELEASES" | grep -q '"message"'; then
        echo "[FEHLER] GitHub API nicht erreichbar."
        return 1
    fi
}

# Neuestes Release nach Tag-Prefix finden
# Gibt "tag|url" zurueck
sm_get_latest() {
    local tag_prefix="$1"
    local channel="${2:-stable}"
    echo "$SM_RELEASES" | python3 -c "
import sys, json
releases = json.load(sys.stdin)
channel = '$channel'
for r in releases:
    is_pre = r.get('prerelease', False)
    if channel == 'beta' and not is_pre:
        continue
    if channel == 'stable' and is_pre:
        continue
    if r['tag_name'].startswith('$tag_prefix'):
        url = r['assets'][0]['browser_download_url'] if r['assets'] else ''
        print(r['tag_name'] + '|' + url)
        break
" 2>/dev/null
}

# Release nach exaktem Tag finden - gibt "tag|url" zurueck
sm_get_by_tag() {
    local tag="$1"
    echo "$SM_RELEASES" | python3 -c "
import sys, json
tag = sys.argv[1]
releases = json.load(sys.stdin)
for r in releases:
    if r['tag_name'] == tag:
        url = r['assets'][0]['browser_download_url'] if r['assets'] else ''
        print(r['tag_name'] + '|' + url)
        break
" "$tag" 2>/dev/null
}

# Download mit Fehlerbehandlung und Entpacken
# Usage: sm_download_and_extract url target_dir [use_sudo]
sm_download_and_extract() {
    local asset_url="$1"
    local target_dir="$2"
    local use_sudo="${3:-false}"
    local tmp_file="/tmp/sm-update-$$.tar.gz"

    if [ -z "$asset_url" ]; then
        echo "[FEHLER] Keine Download-URL angegeben."
        return 1
    fi

    curl -fsSL "$asset_url" -o "$tmp_file"
    if [ $? -ne 0 ]; then
        echo "[FEHLER] Download fehlgeschlagen: $asset_url"
        rm -f "$tmp_file"
        return 1
    fi

    if [ ! -s "$tmp_file" ]; then
        echo "[FEHLER] Heruntergeladene Datei ist leer: $asset_url"
        rm -f "$tmp_file"
        return 1
    fi

    if [ "$use_sudo" = "true" ]; then
        sudo mkdir -p "$target_dir"
        sudo tar --overwrite --no-same-owner -xzf "$tmp_file" -C "$target_dir"
    else
        mkdir -p "$target_dir"
        tar --overwrite --no-same-owner -xzf "$tmp_file" -C "$target_dir"
    fi

    if [ $? -ne 0 ]; then
        echo "[FEHLER] Entpacken fehlgeschlagen."
        rm -f "$tmp_file"
        return 1
    fi

    rm -f "$tmp_file"
}

# Health-Check: Wartet bis der Dienst HTTP spricht.
# Bewertet wird nur, ob ueberhaupt geantwortet wird - welcher Statuscode kommt,
# ist egal. Das Backend liefert unter "/" naemlich 404 (das Frontend kommt von
# Apache, das Backend hat kein wwwroot); auf 200 zu warten lief deshalb immer in
# den Timeout, obwohl der Dienst laengst lief.
sm_health_check() {
    local url="$1"
    local max_wait="${2:-60}"
    local wait=0
    local code

    while [ $wait -lt $max_wait ]; do
        # "|| true": Solange der Dienst nicht antwortet, endet curl mit Fehler -
        # ohne das wuerde "set -e" das Update hier abbrechen.
        code=$(curl -s -o /dev/null -m 5 -w "%{http_code}" "$url" 2>/dev/null || true)
        if [ -n "$code" ] && [ "$code" != "000" ]; then
            return 0
        fi
        sleep 2
        wait=$((wait + 2))
        printf "\r[INFO] Warte auf Backend... %ds / %ds" "$wait" "$max_wait"
    done
    echo ""
    return 1
}
