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
SERVICE="solarmanager.service"
LOG_DIR="/var/log/solarmanager"
LOG_FILE="$LOG_DIR/update.log"
STATE_FILE="$LOG_DIR/update.state"
SERVICE_STOPPED=false

# =============================================================================
# In eigene systemd-Unit umziehen
# Wird das Update aus dem Backend heraus gestartet, laeuft dieses Script als
# Kindprozess im cgroup von solarmanager.service. Sobald der Dienst neu startet
# (geplant oder weil das Entpacken den laufenden Prozess erwischt), raeumt
# systemd den ganzen cgroup ab und bricht das Update mitten drin ab - typisch:
# Backend aktualisiert, Frontend nicht. Als eigene transiente Unit ueberlebt
# das Update den Dienst-Neustart.
# =============================================================================
if [ -z "$SM_UPDATE_DETACHED" ] \
   && grep -qa "solarmanager\.service" /proc/self/cgroup 2>/dev/null \
   && command -v systemd-run > /dev/null 2>&1; then
    echo "[INFO] Update wird in eine eigene systemd-Unit verschoben..."
    sudo -n systemctl reset-failed solarmanager-update.service > /dev/null 2>&1 || true
    if sudo -n systemd-run --unit=solarmanager-update --collect \
            --description="Solarmanager Update" \
            --setenv=SM_UPDATE_DETACHED=1 \
            /bin/bash "$0" "$@" > /dev/null 2>&1; then
        echo "[OK] Update laeuft eigenstaendig weiter (Unit: solarmanager-update)."
        exit 0
    fi
    echo "[WARNUNG] Umzug fehlgeschlagen - Update laeuft als Kindprozess weiter."
fi

# =============================================================================
# Logging
# Die Ausgabe geht zusaetzlich in eine Datei, damit das Frontend den Verlauf
# auch dann noch anzeigen kann, wenn das Backend zwischendurch neu startet.
# Der Endstatus landet in einer eigenen Datei, damit das Frontend erkennt,
# ob das Update noch laeuft, fertig ist oder abgebrochen wurde.
# =============================================================================
if ! sudo mkdir -p "$LOG_DIR" 2>/dev/null \
   || ! sudo touch "$LOG_FILE" "$STATE_FILE" 2>/dev/null; then
    # Kein Schreibzugriff auf /var/log: ausweichen statt das Update abzubrechen.
    # Das Backend sucht die Dateien in beiden Verzeichnissen.
    LOG_DIR="/tmp/solarmanager"
    LOG_FILE="$LOG_DIR/update.log"
    STATE_FILE="$LOG_DIR/update.state"
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE" "$STATE_FILE"
fi
sudo chmod 755 "$LOG_DIR" 2>/dev/null || true
sudo chown "$(id -un):$(id -gn)" "$LOG_FILE" "$STATE_FILE" 2>/dev/null || true
sudo chmod 644 "$LOG_FILE" "$STATE_FILE" 2>/dev/null || true
: > "$LOG_FILE"
echo "running" > "$STATE_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

sm_finish() {
    local code=$1

    # Sicherheitsnetz: Dienst nie gestoppt zuruecklassen
    if [ "$SERVICE_STOPPED" = true ]; then
        echo "[WARNUNG] Update abgebrochen - starte $SERVICE wieder..."
        sudo systemctl start "$SERVICE" || true
    fi

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

# .NET pruefen und ggf. installieren (vor dem Backend-Tausch, damit der Dienst
# nicht ohne Runtime dasteht)
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

# Frontend zuerst aktualisieren: statische Dateien, beruehrt den laufenden
# Dienst nicht. Faellt der Backend-Schritt aus, ist das Frontend trotzdem da.
if [ "$FRONTEND_CHANGED" = true ] && [ -n "$LATEST_FRONTEND_TAG" ]; then
  echo ""
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

# Backend aktualisieren (nur wenn geaendert). Der Dienst wird vorher gestoppt:
# Wird ueber die Dateien des laufenden Prozesses entpackt, stirbt er mitten im
# Update.
if [ "$BACKEND_CHANGED" = true ] && [ -n "$LATEST_BACKEND_TAG" ]; then
  echo ""
  echo "[INFO] Stoppe $SERVICE fuer den Backend-Tausch..."
  sudo systemctl stop "$SERVICE" || true
  SERVICE_STOPPED=true

  echo "[INFO] Backend aktualisieren: $LATEST_BACKEND_TAG..."
  sm_download_and_extract "$LATEST_BACKEND_URL" "$WEB_DIR/backend" "true" || exit 1
  echo "[OK] Backend aktualisiert."
fi

# Rechte setzen
echo "[INFO] Setze Rechte..."
sudo chown -R pi:pi "$WEB_DIR"
sudo find "$WEB_DIR" -type d -exec chmod 755 {} \;
sudo find "$WEB_DIR" -type f -exec chmod 644 {} \;

# Installierte Versionen speichern
sudo tee "$VERSION_FILE" > /dev/null <<EOF
INSTALLED_BACKEND="$LATEST_BACKEND_TAG"
INSTALLED_FRONTEND="$LATEST_FRONTEND_TAG"
EOF
echo "[OK] Versionsdatei aktualisiert."

# Backend starten (nur noetig, wenn es getauscht wurde)
if [ "$SERVICE_STOPPED" = true ]; then
  echo "[INFO] Starte Backend..."
  sudo systemctl start "$SERVICE"
  SERVICE_STOPPED=false

  echo "[INFO] Warte auf Backend-Start..."
  if sm_health_check "http://localhost:5000/healthz" 120; then
      echo ""
      echo "[OK] Backend ist bereit."
  else
      echo "[WARNUNG] Backend antwortet noch nicht. Bitte manuell pruefen: sudo systemctl status $SERVICE"
  fi
fi

echo ""
echo "### Update abgeschlossen! ###"
