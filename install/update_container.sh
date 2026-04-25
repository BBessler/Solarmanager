#!/bin/bash
# =============================================================================
# Solarmanager - Update innerhalb eines Docker-Containers
# Laedt die neuesten Releases herunter, aktualisiert /app und startet neu
# =============================================================================

set -e

# Parameter verarbeiten
CHANNEL="stable"
AUTO_MODE=false
BACKEND_VERSION=""
FRONTEND_VERSION=""
for arg in "$@"; do
    case "$arg" in
        --beta)  CHANNEL="beta" ;;
        --auto)  AUTO_MODE=true ;;
        --backend-version=*)  BACKEND_VERSION="${arg#*=}" ;;
        --frontend-version=*) FRONTEND_VERSION="${arg#*=}" ;;
    esac
done

APP_DIR="/app"
VERSION_FILE="/app/.solarmanager_versions"

# Shared Library laden — IMMER frisch ziehen, sonst kennt eine alte gecachte
# Version (aus vorigem Update-Lauf) neue Funktionen nicht.
LIB_DIR="$(dirname "$0")"
LIB_FILE="$LIB_DIR/lib_solarmanager.sh"
if ! curl -fsSL --max-time 30 \
    "https://raw.githubusercontent.com/BBessler/Solarmanager/main/install/lib_solarmanager.sh" \
    -o "$LIB_FILE"; then
    echo "[FEHLER] lib_solarmanager.sh konnte nicht von GitHub geladen werden."
    exit 1
fi
. "$LIB_FILE"

echo "### Solarmanager Container-Update ($CHANNEL) ###"
echo ""

# Installierte Versionen laden
INSTALLED_BACKEND="(unbekannt)"
INSTALLED_FRONTEND="(unbekannt)"
if [ -f "$VERSION_FILE" ]; then
    . "$VERSION_FILE"
fi

# Releases abfragen
echo "[INFO] Pruefe auf neue Versionen..."
sm_fetch_releases || exit 1

if [ -n "$BACKEND_VERSION" ]; then
    LATEST_BACKEND_INFO=$(sm_get_by_tag "$BACKEND_VERSION")
elif [ "$CHANNEL" = "beta" ]; then
    LATEST_BACKEND_INFO=$(sm_get_latest "beta-backend-" "beta")
else
    LATEST_BACKEND_INFO=$(sm_get_latest "backend-" "stable")
fi

if [ -n "$FRONTEND_VERSION" ]; then
    LATEST_FRONTEND_INFO=$(sm_get_by_tag "$FRONTEND_VERSION")
elif [ "$CHANNEL" = "beta" ]; then
    LATEST_FRONTEND_INFO=$(sm_get_latest "beta-frontend-" "beta")
else
    LATEST_FRONTEND_INFO=$(sm_get_latest "frontend-" "stable")
fi

LATEST_BACKEND_TAG=$(echo "$LATEST_BACKEND_INFO" | cut -d'|' -f1)
LATEST_BACKEND_URL=$(echo "$LATEST_BACKEND_INFO" | cut -d'|' -f2)

LATEST_FRONTEND_TAG=$(echo "$LATEST_FRONTEND_INFO" | cut -d'|' -f1)
LATEST_FRONTEND_URL=$(echo "$LATEST_FRONTEND_INFO" | cut -d'|' -f2)

echo ""
echo "  Installiert        Verfuegbar"
echo "  Backend:  $INSTALLED_BACKEND  ->  $LATEST_BACKEND_TAG"
echo "  Frontend: $INSTALLED_FRONTEND  ->  $LATEST_FRONTEND_TAG"
echo ""

BACKEND_CHANGED=false
FRONTEND_CHANGED=false

if [ "$LATEST_BACKEND_TAG" != "$INSTALLED_BACKEND" ]; then
    BACKEND_CHANGED=true
