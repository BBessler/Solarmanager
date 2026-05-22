# Solarmanager

Energiemanagementsystem zur intelligenten Steuerung von PV-Anlagen, Wallboxen, Batteriespeichern und Fahrzeugladung.

![Dashboard](images/Dashboard.jpg)

### Features

| | |
|---|---|
| ![Dashboard](images/Dashboard_einfach.jpg) | **Dashboard** — Live-Ansicht mit PV-Produktion, Verbrauch, Akku-Status, Wallbox und Wettervorhersage |
| ![Energieverteilung](images/Energieverteilung.jpg) | **Energieverteilung** — Animierte Darstellung des Energieflusses zwischen Solar, Speicher, Netz, E-Fahrzeug und Hausverbrauch mit Einzelverbrauchern |
| ![Auswertungen](images/Auswertungen.jpg) | **Auswertungen** — Monats- und Jahresvergleiche von PV-Leistung, Bezug, Einspeisung und Verbrauch |
| ![Simulation](images/Simulation.jpg) | **Simulation** — Ladesimulation mit Prognose: Wie lange dauert die Ladung bei aktuellem Wetter? |
| ![Einstellungen](images/Einstellungen.jpg) | **Einstellungen** — Konfiguration von PV-Anlagen, Akkus, Wallboxen, Autos, Verbrauchern und Prognosen |

---

## Was ist neu?

### § 51 EEG — Solarspitzengesetz (Nullvergütung)
Anlagen ab 25.02.2025 bekommen in Stunden mit negativem Spotpreis **keine Einspeisevergütung**. Der Solarmanager erkennt diese Stunden automatisch und lenkt PV-Überschuss aktiv in Akku, Heizung oder Wallbox um — statt unvergütet einzuspeisen. Aktivierung pro Vertragsperiode am Strompreis-Tarif (Vertrauensschutz für Bestandsanlagen). Wallbox schaltet bei negativem Endpreis automatisch auf Verbrauchsmodus (Vollast inkl. Netzbezug). Statistik weist `Einspeisung_Unverguetet_kWh` und `Ertrag_Verloren` separat aus.

### Netzdienliches Laden mit Backward-Planning
Klassifiziert die Stunden des Tages in **günstig** (Top-N niedrigste Spotpreise) und **teuer** (Top-N höchste). Die Wallbox lädt konzentriert in günstigen PV-Peak-Stunden statt verteilt über den Tag, der Akku entlädt in teuren Stunden aggressiver. Plan-Vorschau-API liefert eine 7-Tage-Stundenprognose mit erwarteten Lade-Leistungen pro Stunde. Konfigurierbar über den Basiswert `NetzdienlichesLadenAktiv` (benötigt dynamischen Tarif wie Tibber/aWATTar).

### Preissteuerung-Modul
Neues Backend-Modul mit eigenem Service/Business/DbAccess-Pattern. Liefert über `GET /Preissteuerung/Plan` einen stündlichen Plan mit Klassifikation, erwarteter PV, Wallbox-Aktion (Lädt mit PV / Verschoben / Sperre teuer) sowie Auto-SoC-Trajektorie bis zum Ladeziel. Plan-Cache mit LRU-Eviction (max 256 Einträge) für Sim-Performance.

### Heizungs-Steuerung (neue Wärmepumpen-Integration)
- **Buderus KM200** — Modus Auto/Manuell, WW-Boost mit Temperatur + Dauer
- **LG ThinQ Connect** — Therma V (SystemBoiler) über LG-Cloud
- **Vaillant** — Quick Veto für Raum-Soll (3 Stunden)
- Heizstab-Logik: Warmwasser vor Sonntag/Feiertag automatisch auf Max-Temperatur (Komfort)
- Splitklima-Kategorie (ohne Warmwasser) wird sauber getrennt behandelt
- PV-Boost: WW-Solltemperatur bei PV-Überschuss anheben (Basiswert `WPBoostSollDelta`)

### Akku-Steuerung erweitert
- **LG ESS Home** — als eigener PV-Typ über lokale HTTPS-API
- **SMA / SunSpec** — Hold/Sperren-Steuerung mit Watchdog-Renewal (Modell 124)
- Notladungs-Schwelle als Basiswert konfigurierbar (Default 20%)
- Akku-Spätladen-Uhr (Default 12 Uhr) — vor dieser Stunde kein Akku-Laden außer bei knapper Prognose oder § 51 EEG
- Akku-Entladen für Wallbox optional erlaubbar (Basiswert)

### Strompreis-Erweiterungen
- **aWATTar-Fallback** — Börsenpreise ohne Stromanbieter-Login nutzbar
- **Tibber-Konvention** — Arbeitspreis netto, MwSt komplett in Netzentgelten
- **Stromanbieter-Bündel** — Netzentgelte, MwSt, Brutto-Mapping als Basiswerte
- Worker lädt Strompreise sofort beim Start (kein Startup-Block)

### Lade-Prioritäten (PVVerteilung)
Konfigurierbare Reihenfolge wer PV-Überschuss bekommt: z.B. Auto → Akku → Heizung. Haus-Reserve über Prioliste einstellbar. WB-Sperre bei aktivem Großverbraucher (Wasserkocher etc.) verhindert Phasenwechsel-Oszillation.

### Verbraucherprognose
- Mehrtages-Fenster mit realistischer PV-Reserve
- Teildeckungs-Fallback + Nutzbarkeits-Präferenz im Zeitfenster
- OriginalStartZeit-Tracking für bereits begonnene Fenster

