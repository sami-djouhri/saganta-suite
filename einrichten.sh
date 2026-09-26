#!/usr/bin/env bash
# einrichten.sh richtet eine frisch geklonte Suite ein.
#
# WOZU: Die Teile brauchen zusammen ein gutes Dutzend Geheimnisse, und mehrere
# davon muessen an mehreren Stellen IDENTISCH sein. Wer sie von Hand verteilt,
# macht genau einen Tippfehler, und der faellt nicht auf: der Dienst laeuft, er
# antwortet nur mit 401, und zwar erst dann, wenn spaeter jemand
# TENANT_HEADER_ENFORCE auf 1 stellt. Dieses Skript ist die eine Stelle, die
# Gleichheit dort herstellt, wo sie noetig ist, und Verschiedenheit dort, wo sie
# der Zweck ist.
#
# ★ Es ueberschreibt nichts. Eine bestehende .env ist der Live-Zustand einer
# laufenden Suite; sie stillschweigend zu ersetzen waere der Vorfall, den ein
# Einrichtungsskript verhindern soll. Was fehlt, wird ergaenzt; was da ist,
# bleibt.
#
# Aufrufe:
#   ./einrichten.sh            einrichten (idempotent, ergaenzt nur Fehlendes)
#   ./einrichten.sh --pruefen  nur zeigen, was fehlt, nichts schreiben
#   ./einrichten.sh --kennung  die Kennung des Kontos nachtragen. Ohne Angabe
#                              liest das Skript sie aus der Anmelde-Datenbank;
#                              gibt es mehrere Konten, nennt es sie zur Auswahl.
#   ./einrichten.sh --kennung <sub>      ein bestimmtes Konto
set -euo pipefail
cd "$(dirname "$0")"

TEILE=teile
NUR_PRUEFEN=0
KENNUNG=""

WILL_KENNUNG=0

case "${1:-}" in
  --pruefen) NUR_PRUEFEN=1 ;;
  --kennung) WILL_KENNUNG=1; KENNUNG="${2:-}" ;;
  "") ;;
  *) sed -n '2,24p' "$0"; exit 1 ;;
esac

fehler() { echo "FEHLER: $*" >&2; exit 1; }
hinweis() { echo "  $*"; }

