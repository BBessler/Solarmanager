#!/bin/bash
# =============================================================================
# Solarmanager - Shared Library
# Gemeinsame Funktionen fuer Setup- und Update-Scripts
# =============================================================================

GITHUB_RELEASE_REPO="BBessler/Solarmanager"

# GitHub API einmal abrufen, Ergebnis in $SM_RELEASES
#
# Echte Pagination, nicht nur per_page: GitHub deckelt die Seitengroesse bei 100, das
# Repo haelt aber ueber 150 Releases. Ein einzelner Aufruf mit per_page=100 lieferte
# genau 100 Eintraege und schnitt den Rest ab.
#
# Vorgeschichte: Ganz ohne per_page waren es 30. Die stabilen plus die beta-frontend-
# Releases fuellten die Seite, alle beta-backend-Tags lagen dahinter und waren
# unsichtbar — das Update lief mit leerem Tag durch und installierte nichts.
#
# Die Seiten werden ueber DATEIEN zusammengefuehrt, nicht ueber Shell-Variablen als
# Argument: Die JSON-Antwort ist mehrere hundert Kilobyte gross, als Kommandozeilen-
# Argument scheitert das an der Laengengrenze ("Argument list too long").
sm_fetch_releases() {
    local seite=1
    local tmpdir
    tmpdir=$(mktemp -d)

    while : ; do
        if ! curl -fsSL             -H "Accept: application/vnd.github+json"             "https://api.github.com/repos/$GITHUB_RELEASE_REPO/releases?per_page=100&page=$seite"             -o "$tmpdir/seite_$seite.json"; then
            if [ "$seite" -eq 1 ]; then
                rm -rf "$tmpdir"
                echo "[FEHLER] GitHub API nicht erreichbar."
                return 1
            fi
            rm -f "$tmpdir/seite_$seite.json"
            break
        fi

        if grep -q '"message"' "$tmpdir/seite_$seite.json"; then
            if [ "$seite" -eq 1 ]; then
                rm -rf "$tmpdir"
                echo "[FEHLER] GitHub API meldet einen Fehler (Rate-Limit?)."
                return 1
            fi
            rm -f "$tmpdir/seite_$seite.json"
            break
        fi

        local anzahl
        anzahl=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$tmpdir/seite_$seite.json" 2>/dev/null || echo 0)
        [ "$anzahl" -eq 0 ] && { rm -f "$tmpdir/seite_$seite.json"; break; }
        [ "$anzahl" -lt 100 ] && { seite=$((seite + 1)); break; }

        seite=$((seite + 1))
        if [ "$seite" -gt 20 ]; then
            echo "[WARNUNG] Mehr als 2000 Releases — Abruf abgebrochen."
            break
        fi
    done

    SM_RELEASES=$(python3 -c "
import json, glob, sys, os
alle = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], 'seite_*.json'))):
    with open(f) as fh:
        alle.extend(json.load(fh))
json.dump(alle, sys.stdout)
" "$tmpdir" 2>/dev/null)

    rm -rf "$tmpdir"

    local summe
    summe=$(echo "$SM_RELEASES" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    if [ "$summe" -eq 0 ]; then
        echo "[FEHLER] Keine Releases erhalten."
        return 1
    fi
    echo "[INFO] $summe Releases geladen."
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

# Einen vom Aufrufer uebergebenen Tag aufloesen - tolerant gegenueber kaputten Aufrufern.
#
# WICHTIG: Dieses Script ist die Rettungsleine. Das Backend laedt es bei jedem Lauf frisch
# von GitHub, es ist damit der einzige Teil, der auch eine ALTE Installation noch erreicht.
# Es darf deshalb nie daran scheitern, dass der Aufrufer Unsinn schickt - sonst kommt ein
# Geraet aus seiner alten Version nicht mehr heraus.
#
# Bekannter Fall (16.09.2026): Die Oberflaeche baute den Tag als "backend-${installed}"
# zusammen, obwohl installed bereits der vollstaendige Tag war. Heraus kam
# "backend-beta-backend-2026.09.16". Ein hartes Abbrechen haette jede Installation mit
# dieser Oberflaeche dauerhaft festgesetzt.
#
# Reihenfolge: exakter Tag -> doppeltes Praefix abschneiden -> neuester Tag des Kanals.
# Gibt "tag|url" zurueck, leer wenn nichts passt.
sm_aufloesen_tag() {
    local wunsch="$1" praefix="$2" channel="$3"
    local treffer=""

    if [ -n "$wunsch" ]; then
        treffer=$(sm_get_by_tag "$wunsch")
        if [ -n "$treffer" ]; then
            echo "$treffer"
            return 0
        fi

        # Doppeltes Praefix: "backend-beta-backend-2026.09.16" -> "beta-backend-2026.09.16"
        local bereinigt="${wunsch#backend-}"
        bereinigt="${bereinigt#frontend-}"
        if [ "$bereinigt" != "$wunsch" ]; then
            treffer=$(sm_get_by_tag "$bereinigt")
            if [ -n "$treffer" ]; then
                echo "[WARNUNG] Tag '$wunsch' war doppelt praefixiert, verwende '$bereinigt'." >&2
                echo "$treffer"
                return 0
            fi
        fi

        echo "[WARNUNG] Tag '$wunsch' nicht gefunden - weiche auf den neuesten Tag aus." >&2
    fi

    sm_get_latest "$praefix" "$channel"
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
        # Ohne --overwrite: tar loescht jede vorhandene Datei und legt sie neu an, statt in
        # sie hineinzuschreiben. Das Container-Update entpackt ueber das LAUFENDE Backend - ein
        # Prozess, der eine DLL geladen hat, behaelt so die alte Datei bis zum Neustart, statt
        # mitten im Entpacken an einer veraenderten DLL abzustuerzen (und das Script mitzunehmen).
        # Der sudo-Zweig (native Installation) bleibt bei --overwrite: Dort steht der Dienst beim
        # Backend-Tausch, und das Ueberschreiben an Ort behaelt den Besitzer der Dateien.
        mkdir -p "$target_dir"
        tar --no-same-owner -xzf "$tmp_file" -C "$target_dir"
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
