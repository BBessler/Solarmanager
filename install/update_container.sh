#!/bin/bash
# =============================================================================
# Solarmanager - Update innerhalb eines Docker-Containers
# Laedt die neuesten Releases herunter, aktualisiert /app und startet neu
# =============================================================================

set -e

# Parameter verarbeiten
CHANNEL="stable"
AUTO_MODE=false
FORCE=false
BACKEND_VERSION=""
FRONTEND_VERSION=""
for arg in "$@"; do
    case "$arg" in
        --beta)  CHANNEL="beta" ;;
        --auto)  AUTO_MODE=true ;;
        --force) FORCE=true ;;
        --backend-version=*)  BACKEND_VERSION="${arg#*=}" ;;
        --frontend-version=*) FRONTEND_VERSION="${arg#*=}" ;;
    esac
done

APP_DIR="/app"
VERSION_FILE="/app/.solarmanager_versions"
LOG_DIR="/var/log/solarmanager"
LOG_FILE="$LOG_DIR/update.log"
STATE_FILE="$LOG_DIR/update.state"

# Logging: Ausgabe zusaetzlich in eine Datei, damit das Frontend den Verlauf
# auch nach dem Neustart des Containers noch anzeigen kann.
if ! mkdir -p "$LOG_DIR" 2>/dev/null || ! touch "$LOG_FILE" 2>/dev/null; then
    # Container ohne Root: ausweichen statt das Update abzubrechen.
    # Das Backend sucht die Dateien in beiden Verzeichnissen.
    LOG_DIR="/tmp/solarmanager"
    LOG_FILE="$LOG_DIR/update.log"
    STATE_FILE="$LOG_DIR/update.state"
    mkdir -p "$LOG_DIR"
fi
: > "$LOG_FILE"
echo "running" > "$STATE_FILE"
chmod 644 "$LOG_FILE" "$STATE_FILE" 2>/dev/null || true

exec > >(tee -a "$LOG_FILE") 2>&1

sm_finish() {
    local code=$1
    sleep 1   # letzte Zeilen durch tee flushen lassen
    if [ "$code" -eq 0 ]; then
        echo "success" > "$STATE_FILE"
    else
        echo "failed" > "$STATE_FILE"
    fi
}
trap 'sm_finish $?' EXIT

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

if [ "$CHANNEL" = "beta" ]; then
  BACKEND_PRAEFIX="beta-backend-"; FRONTEND_PRAEFIX="beta-frontend-"
else
  BACKEND_PRAEFIX="backend-"; FRONTEND_PRAEFIX="frontend-"
fi

# Tolerant aufloesen: gepinnter Tag, sonst doppeltes Praefix bereinigen, sonst neuester
# Tag des Kanals. Siehe sm_aufloesen_tag - dieses Script muss auch mit einem fehlerhaften
# Aufrufer noch zu einem Update fuehren.
LATEST_BACKEND_INFO=$(sm_aufloesen_tag "$BACKEND_VERSION" "$BACKEND_PRAEFIX" "$CHANNEL")
LATEST_FRONTEND_INFO=$(sm_aufloesen_tag "$FRONTEND_VERSION" "$FRONTEND_PRAEFIX" "$CHANNEL")

LATEST_BACKEND_TAG=$(echo "$LATEST_BACKEND_INFO" | cut -d'|' -f1)
LATEST_BACKEND_URL=$(echo "$LATEST_BACKEND_INFO" | cut -d'|' -f2)

LATEST_FRONTEND_TAG=$(echo "$LATEST_FRONTEND_INFO" | cut -d'|' -f1)
LATEST_FRONTEND_URL=$(echo "$LATEST_FRONTEND_INFO" | cut -d'|' -f2)

# Leeres Ergebnis heisst: kein passendes Release gefunden - NICHT weitermachen.
# Sonst laeuft das Update mit leerem Tag durch, installiert nichts und ueberschreibt
# am Ende die Versionsdatei mit leeren Werten (siehe update_solarmanager.sh).
if [ -z "$LATEST_BACKEND_TAG" ] || [ -z "$LATEST_BACKEND_URL" ]; then
  echo "[FEHLER] Kein Backend-Release fuer Kanal '$CHANNEL' gefunden."
  echo "[FEHLER] Die Versionsdatei bleibt unveraendert."
  exit 1
fi
if [ -z "$LATEST_FRONTEND_TAG" ] || [ -z "$LATEST_FRONTEND_URL" ]; then
  echo "[FEHLER] Kein Frontend-Release fuer Kanal '$CHANNEL' gefunden."
  echo "[FEHLER] Die Versionsdatei bleibt unveraendert."
  exit 1