# Ein Geheimnis. 32 Byte aus /dev/urandom, hex. Bewusst nicht `openssl rand`:
# openssl ist nicht ueberall da, /dev/urandom schon.
geheimnis() { head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# Schreibt SCHLUESSEL=WERT in eine Datei, aber nur wenn dort noch kein echter
# Wert steht. Gibt 0 zurueck, wenn geschrieben wurde, 1 wenn schon einer da war.
#
# ★★ Ein Platzhalter zaehlt als „noch nicht gesetzt". Ohne diese Unterscheidung
# waere `--kennung` wirkungslos gewesen: die Vorlagen tragen
# `ALLOWED_SUBS=change-me-owner-sub` bereits ein, ein reines „steht schon da"
# haette den Platzhalter stehen lassen und gemeldet, alles sei gesetzt. Das
# Ergebnis waere ein Dienst, der laeuft und niemanden hereinlaesst.
setze() {
  local datei=$1 schluessel=$2 wert=$3
  mkdir -p "$(dirname "$datei")"
  touch "$datei"
  local vorhanden
  vorhanden=$(sed -n "s/^${schluessel}=//p" "$datei" | head -1)
  if [ -n "$vorhanden" ] && ! printf '%s' "$vorhanden" | grep -qiE '^(change-me|set-from|CHANGEME)'; then
    return 1
  fi
  # Ein Platzhalter wird ersetzt, nicht ergaenzt: zwei Zeilen mit demselben
  # Schluessel sind je nach Leser die erste oder die letzte.
  if [ -n "$vorhanden" ]; then
    [ "$NUR_PRUEFEN" = 1 ] && { hinweis "Platzhalter: ${datei#./} -> $schluessel"; return 0; }
    sed -i "s|^${schluessel}=.*|${schluessel}=${wert}|" "$datei"
    hinweis "ersetzt: ${datei#./} -> $schluessel (war Platzhalter)"
    return 0
  fi
  if [ "$NUR_PRUEFEN" = 1 ]; then
    hinweis "fehlt: ${datei#./} -> $schluessel"
    return 0
  fi
  # Fehlender Zeilenumbruch am Ende wuerde den neuen Eintrag an die letzte
  # Zeile kleben und beide unbrauchbar machen.
  [ -s "$datei" ] && [ "$(tail -c1 "$datei" | wc -l)" -eq 0 ] && printf '\n' >> "$datei"
  printf '%s=%s\n' "$schluessel" "$wert" >> "$datei"
  hinweis "gesetzt: ${datei#./} -> $schluessel"
  return 0
}

# Traegt die eigene Domaene dort ein, wo in den Vorlagen Beispiel-Namen stehen.
#
# ★★ Ueber die EIGENSCHAFT „ist eine Platzhalter-Domaene", nicht ueber eine
# aufgezaehlte Liste, und unter Erhalt der Unterdomaene. Der erste Entwurf
# kannte genau zwei Muster (`<x>.home` und `saganta.de`) und hat damit zwei
# Klassen uebersehen, beide beim Anmelde-Durchgang am 2026-09-12 gemessen:
#
#   1. `example.com` blieb unangetastet. In `apps/shell/.env` steht darueber
#      `ORIGIN`, und SvelteKit vergleicht ihn bei jedem Formular-POST mit dem
#      Origin des Browsers. Ergebnis war „Cross-site POST form submissions are
#      forbidden" auf Anmeldung UND Registrierung: aus einem frischen Klon kam
#      niemand herein. Unangemeldet sah alles gruen aus, weil GET davon nicht
#      betroffen ist.
#   2. `shell.home.arpa` wurde zu `<domaene>.arpa`. Das Muster `[a-z0-9-]+\.home`
#      traf in `shell.home.arpa` das Stueck `shell.home` und liess `.arpa`
#      stehen. `home.arpa` steht dort, weil der Scrub der Veroeffentlichung die
#      Namen dieses Hauses dorthin umschreibt. Das ist dieselbe Falle, vor der
#      der Kommentar in `platzhalter_ersetzen` schon warnt, nur eine Zeile
#      weiter. Betroffen waren die CORS-Listen von sechs Backends und der
#      ORIGIN von news und projectdeck.
domaene_eintragen() {
  local datei=$1
  [ -f "$datei" ] || return 0
  [ "$NUR_PRUEFEN" = 1 ] && return 0
  DOM="$DOMAENE" python3 - "$datei" <<'DOMAENE_EINTRAGEN'
import os, re, sys

# Woher die Beispiel-Namen kommen:
#   example.com/org/net/test   die Platzhalter der .env.example
#   <irgendwas>.home           Namen, die nur im Netz ihres Erzeugers gelten
#   home.arpa                  was der Scrub der Veroeffentlichung daraus macht
#   saganta.de                 die oeffentliche Adresse des Projekts
#
# ★ Die zweite Zeile nennt bewusst keinen konkreten Namen, sondern die Endung.
# Ein eingetragener Name waere ein instanz-spezifischer Wert im Quelltext, und
# das Veroeffentlichungs-Gate schreibt ihn beim Scrub um: das Muster traefe in
# der veroeffentlichten Fassung genau das nicht mehr, was es treffen soll.
BASIS = r"(?:[a-z0-9-]+\.home|home\.arpa|example\.(?:com|org|net|test)|saganta\.de)"
MUSTER = re.compile(r"\b(?:(?P<vor>[a-z0-9-]+)\.)?" + BASIS + r"\b")
dom = os.environ["DOM"]


def ersetzen(m):
    ganz = m.group(0)
    # ★ Die eigene Domaene darf selbst wie ein Platzhalter aussehen
    # (`beispiel.test`, `probe.example.org`). Ohne diese Ausnahme wuerde jeder
    # weitere Lauf eine Schicht davorsetzen: probe.probe.example.org.
    if ganz == dom or ganz.endswith("." + dom):
        return ganz
    vor = m.group("vor")
    return f"{vor}.{dom}" if vor else dom


pfad = sys.argv[1]
# ★ Erst lesen, dann oeffnen. `open(pfad, "w")` kuerzt die Datei sofort, und
# zwar bevor das Argument ausgewertet wird: eine Einzeiler-Fassung
# (`open(p,"w").write(sub(open(p).read()))`) schreibt garantiert eine leere
# Datei. Gemessen am 2026-09-12, es traf 13 der 17 Konfigurationsdateien.
alt = open(pfad).read()
open(pfad, "w").write(MUSTER.sub(ersetzen, alt))
DOMAENE_EINTRAGEN
}

# Liest einen Wert aus einer Datei, leer wenn nicht da. So bekommen spaetere
# Teile denselben Wert wie der erste, auch bei einem zweiten Lauf.
lies() {
  local datei=$1 schluessel=$2
  [ -f "$datei" ] || return 0
  sed -n "s/^${schluessel}=//p" "$datei" | head -1
}

# Ein Geheimnis, das an mehreren Stellen gleich sein muss: einmal erzeugen,
# ueberall dasselbe eintragen. Steht es irgendwo schon, gilt dieser Wert.
gemeinsam() {
  local schluessel=$1; shift
  local wert=""
  for d in "$@"; do
    wert=$(lies "$d" "$schluessel")
    [ -n "$wert" ] && break
  done
  [ -n "$wert" ] || wert=$(geheimnis)
  for d in "$@"; do setze "$d" "$schluessel" "$wert" || true; done
}

# ── Vorbedingungen ────────────────────────────────────────────────────────

for t in saganta kalender postfach lager mealprep fitness; do
  [ -d "$TEILE/$t" ] || fehler "$TEILE/$t fehlt. Erst ./holen.sh ausfuehren."
done

echo "== Teile gefunden"

SAG="$TEILE/saganta"

# ★★ Der Name der Installation muss VOR dem Einrichten feststehen, und ohne ihn
# wird hier nichts geschrieben. Bis zum 2026-09-12 fiel das Skript auf eine
# Beispiel-Domaene zurueck, und die Reihenfolge im README fuehrte damit
# zuverlaessig in eine kaputte Installation: `./einrichten.sh` schrieb die
# Beispiel-Adresse in ein gutes Dutzend .env, `docker compose up` brach danach
# an der fehlenden Variablen ab, der Betreiber trug sie nach, und die Dienste
# liefen unter seinem Namen, waehrend ihre Konfiguration auf den Beispielnamen
# zeigte. Nichts daran meldete sich: CORS-Listen, ORIGIN und die Kachel-Links
# waren still falsch.
#
# Ein spaeterer Wechsel erreicht die Dateien nicht mehr, denn sie sind dann da
# und werden bewusst nicht ueberschrieben. Deshalb hier abbrechen statt raten.
DOMAENE=$(lies .env SAGANTA_DOMAENE)
DOMAENE=${DOMAENE:-${SAGANTA_DOMAENE:-}}
if [ -z "$DOMAENE" ]; then
  fehler "SAGANTA_DOMAENE ist nicht gesetzt.

  Unter welchem Namen soll die Suite laufen? Die Adresse wandert beim
  Einrichten in ein gutes Dutzend Konfigurationsdateien, ein spaeterer Wechsel
  erreicht sie dort nicht mehr. Eintragen und erneut starten:

    echo 'SAGANTA_DOMAENE=meine-suite.example' >> .env
    echo 'SAGANTA_TLS=internal' >> .env    # nur ohne oeffentlichen Namen,
                                           # sonst holt Caddy echte Zertifikate"
fi
# Auch eintragen, wenn sie nur aus der Umgebung kam: das Compose liest sie beim
# Start erneut, und zwar ausschliesslich aus der .env.
setze .env SAGANTA_DOMAENE "$DOMAENE" || true

# ── Die Kennung nachtragen ────────────────────────────────────────────────
# Eigener Aufruf, weil sie erst existiert, wenn das erste Konto angelegt ist.

if [ "$WILL_KENNUNG" = 1 ] && [ -z "$KENNUNG" ]; then
  # ★★ Ohne Angabe selbst nachsehen. Der Schlusstext hat bis zum 2026-09-12
  # behauptet, die Kennung stehe „im eigenen Profil"; sie steht dort nicht, und
  # es gibt in der ganzen Oberflaeche keine Stelle, die sie zeigt (gemessen an
  # /settings). Wer der Anleitung folgte, suchte also etwas, das es nicht gibt.
  # Die Datenbank kennt sie, und dieses Skript darf sie fragen.
  echo "== Kennung aus der Anmelde-Datenbank lesen"
  konten=$(docker compose exec -T saganta-auth-db \
    psql -U saganta_auth -d saganta_auth -tAF'|' \
    -c 'select id, email from "user" order by "createdAt"' 2>/dev/null | grep . || true)
  anzahl=$(printf '%s\n' "$konten" | grep -c . || true)
  if [ "$anzahl" = 0 ]; then
    fehler "Es gibt noch kein Konto (oder die Datenbank laeuft nicht).
  Erst https://shell.$DOMAENE aufrufen und eines anlegen."
  elif [ "$anzahl" = 1 ]; then
    KENNUNG=${konten%%|*}
    hinweis "ein Konto gefunden: ${konten#*|}"
  else
    echo "  Es gibt $anzahl Konten. Welches ist deins?" >&2
    printf '%s\n' "$konten" | while IFS='|' read -r id mail; do
      printf '    --kennung %s   (%s)\n' "$id" "$mail" >&2
    done
    exit 1
  fi
fi

if [ -n "$KENNUNG" ]; then
  echo "== Kennung des ersten Kontos eintragen"
  for t in lager mealprep fitness kalender; do
    setze "$TEILE/$t/.env" DEFAULT_OWNER_SUB "$KENNUNG" \
      || hinweis "schon gesetzt: $t (nicht angefasst)"
  done
  # ★★ Im saganta-Teil wird nicht aufgezaehlt, sondern gesucht. Die Kennung
  # steht dort unter mindestens drei Namen (`OWNER_SUB`, `ALLOWED_SUBS`,
  # `KALENDER_OWNER_SUB`) in wechselnden Dateien. Eine Liste haette beim
  # naechsten neuen Dienst still eine Stelle ausgelassen, und das Ergebnis
  # waere ein Dienst, der laeuft und niemanden hereinlaesst.
  #
  # Gesucht wird an der Eigenschaft: jeder Schluessel, der auf SUB oder SUBS
  # endet und noch einen Platzhalter traegt.
  if [ "$NUR_PRUEFEN" = 0 ]; then
    KENN="$KENNUNG" python3 - "$SAG" <<'KENNUNG_EINTRAGEN'
import os, pathlib, re, sys

wurzel = pathlib.Path(sys.argv[1])
kennung = os.environ["KENN"]
PLATZHALTER = re.compile(r"^(change-me|set-from|CHANGEME)", re.I)
SUB = re.compile(r"(^|_)(SUB|SUBS)$")

for p in sorted(wurzel.rglob("*.env")):
    if p.name.endswith(".example") or "node_modules" in p.parts:
        continue
    zeilen, geaendert = [], []
    for z in p.read_text().splitlines():
        k, t, v = z.partition("=")
        if t and SUB.search(k.strip()) and PLATZHALTER.match(v.strip()):
            z = f"{k}={kennung}"
            geaendert.append(k.strip())
        zeilen.append(z)
    if geaendert:
        p.write_text("\n".join(zeilen) + "\n")
        print(f"  eingetragen: {p.relative_to(wurzel.parent.parent)} -> {', '.join(geaendert)}")
KENNUNG_EINTRAGEN
  fi
  # ★★ Welche Dienste neu erstellt werden muessen, wird ABGELEITET statt
  # aufgezaehlt. Hier standen acht Namen fest im Skript, und drei fehlten
  # darin (notizen, tagebuch, post): genau die Apps, die den neuen Wert
  # bekommen hatten, liefen danach weiter mit dem alten und antworteten mit
  # „403 Not authorized", waehrend die Konfiguration daneben richtig war.
  # Gemessen am 2026-09-12 beim ersten Durchgang mit echter Anmeldung.
  #
  # Die Frage „wer traegt die Kennung" beantwortet das aufgeloeste Compose. Es
  # wird nach der fertigen UMGEBUNG gefragt und nicht nach `env_file`: beim
  # Aufloesen liest Compose die Dateien ein und laesst das Feld leer zurueck.
  # Die Umgebung ist ohnehin die ehrlichere Frage, denn sie deckt auch Dienste
  # ab, die den Wert direkt im Compose stehen haben.
  echo
  if [ "$NUR_PRUEFEN" = 0 ] && command -v docker >/dev/null 2>&1; then
    dienste=$(SAGANTA_DOMAENE="$DOMAENE" docker compose config --format json 2>/dev/null \
      | KENN="$KENNUNG" python3 -c '
import json, os, sys

kennung = os.environ["KENN"]
daten = json.load(sys.stdin)
betroffen = []
for name, dienst in sorted(daten.get("services", {}).items()):
    umgebung = dienst.get("environment") or {}
    werte = umgebung.values() if isinstance(umgebung, dict) else umgebung
    if any(kennung in str(w) for w in werte if w is not None):
        betroffen.append(name)
print(" ".join(betroffen))
' 2>/dev/null)
  fi
  if [ -n "${dienste:-}" ]; then
    echo "Danach die betroffenen Dienste neu erstellen:"
    echo "  docker compose up -d --force-recreate $dienste"
  else
    echo "Danach die Dienste neu erstellen, die eine der geaenderten Dateien"
    echo "lesen (ohne laufendes Docker nicht ermittelbar):"
    echo "  docker compose up -d --force-recreate"
  fi
  exit 0
fi

# ── Die Geheimnisse ───────────────────────────────────────────────────────

echo "== Geheimnisse"

# Verbindet jede Oberflaeche mit ihrem Backend. Ueberall derselbe Wert.
gemeinsam SAGANTA_BACKEND_SECRET \
  "$TEILE/lager/.env" "$TEILE/mealprep/.env" "$TEILE/fitness/.env"

# Lesezugriff auf den Kalender ohne Anmeldung. Der Kalender nennt ihn
# FEED_TOKEN, seine Leser KALENDER_FEED_TOKEN. Derselbe Wert, zwei Namen.
feed=$(lies "$TEILE/kalender/.env" FEED_TOKEN)
[ -n "$feed" ] || feed=$(geheimnis)
setze "$TEILE/kalender/.env" FEED_TOKEN "$feed" || true
for t in postfach mealprep; do
  setze "$TEILE/$t/.env" KALENDER_FEED_TOKEN "$feed" || true
done

# Das Anmeldekennwort des Kalenders. Der einzige Wert, den ein Mensch spaeter
# eintippen muss, deshalb kuerzer und lesbar statt 64 Hex-Zeichen.
setze "$TEILE/kalender/.env" KALENDER_PASSWORD "$(head -c9 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
  || true
setze "$TEILE/kalender/.env" SECRET_KEY "$(geheimnis)" || true

# ── Die Mandanten-Geheimnisse ─────────────────────────────────────────────
# ★ Je Gruppe eines. ZWISCHEN den Gruppen muessen sie sich unterscheiden, das
# ist ihr Zweck: wer das Geheimnis des Lagers hat, soll damit keine gueltige
# Kennung fuer die Trainings-App erzeugen koennen. INNERHALB einer Gruppe
# muessen sie gleich sein, sonst bekommt genau ein Weg 401.
#
# Die Gruppe umfasst den Pruefer und alle, die ihn aufrufen. mealprep ruft das
# Lager auf (Vorratsabgleich fuer den Wochenplan) und braucht deshalb dessen
# Geheimnis zusaetzlich zum eigenen.

gemeinsam LAGER_TENANT_SECRET    "$TEILE/lager/.env"    "$TEILE/mealprep/.env"
gemeinsam MEALPREP_TENANT_SECRET "$TEILE/mealprep/.env"
gemeinsam FITNESS_TENANT_SECRET  "$TEILE/fitness/.env"
gemeinsam KALENDER_TENANT_SECRET "$TEILE/kalender/.env.tenant"
gemeinsam POSTFACH_TENANT_SECRET "$TEILE/postfach/.env"

# Beobachten, nicht ablehnen. Siehe ENV_VORLAGE.md.
for t in lager mealprep fitness postfach; do
  setze "$TEILE/$t/.env" TENANT_HEADER_ENFORCE 0 || true
done
setze "$TEILE/kalender/.env.tenant" TENANT_HEADER_ENFORCE 0 || true

# ── Der saganta-Teil: 22 .env-Dateien ─────────────────────────────────────
#
# Jeder seiner Dienste hat eine eigene. Die meisten haben eine `.env.example`
# daneben; die wird kopiert und danach werden die Platzhalter ersetzt. Wo keine
# Vorlage liegt, entsteht eine knappe Datei aus dem, was das Compose braucht.
#
# ★ Die Platzhalter heissen `change-me-shared-with-auth-proxy`,
# `change-me-shared-with-bffs`, `change-me-shared-with-shell` und
# `change-me-32-chars-or-more`. Vier Namen, aber **ein** Wert: der Schluessel,
# mit dem die Oberflaechen ihre kurzlebigen Backend-Token stempeln und die
# Backends sie pruefen. Wer hier vier verschiedene Geheimnisse einsetzt,
# bekommt einen Stapel, der startet und bei jeder Anfrage 401 antwortet.

echo "== saganta"

# Derselbe Wert wie bei den nativen Apps: die BFFs sprechen beide Seiten an.
backend_geheimnis=$(lies "$TEILE/lager/.env" SAGANTA_BACKEND_SECRET)

vorlage_uebernehmen() {
  local ziel=$1 vorlage=$2
  if [ -f "$ziel" ]; then
    return 1
  fi
  if [ "$NUR_PRUEFEN" = 1 ]; then
    hinweis "fehlt: ${ziel#./}"
    return 0
  fi
  mkdir -p "$(dirname "$ziel")"
  if [ -f "$vorlage" ]; then
    cp "$vorlage" "$ziel"
  else
    : > "$ziel"
  fi
  hinweis "angelegt: ${ziel#./}"
  return 0
}

# Setzt in einer fertigen Datei alle Platzhalter auf echte Werte.
#
# ★★ Die Zuordnung geht ueber den SCHLUESSEL, nicht ueber den Platzhalter-Text.
# Der erste Entwurf zaehlte sechs Texte auf. Das ist eine aufgezaehlte
# Sperrliste und veraltet still: wer einen Platzhalter in einer .env.example
# umformuliert, bekommt eine .env, in der er unersetzt stehen bleibt, und der
# Dienst startet damit und antwortet mit 401. Ueber den Schluessel ist es eine
# Eigenschaft statt einer Liste.
#
# Was es ausloeste: einer der Texte enthielt einen Rechnernamen, und der Scrub
# der Veroeffentlichungs-Pipeline haette ihn umgeschrieben. Das Skript haette
# in der veroeffentlichten Fassung genau den Platzhalter nicht mehr getroffen,
# den es ersetzen soll. Aus demselben Grund steht unten eine Regel fuer
# Beispiel-Adressen statt einer festen Domaene.
platzhalter_ersetzen() {
  local datei=$1
  [ -f "$datei" ] || return 0
  [ "$NUR_PRUEFEN" = 1 ] && return 0
  BACKEND="$backend_geheimnis" FEED="$feed" BETTER="$better_auth" \
  FERNET="$fernet" DBPASS="$db_kennwort" DOM="$DOMAENE" \
  python3 - "$datei" <<'ERSETZEN'
import os, re, sys

werte = {
    "JWT_SECRET": os.environ["BACKEND"],
    "SAGANTA_BACKEND_SECRET": os.environ["BACKEND"],
    "KALENDER_FEED_TOKEN": os.environ["FEED"],
    "BETTER_AUTH_SECRET": os.environ["BETTER"],
    "FERNET_KEY": os.environ["FERNET"],
}
# Ein Platzhalter ist alles, was noch nach Vorlage aussieht. Ein echter Wert
# bleibt unangetastet, damit ein zweiter Lauf nichts kaputt macht.
PLATZHALTER = re.compile(r"^(change-me|set-from|CHANGEME)", re.I)

pfad = sys.argv[1]
neu = []
for zeile in open(pfad).read().splitlines():
    schluessel, trenner, wert = zeile.partition("=")
    if trenner and PLATZHALTER.match(wert.strip()) and schluessel.strip() in werte:
        zeile = f"{schluessel}={werte[schluessel.strip()]}"
    elif schluessel.strip() == "DATABASE_URL" and "postgres://" in wert:
        # Nur das Kennwort zwischen ":" und "@" tauschen, der Rest der Adresse
        # (Benutzer, Wirt, Datenbank) bleibt wie in der Vorlage.
        zeile = schluessel + "=" + re.sub(
            r"(postgres://[^:]+:)[^@]+(@)", r"\g<1>" + os.environ["DBPASS"] + r"\g<2>", wert)
    neu.append(zeile)

open(pfad, "w").write("\n".join(neu) + "\n")
ERSETZEN
  # Die Beispiel-Adressen der Vorlage durch die eigene Domaene ersetzen. Steht
  # bewusst in `domaene_eintragen` und nicht hier: dieselbe Ersetzung wird
  # weiter unten fuer notizen und tagebuch gebraucht, und zwei Kopien einer
  # Regel driften.
  domaene_eintragen "$datei"
}

better_auth=$(lies "$SAG/apps/auth-service/.env" BETTER_AUTH_SECRET)
[ -n "$better_auth" ] || better_auth=$(geheimnis)
db_kennwort=$(lies "$SAG/apps/auth-service/db.env" POSTGRES_PASSWORD)
[ -n "$db_kennwort" ] || db_kennwort=$(geheimnis)

# Ein Fernet-Schluessel ist kein beliebiges Geheimnis: 32 Byte, urlsafe-base64,
# mit Polsterung. Ein hex-String wird von der Bibliothek abgelehnt, und zwar
# erst beim ersten Verschluesseln, nicht beim Start.
fernet=$(lies "$SAG/services/mail-api/.env" FERNET_KEY)
if [ -z "$fernet" ]; then
  fernet=$(head -c32 /dev/urandom | base64 | tr '+/' '-_')
fi

for paar in \
  "apps/assets/.env|apps/assets/.env.example" \
  "apps/auth-service/.env|apps/auth-service/.env.example" \
  "apps/kalender/.env|apps/kalender/.env.example" \
  "apps/news/.env|apps/news/.env.example" \
  "apps/post/.env|apps/post/.env.example" \
  "apps/projectdeck/.env|apps/projectdeck/.env.example" \
  "apps/shell/.env|apps/shell/.env.example" \
  "apps/app-proxy/fitness.env|apps/app-proxy/.env.example" \
  "apps/app-proxy/lager.env|apps/app-proxy/.env.example" \
  "apps/app-proxy/mealprep.env|apps/app-proxy/.env.example" \
  "services/assets-api/.env|services/assets-api/.env.example" \
  "services/auth-proxy/.env|services/auth-proxy/.env.example" \
  "services/kalender-bff/.env|services/kalender-bff/.env.example" \
  "services/mail-api/.env|services/mail-api/.env.example" \
  "services/news-api/.env|services/news-api/.env.example" \
  "services/projectdeck-api/.env|services/projectdeck-api/.env.example" \
  "services/shell-api/.env|services/shell-api/.env.example" \
  ; do
  ziel="$SAG/${paar%%|*}"
  vorlage="$SAG/${paar##*|}"
  vorlage_uebernehmen "$ziel" "$vorlage" && platzhalter_ersetzen "$ziel"
done

# ★★ Der auth-Dienst prueft SAGANTA_BACKEND_SECRET beim Start und beendet sich
# sonst mit FATAL. Seine `.env.example` kennt den Schluessel aber gar nicht,
# also findet `platzhalter_ersetzen` dort nichts zu ersetzen: es ersetzt
# Platzhalter, es ergaenzt keine fehlenden Zeilen. Ergebnis war ein Dienst, der
# beim ersten echten Start am 2026-09-12 in einer Neustartschleife haengenblieb,
# waehrend `pruefen.py` das Geheimnis als „1 Wert ueber 9 Stellen" gruen
# meldete. Der Grund dafuer ist derselbe in anderer Gestalt: die neun Stellen
# waren aufgezaehlt, und auth-service stand nicht in der Liste.
#
# Hier wird der Wert deshalb gesetzt statt ersetzt. Er muss derselbe sein wie
# ueberall sonst, sonst laeuft der Dienst und antwortet mit 401.
setze "$SAG/apps/auth-service/.env" SAGANTA_BACKEND_SECRET "$backend_geheimnis" || true

# ★★ Ohne diese Zeile kann auf einer frischen Installation NIEMAND ein Konto
# anlegen. Der Anmeldedienst hat die Registrierung fest zu (`disableSignUp`,
# Vorgabe), weil die Instanz des Projekts sie bewusst geschlossen haelt. Fuer
# einen Selbsthoster ist das erste Konto aber der einzige Weg hinein: die
# Registrierung antwortete mit „Email and password sign up is not enabled",
# gemessen beim Anmelde-Durchgang am 2026-09-12.
#
# Sie steht danach offen. Wer die Suite unter einem oeffentlichen Namen
# betreibt, schliesst sie nach dem ersten Konto wieder (siehe Schlusstext).
setze "$SAG/apps/auth-service/.env" AUTH_ALLOW_SIGNUP true || true

# ★★ Die oeffentliche Adresse des Anmeldedienstes ist die der Schale, nicht
# `auth.<domaene>`. Aus ihr baut der Dienst die Links, die in Mails gehen: die
# Bestaetigung zeigt auf `<adresse>/api/auth/verify-email`, die
# Passwort-Ruecksetzung auf `<adresse>/reset`, und die zweite Seite gibt es nur
# in der Schale. Die Vorlage traegt hier einen eigenen Namen ein, den der
# Eingang dieser Suite nicht bedient; wer der Vorlage folgt, bekommt ein Konto,
# das sich nie bestaetigen laesst.
#
# Gesetzt statt ergaenzt: nach dem Eintragen der Domaene steht dort ein echter
# Wert, und `setze` fasst einen echten Wert bewusst nicht an.
if [ "$NUR_PRUEFEN" = 0 ] && [ -f "$SAG/apps/auth-service/.env" ]; then
  sed -i "s|^BETTER_AUTH_URL=.*|BETTER_AUTH_URL=https://shell.$DOMAENE|" \
    "$SAG/apps/auth-service/.env"
  hinweis "Anmeldedienst oeffentlich unter https://shell.$DOMAENE/api/auth"
fi

# ★ Aus demselben Grund die Anmeldeadresse, die die anderen Apps anspringen:
# die Vorlagen tragen den nackten Namen ein, und der leitet nur weiter. Eine
# Weiterleitung mitten im Anmeldeweg ist unnoetig, und sie faellt aus, sobald
# jemand die Weiterleitung im Caddyfile anders loest.
if [ "$NUR_PRUEFEN" = 0 ]; then
  for f in "$SAG"/apps/*/.env "$SAG"/apps/app-proxy/*.env; do
    [ -f "$f" ] || continue
    sed -i "s|^AUTH_LOGIN_URL=https://$DOMAENE/|AUTH_LOGIN_URL=https://shell.$DOMAENE/|" "$f"
  done
fi

# ★★ Die Anmeldung verlangt eine bestaetigte Mail-Adresse, und die
# Bestaetigungsmail geht nur mit eingerichtetem SMTP raus. Ohne SMTP ist das
# frisch angelegte Konto damit dauerhaft ausgesperrt, ohne dass irgendwo etwas
# rot wird. Der Anmeldedienst kennt fuer genau diesen Fall einen Schalter: den
# Link statt in eine Mail in sein eigenes Protokoll schreiben.
#
# Er heisst im Quelltext „insecure", und das ist keine Uebertreibung: wer das
# Protokoll lesen kann, kann das Konto uebernehmen. Deshalb wird er nur
# gesetzt, solange kein SMTP-Wirt eingetragen ist, und der Schlusstext sagt,
# wie man ihn wieder los wird.
if [ -z "$(lies "$SAG/apps/auth-service/.env" SMTP_HOST)" ]; then
  setze "$SAG/apps/auth-service/.env" AUTH_ALLOW_INSECURE_MAIL_LOG true || true
  ohne_smtp=1
else
  ohne_smtp=0
fi

# Der Postgres-Zugang des Auth-Dienstes. Keine Vorlage im Repo, und die drei
# Werte muessen zur DATABASE_URL in apps/auth-service/.env passen.
if vorlage_uebernehmen "$SAG/apps/auth-service/db.env" ""; then
  if [ "$NUR_PRUEFEN" = 0 ]; then
    {
      printf 'POSTGRES_USER=saganta_auth\n'
      printf 'POSTGRES_PASSWORD=%s\n' "$db_kennwort"
      printf 'POSTGRES_DB=saganta_auth\n'
    } >> "$SAG/apps/auth-service/db.env"
  fi
fi

# ★★ Notizen und Tagebuch bekommen KEINE Vorlage aus einem Nachbarn, sondern
# ihre eigenen Anlege-Skripte aus dem Repo. Der erste Versuch nahm hier die
# shell-Vorlage, und das Ergebnis war gruen und falsch: `DATABASE_URL` zeigte
# auf `shell.db`, `CORS_ORIGINS` liess nur `shell.<domaene>` zu, und die
# app-eigenen Adressen (`NOTIZEN_API_BASE_URL`, `ANHANG_VERZEICHNIS`) fehlten
# ganz. Die Skripte wissen das alles; sie uebernehmen die Geheimnisse aus den
# Nachbarn, statt neue zu wuerfeln, und pruefen am Ende selbst nach, dass
# Stempel und Pruefung denselben Schluessel tragen.
#
# ★ Reihenfolge ist Pflicht: notizen liest aus post und projectdeck, tagebuch
# liest aus notizen.
if [ "$NUR_PRUEFEN" = 0 ]; then
  for s in notizen tagebuch; do
    if [ ! -f "$SAG/apps/$s/.env" ]; then
      ( cd "$SAG/infra" && bash "$s-env-anlegen.sh" >/dev/null 2>&1 ) \
        && hinweis "angelegt: teile/saganta/apps/$s/.env + services/$s-api/.env" \
        || hinweis "FEHLER beim Anlegen von $s (Quelle fehlt?)"
    fi
  done
  # Die Skripte tragen die Adressen dieses Hauses fest ein. Fuer eine Suite,
  # die anderswo laeuft, muss die eigene Domaene daraus werden.
  for f in "$SAG/apps/notizen/.env" "$SAG/services/notizen-api/.env" \
           "$SAG/apps/tagebuch/.env" "$SAG/services/tagebuch-api/.env"; do
    [ -f "$f" ] || continue
    domaene_eintragen "$f"
    # ★ Die Skripte listen dieselbe App unter .de UND .home. Nach dem Ersetzen
    # steht derselbe Ursprung zweimal in CORS_ORIGINS. Funktional harmlos, aber
    # es sieht wie ein Fehler aus, und wer das spaeter liest, sucht einen.
    python3 - "$f" <<'ENTDOPPELN'
import sys
p = sys.argv[1]
zeilen = []
for z in open(p).read().splitlines():
    if z.startswith("CORS_ORIGINS="):
        s, _, wert = z.partition("=")
        gesehen, eindeutig = set(), []
        for u in wert.split(","):
            u = u.strip()
            if u and u not in gesehen:
                gesehen.add(u)
                eindeutig.append(u)
        z = f"{s}={','.join(eindeutig)}"
    zeilen.append(z)
open(p, "w").write("\n".join(zeilen) + "\n")
ENTDOPPELN
  done
elif [ ! -f "$SAG/apps/notizen/.env" ]; then
  hinweis "fehlt: teile/saganta/apps/notizen/.env + tagebuch (ueber die Anlege-Skripte)"
fi

# ★★ Die drei app-proxy-Dateien kommen aus EINER Vorlage, und die ist fuer
# fitness geschrieben (`APP_NAME=saganta-fitness`, `BACKEND_URL=http://fitness:8000`).
# Unveraendert kopiert zeigen alle drei auf dasselbe Backend: `lager.<domaene>`
# lieferte dann Trainingsdaten. Nichts daran sieht nach Fehler aus, der
# Container laeuft und die Oberflaeche laedt, sie zeigt nur die falsche App.
# Deshalb wird hier je Proxy umgestellt, nicht nur ergaenzt.
#
# Dazu je das Mandanten-Geheimnis SEINER App: drei Kopien desselben Wertes
# hoeben genau die Trennung auf, die diese Geheimnisse herstellen.
if [ "$NUR_PRUEFEN" = 0 ]; then
  for app in lager mealprep fitness; do
    datei="$SAG/apps/app-proxy/$app.env"
    [ -f "$datei" ] || continue
    sed -i \
      -e "s|^APP_NAME=.*|APP_NAME=saganta-$app|" \
      -e "s|^BACKEND_URL=.*|BACKEND_URL=http://$app:8000|" \
      "$datei"
    gross=$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')
    wert=$(lies "$TEILE/$app/.env" "${gross}_TENANT_SECRET")
    [ -n "$wert" ] && { setze "$datei" "${gross}_TENANT_SECRET" "$wert" >/dev/null || true; }
    hinweis "app-proxy $app -> http://$app:8000"
  done
fi

# ★ Das Briefkasten-Token verbindet die Post-Oberflaeche mit dem nativen
# Briefkasten. Es heisst auf beiden Seiten anders (`KG_INTERNAL_TOKEN` dort,
# `BRIEFKASTEN_INTERNAL_TOKEN` hier), muss aber derselbe Wert sein. Ohne ihn
# laedt die Oberflaeche und zeigt kein einziges Schriftstueck.
#
# Steht hier unten, weil apps/notizen/.env erst durch das Anlege-Skript
# entsteht: weiter oben haette der Eintrag dort ins Leere gegriffen.
brief_token=$(lies "$TEILE/postfach/.env" KG_INTERNAL_TOKEN)
[ -n "$brief_token" ] || brief_token=$(geheimnis)
setze "$TEILE/postfach/.env" KG_INTERNAL_TOKEN "$brief_token" >/dev/null || true
for d in "$SAG/apps/post/.env" "$SAG/apps/shell/.env" "$SAG/apps/notizen/.env"; do
  [ -f "$d" ] && { setze "$d" BRIEFKASTEN_INTERNAL_TOKEN "$brief_token" >/dev/null || true; }
done

# ── Wo die Daten liegen ───────────────────────────────────────────────────

daten=$(lies .env POSTFACH_DATEN)
daten=${daten:-./daten/postfach}
# ★★ Absolut eintragen, nicht relativ. Das Compose des Postfachs wird per
# `include` eingebunden, und Compose loest relative Pfade darin gegen das
# Verzeichnis DIESER Datei auf, nicht gegen das Projektverzeichnis. Ein
# eingetragenes `./daten/postfach` suchte deshalb unter
# `teile/postfach/daten/postfach`, waehrend hier `./daten/postfach` angelegt
# wurde. Beides sah je fuer sich richtig aus, und der Start brach ab mit einem
# Pfad, den so niemand geschrieben hatte.
case "$daten" in
  /*) ;;                          # schon absolut
  *)  daten="$PWD/${daten#./}" ;; # $PWD ist das Projektverzeichnis (cd oben)
esac
# ★★ Den gewaehlten Pfad AUCH eintragen, nicht nur das Verzeichnis anlegen.
# Bis zum 2026-09-06 stand hier nur das mkdir. Das Compose des Postfachs faellt
# ohne diesen Eintrag auf seine eigene Vorgabe zurueck, und die zeigt in das
# Haus, in dem dieses Projekt entstanden ist. Ergebnis war ein Abbruch mit
# "bind source path does not exist" auf einen Pfad, den es beim Selbsthoster nie
# geben konnte, waehrend das frisch angelegte, richtige Verzeichnis danebenlag
# und niemand es benutzte. Ein Skript, das etwas herrichtet, muss auch
# aufschreiben, was es hergerichtet hat.
#
# Steht ausserhalb der Trockenlauf-Weiche, weil `setze` den Trockenlauf selbst
# beachtet: es meldet dann "fehlt", statt zu schreiben. Innerhalb der Weiche
# haette der Trockenlauf ueber genau den Eintrag geschwiegen, dessen Fehlen den
# Start verhindert.
setze .env POSTFACH_DATEN "$daten" || true
if [ "$NUR_PRUEFEN" = 0 ]; then
  mkdir -p "$daten"
  hinweis "Briefkasten-Daten: $daten"
fi

# ── Die Datenverzeichnisse gehoeren dem Dienst ────────────────────────────
#
# ★★ Docker legt ein fehlendes Bind-Ziel als root an, und alle Dienste hier
# laufen unprivilegiert als uid 1000. SQLite braucht Schreibrecht am
# VERZEICHNIS, nicht nur an der Datei. Beim ersten echten Start am 2026-09-12
# sind daran zwei von 28 Diensten gescheitert (kalender und briefkasten, beide
# mit "unable to open database file"), und zwar nach einem erfolgreichen Bau
# und einem gruenen `pruefen.py`. Auf dem Wirt, auf dem dieses Projekt
# entstanden ist, gibt es die Verzeichnisse laengst mit den richtigen Rechten,
# deshalb war es dort nie zu sehen.
#
# Die Liste kommt aus dem aufgeloesten Compose statt aus einer Aufzaehlung: ein
# neuer Dienst mit eigenem Datenverzeichnis ist damit ohne Zutun dabei.
if [ "$NUR_PRUEFEN" = 0 ] && command -v docker >/dev/null 2>&1; then
  if ! SAGANTA_DOMAENE="$DOMAENE" docker compose config --format json 2>/dev/null \
     | python3 -c '
import json, os, pathlib, sys

# Alle Images legen ihren Dienstnutzer als uid 1000 an (appuser).
UID = GID = 1000

daten = json.load(sys.stdin)
behandelt, offen = [], []
for name, dienst in sorted(daten.get("services", {}).items()):
    for m in dienst.get("volumes") or []:
        if m.get("type") != "bind" or m.get("read_only"):
            continue
        pfad = pathlib.Path(m["source"])
        # Eingehaengte Dateien (Caddyfile, Zertifikate) nicht anfassen. Was es
        # noch nicht gibt, gilt als Verzeichnis, sofern es keine Endung traegt.
        if pfad.exists():
            if not pfad.is_dir():
                continue
        elif pfad.suffix:
            continue
        else:
            pfad.mkdir(parents=True, exist_ok=True)
        if pfad.stat().st_uid == UID:
            continue
        try:
            os.chown(pfad, UID, GID)
            behandelt.append(str(pfad))
        except PermissionError:
            offen.append(str(pfad))

for p in behandelt:
    print(f"  uebereignet an uid {UID}: {p}")
for p in offen:
    print(f"  ⚠️ {p} gehoert uid {pathlib.Path(p).stat().st_uid}, der Dienst "
          f"laeuft als {UID}. Nachziehen mit: sudo chown -R {UID}:{GID} {p}",
          file=sys.stderr)
sys.exit(1 if offen else 0)
'; then
    echo "  ⚠️ Mindestens ein Datenverzeichnis ist fuer den Dienst nicht beschreibbar." >&2
    echo "     Ohne das bricht der Start mit 'unable to open database file' ab." >&2
  fi
fi

# ── Schluss ───────────────────────────────────────────────────────────────

echo
if [ "$NUR_PRUEFEN" = 1 ]; then
  echo "Trockenlauf, nichts geschrieben."
  exit 0
fi

cat <<EOF

Fertig. Die naechsten Schritte:

  1. docker compose up -d
  2. Im Browser https://shell.$DOMAENE aufrufen und das erste Konto anlegen.
EOF

if [ "${ohne_smtp:-0}" = 1 ]; then
  cat <<'EOF'
  3. Den Bestaetigungslink abholen. Die Anmeldung verlangt eine bestaetigte
     Adresse, und es ist kein SMTP eingetragen, also steht der Link im
     Protokoll des Anmeldedienstes statt in einer Mail:

       docker compose logs saganta-auth | grep verify-email

     Wer echte Mails will, traegt SMTP_HOST und MAIL_FROM in
     teile/saganta/apps/auth-service/.env ein und entfernt dort die Zeile
     AUTH_ALLOW_INSECURE_MAIL_LOG. Solange sie steht, kann jeder, der die
     Protokolle liest, ein frisches Konto uebernehmen.
EOF
else
  cat <<'EOF'
  3. Den Bestaetigungslink aus der Mail anklicken. Ohne bestaetigte Adresse
     laesst die Anmeldung niemanden herein.
EOF
fi

cat <<'EOF'
  4. Die Registrierung wieder schliessen, sobald das eigene Konto steht. Sie
     ist offen, weil sonst niemand hineinkommt, und sie soll nicht offen
     bleiben:

       sed -i 's/^AUTH_ALLOW_SIGNUP=.*/AUTH_ALLOW_SIGNUP=false/' \
         teile/saganta/apps/auth-service/.env
       docker compose up -d --force-recreate saganta-auth

  5. Die Kennung des Kontos eintragen, damit die Apps wissen, wem die
     bestehenden Daten gehoeren:

       ./einrichten.sh --kennung

     Ohne Angabe holt das Skript sie aus der Anmelde-Datenbank. Ohne sie leiten
     lager, mealprep und fitness den Mandanten aus ihren eigenen Daten ab,
     solange dort genau einer vorkommt. Das ist eine Notmassnahme, kein
     Zustand: sie protokolliert bei jedem Start eine Warnung und versagt,
     sobald ein zweites Konto dazukommt.

Das Kennwort des Kalenders steht in teile/kalender/.env unter
KALENDER_PASSWORD. Es wird beim ersten Start in die Datenbank uebernommen.
EOF
