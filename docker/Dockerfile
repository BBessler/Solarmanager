# .NET 10 (LTS). Fuer .NET 10 gibt es keine Debian-Images mehr, "noble" ist Ubuntu 24.04
# (fest angegeben, damit "10.0" nicht unbemerkt auf ein neueres Ubuntu wandert).
FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble

# Python fuer BMW/Hyundai-Scripts, tzdata fuer Zeitzonen-Unterstuetzung,
# mariadb-client fuer die Datensicherung (MariaDB selbst laeuft auf dem Host),
# iproute2 fuer die ARP-Pruefung der Netzwerkgeraete ("ip neigh": PCs, deren Firewall den Ping verwirft)
# libjpeg-dev statt libjpeg62-turbo-dev: den Namen gibt es nur unter Debian, libjpeg-dev ueberall.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv python3-dev \
        curl jq tzdata ca-certificates \
        mariadb-client \
        iproute2 \
        gcc g++ make \
        libjpeg-dev zlib1g-dev libffi-dev \
    && ln -sf /usr/bin/python3 /usr/bin/python \
    && python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir hyundai-kia-connect-api bimmer_connected \
    && apt-get purge -y --auto-remove gcc g++ make python3-dev \
    && rm -rf /var/lib/apt/lists/*

# Uebergang .NET 9 -> 10: Die Anwendung liegt in ./app, nicht im Image. Beim Neubau des Images
# kann dort noch ein .NET-9-Backend stehen (update_docker.sh baut das Image vor dem Tausch des
# Backends, ein gepinntes altes Release), das ohne diese Laufzeit nicht startet. Entfernen, sobald
# kein .NET-9-Release mehr installiert werden soll.
# Architektur aus dpkg: Ein arm32-Container auf einem arm64-Host meldet in "uname -m" aarch64.
RUN case "$(dpkg --print-architecture)" in \
        arm64) arch=arm64 ;; armhf) arch=arm ;; *) arch=x64 ;; \
    esac \
    && curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && bash /tmp/dotnet-install.sh --runtime aspnetcore --channel 9.0 --architecture "$arch" \
        --install-dir /usr/share/dotnet --skip-non-versioned-files --no-path \
    && rm -f /tmp/dotnet-install.sh \
    && dotnet --list-runtimes

ENV PATH="/opt/venv/bin:$PATH"

# Default-Zeitzone (wird von docker-compose via TZ env var ueberschrieben)
ENV TZ=Europe/Berlin

WORKDIR /app
EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080

ENTRYPOINT ["dotnet", "Solarmanager.dll"]