fi
if [ "$LATEST_FRONTEND_TAG" != "$INSTALLED_FRONTEND" ]; then
    FRONTEND_CHANGED=true
fi

if [ "$BACKEND_CHANGED" = false ] && [ "$FRONTEND_CHANGED" = false ]; then
    echo "[INFO] Alles aktuell."
    exit 0
fi

echo "[AUTO] Update wird durchgefuehrt..."

# Pre-Flight-Validierung absichert: neue Builds werden in /app/staging/ entpackt,
# dort gegen --validate-config geprüft (DI-Graph + DB-Verbindung), und nur bei
# Erfolg per rsync atomar nach /app übernommen. Schlägt die Validierung fehl,
# wird das Staging-Verzeichnis gelöscht — der laufende Container bleibt unangetastet.
STAGING_DIR="/app/staging-$(date +%s)"
BACKUP_DIR="/app/.backup-$(date +%Y%m%d_%H%M%S)"

cleanup_staging() {
    rm -rf "$STAGING_DIR"
}
trap cleanup_staging EXIT

# Backend ins Staging entpacken
if [ "$BACKEND_CHANGED" = true ] && [ -n "$LATEST_BACKEND_URL" ]; then
    echo "[INFO] Backend deployen (Staging): $LATEST_BACKEND_TAG..."
    mkdir -p "$STAGING_DIR/app"
    BACKEND_TMP=$(sm_download_validated "$LATEST_BACKEND_URL") || exit 1
    if ! tar --no-same-owner -xzf "$BACKEND_TMP" -C "$STAGING_DIR/app"; then
        echo "[FEHLER] Backend-Extract fehlgeschlagen."
        rm -f "$BACKEND_TMP"
        exit 1
    fi
    rm -f "$BACKEND_TMP"

    # .NET 9 Static-Web-Assets-Manifest entfernen (Frontend wird separat deployed)
    rm -f "$STAGING_DIR/app/Solarmanager.staticwebassets.endpoints.json"

    if [ ! -f "$STAGING_DIR/app/Solarmanager.dll" ]; then
        echo "[FEHLER] Solarmanager.dll fehlt im Backend-Archiv."
        exit 1
    fi
fi

# Frontend ins Staging entpacken
if [ "$FRONTEND_CHANGED" = true ] && [ -n "$LATEST_FRONTEND_URL" ]; then
    echo "[INFO] Frontend deployen (Staging): $LATEST_FRONTEND_TAG..."
    mkdir -p "$STAGING_DIR/wwwroot"
    FRONTEND_TMP=$(sm_download_validated "$LATEST_FRONTEND_URL") || exit 1
    if ! tar --no-same-owner -xzf "$FRONTEND_TMP" -C "$STAGING_DIR/wwwroot"; then
        echo "[FEHLER] Frontend-Extract fehlgeschlagen."
        rm -f "$FRONTEND_TMP"
        exit 1
    fi
    rm -f "$FRONTEND_TMP"

    cat > "$STAGING_DIR/wwwroot/config.json" <<CFGEOF
{
  "API_URL": "/",
  "APP_ENV": "production"
}
CFGEOF
fi

# Pre-Flight: das neue Backend gegen --validate-config laufen lassen.
# Lädt DI-Graph + öffnet DB-Verbindung, ohne Server-Listener zu starten.
# Bei Erfolg: "VALIDATE_OK" auf stdout, exit 0.
# Wir kopieren appsettings.json aus dem laufenden /app, damit DB-Connection
# und Konfiguration für den Validate-Lauf zur Verfügung stehen.
if [ "$BACKEND_CHANGED" = true ]; then
    if [ -f "/app/appsettings.json" ] && [ ! -f "$STAGING_DIR/app/appsettings.json" ]; then
        cp /app/appsettings.json "$STAGING_DIR/app/appsettings.json"
    fi

    echo "[INFO] Pre-Flight: validiere neuen Build (--validate-config)..."
    VALIDATE_OUTPUT=$(cd "$STAGING_DIR/app" && timeout 30 dotnet Solarmanager.dll --validate-config 2>&1) || {
        echo "[FEHLER] Pre-Flight fehlgeschlagen — neuer Build wird NICHT übernommen:"
        echo "$VALIDATE_OUTPUT" | sed 's/^/    /'
        exit 1
    }

    if ! echo "$VALIDATE_OUTPUT" | grep -q "VALIDATE_OK"; then
        echo "[FEHLER] Pre-Flight lieferte unerwartete Ausgabe — neuer Build wird NICHT übernommen:"
        echo "$VALIDATE_OUTPUT" | sed 's/^/    /'
        exit 1
    fi
    echo "[OK] Pre-Flight bestanden."
