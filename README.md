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

- **PV-Steuerung & Eigenverbrauch** — automatische Verteilung des PV-Überschusses auf Akku, Wallbox, Heizung und Smart-Home-Verbraucher
- **Lade-Prioritäten** — konfigurierbare Reihenfolge wer zuerst PV bekommt (z.B. Auto → Akku → Heizung)
- **PV-Prognose** — eigene ML-basierte Prognose (intern) oder externe Anbieter, Mischmodus mit Fallback
- **Wettervorhersage** — Sonnenauf-/untergang, Bewölkungsgrad, Temperatur (Multi-Modell)
- **§ 51 EEG / Solarspitzengesetz** — automatisches Umlenken des PV-Überschusses in Akku/Heizung/Wallbox bei negativem Spotpreis, separate Statistik-Ausweisung der unvergüteten Einspeisung
- **Netzdienliches Laden** — Klassifikation der Tagesstunden in günstig/teuer, konzentriertes Laden in günstigen PV-Peak-Stunden, aggressiveres Akku-Entladen in teuren Stunden
- **Preissteuerungs-Plan** — 7-Tage-Vorschau pro Stunde mit Wallbox-, Akku- und Heizungs-Aktionen
- **Wallbox-Ladealgorithmen** — Verbrauch / Sonne / Sonne (max) / Prognose – mit Phasenwechsel-Logik und Backward-Planning bis zum Ladeziel
- **Auto-Kalender** — Termine mit Abfahrt + Ladelimit, der Solarmanager lädt rechtzeitig voll (auch mit Netzbezug bei variablem Tarif)
- **Akku-Steuerung** — Lade-/Entlade-Optimierung, Notladung, Spätlade-Uhr, Hold/Sperren-Steuerung für viele Modelle
- **Heizungs-Steuerung** — Wärmepumpen, Heizstäbe, Klimaanlagen über PV-Überschuss, mit Heizungsunterstützung und WW-Komfort-Logik (Sonntag/Feiertag)
- **Verbraucherprognose** — Mehrtages-Fenster für Großverbraucher (Waschmaschine, Spülmaschine, …) mit realistischer PV-Reserve
- **Smart Home** — Schalter, Dimmer, Energiezähler, Räume/Etagen mit Grundrissen, Szenen
- **Statistik & Auswertung** — Tagesvergleiche, Monatsverläufe, kWh und Kosten pro Verbraucher/Heizung, vermiedenes CO2, Auto-Reichweite, Kosten/100 km
- **Simulation (Ladetag)** — interaktive Simulation kompletter Ladetage mit verschiedenen PV-Quellen und Modi
- **Push-Benachrichtigungen** — Web Push für PV-Ausfall, Wallbox-Fehler, Auto fertig, Speicher voll
- **Setup-Wizard** — geführte Ersteinrichtung aller Bereiche
- **Historischer Datenimport** — PV- und Wallbox-Daten rückwirkend importieren
- **Bundesland-spezifische Feiertage** — für regionale Brückentag-Erkennung im Backward-Planning

---

## Unterstützte Geräte & Schnittstellen

| Kategorie | Hersteller / Protokoll |
|-----------|------------------------|
| **PV-Wechselrichter** | Huawei (Modbus / FusionSolar), SMA, SunSpec, Fronius, Kostal Plenticore, GoodWe, SolarEdge, Growatt, LG ESS Home, Shelly (BKW), Solaranzeige |
| **Wallboxen** | go-eCharger, Easee, OCPP 1.6/2.0, SunSpec (Modbus), Keba, Fronius Wattpilot, Mennekes, Webasto, Hardy Barth, Heidelberg |
| **Batteriespeicher** | Marstek, Huawei, SMA, SunSpec (Modell 124), LG ESS, Ecoflow |
| **Elektrofahrzeuge** | Tesla, BMW, Hyundai, Kia, VW, Audi, Skoda, Seat/Cupra, Mercedes, Opel, Peugeot, Citroën, DS, Renault, Manuell |
| **Smart Home** | Shelly (Schalter, Dimmer, Energiezähler, Thermostat), MQTT |
| **Heizung / Wärmepumpe** | Heizstab (via Shelly), Buderus KM200, LG ThinQ Connect (Therma V), Vaillant, Splitklima, Gas-Heizung |
| **PV-Prognose** | Solcast, Solarmanager-intern (ML.NET) |
| **Stromanbieter** | Tibber, aWATTar (Spotpreis-Fallback ohne Login) |
| **Wetter** | Open-Meteo |

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
