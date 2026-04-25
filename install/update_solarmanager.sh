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

# Shared Library laden — IMMER frisch ziehen, sonst kennt eine alte gecachte
# Version (aus vorigem Update-Lauf in /tmp) neue Funktionen nicht.
LIB_DIR="$(dirname "$0")"
LIB_FILE="$LIB_DIR/lib_solarmanager.sh"
if ! curl -fsSL --max-time 30 \
    "https://raw.githubusercontent.com/BBessler/Solarmanager/main/install/lib_solarmanager.sh" \
    -o "$LIB_FILE"; then
    echo "[FEHLER] lib_solarmanager.sh konnte nicht von GitHub geladen werden."
    exit 1
fi
. "$LIB_FILE"

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

# Symlink-Layout sicherstellen (idempotent — beim ersten Lauf wird der echte
# Ordner unter /var/www/html/releases/<name>/initial-<ts> migriert).
sm_ensure_symlink_layout "$WEB_DIR/backend" backend true
sm_ensure_symlink_layout "$WEB_DIR/frontend" frontend true

# Vorige Symlink-Targets für Rollback merken
PREV_BACKEND=$(readlink "$WEB_DIR/backend" 2>/dev/null || echo "")
PREV_FRONTEND=$(readlink "$WEB_DIR/frontend" 2>/dev/null || echo "")

# 1. Beide Archive ZUERST validieren & neue Releases entpacken — der laufende
#    Service bleibt unangetastet bis alles bereitsteht.
NEW_BACKEND=""
NEW_FRONTEND=""

if [ "$BACKEND_CHANGED" = true ] && [ -n "$LATEST_BACKEND_TAG" ]; then
  echo ""
  echo "[INFO] Backend deployen: $LATEST_BACKEND_TAG..."
  NEW_BACKEND=$(sm_deploy_release "$LATEST_BACKEND_URL" "$WEB_DIR/backend" backend true "Solarmanager.dll") || {
    echo "[FEHLER] Backend-Deploy fehlgeschlagen — alte Version läuft weiter."
    exit 1
  }
  echo "[OK] Backend entpackt: $NEW_BACKEND"
fi

if [ "$FRONTEND_CHANGED" = true ] && [ -n "$LATEST_FRONTEND_TAG" ]; then
  echo "[INFO] Frontend deployen: $LATEST_FRONTEND_TAG..."
  NEW_FRONTEND=$(sm_deploy_release "$LATEST_FRONTEND_URL" "$WEB_DIR/frontend" frontend true "index.html") || {
    echo "[FEHLER] Frontend-Deploy fehlgeschlagen — entferne neues Backend, alte Version läuft weiter."
    [ -n "$NEW_BACKEND" ] && sudo rm -rf "$NEW_BACKEND"
    exit 1
  }
  # config.json aus aktuellem Frontend übernehmen (Frontend-Layout liegt eine
  # Ebene flacher als Backend, da WEB_DIR=/var/www/html sowohl Symlink-Ziel als
  # auch Config-Ort ist — config.json wird darum NICHT in den Release-Ordner
  # gelegt, sondern auf WEB_DIR-Ebene belassen).
  if [ -f "$WEB_DIR/config.json" ]; then
    sudo cp "$WEB_DIR/config.json" "$NEW_FRONTEND/config.json"
  fi
  echo "[OK] Frontend entpackt: $NEW_FRONTEND"
fi

# 1b. Pre-Flight: neuen Build mit --validate-config gegen DI/DB testen, BEVOR
#     der laufende Service gestoppt wird. Spart Downtime bei kaputten Builds —
#     ohne Pre-Flight: stop → swap → start → 60 s Health-Wait → Rollback (~2 min Downtime).
#     Mit Pre-Flight: validate (~5 s) → wenn KO, alter Service läuft ungestört weiter.
#     Wir kopieren appsettings.json vom aktuellen Symlink-Ziel in den neuen Ordner,
#     damit DB-Connection-Strings für den Validate-Lauf verfügbar sind.
if [ "$BACKEND_CHANGED" = true ] && [ -n "$NEW_BACKEND" ] && command -v dotnet &> /dev/null; then
    if [ -f "$WEB_DIR/backend/appsettings.json" ] && [ ! -f "$NEW_BACKEND/appsettings.json" ]; then
        sudo cp "$WEB_DIR/backend/appsettings.json" "$NEW_BACKEND/appsettings.json"
    fi

    echo "[INFO] Pre-Flight: validiere neuen Build (--validate-config)..."
    VALIDATE_OUTPUT=$(cd "$NEW_BACKEND" && timeout 30 sudo -u pi dotnet Solarmanager.dll --validate-config 2>&1) || {
        echo "[FEHLER] Pre-Flight fehlgeschlagen — neuer Build wird verworfen, alte Version läuft weiter:"
        echo "$VALIDATE_OUTPUT" | sed 's/^/    /'
        sudo rm -rf "$NEW_BACKEND"
        [ -n "$NEW_FRONTEND" ] && sudo rm -rf "$NEW_FRONTEND"
        exit 1
    }
    if ! echo "$VALIDATE_OUTPUT" | grep -q "VALIDATE_OK"; then
        echo "[FEHLER] Pre-Flight lieferte unerwartete Ausgabe — neuer Build wird verworfen:"
        echo "$VALIDATE_OUTPUT" | sed 's/^/    /'
        sudo rm -rf "$NEW_BACKEND"
        [ -n "$NEW_FRONTEND" ] && sudo rm -rf "$NEW_FRONTEND"
        exit 1
    fi
    echo "[OK] Pre-Flight bestanden."