### Wetter & PV-Prognose
- **Open-Meteo** als Wetter-Provider (Multi-Modell, 15-Minuten-Granularität)
- Sonnenauf-/untergang aus Koordinaten direkt in Wettervorhersage-Response
- PV-Prognose-Mischmodus (Auto / Manuell / Solarmanager-Fallback)
- Slot-basiertes Merging mit korrekter Slot-Dauer pro Quelle

### Auto-Integration
- **OptionAutoPortal** — Portal-Zugangsdaten von Auto-Konfiguration getrennt (mehrere Autos pro Portal-Login)
- VIN-Feld zur expliziten Fahrzeug-Auswahl
- Tesla mit eigener Client-ID (developer.tesla.com)
- Auto-Kalender mit `LadeLimit %`-Override pro Termin

### Bundesland-Konfiguration
Bundesland gehört jetzt zur HomeBase (Standort-Eigenschaft) statt zu den Basiswerten. Wird für Feiertagsberechnung (Brückentag-Erkennung im Backward-Planning, Wochenende/Feiertag-Heuristik) verwendet. 16 Bundesländer im Setup-Wizard und in den Homebase-Einstellungen wählbar.

### Statistik-Erweiterungen
- Pro Tag/Stunde: Akku-Laden/Entladen-kWh + monetärer Wert
- Heizung-kWh / Heizung-Wärme-kWh (für Wärmepumpen-Auswertung)
- StatistikSumHeizung — eigene Tabelle für DurchschnittsCOP
- StatistikSumAuto — pre-aggregierte Verbrauchskennzahlen (km, kWh, CO2)
- Einspeisung_Unverguetet_kWh und Ertrag_Verloren (§ 51 EEG-Transparenz)

### Simulation (Ladetag)
- Tick-Intervall von 30s auf 5min reduziert (Faktor 10 schneller)
- SimPreissteuerungService delegiert an Live-Service mit Sim-HausData-Override
- § 51 EEG in der Simulation sichtbar + Log-Transparenz
- Plan-Cache mit SoC-Quantisierung (5%-Blöcke) gegen Cache-Miss-Storm

### Push-Benachrichtigungen
Web Push (VAPID) für: PV-Anlage nicht erreichbar, Wallbox-Ausfall, Auto fertig geladen, Speicher voll. Cooldown-Steuerung gegen Spam.

### Setup-Wizard
Geführte Ersteinrichtung: PV → Wallbox → Auto → Haus → Akku → Heizung → Stromanbieter → Strompreis → Zusammenfassung. Übernimmt bestehende Konfigurationen aus dem Import (Migration von älteren Installationen).

### Historischer Datenimport
PV- und Wallbox-Daten rückwirkend aus externen Quellen importieren (PV: SunSpec, Modbus / WB: OCPP-Sessions). Statusfeld pro Anlage mit letztem importiertem Datum.

---

## Unterstützte Geräte

| Kategorie | Geräte |
|-----------|--------|
| **PV-Wechselrichter** | Huawei (Modbus / FusionSolar), SMA, SunSpec, Fronius, Kostal Plenticore, GoodWe, SolarEdge, Growatt, LG ESS Home, Shelly (BKW), Solaranzeige |
| **Wallboxen** | go-eCharger, Easee, OCPP 1.6/2.0, SunSpec (Modbus), Keba, Fronius Wattpilot, Mennekes, Webasto, Hardy Barth, Heidelberg |
| **Batteriespeicher** | Marstek, Huawei, SMA, SunSpec (Modell 124), LG ESS, Ecoflow |
| **Elektrofahrzeuge** | Tesla, BMW, Hyundai, Kia, VW, Audi, Skoda, Seat/Cupra, Mercedes, Opel, Peugeot, Citroën, DS, Renault, Manuell |
| **Smart Home** | Shelly (Schalter, Dimmer, Energiezähler, Thermostat), MQTT |
| **Heizung / Wärmepumpe** | Heizstab (via Shelly), Buderus KM200, LG ThinQ Connect (Therma V), Vaillant, Splitklima, Gas-Heizung |
| **PV-Prognose** | Solcast, Solarmanager (ML.NET intern, Auto/Mischmodus) |
| **Stromanbieter** | Tibber, aWATTar (Spotpreis-Fallback ohne Login) |
| **Wetter** | Open-Meteo (Multi-Modell, 15-Min) |

---

## API-Endpoints (Auszug)

| Endpoint | Beschreibung |
|----------|-------------|
| `GET /Preissteuerung/Plan` | 7-Tage-Plan mit Klassifikation + erwarteter Wallbox/Akku/Heizungs-Leistung pro Stunde |
| `GET /AutoKalender` | Termine mit Abfahrt + Ladelimit |
| `GET /HomeBaseOptionHomebase` | HomeBase-Stammdaten inkl. Bundesland + Counts pro Kategorie |
| `PUT /Basiswert` | Schwellenwerte & Feintuning ändern (Cache-Invalidierung automatisch) |
| `GET /Simulation/Ladetag` | Sim-Lauf für einen kompletten Tag mit Modus/PV-Quelle |
| `POST /PushSubscription` | Web Push-Subscription registrieren |

Vollständige API-Dokumentation: Swagger UI unter `/swagger` im Development-Modus.

---

## Installation & Dokumentation

Die vollständige Installationsanleitung findest du im **[Wiki](https://github.com/BBessler/Solarmanager/wiki)**:

- **[Installation mit Docker (empfohlen)](https://github.com/BBessler/Solarmanager/wiki/Installation-Docker)**
- **[Native Installation (ohne Docker)](https://github.com/BBessler/Solarmanager/wiki/Installation-Nativ)**

### Schnellstart (Docker)

```bash
wget https://raw.githubusercontent.com/BBessler/Solarmanager/main/install/setup_docker.sh
chmod +x setup_docker.sh
./setup_docker.sh
```
