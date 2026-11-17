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

# Neuestes Release fuer Praefix und Kanal - gibt "tag|url" zurueck.
# Im Beta-Kanal zaehlen Betas UND normale Releases: Ist das normale Release neuer als die letzte
# Beta, wird es installiert (Vorgabe 21.10.2026). Sortiert wird nach der Version im Tag, nicht nach
# der Reihenfolge der API - Releases werden teils Tage vor der Veroeffentlichung angelegt.
# Gleiche Version: im Beta-Kanal die Beta. Gleiche Regel wie UpdateCheckService.NeuestesRelease.
sm_get_latest() {
    local tag_prefix="$1"
    local channel="${2:-stable}"
    echo "$SM_RELEASES" | python3 -c "
import sys, json
releases = json.load(sys.stdin)
channel = sys.argv[1]
praefix = sys.argv[2]
stabil = praefix[len('beta-'):] if praefix.startswith('beta-') else praefix
beta = 'beta-' + stabil

def version(tag):
    try:
        return tuple(int(t) for t in tag.rsplit('-', 1)[1].split('.'))
    except Exception:
        return ()

kandidaten = []
for i, r in enumerate(releases):
    is_pre = r.get('prerelease', False)
    tag = r['tag_name']
    if not is_pre and tag.startswith(stabil):
        kandidaten.append((version(tag), 0 if channel == 'stable' else 1, i, r))
    elif channel == 'beta' and is_pre and tag.startswith(beta):
        kandidaten.append((version(tag), 0, i, r))

if kandidaten:
    kandidaten.sort(key=lambda k: (tuple(-x for x in k[0]), k[1], k[2]))
    r = kandidaten[0][3]
    url = r['assets'][0]['browser_download_url'] if r['assets'] else ''
    print(r['tag_name'] + '|' + url)
" "$channel" "$tag_prefix" 2>/dev/null
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

# =============================================================================
# .NET-Laufzeit (Issue Backend #403, Umstellung auf .NET 10)
#
# Die Releases sind framework-abhaengig: Das Backend startet nur, wenn die ASP.NET Core
# Runtime seiner Hauptversion installiert ist. Die Update-Skripte stellen sie deshalb VOR dem
# Austausch des Backends sicher. Klappt das nicht, wird das Backend nicht getauscht und die
# alte Version laeuft weiter.
#
# Installiert wird neben die vorhandenen Laufzeiten (.NET 9 bleibt), mit Microsofts
# dotnet-install.sh in das Verzeichnis des vorhandenen "dotnet". Neuinstallation: /opt/dotnet
# mit Link /usr/local/bin/dotnet, wie bisher das Fremdskript dotnet9pi.
#
# Beim naechsten Wechsel (.NET 12) nur SM_DOTNET_KANAL anheben.
# =============================================================================
SM_DOTNET_KANAL="10.0"

# Kennt dieses "dotnet" die Laufzeit Microsoft.AspNetCore.App <kanal>.x?
# Usage: sm_dotnet_hat_laufzeit dotnet_bin [kanal]
sm_dotnet_hat_laufzeit() {
    local dotnet_bin="$1" kanal="${2:-$SM_DOTNET_KANAL}"
    [ -n "$dotnet_bin" ] || return 1
    "$dotnet_bin" --list-runtimes 2>/dev/null | grep -q "^Microsoft\.AspNetCore\.App ${kanal//./\\.}\."
}

# Architektur fuer dotnet-install.sh (arm64, arm, x64), leer = nicht unterstuetzt.
# Massgeblich ist das Userland, nicht der Kernel: 32-Bit-Raspberry-Pi-OS laeuft auf Pi 4/5 oft
# mit 64-Bit-Kernel, "uname -m" meldet dort aarch64. Ebenso ein arm32-Container auf arm64-Host.
sm_dotnet_architektur() {
    local arch=""
    if command -v dpkg > /dev/null 2>&1; then
        case "$(dpkg --print-architecture 2>/dev/null)" in
            arm64) arch="arm64" ;;
            armhf) arch="arm" ;;
            amd64) arch="x64" ;;
        esac
    fi
    if [ -z "$arch" ]; then
        case "$(uname -m)" in
            aarch64|arm64)
                if [ "$(getconf LONG_BIT 2>/dev/null)" = "32" ]; then arch="arm"; else arch="arm64"; fi ;;
            armv7l|armv8l) arch="arm" ;;
            x86_64|amd64)  arch="x64" ;;
        esac
    fi
    echo "$arch"
}

