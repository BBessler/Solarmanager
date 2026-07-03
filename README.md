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

## Funktionen

- **PV-Steuerung & Eigenverbrauch** — automatische Verteilung des PV-Überschusses auf Akku, Wallbox, Heizung und Smart-Home-Verbraucher; konfigurierbare Lade-Prioritäten
- **Wallbox-Steuerung** — Lademodi Verbrauch / Sonne / Sonne (max) / Prognose, automatischer Phasenwechsel, Auto-Kalender mit Abfahrts- und Ankunftszeit (Anwesenheitsfenster) und Ladelimit
- **Akku-Steuerung** — Lade-/Entlade-Optimierung, Notladung, Hold/Sperren-Steuerung für gängige Hybrid-Modelle; optionale Akku-Entladung für Heizstab/Warmwasser und Wallbox mit automatischer, am Nachtverbrauch orientierter SoC-Untergrenze
- **Heizungs-Steuerung** — Wärmepumpen, Heizstäbe und Klimaanlagen über PV-Überschuss, mit Heizungsunterstützung und WW-Komfort-Logik
- **PV-Prognose & Wettervorhersage** — eigene ML-Prognose oder externer Anbieter (Mischmodus mit Fallback)
- **Verbraucherprognose** — Großverbraucher (Waschmaschine, Spülmaschine, …) in den passenden PV-Zeitraum legen
- **Preisbasierte Steuerung** — dynamische Tarife (Tibber, aWATTar), § 51 EEG-Nullvergütung, Netzdienliches Laden mit 7-Tage-Plan-Vorschau
- **Smart Home** — Shelly-Geräte, MQTT, Räume/Etagen mit Grundrissen, Szenen
- **Statistik & Auswertung** — Tages-/Monats-/Jahresvergleiche, kWh und Kosten pro Verbraucher, CO2-Bilanz, Auto-Reichweite & Kosten/100 km
- **Individuelle Dashboards (Boards)** — frei konfigurierbare Widget-Boards mit Drag & Drop, eigenem Stil-Editor und geräteübergreifender Synchronisation
- **Simulation (Ladetag)** — interaktive Simulation eines kompletten Ladetags
- **Push-Benachrichtigungen** — Web Push bei PV-Ausfall, Wallbox-Fehler, Auto fertig, Speicher voll
- **Setup-Wizard** — geführte Ersteinrichtung

---

## Unterstützte Geräte & Schnittstellen

| Kategorie | Hersteller / Protokoll |
|-----------|------------------------|
| **PV-Wechselrichter** | Huawei (Modbus / FusionSolar), SMA, SunSpec, Fronius, Kostal Plenticore, GoodWe, SolarEdge, Growatt, LG ESS Home, Shelly (BKW), Solaranzeige |
| **Wallboxen** | go-eCharger, Easee, OCPP 1.6/2.0, SunSpec (Modbus), Keba, Fronius Wattpilot, Mennekes, Webasto, Hardy Barth, Heidelberg |
| **Batteriespeicher** | Marstek, Huawei, SMA, SunSpec (Modell 124), LG ESS, Ecoflow |
| **Elektrofahrzeuge** | Tesla, BMW, Hyundai, Kia, Mercedes, Opel, Peugeot, Citroën, DS, Renault, Manuell |
| **Smart Home** | Shelly (Schalter, Dimmer, Energiezähler, Thermostat), MQTT |
| **Heizung / Wärmepumpe** | Heizstab (via Shelly), Buderus KM200, LG ThinQ Connect (Therma V), Vaillant, Splitklima, Gas-Heizung |
| **PV-Prognose** | Solcast, Solarmanager-intern (ML.NET) |
| **Stromanbieter** | Tibber, aWATTar (Spotpreis-Fallback ohne Login) |
| **Wetter** | Open-Meteo |

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
