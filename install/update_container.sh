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

# Shared Library laden
LIB_DIR="$(dirname "$0")"
if [ ! -f "$LIB_DIR/lib_solarmanager.sh" ]; then
    curl -fsSL "https://raw.githubusercontent.com/BBessler/Solarmanager/main/install/lib_solarmanager.sh" \
        -o "$LIB_DIR/lib_solarmanager.sh"
fi
. "$LIB_DIR/lib_solarmanager.sh"

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

# Backend aktualisieren
if [ "$BACKEND_CHANGED" = true ] && [ -n "$LATEST_BACKEND_URL" ]; then
    echo "[INFO] Backend aktualisieren: $LATEST_BACKEND_TAG..."
    sm_download_and_extract "$LATEST_BACKEND_URL" "$APP_DIR" || exit 1
    echo "[OK] Backend aktualisiert."
fi

# Frontend aktualisieren
if [ "$FRONTEND_CHANGED" = true ] && [ -n "$LATEST_FRONTEND_URL" ]; then
    echo "[INFO] Frontend aktualisieren: $LATEST_FRONTEND_TAG..."

    # config.json sichern (wird in Docker aus .env generiert)
    CONFIG_BACKUP=""
    if [ -f "$APP_DIR/wwwroot/config.json" ]; then
        CONFIG_BACKUP=$(cat "$APP_DIR/wwwroot/config.json")
    fi

    sm_download_and_extract "$LATEST_FRONTEND_URL" "$APP_DIR/wwwroot" || exit 1

    # config.json wiederherstellen
    if [ -n "$CONFIG_BACKUP" ]; then
        echo "$CONFIG_BACKUP" > "$APP_DIR/wwwroot/config.json"
        echo "[OK] config.json wiederhergestellt."
    fi
    echo "[OK] Frontend aktualisiert."
fi

# Versionsdatei schreiben
cat > "$VERSION_FILE" <<EOF
INSTALLED_BACKEND="$LATEST_BACKEND_TAG"
INSTALLED_FRONTEND="$LATEST_FRONTEND_TAG"
EOF
echo "[OK] Versionsdatei aktualisiert."

# Anwendung beenden - Docker restart-policy startet den Container neu
echo "[INFO] Starte Anwendung neu..."
echo "### Update abgeschlossen! ###"
kill -TERM 1