# Reicht die glibc fuer .NET? Mindestversionen laut Microsoft (supported-os.json, .NET 10):
# arm 2.35, arm64/x64 2.27 - fuer arm dieselbe wie unter .NET 9.
# Unbekannte Version (kein glibc) blockiert nicht, dann entscheidet die Installation selbst.
sm_dotnet_glibc_reicht() {
    local arch="$1" mindest="2.27" ist
    [ "$arch" = "arm" ] && mindest="2.35"
    ist=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
    [ -z "$ist" ] && return 0
    if [ "$(printf '%s\n%s\n' "$mindest" "$ist" | sort -V | head -n1)" != "$mindest" ]; then
        echo "[FEHLER] glibc $ist ist zu alt fuer .NET $SM_DOTNET_KANAL ($arch braucht mindestens $mindest)."
        echo "[FEHLER] Bitte das Betriebssystem aktualisieren (z. B. Raspberry Pi OS Bookworm)."
        return 1
    fi
    return 0
}

# Stellt die ASP.NET Core Runtime $SM_DOTNET_KANAL sicher.
# Usage: sm_dotnet_laufzeit_sicherstellen [use_sudo]
#   use_sudo=true  native Installation (Skript laeuft als pi oder root)
#   use_sudo=false im Container (laeuft als root, sudo fehlt dort)
# Rueckgabe 0 = vorhanden oder installiert, 1 = fehlt -> Backend NICHT tauschen.
# Setzt SM_DOTNET_NACHINSTALLIERT=true, wenn in diesem Lauf installiert wurde.
sm_dotnet_laufzeit_sicherstellen() {
    local use_sudo="${1:-true}" kanal="$SM_DOTNET_KANAL"
    local sudo_cmd="" dotnet_bin ziel arch skript
    SM_DOTNET_NACHINSTALLIERT=false
    if [ "$use_sudo" = "true" ] && [ "$(id -u)" != "0" ]; then
        sudo_cmd="sudo"
    fi

    dotnet_bin=$(command -v dotnet 2>/dev/null || true)
    if sm_dotnet_hat_laufzeit "$dotnet_bin" "$kanal"; then
        echo "[OK] ASP.NET Core Runtime $kanal ist installiert."
        return 0
    fi

    # Ziel: dort, wo das vorhandene "dotnet" wirklich liegt (Link aufloesen), sonst /opt/dotnet.
    if [ -n "$dotnet_bin" ]; then
        ziel=$(dirname "$(readlink -f "$dotnet_bin")")
    else
        ziel="/opt/dotnet"
    fi

    arch=$(sm_dotnet_architektur)
    if [ -z "$arch" ]; then
        echo "[FEHLER] Prozessor-Architektur $(uname -m) wird von .NET $kanal nicht unterstuetzt."
        return 1
    fi
    sm_dotnet_glibc_reicht "$arch" || return 1

    echo "[INFO] ASP.NET Core Runtime $kanal fehlt - installiere sie ($arch) nach $ziel ..."
    skript=$(mktemp /tmp/dotnet-install-XXXXXX.sh)
    if ! curl -fsSL "https://dot.net/v1/dotnet-install.sh" -o "$skript"; then
        rm -f "$skript"
        echo "[FEHLER] dotnet-install.sh nicht ladbar (Internet?)."
        return 1
    fi

    # Vorhandenes "dotnet" nicht ersetzen (--skip-non-versioned-files): Das alte Backend laeuft
    # waehrenddessen weiter. Der Starter waehlt die neueste hostfxr aus host/fxr und startet damit
    # auch .NET-10-Anwendungen. Nur ohne vorhandenes dotnet wird der Starter mit installiert.
    local ohne_starter=""
    [ -n "$dotnet_bin" ] && ohne_starter="--skip-non-versioned-files"
    if ! $sudo_cmd bash "$skript" --runtime aspnetcore --channel "$kanal" --architecture "$arch" \
            --install-dir "$ziel" --no-path $ohne_starter; then
        rm -f "$skript"
        echo "[FEHLER] Installation der ASP.NET Core Runtime $kanal fehlgeschlagen."
        return 1
    fi
    rm -f "$skript"

    if [ -z "$dotnet_bin" ]; then
        $sudo_cmd ln -sf "$ziel/dotnet" /usr/local/bin/dotnet
    fi

    if sm_dotnet_hat_laufzeit "$ziel/dotnet" "$kanal"; then
        SM_DOTNET_NACHINSTALLIERT=true
        echo "[OK] ASP.NET Core Runtime $kanal installiert."
        return 0
    fi
    echo "[FEHLER] ASP.NET Core Runtime $kanal nach der Installation nicht gefunden."
    return 1
}