fi

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

# Neu installieren trotz gleichem Tag (siehe update_solarmanager.sh).
if [ "$FORCE" = true ]; then
    echo "[INFO] Neuinstallation angefordert (--force)."
    BACKEND_CHANGED=true
    FRONTEND_CHANGED=true
fi

if [ "$BACKEND_CHANGED" = false ] && [ "$FRONTEND_CHANGED" = false ]; then
    echo "[INFO] Alles aktuell."
    exit 0
fi

echo "[AUTO] Update wird durchgefuehrt..."

# Frontend zuerst: statische Dateien, beruehrt den laufenden Prozess nicht.
if [ "$FRONTEND_CHANGED" = true ] && [ -n "$LATEST_FRONTEND_URL" ]; then
    echo "[INFO] Frontend aktualisieren: $LATEST_FRONTEND_TAG..."

    sm_download_and_extract "$LATEST_FRONTEND_URL" "$APP_DIR/wwwroot" || exit 1

    # config.json generieren (relative URL - funktioniert mit Hostname und IP)
    cat > "$APP_DIR/wwwroot/config.json" <<CFGEOF
{
  "API_URL": "/",
  "APP_ENV": "production"
}
CFGEOF
    echo "[OK] config.json generiert."
    echo "[OK] Frontend aktualisiert."
fi

# Backend aktualisieren. Hier wird ueber die Dateien des laufenden Prozesses
# entpackt - der Container startet direkt danach neu.
if [ "$BACKEND_CHANGED" = true ] && [ -n "$LATEST_BACKEND_URL" ]; then
    echo "[INFO] Backend aktualisieren: $LATEST_BACKEND_TAG..."
    sm_download_and_extract "$LATEST_BACKEND_URL" "$APP_DIR" || exit 1
    # .NET 9 Static-Web-Assets-Manifest entfernen (Frontend wird separat deployed)
    rm -f "$APP_DIR/Solarmanager.staticwebassets.endpoints.json"
    echo "[OK] Backend aktualisiert."
fi

# Versionsdatei schreiben
# Nur fortschreiben, was in diesem Lauf wirklich getauscht wurde.
NEUES_BACKEND="$INSTALLED_BACKEND"
NEUES_FRONTEND="$INSTALLED_FRONTEND"
[ "$BACKEND_CHANGED" = true ] && NEUES_BACKEND="$LATEST_BACKEND_TAG"
[ "$FRONTEND_CHANGED" = true ] && NEUES_FRONTEND="$LATEST_FRONTEND_TAG"
[ "$NEUES_BACKEND" = "(unbekannt)" ] && NEUES_BACKEND=""
[ "$NEUES_FRONTEND" = "(unbekannt)" ] && NEUES_FRONTEND=""

cat > "$VERSION_FILE" <<EOF
INSTALLED_BACKEND="$NEUES_BACKEND"
INSTALLED_FRONTEND="$NEUES_FRONTEND"
EOF
echo "[OK] Versionsdatei aktualisiert."

# Besitz zurueckgeben: /app ist ein Ordner des Hosts (./app:/app), dieses Script laeuft im
# Container aber als root. Ohne diesen Schritt gehoeren alle getauschten Dateien root, und
# update_docker.sh auf dem Host (als pi) kann sie nicht mehr ueberschreiben
# ("tar: Cannot open: Permission denied"). Massgeblich ist der Besitzer von /app selbst.
APP_OWNER=$(stat -c '%u:%g' "$APP_DIR" 2>/dev/null || true)
if [ -n "$APP_OWNER" ] && [ "$APP_OWNER" != "0:0" ] && [ "$(id -u)" = "0" ]; then
    if chown -R "$APP_OWNER" "$APP_DIR"; then
        echo "[OK] Dateien gehoeren wieder $APP_OWNER."
    else
        echo "[WARN] Besitz unter $APP_DIR nicht vollstaendig korrigierbar."
    fi
fi

# Anwendung beenden - Docker restart-policy startet den Container neu
echo "[INFO] Starte Anwendung neu..."
echo "### Update abgeschlossen! ###"

# Endstatus vor dem Neustart festhalten: mit PID 1 stirbt auch dieses Script,
# der EXIT-Trap kommt dann nicht mehr zum Zug.
sleep 1
echo "success" > "$STATE_FILE"

kill -TERM 1