fi

# Backup für Notfall-Rollback nach Restart (falls trotz Pre-Flight etwas crasht).
# Nur die Dinge, die wir gleich überschreiben — nicht das ganze /app.
echo "[INFO] Backup laufender Version → $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
if [ "$BACKEND_CHANGED" = true ]; then
    # Nur Backend-Dateien (alles in /app außer wwwroot, staging, backups)
    find /app -maxdepth 1 -mindepth 1 \
        ! -name 'wwwroot' \
        ! -name 'staging-*' \
        ! -name '.backup-*' \
        -exec cp -a {} "$BACKUP_DIR/" \;
fi
if [ "$FRONTEND_CHANGED" = true ] && [ -d /app/wwwroot ]; then
    cp -a /app/wwwroot "$BACKUP_DIR/wwwroot"
fi

# Übernahme: Staging → /app (rsync mit --delete für saubere Backend-Ablage,
# Frontend nur überschreibend ohne --delete, damit eventuell zusätzliche
# Static-Files aus dem Mount erhalten bleiben).
if [ "$BACKEND_CHANGED" = true ]; then
    echo "[INFO] Übernehme Backend-Dateien nach /app..."
    if command -v rsync &> /dev/null; then
        rsync -a --delete \
            --exclude='/wwwroot' \
            --exclude='/staging-*' \
            --exclude='/.backup-*' \
            --exclude='appsettings.json' \
            "$STAGING_DIR/app/" /app/
    else
        # Fallback ohne rsync: alte Backend-Files (ausser wwwroot/staging/backups) löschen + kopieren
        find /app -maxdepth 1 -mindepth 1 \
            ! -name 'wwwroot' \
            ! -name 'staging-*' \
            ! -name '.backup-*' \
            ! -name 'appsettings.json' \
            -exec rm -rf {} +
        cp -a "$STAGING_DIR/app/." /app/
    fi
    echo "[OK] Backend übernommen."
fi

if [ "$FRONTEND_CHANGED" = true ]; then
    echo "[INFO] Übernehme Frontend-Dateien nach /app/wwwroot..."
    mkdir -p /app/wwwroot
    if command -v rsync &> /dev/null; then
        rsync -a --delete "$STAGING_DIR/wwwroot/" /app/wwwroot/
    else
        rm -rf /app/wwwroot
        cp -a "$STAGING_DIR/wwwroot" /app/wwwroot
    fi
    echo "[OK] Frontend übernommen."
fi

# Alte Backups aufräumen — nur die letzten 3 behalten
ls -1dt /app/.backup-*/ 2>/dev/null | tail -n +4 | xargs -r rm -rf

# Versionsdatei schreiben
cat > "$VERSION_FILE" <<EOF
INSTALLED_BACKEND="$LATEST_BACKEND_TAG"
INSTALLED_FRONTEND="$LATEST_FRONTEND_TAG"
EOF
echo "[OK] Versionsdatei aktualisiert."

# trap räumt staging weg, danach Container-Restart triggern
echo "[INFO] Starte Anwendung neu..."
echo "### Update abgeschlossen! ###"
kill -TERM 1
