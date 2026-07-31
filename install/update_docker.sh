#!/bin/bash
# =============================================================================
# Solarmanager - Docker Update
# Laedt die neuesten Releases herunter und startet die Container neu
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

INSTALL_DIR="$HOME/solarmanager"
VERSION_FILE="$INSTALL_DIR/app/.solarmanager_versions"

# Shared Library laden
LIB_DIR="$(dirname "$0")"
if [ ! -f "$LIB_DIR/lib_solarmanager.sh" ]; then
    curl -fsSL "https://raw.githubusercontent.com/BBessler/Solarmanager/main/install/lib_solarmanager.sh" \
        -o "$LIB_DIR/lib_solarmanager.sh"
fi
. "$LIB_DIR/lib_solarmanager.sh"

if [ ! -f "$INSTALL_DIR/docker-compose.yml" ]; then
    echo "FEHLER: $INSTALL_DIR/docker-compose.yml nicht gefunden."
    echo "Bitte zuerst setup_docker.sh ausfuehren."
    exit 1
fi

cd "$INSTALL_DIR"

# Host-Zeitzone mit .env synchronisieren (falls sich die System-TZ geaendert hat
# oder die TZ-Zeile in aelteren .env-Dateien fehlt)
if [ -f "$INSTALL_DIR/.env" ]; then
    HOST_TZ=""
    if command -v timedatectl &> /dev/null; then
        HOST_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
    fi
    if [ -z "$HOST_TZ" ] && [ -f /etc/timezone ]; then
        HOST_TZ=$(cat /etc/timezone 2>/dev/null | tr -d '[:space:]')
    fi
    if [ -z "$HOST_TZ" ] && [ -L /etc/localtime ]; then
        HOST_TZ=$(readlink -f /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
    fi
    if [ -n "$HOST_TZ" ]; then
        if grep -q "^TZ=" "$INSTALL_DIR/.env"; then
            sed -i "s|^TZ=.*|TZ=$HOST_TZ|" "$INSTALL_DIR/.env"
        else
            echo "TZ=$HOST_TZ" >> "$INSTALL_DIR/.env"
        fi
    fi
fi

echo "### Solarmanager Docker Update ($CHANNEL) ###"
echo ""

# Installierte Versionen laden
INSTALLED_BACKEND="(unbekannt)"
INSTALLED_FRONTEND="(unbekannt)"
if [ -f "$VERSION_FILE" ]; then
    . "$VERSION_FILE"
fi

# Alle Releases abfragen
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
    if [ "$AUTO_MODE" = true ]; then
        exit 0
    fi
    read -p "Trotzdem neu installieren? (j/n) [n]: " CONFIRM
    CONFIRM="${CONFIRM:-n}"
    if [[ ! "$CONFIRM" =~ ^[Jj]$ ]]; then
        echo "[INFO] Abgebrochen."
        exit 0
    fi
    # Bei Reinstall alles herunterladen
    BACKEND_CHANGED=true
    FRONTEND_CHANGED=true
else
    if [ "$AUTO_MODE" = false ]; then
        read -p "Update jetzt durchfuehren? (j/n) [j]: " CONFIRM
        CONFIRM="${CONFIRM:-j}"
        if [[ ! "$CONFIRM" =~ ^[Jj]$ ]]; then
            echo "[INFO] Update abgebrochen."
            exit 0
        fi
    else
        echo "[AUTO] Update wird durchgefuehrt..."
    fi
fi

# Frontend zuerst aktualisieren (nur wenn geaendert): statische Dateien,
# beruehrt den laufenden Container nicht.
if [ "$FRONTEND_CHANGED" = true ] && [ -n "$LATEST_FRONTEND_TAG" ]; then
    echo "[INFO] Frontend aktualisieren: $LATEST_FRONTEND_TAG..."
    sm_download_and_extract "$LATEST_FRONTEND_URL" "$INSTALL_DIR/app/wwwroot" || exit 1

    # config.json generieren (relative URL - funktioniert mit Hostname und IP)
    cat > "$INSTALL_DIR/app/wwwroot/config.json" <<CFGEOF
{
  "API_URL": "/",
  "APP_ENV": "production"
}
CFGEOF
    echo "[OK] config.json generiert (API_URL: /)."
    echo "[OK] Frontend aktualisiert."
fi

# Backend aktualisieren (nur wenn geaendert). Container vorher stoppen: wird
# ueber die Dateien des laufenden Prozesses entpackt, stirbt er mitten drin.
if [ "$BACKEND_CHANGED" = true ] && [ -n "$LATEST_BACKEND_TAG" ]; then
    echo "[INFO] Stoppe Container fuer den Backend-Tausch..."
    docker compose stop solarmanager || true

    echo "[INFO] Backend aktualisieren: $LATEST_BACKEND_TAG..."
    if ! sm_download_and_extract "$LATEST_BACKEND_URL" "$INSTALL_DIR/app"; then
        echo "[FEHLER] Backend-Update fehlgeschlagen - starte Container wieder..."
        docker compose up -d || true
        exit 1
    fi
    echo "[OK] Backend aktualisiert."
fi

# Container neu starten
echo "[INFO] Starte Container neu..."
docker compose up -d
docker compose restart solarmanager

echo ""
echo "[INFO] Warte auf Backend-Start..."
if sm_health_check "http://localhost:8080" 60; then
    echo ""
    echo "[OK] Backend ist bereit."
else
    echo "[WARNUNG] Backend antwortet noch nicht. Bitte manuell pruefen: docker compose logs -f"
fi

# Versionen NACH erfolgreichem Health-Check speichern
cat > "$VERSION_FILE" <<EOF
INSTALLED_BACKEND="$LATEST_BACKEND_TAG"
INSTALLED_FRONTEND="$LATEST_FRONTEND_TAG"
EOF

echo ""
echo "### Update abgeschlossen! ###"
