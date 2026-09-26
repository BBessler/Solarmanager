#!/bin/bash

# Solarmanager Update
# Laedt die neuesten Releases herunter und aktualisiert Backend/Frontend

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

# Shared Library laden - IMMER frisch, passend zu diesem Script. Das Backend laedt das Script
# bei jedem Lauf neu; eine Bibliothek daneben kann aber von einem frueheren Update stammen
# (Backends bis 2026.09 legen beides direkt nach /tmp) und kennt dann neue Funktionen nicht:
# "sm_aufloesen_tag: command not found". Die Kopie daneben ist nur der Rueckfall ohne GitHub.
LIB_DIR="$(dirname "$0")"
LIB_URL="https://raw.githubusercontent.com/BBessler/Solarmanager/main/install/lib_solarmanager.sh"
if curl -fsSL "$LIB_URL" -o "$LIB_DIR/lib_solarmanager.sh.neu"; then
    mv -f "$LIB_DIR/lib_solarmanager.sh.neu" "$LIB_DIR/lib_solarmanager.sh"
else
    rm -f "$LIB_DIR/lib_solarmanager.sh.neu"
    echo "[WARN] Bibliothek nicht von GitHub ladbar - verwende die vorhandene Kopie."
fi
if [ ! -f "$LIB_DIR/lib_solarmanager.sh" ]; then
    echo "[FEHLER] Bibliothek lib_solarmanager.sh fehlt und ist nicht ladbar."
    exit 1
fi
. "$LIB_DIR/lib_solarmanager.sh"
if ! type sm_aufloesen_tag >/dev/null 2>&1; then
    echo "[FEHLER] Die Bibliothek unter $LIB_DIR ist veraltet und GitHub nicht erreichbar."
    echo "[FEHLER] Bitte $LIB_DIR/lib_solarmanager.sh loeschen und das Update erneut starten."
    exit 1
fi

echo "### Solarmanager Update ($CHANNEL) ###"
# Aufruf protokollieren: Ohne das laesst sich hinterher nicht klaeren, ob ein Lauf mit
# gepinnter Version kam oder den neuesten Tag suchen sollte - und genau daran hing die
# Fehlersuche am 16.09.2026 fest.
echo "[INFO] Aufruf: Kanal=$CHANNEL  Backend-Version=${BACKEND_VERSION:-(neueste)}  Frontend-Version=${FRONTEND_VERSION:-(neueste)}"
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
#
# Ohne diese Pruefung lief das Update mit leerem Tag durch: Es lud nichts herunter,
# entpackte nichts, schrieb am Ende aber INSTALLED_BACKEND="" in die Versionsdatei und
# meldete Erfolg. Die vorher korrekte Version war damit ueberschrieben und die Anzeige
# im Frontend leer (live am 16.09.2026, Kanal beta).
#
# Ein fehlendes Release ist ein Fehler, kein "alles aktuell": Wer ein Update anstoesst,
# soll erfahren, dass es fuer seinen Kanal nichts gibt.
# Leeres Ergebnis heisst: kein passendes Release gefunden - NICHT weitermachen.
# Die Meldung nennt die tatsaechliche Ursache: ein gepinnter Tag, den es nicht gibt, ist
# etwas anderes als ein Kanal ohne Release. Vorher stand in beiden Faellen derselbe
# Praefix-Text und fuehrte die Fehlersuche in die Irre.
sm_pruefe_treffer() {
  local was="$1" tag="$2" url="$3" gepinnt="$4" praefix="$5"

  if [ -n "$tag" ] && [ -n "$url" ]; then
    return 0
  fi

  if [ -n "$gepinnt" ]; then
    echo "[FEHLER] $was-Version '$gepinnt' wurde nicht gefunden."
    echo "[FEHLER] Der Tag existiert nicht oder hat kein Release-Asset."
  elif [ -n "$tag" ]; then
    echo "[FEHLER] $was-Release '$tag' hat kein Download-Asset."
  else
    echo "[FEHLER] Kein $was-Release fuer Kanal '$CHANNEL' (Praefix '$praefix')."
  fi
  echo "[FEHLER] Die Versionsdatei bleibt unveraendert."
  return 1
}

# Der gepinnte Tag entscheidet hier nicht mehr: sm_aufloesen_tag weicht bei einem
# unbekannten Wunsch bereits auf den neuesten Tag des Kanals aus und warnt dabei.
# Bleibt es trotzdem leer, gibt es fuer diesen Kanal wirklich kein Release.
sm_pruefe_treffer "Backend" "$LATEST_BACKEND_TAG" "$LATEST_BACKEND_URL" "" "$BACKEND_PRAEFIX" || exit 1
sm_pruefe_treffer "Frontend" "$LATEST_FRONTEND_TAG" "$LATEST_FRONTEND_URL" "" "$FRONTEND_PRAEFIX" || exit 1

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

# Neu installieren trotz gleichem Tag: Beta-Releases eines Tages tragen denselben Tag
# (beta-backend-YYYY.MM.DD), ein spaeterer Build desselben Tages wurde sonst als
# "Alles aktuell" verworfen - und im Auto-Modus beendete sich der Knopf "Aktuelle
# Version neu installieren" ohne jede Installation.
if [ "$FORCE" = true ]; then
    echo "[INFO] Neuinstallation angefordert (--force)."
    BACKEND_CHANGED=true
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

# Installierte Versionen speichern.
#
# Nur fortschreiben, was in diesem Lauf auch wirklich getauscht wurde: Wurde nur das
# Frontend aktualisiert, darf die Backend-Zeile nicht auf den neuesten Tag springen -
# sonst gilt eine Version als installiert, die nie ausgepackt wurde.
NEUES_BACKEND="$INSTALLED_BACKEND"
NEUES_FRONTEND="$INSTALLED_FRONTEND"
[ "$BACKEND_CHANGED" = true ] && NEUES_BACKEND="$LATEST_BACKEND_TAG"
[ "$FRONTEND_CHANGED" = true ] && NEUES_FRONTEND="$LATEST_FRONTEND_TAG"

# "(unbekannt)" ist der Platzhalter aus dem Einlesen und gehoert nicht in die Datei.
[ "$NEUES_BACKEND" = "(unbekannt)" ] && NEUES_BACKEND=""
[ "$NEUES_FRONTEND" = "(unbekannt)" ] && NEUES_FRONTEND=""

sudo tee "$VERSION_FILE" > /dev/null <<EOF
INSTALLED_BACKEND="$NEUES_BACKEND"
INSTALLED_FRONTEND="$NEUES_FRONTEND"
EOF
echo "[OK] Versionsdatei aktualisiert: Backend=$NEUES_BACKEND Frontend=$NEUES_FRONTEND"

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
