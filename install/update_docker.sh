#!/bin/bash
# =============================================================================
# Solarmanager - Docker Update
# Laedt die neuesten Releases herunter und startet die Container neu
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

INSTALL_DIR="$HOME/solarmanager"
VERSION_FILE="$INSTALL_DIR/app/.solarmanager_versions"

# Shared Library laden - IMMER frisch, passend zu diesem Script. Eine Bibliothek daneben kann
# von einem frueheren Lauf stammen und kennt dann neue Funktionen nicht. Die Kopie daneben
# ist nur der Rueckfall ohne GitHub.
LIB_DIR="$(dirname "$0")"
LIB_URL="https://raw.githubusercontent.com/BBessler/Solarmanager/${SM_SKRIPT_REF:-main}/install/lib_solarmanager.sh"
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
if ! type sm_extract > /dev/null 2>&1 || ! type sm_dotnet_kanal_aus_archiv > /dev/null 2>&1; then
    echo "[FEHLER] Die Bibliothek unter $LIB_DIR ist veraltet und GitHub nicht erreichbar."
    echo "[FEHLER] Bitte $LIB_DIR/lib_solarmanager.sh loeschen und das Update erneut starten."
    exit 1
fi

if [ ! -f "$INSTALL_DIR/docker-compose.yml" ]; then
    echo "FEHLER: $INSTALL_DIR/docker-compose.yml nicht gefunden."
    echo "Bitte zuerst setup_docker.sh ausfuehren."
    exit 1
fi

cd "$INSTALL_DIR"

# Dateien unter app/, die das Update ueber die Oberflaeche im Container als root angelegt hat,
# kann dieser Benutzer weder ueberschreiben noch config.json/Versionsdatei neu schreiben.
# Einmal zurueckgeben, statt mitten im Entpacken zu scheitern.
if [ "$(id -u)" != "0" ] && [ -n "$(find "$INSTALL_DIR/app" ! -user "$(id -u)" -print -quit 2>/dev/null)" ]; then
    echo "[INFO] Dateien unter $INSTALL_DIR/app gehoeren nicht $(id -un) - Besitz wird korrigiert (sudo)..."
    SUDO_CMD="sudo"
    [ "$AUTO_MODE" = true ] && SUDO_CMD="sudo -n"
    if ! $SUDO_CMD chown -R "$(id -u):$(id -g)" "$INSTALL_DIR/app"; then
        echo "[FEHLER] Besitz nicht korrigierbar. Bitte ausfuehren:"
        echo "         sudo chown -R $(id -un): $INSTALL_DIR/app"
        exit 1
    fi
    echo "[OK] Besitz korrigiert."
fi

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

# Neu installieren trotz gleichem Tag (siehe update_solarmanager.sh).
if [ "$FORCE" = true ]; then
    echo "[INFO] Neuinstallation angefordert (--force)."
    BACKEND_CHANGED=true
    FRONTEND_CHANGED=true
fi

# Liegt auf GitHub ein geaendertes Dockerfile (neues Paket, neue .NET-Version)? Laedt es nach
# Dockerfile.neu; Rueckgabe 0 = geaendert. Ohne GitHub bleibt das Image unveraendert.
DOCKERFILE_URL="https://raw.githubusercontent.com/BBessler/Solarmanager/${SM_SKRIPT_REF:-main}/docker/Dockerfile"
sm_dockerfile_geaendert() {
    if ! curl -fsSL "$DOCKERFILE_URL" -o "$INSTALL_DIR/Dockerfile.neu"; then
        rm -f "$INSTALL_DIR/Dockerfile.neu"
        echo "[WARN] Dockerfile nicht von GitHub ladbar - Image bleibt unveraendert."
        return 1
    fi
    if cmp -s "$INSTALL_DIR/Dockerfile.neu" "$INSTALL_DIR/Dockerfile"; then
        rm -f "$INSTALL_DIR/Dockerfile.neu"
        return 1
    fi
    return 0
}

# Hat das Image die ASP.NET Core Runtime <kanal>? Leerer Kanal = keine Aussage (gilt als ja).
sm_image_hat_laufzeit() {
    local kanal="$1" laufzeiten
    [ -n "$kanal" ] || return 0
    laufzeiten=$(docker compose run --rm --no-deps --entrypoint dotnet solarmanager --list-runtimes 2>/dev/null || true)
    echo "$laufzeiten" | grep -q "^Microsoft\.AspNetCore\.App ${kanal//./\\.}\."
}

# Image bauen. Die .NET-Laufzeit des Backends geht als DOTNET_ZUSATZ mit: Das Dockerfile legt sie
# zusaetzlich ins Image, wenn das Basis-Image sie nicht hat (.NET 10 vorerst nur Beta, #403).
# Scheitert der Bau, bleiben altes Dockerfile und Image.
sm_image_bauen() {
    local kanal="$1"
    if [ -f "$INSTALL_DIR/Dockerfile.neu" ]; then
        [ -f "$INSTALL_DIR/Dockerfile" ] && cp -f "$INSTALL_DIR/Dockerfile" "$INSTALL_DIR/Dockerfile.alt"
        mv -f "$INSTALL_DIR/Dockerfile.neu" "$INSTALL_DIR/Dockerfile"
    fi
    echo "[INFO] Baue das Image neu (dauert einige Minuten)..."
    if docker compose build --build-arg DOTNET_ZUSATZ="$kanal" solarmanager; then
        rm -f "$INSTALL_DIR/Dockerfile.alt"
        echo "[OK] Image neu gebaut."
        return 0
    fi
    echo "[WARNUNG] Image-Bau fehlgeschlagen - altes Image bleibt in Betrieb."
    if [ -f "$INSTALL_DIR/Dockerfile.alt" ]; then mv -f "$INSTALL_DIR/Dockerfile.alt" "$INSTALL_DIR/Dockerfile"; fi
    return 1
}