fi

# 2. .NET prüfen/installieren (nur falls Backend-Update)
if [ "$BACKEND_CHANGED" = true ] && ! command -v dotnet &> /dev/null; then
    echo "[INFO] .NET ist nicht installiert. Wird jetzt installiert..."
    curl -fsSL https://raw.githubusercontent.com/pjgpetecodes/dotnet9pi/main/install.sh | sudo bash
    if [ -d "$HOME/.dotnet" ]; then
        export PATH="$HOME/.dotnet:$PATH"
    elif [ -d "/usr/share/dotnet" ]; then
        export PATH="/usr/share/dotnet:$PATH"
    fi
    if ! command -v dotnet &> /dev/null; then
        echo "[FEHLER] .NET-Installation fehlgeschlagen. Manuell installieren."
        [ -n "$NEW_BACKEND" ] && sudo rm -rf "$NEW_BACKEND"
        [ -n "$NEW_FRONTEND" ] && sudo rm -rf "$NEW_FRONTEND"
        exit 1
    fi
fi

# 3. Service stoppen, Symlinks atomar umschalten, neu starten
echo ""
echo "[INFO] Stoppe Service und schalte um..."
sudo systemctl stop solarmanager.service || true

if [ -n "$NEW_BACKEND" ]; then
    sm_swap_symlink "$WEB_DIR/backend" "$NEW_BACKEND" true
fi
if [ -n "$NEW_FRONTEND" ]; then
    sm_swap_symlink "$WEB_DIR/frontend" "$NEW_FRONTEND" true
fi

# Versionsdatei aktualisieren (vor Start, damit /Version sofort korrekte Werte
# liefert)
sudo tee "$VERSION_FILE" > /dev/null <<EOF
INSTALLED_BACKEND="$LATEST_BACKEND_TAG"
INSTALLED_FRONTEND="$LATEST_FRONTEND_TAG"
EOF

# Restart-Counter zurücksetzen, sonst weigert systemd den Start nach mehreren
# Crashes ("Start request repeated too quickly").
sudo systemctl reset-failed solarmanager.service || true
sudo systemctl start solarmanager.service

# 4. Health-Check — kommt der neue Service hoch?
echo "[INFO] Warte auf Backend-Start..."
if sm_health_check "http://localhost:5000" 60; then
    echo ""
    echo "[OK] Backend ist bereit."
    sm_cleanup_old_releases "$WEB_DIR/backend" backend 3 true
    sm_cleanup_old_releases "$WEB_DIR/frontend" frontend 3 true
    echo ""
    echo "### Update abgeschlossen! ###"
    exit 0
fi

# 5. Health-Check fehlgeschlagen → Rollback auf vorige Versionen
echo ""
echo "[FEHLER] Backend kommt nicht hoch — Rollback auf vorige Version."
sudo systemctl stop solarmanager.service || true

if [ -n "$NEW_BACKEND" ] && [ -n "$PREV_BACKEND" ] && [ -d "$PREV_BACKEND" ]; then
    echo "[INFO] Rollback Backend → $PREV_BACKEND"
    sm_swap_symlink "$WEB_DIR/backend" "$PREV_BACKEND" true
    sudo rm -rf "$NEW_BACKEND"
fi
if [ -n "$NEW_FRONTEND" ] && [ -n "$PREV_FRONTEND" ] && [ -d "$PREV_FRONTEND" ]; then
    echo "[INFO] Rollback Frontend → $PREV_FRONTEND"
    sm_swap_symlink "$WEB_DIR/frontend" "$PREV_FRONTEND" true
    sudo rm -rf "$NEW_FRONTEND"
fi

# Versionsdatei zurücksetzen
sudo tee "$VERSION_FILE" > /dev/null <<EOF
INSTALLED_BACKEND="$INSTALLED_BACKEND"
INSTALLED_FRONTEND="$INSTALLED_FRONTEND"
EOF

sudo systemctl reset-failed solarmanager.service || true
sudo systemctl start solarmanager.service

if sm_health_check "http://localhost:5000" 60; then
    echo "[OK] Rollback erfolgreich — alte Version läuft wieder."
else
    echo "[KRITISCH] Auch nach Rollback startet der Service nicht. Bitte manuell prüfen:"
    echo "  sudo systemctl status solarmanager.service"
    echo "  sudo journalctl -u solarmanager.service -n 100"
fi

echo ""
echo "### Update fehlgeschlagen, Rollback durchgeführt ###"
exit 1
