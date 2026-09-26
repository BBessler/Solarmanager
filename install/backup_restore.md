# MariaDB Backup & Restore

## Über die Oberfläche (empfohlen)

Unter **Einstellungen → Datensicherung** lassen sich Sicherungen erstellen, herunterladen,
hochladen und wiederherstellen. Dort wird auch die automatische Sicherung eingestellt
(Uhrzeit, Wochentage, Anzahl, Kopie auf USB-Stick oder per SFTP/FTP/FTPS auf einen Server).

- Gesichert werden `solardb` und `ocpp`.
- Ablage: nativ `/var/backups/solarmanager`, Docker `~/solarmanager/app/backups`.
- Vor jeder Wiederherstellung wird der aktuelle Stand automatisch gesichert
  (Eintrag „Vor Wiederherstellung“). Damit lässt sie sich wieder rückgängig machen.
- Hochladen nimmt eigene Sicherungen (`.tar`) und einfache Dumps von `solardb`
  (`.sql`, `.sql.gz`) an, z. B. vom alten Cron-Backup.

### Docker: bestehende Installation nachrüsten

Neue Installationen bringen das mit. Bei bestehenden Docker-Installationen:

1. In `~/solarmanager/docker-compose.yml` beim Dienst `solarmanager` unter `volumes:` ergänzen
   (nur nötig für den USB-Stick):
   ```yaml
         - /media:/media:rslave
   ```
2. `Dockerfile` aktualisieren und neu bauen (bringt den MariaDB-Client mit):
   ```bash
   cd ~/solarmanager
   curl -fsSL https://raw.githubusercontent.com/BBessler/Solarmanager/main/docker/Dockerfile -o Dockerfile
   docker compose build solarmanager && docker compose up -d
   ```
   Ohne Neubau installiert die Datensicherung den Client beim ersten Lauf selbst nach
   (Internet nötig, hält bis zum nächsten Neuaufbau des Containers).

Der USB-Stick muss im Docker-Setup auf dem Host eingehängt sein, z. B. unter
`/media/solarmanager-usb`. Diesen Pfad dann in der Oberfläche eintragen.

### Altes Cron-Backup

`create_Solarmanager_Backup.sh` legt einen Cronjob an, der nach `/var/www/html/solardb.sql`
sichert. Wer auf die automatische Sicherung umsteigt und nicht doppelt sichern will, kann
ihn entfernen:

```bash
sudo crontab -l | grep -v backup_solardb.sh | sudo crontab -
sudo rm -f /var/www/html/solardb.sql /usr/local/bin/backup_solardb.sh
```

## Manuell auf der Kommandozeile

Backup von einem bestehenden (nativen) Solarmanager ziehen und auf einem neuen Solarmanager (Docker-Setup) einspielen.

Im Docker-Setup läuft MariaDB nativ auf dem Host — daher funktionieren alle Befehle direkt ohne Docker-Umwege.

## Zugangsdaten

- **DB-User:** `pi`
- **DB-Passwort:** `solarmanager` (Standard, falls bei der Installation nicht geändert)

Bei allen folgenden Befehlen mit `-p` wird das Passwort nach Ausführung abgefragt.

## 1. Backup erstellen (Quell-System)

Die Solarmanager-Datenbank `solardb` sichern (enthält alle Daten inkl. OCPP):

```bash
mysqldump -u pi -p solardb > solardb_backup.sql
```

Falls `pi` keinen Zugriff hat, mit root:

```bash
sudo mysqldump solardb > solardb_backup.sql
```

### Komprimiertes Backup (bei großen Datenbanken)

```bash
mysqldump -u pi -p solardb | gzip > solardb_backup.sql.gz
```

## 2. Backup auf das Ziel-System übertragen

In den folgenden Beispielen ist `192.168.178.10` die IP-Adresse des neuen Solarmanager-Systems und `pi` der Benutzername.

### Per SCP (SSH)

```bash
scp solardb_backup.sql pi@192.168.178.10:~/
```

### Direkt per Pipe (Backup + Restore in einem Schritt)

Ohne Zwischendatei — direkt vom Quell-System auf das Ziel-System:

```bash
mysqldump -u pi -p solardb | ssh pi@192.168.178.10 "mysql -u pi -p solardb"
```

### Per USB-Stick

1. Backup auf USB-Stick kopieren:
   ```bash
   cp solardb_backup.sql /media/usb/
   ```
2. USB-Stick am Ziel-System einstecken und Datei kopieren:
   ```bash
   cp /media/usb/solardb_backup.sql ~/
   ```

## 3. Backup einspielen (Ziel-System / Docker-Setup)

### Solarmanager stoppen

```bash
cd ~/solarmanager
docker compose down
```

### Datenbank einspielen

```bash
mysql -u pi -p solardb < solardb_backup.sql
```

Falls `pi` keinen Zugriff hat, mit root:

```bash
sudo mysql solardb < solardb_backup.sql
```

Bei komprimierten Backups:

```bash
gunzip -c solardb_backup.sql.gz | mysql -u pi -p solardb
```

### Solarmanager wieder starten

```bash
cd ~/solarmanager
docker compose up -d
```

## 4. Prüfen

```bash
# MariaDB-Verbindung testen
mysql -u pi -p -e "USE solardb; SHOW TABLES;"

# Solarmanager-Logs prüfen
cd ~/solarmanager
docker compose logs -f
```

## Passwörter

Die Datenbank enthält Passwörter für konfigurierte Geräte (Wallbox, PV-Anlage, Akku, Haus-Systeme etc.) in den Options-Tabellen. Diese werden beim Backup/Restore 1:1 übernommen.

Falls auf dem Ziel-System ein anderes **Datenbank-Passwort** (für den MariaDB-User `pi`) vergeben wurde als auf dem Quell-System:

1. Entweder das DB-Passwort auf dem Ziel-System anpassen:
   ```bash
   sudo mysql -e "ALTER USER 'pi'@'%' IDENTIFIED BY 'passwort-vom-quellsystem'; FLUSH PRIVILEGES;"
   ```

2. Oder die `.env`-Datei auf dem Ziel-System anpassen:
   ```bash
   nano ~/solarmanager/.env
   # MYSQL_PASSWORD= auf das Passwort vom Quell-System ändern
   ```

Danach den Solarmanager neu starten:
```bash
cd ~/solarmanager
docker compose restart
```

## Hinweise

- InfluxDB-Daten (Zeitreihen/Statistiken) sind in MariaDB nicht enthalten und müssen separat migriert werden, falls vorhanden.