# Welche .NET-Laufzeit braucht das installierte Backend (runtimeconfig in ./app)?
DOTNET_INSTALLIERT=""
if type sm_dotnet_kanal_aus_verzeichnis > /dev/null 2>&1; then
    DOTNET_INSTALLIERT=$(sm_dotnet_kanal_aus_verzeichnis "$INSTALL_DIR/app")
fi

IMAGE_VERALTET=false
if sm_dockerfile_geaendert; then
    IMAGE_VERALTET=true
fi
# Laufzeit nur im Container nachinstalliert (Update ueber die Oberflaeche)? Dann fehlt sie im
# Image, und ein neu erzeugter Container startete das Backend nicht mehr.
if [ -n "$DOTNET_INSTALLIERT" ] && ! sm_image_hat_laufzeit "$DOTNET_INSTALLIERT"; then
    echo "[INFO] Dem Image fehlt die ASP.NET Core Runtime $DOTNET_INSTALLIERT des installierten Backends."
    IMAGE_VERALTET=true
fi

if [ "$BACKEND_CHANGED" = false ] && [ "$FRONTEND_CHANGED" = false ]; then
    if [ "$IMAGE_VERALTET" = true ]; then
        echo "[INFO] Backend und Frontend sind aktuell, das Docker-Image nicht - es wird erneuert."
    else
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
    fi
else
    if [ "$AUTO_MODE" = false ]; then
        read -p "Update jetzt durchfuehren? (j/n) [j]: " CONFIRM
        CONFIRM="${CONFIRM:-j}"
        if [[ ! "$CONFIRM" =~ ^[Jj]$ ]]; then
            rm -f "$INSTALL_DIR/Dockerfile.neu"
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

# Benoetigte .NET-Laufzeit: die des neuen Backends (aus dem Archiv), sonst die des installierten.
DOTNET_BENOETIGT="$DOTNET_INSTALLIERT"
BACKEND_ARCHIV=""
if [ "$BACKEND_CHANGED" = true ] && [ -n "$LATEST_BACKEND_TAG" ]; then
    BACKEND_ARCHIV="/tmp/sm-backend-$$.tar.gz"
    trap 'rm -f "$BACKEND_ARCHIV"' EXIT
    echo "[INFO] Lade Backend $LATEST_BACKEND_TAG herunter..."
    sm_download "$LATEST_BACKEND_URL" "$BACKEND_ARCHIV" || exit 1
    DOTNET_BENOETIGT=$(sm_dotnet_kanal_aus_archiv "$BACKEND_ARCHIV")
    echo "[INFO] Das Backend braucht ASP.NET Core ${DOTNET_BENOETIGT:-(unbekannt)}."
    if [ -n "$DOTNET_BENOETIGT" ] && ! sm_image_hat_laufzeit "$DOTNET_BENOETIGT"; then
        IMAGE_VERALTET=true
    fi
fi

# Image erneuern - VOR dem Backend-Tausch (Backend-Issue #403): Die .NET-Laufzeit kommt aus dem
# Image. Frueher wurde erst getauscht und dann gebaut; scheiterte der Bau, stand ein .NET-10-Backend
# in einem .NET-9-Image und startete nicht.
if [ "$IMAGE_VERALTET" = true ]; then
    sm_image_bauen "$DOTNET_BENOETIGT" || true
fi

# Backend aktualisieren (nur wenn geaendert). Vorher pruefen, ob das Image die .NET-Laufzeit
# des neuen Backends hat - sonst nicht tauschen, das alte Backend laeuft weiter.
if [ "$BACKEND_CHANGED" = true ] && [ -n "$LATEST_BACKEND_TAG" ]; then
    if ! sm_image_hat_laufzeit "$DOTNET_BENOETIGT"; then
        echo "[FEHLER] Im Docker-Image fehlt die ASP.NET Core Runtime $DOTNET_BENOETIGT."
        echo "[FEHLER] Backend nicht getauscht - das bisherige laeuft weiter. Image-Bau pruefen:"
        echo "         cd $INSTALL_DIR && docker compose build --build-arg DOTNET_ZUSATZ=$DOTNET_BENOETIGT solarmanager"
        docker compose up -d || true
        exit 1
    fi

    # Container vorher stoppen: wird ueber die Dateien des laufenden Prozesses entpackt,
    # stirbt er mitten drin.
    echo "[INFO] Stoppe Container fuer den Backend-Tausch..."
    docker compose stop solarmanager || true

    echo "[INFO] Backend aktualisieren: $LATEST_BACKEND_TAG..."
    if ! sm_extract "$BACKEND_ARCHIV" "$INSTALL_DIR/app"; then
        echo "[FEHLER] Backend-Update fehlgeschlagen - starte Container wieder..."
        docker compose up -d || true
        exit 1
    fi
    rm -f "$BACKEND_ARCHIV"
    echo "[OK] Backend aktualisiert."
fi

# Container neu starten (ein neu gebautes Image ersetzt dabei den Container)
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
