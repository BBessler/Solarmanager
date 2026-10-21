#!/usr/bin/env bash
# Erzeugt den Text eines Releases aus einer Commit-Liste ("- Titel" je Zeile, über stdin).
#
# Aufruf: release-notes.sh "<Überschrift>" <<< "$CHANGELOG"
#
# Mit MISTRAL_API_KEY: Kurzfassung für Anwender oben, vollständige Liste eingeklappt darunter.
# Ohne Key oder wenn Mistral nicht antwortet: nur die gruppierte Liste. Das Release bricht nie ab.

set -uo pipefail

TITEL="$1"
# Merge-Commits und Pflege der KI-Anleitung (CLAUDE.md, .claude/) gehören nicht in die Release-Notes
# Verweisnummern am Ende ("– #112", "(#123)") sind interne Bezüge, keine Information für Anwender
# Gefiltert wird VOR Mistral: Kurzfassung und Liste entstehen beide aus COMMITS.
# "–" ist mehrbytig — als Alternative statt in einer Zeichenklasse, sonst bleibt ein halbes Zeichen stehen.
COMMITS=$(sed -n 's/^- //p' | grep -v '^Merge ' | grep -vi 'claude'   | sed -E 's/[[:space:]]*(–|-)?[[:space:]]*[(]?#[0-9]+[)]?[[:space:]]*$//' || true)

if [ -z "$COMMITS" ] || [ "$COMMITS" = "Keine neuen Commits" ]; then
  printf '## %s\n- Keine Änderungen\n' "$TITEL"
  exit 0
fi

# Commits eines oder mehrerer Typen als "- **bereich:** Beschreibung"
gruppe() {
  echo "$COMMITS" | grep -E "^($1)(\([^)]*\))?!?: " \
    | sed -E 's/^[a-z]+\(([^)]*)\)!?: /- **\1:** /; s/^[a-z]+!?: /- /'
}

abschnitt() {
  local inhalt="$2"
  [ -n "$inhalt" ] && printf '### %s\n%s\n\n' "$1" "$inhalt"
}

LISTE=$(
  abschnitt "Neue Funktionen" "$(gruppe 'feat')"
  abschnitt "Verbesserungen" "$(gruppe 'perf')"
  abschnitt "Fehlerbehebungen" "$(gruppe 'fix')"
  abschnitt "Sonstiges" "$(echo "$COMMITS" | grep -vE '^[a-z]+(\([^)]*\))?!?: ' | sed 's/^/- /')"
  abschnitt "Technisches" "$(gruppe 'chore|docs|style|test|refactor|ci|build')"
)

SYSTEM='Du schreibst Release-Notes für die Anwender der Software Solarmanager (Energiemanagement mit PV-Anlage, Speicher, Wallbox, Autos und Smart Home).
Du bekommst Commit-Titel im Format "typ(bereich): Beschreibung".
Fasse sie in 3 bis 6 Stichpunkten zusammen, die ein Anwender ohne Programmierkenntnisse versteht.
Bündele zusammengehörige Änderungen zu einem Thema, z. B. "Schnittstellen für die Autos überarbeitet" oder "Neue 3D- und 2D-Ansichten".
Fasse Fehlerbehebungen in einem Stichpunkt zusammen, sofern es mehrere gibt.
Lass interne Änderungen (chore, docs, style, test, refactor, ci, build) weg, wenn sie für Anwender keine Wirkung haben.
Keine Commit-Typen, keine Bereichsnamen in Klammern, keine Personennamen, keine Verweisnummern wie #112, nichts erfinden.
Lass Änderungen an interner Dokumentation und Entwickler-Anleitungen weg.
Schreibe Deutsch mit korrekten Umlauten (ä, ö, ü, ß).
Antworte ausschließlich mit den Stichpunkten. Jede Zeile beginnt mit "- ".'

KURZ=""
if [ -n "${MISTRAL_API_KEY:-}" ]; then
  ANFRAGE=$(jq -n --arg system "$SYSTEM" --arg commits "$COMMITS" '{
    model: "mistral-small-latest",
    temperature: 0.2,
    messages: [{role: "system", content: $system}, {role: "user", content: $commits}]
  }')

  # Der kostenlose Tarif erlaubt nur wenige Anfragen pro Minute: bei 429 warten und erneut versuchen
  for VERSUCH in 1 2 3; do
    ANTWORT=$(curl -sS --max-time 60 -w '\n%{http_code}' https://api.mistral.ai/v1/chat/completions \
      -H "Authorization: Bearer $MISTRAL_API_KEY" \
      -H 'Content-Type: application/json' \
      -d "$ANFRAGE" 2>/dev/null)
    STATUS="${ANTWORT##*$'\n'}"

    if [ "$STATUS" = "200" ]; then
      KURZ=$(echo "${ANTWORT%$'\n'*}" | jq -r '.choices[0].message.content // empty' | grep '^- ' || true)
      break
    fi

    echo "::warning::Mistral antwortet mit HTTP ${STATUS:-keine Antwort} (Versuch $VERSUCH/3)" >&2
    [ "$STATUS" = "429" ] || break
    sleep 35
  done
fi

if [ -n "$KURZ" ]; then
  printf '## %s\n%s\n\n<details><summary>Alle Änderungen</summary>\n\n%s\n</details>\n' "$TITEL" "$KURZ" "$LISTE"
else
  printf '## %s\n\n%s\n' "$TITEL" "$LISTE"
fi
