#!/bin/bash

# Solarmanager Update
# Laedt die neuesten Releases herunter und aktualisiert Backend/Frontend

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

WEB_DIR="/var/www/html"
VERSION_FILE="/var/www/html/.solarmanager_versions"

# Shared Library laden
LIB_DIR="$(dirname "$0")"
if [ ! -f "$LIB_DIR/lib_solarmanager.sh" ]; then
    curl -fsSL "https://raw.githubusercontent.com/BBessler/Solarmanager/main/install/lib_solarmanager.sh" \
        -o "$LIB_DIR/lib_solarmanager.sh"
fi
. "$LIB_DIR/lib_solarmanager.sh"

echo "### Solarmanager Update ($CHANNEL) ###"
echo ""

# Installierte Versionen laden (falls vorhanden)
INSTALLED_BACKEND="(unbekannt)"
INSTALLED_FRONTEND="(unbekannt)"
if [ -f "$VERSION_FILE" ]; then
  . "$VERSION_FILE"
fi

# Alle Releases einmalig abfragen
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

# Backend aktualisieren (nur wenn geaendert)
if [ "$BACKEND_CHANGED" = true ] && [ -n "$LATEST_BACKEND_TAG" ]; then
  echo ""
  echo "[INFO] Backend aktualisieren: $LATEST_BACKEND_TAG..."
  sm_download_and_extract "$LATEST_BACKEND_URL" "$WEB_DIR/backend" "true" || exit 1
  echo "[OK] Backend aktualisiert."
fi

# Frontend aktualisieren (nur wenn geaendert)
if [ "$FRONTEND_CHANGED" = true ] && [ -n "$LATEST_FRONTEND_TAG" ]; then
  echo "[INFO] Frontend aktualisieren: $LATEST_FRONTEND_TAG..."

  # config.json sichern
  CONFIG_BACKUP=""
  if [ -f "$WEB_DIR/config.json" ]; then
    CONFIG_BACKUP=$(cat "$WEB_DIR/config.json")
  fi

  sm_download_and_extract "$LATEST_FRONTEND_URL" "$WEB_DIR" "true" || exit 1

  # config.json wiederherstellen
  if [ -n "$CONFIG_BACKUP" ]; then
    echo "$CONFIG_BACKUP" | sudo tee "$WEB_DIR/config.json" > /dev/null
    echo "[OK] config.json wiederhergestellt."
  fi
  echo "[OK] Frontend aktualisiert."
fi

# Rechte setzen
sudo chown -R pi:pi "$WEB_DIR"
sudo find "$WEB_DIR" -type d -exec chmod 755 {} \;
sudo find "$WEB_DIR" -type f -exec chmod 644 {} \;

# .NET pruefen und ggf. installieren
if command -v dotnet &> /dev/null; then
    echo "[INFO] .NET ist installiert (Version: $(dotnet --version 2>/dev/null || echo 'unbekannt'))."
else
    echo "[INFO] .NET ist nicht installiert. Wird jetzt installiert..."
    curl -fsSL https://raw.githubusercontent.com/pjgpetecodes/dotnet9pi/main/install.sh | sudo bash
    # Sicherstellen, dass dotnet im PATH ist
    if [ -d "$HOME/.dotnet" ]; then
        export PATH="$HOME/.dotnet:$PATH"
    elif [ -d "/usr/share/dotnet" ]; then
        export PATH="/usr/share/dotnet:$PATH"
    fi
    if command -v dotnet &> /dev/null; then
        echo "[OK] .NET $(dotnet --version) erfolgreich installiert."
    else
        echo "[FEHLER] .NET-Installation fehlgeschlagen. Bitte manuell installieren."
        exit 1
    fi
fi

# Installierte Versionen speichern (vor Restart, da das Script als Child-Prozess des Backends laeuft)
sudo tee "$VERSION_FILE" > /dev/null <<EOF
INSTALLED_BACKEND="$LATEST_BACKEND_TAG"
INSTALLED_FRONTEND="$LATEST_FRONTEND_TAG"
EOF
echo "[OK] Versionsdatei aktualisiert."

# Backend neu starten
echo "[INFO] Starte Backend neu..."
sudo systemctl restart solarmanager.service

echo "[INFO] Warte auf Backend-Start..."
if sm_health_check "http://localhost:5000" 60; then
    echo ""
    echo "[OK] Backend ist bereit."
else
    echo "[WARNUNG] Backend antwortet noch nicht. Bitte manuell pruefen: sudo systemctl status solarmanager.service"
fi

echo ""
echo "### Update abgeschlossen! ###"
