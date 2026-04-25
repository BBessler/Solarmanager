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

# Download mit Fehlerbehandlung und Entpacken (Legacy-In-Place-Variante).
# Bleibt für bestehende Aufrufer; neue Skripte sollten sm_deploy_release nutzen.
# Usage: sm_download_and_extract url target_dir [use_sudo]
sm_download_and_extract() {
    local asset_url="$1"
    local target_dir="$2"
    local use_sudo="${3:-false}"
    local tmp_file
    tmp_file=$(sm_download_validated "$asset_url") || return 1

    if [ "$use_sudo" = "true" ]; then
        sudo mkdir -p "$target_dir"
        sudo tar --overwrite --no-same-owner -xzf "$tmp_file" -C "$target_dir"
    else
        mkdir -p "$target_dir"
        tar --overwrite --no-same-owner -xzf "$tmp_file" -C "$target_dir"
    fi

    local rc=$?
    rm -f "$tmp_file"
    if [ $rc -ne 0 ]; then
        echo "[FEHLER] Entpacken fehlgeschlagen."
        return 1
    fi
}

# Lädt ein Archiv, prüft Größe und tar-Integrität.
# Gibt bei Erfolg den Pfad zur validierten tmp-Datei via stdout zurück (rc=0).
# Bei Fehler rc!=0 und keine Ausgabe.
# Usage: tmp=$(sm_download_validated "$url") || handle_error
sm_download_validated() {
    local asset_url="$1"
    local timeout="${SM_DOWNLOAD_TIMEOUT:-180}"
    local min_size="${SM_MIN_ARCHIVE_BYTES:-102400}"   # 100 KB sanity floor
    local tmp_file="/tmp/sm-update-$$-$(date +%s).tar.gz"

    if [ -z "$asset_url" ]; then
        echo "[FEHLER] Keine Download-URL angegeben." >&2
        return 1
    fi

    if ! curl -fsSL --max-time "$timeout" "$asset_url" -o "$tmp_file"; then
        echo "[FEHLER] Download fehlgeschlagen oder Timeout (>${timeout}s): $asset_url" >&2
        rm -f "$tmp_file"
        return 1
    fi

    local size
    size=$(stat -c%s "$tmp_file" 2>/dev/null || echo 0)
    if [ "$size" -lt "$min_size" ]; then
        echo "[FEHLER] Archiv unplausibel klein ($size Bytes, min $min_size)" >&2
        rm -f "$tmp_file"
        return 1
    fi

    if ! tar -tzf "$tmp_file" > /dev/null 2>&1; then
        echo "[FEHLER] Archiv ist beschädigt (tar -tzf liefert Fehler)" >&2
        rm -f "$tmp_file"
        return 1
    fi

    echo "$tmp_file"
}

# Stellt sicher, dass $link ein Symlink ist und ein releases/$name/ existiert.
# Bei vorhandenem Real-Ordner wird er nach releases/$name/initial-<ts> migriert.
# Usage: sm_ensure_symlink_layout link_path name [use_sudo]
sm_ensure_symlink_layout() {
    local link="$1"
    local name="$2"
    local use_sudo="${3:-true}"
    local SUDO=""
    [ "$use_sudo" = "true" ] && SUDO="sudo"

    local rel_dir
    rel_dir="$(dirname "$link")/releases/$name"
    $SUDO mkdir -p "$rel_dir"

    if [ -L "$link" ]; then
        return 0
    fi

    if [ -d "$link" ]; then
        local first="$rel_dir/initial-$(date +'%Y-%m-%d_%H%M%S')"
        echo "[INFO] Migriere $link → Symlink-Layout ($first)"
        $SUDO mv "$link" "$first"
        $SUDO ln -s "$first" "$link"
    fi
}

# Atomarer Symlink-Swap (Linux: mv -T überschreibt einen Symlink atomar).
# Usage: sm_swap_symlink link target [use_sudo]
sm_swap_symlink() {
    local link="$1"
    local target="$2"
    local use_sudo="${3:-true}"
    local SUDO=""
    [ "$use_sudo" = "true" ] && SUDO="sudo"

    local tmp_link="${link}.swap.$$"
    $SUDO ln -s "$target" "$tmp_link"
    $SUDO mv -Tf "$tmp_link" "$link"
}

# Lädt ein Archiv, validiert es und entpackt es in einen NEUEN Ordner unter
# releases/$name/<timestamp>/. Der laufende Symlink-Pfad bleibt unangetastet.
# Gibt den Pfad zum neuen Release via stdout zurück.
# Usage: new_path=$(sm_deploy_release url link_path name [use_sudo] [required_file])
sm_deploy_release() {
    local asset_url="$1"
    local link="$2"
    local name="$3"
    local use_sudo="${4:-true}"
    local required_file="${5:-}"   # optional: Datei, die im Archiv enthalten sein muss
    local SUDO=""
    [ "$use_sudo" = "true" ] && SUDO="sudo"

    local rel_dir
    rel_dir="$(dirname "$link")/releases/$name"
    local new_release="$rel_dir/$(date +'%Y-%m-%d_%H%M%S')"

    local tmp_file
    tmp_file=$(sm_download_validated "$asset_url") || return 1

    $SUDO mkdir -p "$new_release"
    if ! $SUDO tar --no-same-owner -xzf "$tmp_file" -C "$new_release"; then
        echo "[FEHLER] Entpacken fehlgeschlagen — entferne unvollständigen Ordner $new_release" >&2
        $SUDO rm -rf "$new_release"
        rm -f "$tmp_file"
        return 1
    fi
    rm -f "$tmp_file"

    if [ -n "$required_file" ] && [ ! -f "$new_release/$required_file" ]; then
        echo "[FEHLER] $required_file fehlt im entpackten Release $new_release" >&2
        $SUDO rm -rf "$new_release"
        return 1
    fi

    echo "$new_release"
}

# Räumt alte Releases auf — behält die letzten N (Default 3) sowie immer das aktuell verlinkte.
# Usage: sm_cleanup_old_releases link_path name [keep] [use_sudo]
sm_cleanup_old_releases() {
    local link="$1"
    local name="$2"
    local keep="${3:-3}"
    local use_sudo="${4:-true}"
    local SUDO=""
    [ "$use_sudo" = "true" ] && SUDO="sudo"

    local rel_dir
    rel_dir="$(dirname "$link")/releases/$name"
    [ -d "$rel_dir" ] || return 0

    local current
    current=$(readlink -f "$link" 2>/dev/null || echo "")

    # ls -1dt liefert Ordner sortiert nach mtime, neueste zuerst
    ls -1dt "$rel_dir"/*/ 2>/dev/null | tail -n +$((keep + 1)) | while read -r d; do
        local d_resolved
        d_resolved=$(readlink -f "$d")
        if [ "$d_resolved" = "$current" ]; then
            continue
        fi
        echo "[INFO] Lösche altes Release: $d"
        $SUDO rm -rf "$d"
    done
}

# Health-Check: Wartet bis URL antwortet (nur 200|301|302, kein 404)
sm_health_check() {
    local url="$1"
    local max_wait="${2:-60}"
    local wait=0

    while [ $wait -lt $max_wait ]; do
        if curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null | grep -q "200\|301\|302"; then
            return 0
        fi
        sleep 2
        wait=$((wait + 2))
        printf "\r[INFO] Warte auf Backend... %ds / %ds" "$wait" "$max_wait"
    done
    echo ""
    return 1
}
