FROM mcr.microsoft.com/dotnet/aspnet:9.0

# Python fuer BMW/Hyundai-Scripts, tzdata fuer Zeitzonen-Unterstuetzung,
# mariadb-client fuer die Datensicherung (MariaDB selbst laeuft auf dem Host),
# iproute2 fuer die ARP-Pruefung der Netzwerkgeraete ("ip neigh": PCs, deren Firewall den Ping verwirft)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv python3-dev \
        curl jq tzdata \
        mariadb-client \
        iproute2 \
        gcc g++ make \
        libjpeg62-turbo-dev zlib1g-dev libffi-dev \
    && ln -sf /usr/bin/python3 /usr/bin/python \
    && python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir hyundai-kia-connect-api bimmer_connected \
    && apt-get purge -y --auto-remove gcc g++ make python3-dev \
    && rm -rf /var/lib/apt/lists/*

# Zusaetzliche ASP.NET Core Runtime, wenn das Backend eine andere Hauptversion braucht als das
# Basis-Image (Backend-Issue #403: .NET 10 vorerst nur fuer Beta). update_docker.sh setzt
# DOTNET_ZUSATZ aus der runtimeconfig des Backends; ohne Angabe bleibt das Image wie bisher.
# Architektur aus dpkg: Ein arm32-Container auf einem arm64-Host meldet in "uname -m" aarch64.
# Wechselt das stabile Release auf .NET 10: Basis auf aspnet:10.0-noble (Ubuntu 24.04, fuer .NET 10
# gibt es keine Debian-Images; dort libjpeg-dev statt libjpeg62-turbo-dev).
ARG DOTNET_ZUSATZ=""
RUN if [ -n "$DOTNET_ZUSATZ" ] && ! dotnet --list-runtimes | grep -q "^Microsoft.AspNetCore.App $DOTNET_ZUSATZ\."; then \
        case "$(dpkg --print-architecture)" in \
            arm64) arch=arm64 ;; armhf) arch=arm ;; *) arch=x64 ;; \
        esac \
        && curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
        && bash /tmp/dotnet-install.sh --runtime aspnetcore --channel "$DOTNET_ZUSATZ" --architecture "$arch" \
            --install-dir /usr/share/dotnet --skip-non-versioned-files --no-path \
        && rm -f /tmp/dotnet-install.sh \
        && dotnet --list-runtimes | grep -q "^Microsoft.AspNetCore.App $DOTNET_ZUSATZ\."; \
    fi

ENV PATH="/opt/venv/bin:$PATH"

# Default-Zeitzone (wird von docker-compose via TZ env var ueberschrieben)
ENV TZ=Europe/Berlin

WORKDIR /app
EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080

ENTRYPOINT ["dotnet", "Solarmanager.dll"]
