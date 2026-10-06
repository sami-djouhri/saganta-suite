#!/usr/bin/env python3
"""Prueft die Suite, bevor sie startet.

WOZU: Ein Compose, das `config` besteht, ist gueltig, nicht richtig. Die Fehler,
die hier gesucht werden, machen alle einen gesunden Eindruck:

1. Ein Vhost im Caddyfile zeigt auf einen Dienst, den es nicht gibt. Der
   Eingang startet, alles ist gruen, und genau diese eine Adresse antwortet mit
   502. Beim Bau der Suite waere das mehrfach passiert, weil die Zuordnung aus
   einer fremden nginx-Konfiguration stammt und die Dienstnamen dort teils
   anders heissen.
2. Ein Vhost zeigt auf einen Dienst, den es gibt, aber der Eingang teilt kein
   Netz mit ihm. Gleicher Effekt, andere Ursache, und im Compose nicht zu
   sehen.
3. Ein Geheimnis, das an mehreren Stellen gleich sein muss, ist es nicht. Der
   Stapel laeuft dann und antwortet auf jede Anfrage mit 401.
4. Ein Bind-Mount zeigt auf ein Verzeichnis, das es nicht gibt und das Docker
   bewusst nicht anlegt, oder ein veroeffentlichter Port ist auf diesem Wirt
   schon belegt. Beides bricht den Start ab, und beides meldet Docker mit einem
   Satz, der wie ein Fehler des Lesers aussieht statt wie ein fehlender Eintrag.
5. Eine konfigurierte Adresse hat kein Ziel: ein Dienstname, den es in dieser
   Suite nicht gibt, oder eine eigene Unterdomaene ohne Vhost. Sichtbar wird
   davon nur eine Zeile im Protokoll oder gar nichts.
6. Ein Dienst hat keine Neustart-Regel. Nach einem Neustart des Wirts kommen
   alle wieder, dieser nicht, und die Uebersicht meldet weiter eine hohe Zahl.
7. Ein Teil unter `teile/` ist gegenueber seinem Repo zurueckgefallen. Das ist
   der stillste Fall von allen: `teile/` ist absichtlich nicht versioniert,
   ein Klon veraltet ohne jedes Anzeichen, und wer dort hineinsieht, haelt den
   alten Stand fuer den Stand der Suite. Gemessen am 2026-09-27 lagen alle
   sechs Klone zwischen 7 und 32 Commits hinter ihrem Gitea-Zweig, und drei
   von ihnen trugen deshalb noch eine Vorlagen-CSS samt Google-Fonts-Abruf,
   die in den Quell-Repos am selben Tag entfernt worden war. Ein Spiegel, der
   schweigend zurueckfaellt, sieht aus wie eine zweite Wahrheit.

Nutzung:  SAGANTA_DOMAENE=beispiel.test python3 pruefen.py
Rueckgabe: 0 = alles gut, 1 = mindestens ein Befund
"""

import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys

HIER = pathlib.Path(__file__).resolve().parent
TEILE = HIER / "teile"
SAG = TEILE / "saganta"


def compose_config():
    umgebung = dict(os.environ)
    umgebung.setdefault("SAGANTA_DOMAENE", "beispiel.test")
    p = subprocess.run(
        ["docker", "compose", "config", "--format", "json"],
        cwd=HIER, capture_output=True, text=True, env=umgebung,
    )
    if p.returncode != 0:
        print("FEHLER: 'docker compose config' scheitert.", file=sys.stderr)
        print(p.stderr.strip()[:800], file=sys.stderr)
        sys.exit(1)
    return json.loads(p.stdout)


def lies(pfad, schluessel):
    p = pathlib.Path(pfad)
    if not p.exists():
        return None
    for z in p.read_text().splitlines():
        if z.startswith(schluessel + "="):
            return z.split("=", 1)[1]
    return None


def fp(wert):
    return hashlib.sha256(wert.encode()).hexdigest()[:8] if wert else "FEHLT"


def env_dateien():
    """Jede Konfigurationsdatei unter teile/, egal welcher Teil sie mitbringt.

    Eine Eigenschaft statt einer Liste: `db.env`, `.env.tenant` und
    `lager.env` heissen alle anders und sind alle gemeint.
    """
    treffer = []
    for p in sorted(TEILE.rglob("*")):
        if not p.is_file() or "node_modules" in p.parts:
            continue
        if p.name.endswith(".example"):
            continue
        if p.name == ".env" or p.name.endswith(".env") or p.name == ".env.tenant":
            treffer.append(p)
    return treffer


def pruefe_eingang(d):
    """Jeder Vhost muss auf einen Dienst zeigen, den der Eingang erreicht."""
    dienste = {v.get("container_name", k): set(v.get("networks", {}))
               for k, v in d["services"].items()}
    eingang = dienste.get("saganta-eingang")
    if eingang is None:
        return ["Der Dienst saganta-eingang fehlt im Compose."]

    text = (HIER / "Caddyfile").read_text()
    ziele = re.findall(r"reverse_proxy\s+([a-z0-9-]+):(\d+)", text)
    ziele += [(m, "8000") for m in re.findall(r"forward_auth\s+([a-z0-9-]+):\d+", text)]

    befunde = []
    for name, port in ziele:
        if name not in dienste:
            befunde.append(f"Caddyfile zeigt auf {name}:{port}, diesen Dienst gibt es nicht.")
        elif not (dienste[name] & eingang):
            befunde.append(
                f"Der Eingang erreicht {name} nicht: der Dienst haengt in "
                f"{sorted(dienste[name])}, der Eingang in {sorted(eingang)}."
            )
    print(f"  Eingang: {len(ziele)} Ziele, {len(ziele) - len(befunde)} erreichbar")
    return befunde


def pruefe_start(d):
    """Was `docker compose up` sofort abbrechen laesst, ohne dass `config` klagt.

    Beide Faelle sind schon vorgekommen und sahen beide nicht nach einem Fehler
    im Projekt aus, sondern nach einem Fehler beim Leser.
    """
    befunde = []

    # ★★ Bind-Quellen, die es nicht gibt und die Docker auch nicht anlegt.
    # Der Briefkasten steht bewusst auf create_host_path: false, damit ein
    # zuger Tresor den Start verhindert statt eine Klartext-Ablage anzulegen.
    # Die Kehrseite: wer den Pfad nicht setzt, bekommt einen Abbruch mit einem
    # Verzeichnisnamen, mit dem er nichts anfangen kann.
    fehlend = []
    for name, dienst in sorted(d["services"].items()):
        for m in dienst.get("volumes") or []:
            if m.get("type") != "bind":
                continue
            # Fehlt der Schalter, legt Compose das Verzeichnis selbst an. Nur
            # das ausdrueckliche false ist ein Grund zur Sorge.
            if (m.get("bind") or {}).get("create_host_path") is not False:
                continue
            if not pathlib.Path(m["source"]).exists():
                fehlend.append((name, m["source"]))
    for name, quelle in fehlend:
        befunde.append(
            f"{name} haengt {quelle} ein, es gibt das Verzeichnis nicht, und "
            "Docker legt es hier bewusst nicht an. Der Start bricht ab. "
            "Verzeichnis anlegen oder den Pfad in der .env setzen."
        )
    print(f"  Bind-Quellen: {len(fehlend)} fehlen")

    # ★★ Ein Bind-Verzeichnis, das dem Dienst nicht gehoert (2026-09-12). Es
    # ist da, der Start gelingt, und erst die erste Schreiboperation scheitert:
    # SQLite braucht Schreibrecht am VERZEICHNIS, nicht nur an der Datei, und
    # meldet dann "unable to open database file", was wie ein falscher Pfad
    # aussieht und keiner ist. Beim ersten echten Start hat das zwei von 28
    # Diensten gekostet (kalender und briefkasten), nachdem Bau und Pruefung
    # gruen waren. Ursache ist Docker selbst: ein fehlendes Bind-Ziel legt es
    # als root an, und alle Dienste hier laufen als uid 1000.
    UID_DIENST = 1000
    unbeschreibbar = []
    for name, dienst in sorted(d["services"].items()):
        for m in dienst.get("volumes") or []:
            if m.get("type") != "bind" or m.get("read_only"):
                continue
            quelle = pathlib.Path(m["source"])
            if not quelle.is_dir():
                continue
            st = quelle.stat()
            eigen = st.st_uid == UID_DIENST
            fuer_alle = bool(st.st_mode & 0o002)
            if not (eigen or fuer_alle):
                unbeschreibbar.append((name, str(quelle), st.st_uid))
    for name, quelle, uid in unbeschreibbar:
        befunde.append(
            f"{name} schreibt nach {quelle}, das Verzeichnis gehoert aber uid "
            f"{uid} und der Dienst laeuft als {UID_DIENST}. Der Container "
            "startet und bricht bei der ersten Schreiboperation ab "
            f"('unable to open database file'). Beheben: ./einrichten.sh, oder "
            f"sudo chown -R {UID_DIENST}:{UID_DIENST} {quelle}"
        )
    print(f"  Datenverzeichnisse: {len(unbeschreibbar)} nicht beschreibbar")

    # ★ Ports, die schon jemand haelt. Die Teile veroeffentlichen je einen
    # eigenen Port auf 127.0.0.1. Auf einem leeren Wirt stoert das nicht, auf
    # einem, der die Einzel-Apps schon betreibt, verhindert es den Start, und
    # die Meldung von Docker nennt nur die Portnummer.
    # ★ Adresse mitlesen, nicht nur die Nummer. Ein Dienst, der ausschliesslich
    # auf der LAN-Adresse des Wirts lauscht, steht einer Veroeffentlichung auf
    # 127.0.0.1 mit derselben Portnummer NICHT im Weg. Ein Vergleich allein
    # ueber die Nummer haette dort falschen Alarm geschlagen, und ein Pruefer,
    # dem man nicht glaubt, wird uebersprungen.
    belegt = set()   # (adresse, port)
    gemessen = False
    try:
        aus = subprocess.run(["ss", "-tlnH"], capture_output=True, text=True)
        gemessen = aus.returncode == 0
        for z in aus.stdout.splitlines():
            felder = z.split()
            if len(felder) >= 4:
                adresse, _, hafen = felder[3].rpartition(":")
                belegt.add((adresse.strip("[]"), hafen))
    except FileNotFoundError:
        pass  # ohne ss keine Aussage, lieber schweigen als raten

    # ★★ Die eigenen Container sind keine Fremden (2026-09-12). Nach einem
    # `docker compose up` haelt die Suite ihre Ports selbst, und ein Lauf des
    # Pruefers danach meldete sieben Kollisionen mit sich selbst. Das ist genau
    # die Sorte Befund, die einen Pruefer unbrauchbar macht: wer sich an rote
    # Meldungen gewoehnt, liest die naechste nicht mehr. Gefragt wird deshalb
    # nicht "lauscht da jemand", sondern "lauscht da jemand ANDERES".
    eigene = set()
    try:
        aus = subprocess.run(
            ["docker", "compose", "ps", "--format", "json"],
            cwd=HIER, capture_output=True, text=True,
            env={**os.environ, "SAGANTA_DOMAENE": domaene()},
        )
        if aus.returncode == 0 and aus.stdout.strip():
            roh = aus.stdout.strip()
            # Compose liefert je nach Fassung ein Array oder eine Zeile je
            # Container. Beides lesen, statt sich auf eine Fassung zu verlassen.
            zeilen = ([json.loads(roh)] if roh.startswith("[")
                      else [[json.loads(z) for z in roh.splitlines() if z.strip()]])
            for satz in zeilen:
                for c in satz:
                    for p in c.get("Publishers") or []:
                        if p.get("PublishedPort"):
                            eigene.add(str(p["PublishedPort"]))
    except (FileNotFoundError, json.JSONDecodeError):
        pass  # ohne Auskunft lieber streng bleiben als still durchwinken

    def steht_im_weg(wirt_ip, hafen):
        if hafen in eigene:
            return False
        # Ein Lauscher auf einer Platzhalter-Adresse belegt den Port fuer alle.
        for platzhalter in ("0.0.0.0", "*", "::"):
            if (platzhalter, hafen) in belegt:
                return True
        if wirt_ip in ("", "0.0.0.0"):
            # Wir wollen selbst auf alle Adressen: jeder Lauscher stoert.
            return any(h == hafen for _, h in belegt)
        return (wirt_ip, hafen) in belegt

    kollisionen = []
    for name, dienst in sorted(d["services"].items()):
        for p in dienst.get("ports") or []:
            hafen = str(p.get("published"))
            if steht_im_weg(p.get("host_ip", ""), hafen):
                kollisionen.append((name, hafen))
    for name, hafen in kollisionen:
        befunde.append(
            f"Port {hafen} ({name}) ist auf diesem Wirt schon belegt. "
            "Der Start bricht ab, sobald dieser eine Dienst an die Reihe kommt."
        )
    print(f"  Ports: {len(kollisionen)} Kollision(en)"
          + (f", {len(eigene)} haelt die Suite selbst" if eigene else "")
          + ("" if gemessen else ", nicht pruefbar (ss fehlt)"))

    return befunde


def pruefe_geheimnisse():
    """Gleich, wo es gleich sein muss. Verschieden, wo das der Zweck ist."""
    befunde = []

    # Ein Wert, zwei Namen, beide Welten: der Schluessel, mit dem die
    # Oberflaechen ihre Backend-Token stempeln und die Backends sie pruefen.
    #
    # ★★ Gesucht statt aufgezaehlt (2026-09-12). Hier standen neun Stellen als
    # Liste, und `apps/auth-service` fehlte darin. Der Anmeldedienst prueft den
    # Wert beim Start und beendet sich sonst mit FATAL: beim ersten echten
    # Start hing er in einer Neustartschleife, waehrend diese Pruefung
    # „1 Wert ueber 9 Stellen" meldete und damit gruen war. Wer den Wert
    # traegt, ist eine Eigenschaft der Dateien und keine Frage an ein
    # Gedaechtnis, das beim naechsten neuen Dienst still veraltet.
    gemeinsam = [(p, s) for p in env_dateien()
                 for s in ("JWT_SECRET", "SAGANTA_BACKEND_SECRET")
                 if lies(p, s) is not None]
    werte = {fp(lies(d, s)) for d, s in gemeinsam}
    if len(werte) > 1:
        stellen = {}
        for d, s in gemeinsam:
            stellen.setdefault(fp(lies(d, s)), []).append(
                f"{d.relative_to(HIER)}:{s}")
        kleinste = min(stellen.values(), key=len)
        befunde.append(
            f"Das Backend-Geheimnis hat {len(werte)} verschiedene Werte. "
            f"Jeder Weg mit dem falschen bekommt 401. Am seltensten: "
            f"{', '.join(kleinste)}."
        )
    print(f"  Backend-Geheimnis: {len(werte)} Wert(e) ueber {len(gemeinsam)} Stellen")

    # Je App eines, und zwischen den Apps verschieden: wer das Geheimnis des
    # Lagers hat, soll damit keine Kennung fuer die Trainings-App stempeln.
    mandanten = {
        "lager": TEILE / "lager/.env",
        "mealprep": TEILE / "mealprep/.env",
        "fitness": TEILE / "fitness/.env",
        "postfach": TEILE / "postfach/.env",
        "kalender": TEILE / "kalender/.env.tenant",
    }
    gesehen = {}
    for app, datei in mandanten.items():
        schluessel = ("KALENDER" if app == "kalender" else
                      "POSTFACH" if app == "postfach" else app.upper()) + "_TENANT_SECRET"
        wert = lies(datei, schluessel)
        if wert:
            gesehen.setdefault(fp(wert), []).append(app)
    doppelt = {k: v for k, v in gesehen.items() if len(v) > 1}
    if doppelt:
        for apps in doppelt.values():
            befunde.append(
                f"Diese Apps teilen sich ein Mandanten-Geheimnis: {', '.join(apps)}. "
                "Das hebt die Trennung auf, die sie herstellen sollen."
            )
    print(f"  Mandanten-Geheimnisse: {len(gesehen)} verschiedene bei {len(mandanten)} Apps")

    # Jeder App-Proxy muss auf SEIN Backend zeigen. Alle drei kommen aus einer
    # Vorlage, und die ist fuer fitness geschrieben.
    for app in ("lager", "mealprep", "fitness"):
        datei = SAG / f"apps/app-proxy/{app}.env"
        ziel = lies(datei, "BACKEND_URL")
        if ziel and f"//{app}:" not in ziel:
            befunde.append(
                f"app-proxy {app} zeigt auf {ziel}. Die Oberflaeche laedt dann, "
                "sie zeigt nur die falsche App."
            )
    print("  App-Proxys: je auf das eigene Backend")

    # ★ Ein stehengebliebener Platzhalter ist der leiseste Fehler von allen: die
    # Datei sieht vollstaendig aus, der Dienst startet, und erst im Betrieb
    # antwortet er mit 401 oder laesst niemanden herein. Beim ersten Probelauf
    # sind neun davon uebriggeblieben, weil das Einrichtungsskript einen
    # Platzhalter als „schon gesetzt" gelesen hat.
    import re
    PLATZ = re.compile(r"^(change-me|set-from|CHANGEME)", re.I)
    # ★ Die Kennung des ersten Kontos ist der eine Platzhalter, der hier
    # berechtigt steht: sie entsteht erst bei der Anmeldung. Sie als Fehler zu
    # melden hiesse, direkt nach dem Einrichten rot zu sein, und wer sich an
    # rote Meldungen gewoehnt, liest die naechste nicht mehr.
    SUB = re.compile(r"(^|_)(SUB|SUBS)$")

    reste, offene_kennung = [], []
    for p in env_dateien():
        for z in p.read_text(errors="replace").splitlines():
            k, t, v = z.partition("=")
            if t and PLATZ.match(v.strip()):
                (offene_kennung if SUB.search(k.strip()) else reste).append(
                    f"{p.relative_to(HIER)}: {k.strip()}")
    if reste:
        befunde.append(
            f"{len(reste)} Platzhalter sind stehengeblieben, u.a. {reste[0]}. "
            "Der Dienst startet damit und antwortet erst im Betrieb mit 401."
        )
    print(f"  Platzhalter: {len(reste)} uebrig")
    if offene_kennung:
        print(f"  Kennung: an {len(offene_kennung)} Stellen noch offen, das ist vor der "
              "Kontoanlage normal (danach ./einrichten.sh --kennung <sub>)")

    # ★ Das Briefkasten-Token heisst auf beiden Seiten anders und muss derselbe
    # Wert sein. Ohne ihn laedt die Post-Oberflaeche und zeigt kein einziges
    # Schriftstueck, ohne Fehlermeldung.
    a = lies(TEILE / "postfach/.env", "KG_INTERNAL_TOKEN")
    b = lies(SAG / "apps/post/.env", "BRIEFKASTEN_INTERNAL_TOKEN")
    if a and b and a != b:
        befunde.append(
            "Der Briefkasten und die Post-Oberflaeche tragen verschiedene Token. "
            "Die Oberflaeche laedt dann und zeigt kein Schriftstueck."
        )
    print(f"  Briefkasten-Token: {'gleich' if a and a == b else 'fehlt oder weicht ab'}")

    return befunde


def domaene():
    """Der Name dieser Installation, so wie ihn das Compose sehen wird."""
    return (lies(HIER / ".env", "SAGANTA_DOMAENE")
            or os.environ.get("SAGANTA_DOMAENE")
            or "beispiel.test")


def bediente_namen():
    """Die Unterdomaenen, die der Eingang laut Caddyfile bedient.

    Die Wurzel (der nackte Name) steht als "" in der Menge.
    """
    text = (HIER / "Caddyfile").read_text()
    namen = set(re.findall(r"([a-z0-9-]+)\.\{\$SAGANTA_DOMAENE\}", text))
    if re.search(r"(?m)^\{\$SAGANTA_DOMAENE\}", text):
        namen.add("")
    return namen


def erreichbare_namen(d):
    """Alles, was die Docker-Namensaufloesung innerhalb der Suite beantwortet.

    Dienstschluessel, container_name und Netz-Aliase, weil ein Dienst unter
    jedem dieser Namen antwortet und eine Konfiguration jeden davon benutzen
    darf.
    """
    namen = set()
    for schluessel, dienst in d["services"].items():
        namen.add(schluessel)
        if dienst.get("container_name"):
            namen.add(dienst["container_name"])
        for netz in (dienst.get("networks") or {}).values():
            for alias in ((netz or {}).get("aliases") or []):
                namen.add(alias)
    return namen


ADRESSE = re.compile(r"^(?:https?)://([^/\s]+)")


def pruefe_adressen(d):
    """Adressen, die konfiguriert sind, aber ins Leere zeigen.

    ★★ Zwei Fehlerbilder, beide am 2026-09-12 beim ersten Durchgang mit echter
    Anmeldung gemessen, beide vorher unsichtbar:

    1. Ein Platzhalter-Name aus der Vorlage ist stehengeblieben. In
       `apps/shell/.env` steht darueber `ORIGIN`, und SvelteKit lehnt jeden
       Formular-POST ab, dessen Origin davon abweicht: niemand konnte sich
       anmelden oder registrieren, waehrend jede Leseprobe 200 lieferte.
    2. Eine Adresse zeigt auf eine Unterdomaene, die der Eingang nicht bedient.
       So fehlten `kalender` und `assets` im Caddyfile, obwohl beide Dienste
       liefen und die Schale auf sie verlinkte. Ein fehlender Vhost macht
       keinen Dienst rot, er macht nur eine Kachel tot.
    """
    befunde = []
    dom = domaene()
    bedient = bediente_namen()

    # 1. Platzhalter-Domaenen. Dieselbe Eigenschaft wie in einrichten.sh: was
    # nach Beispiel aussieht, ist keine Installation.
    PLATZ_DOM = re.compile(
        r"\b(?:[a-z0-9-]+\.)?(?:[a-z0-9-]+\.home|home\.arpa|example\.(?:com|org|net|test))\b")
    reste = []
    for p in env_dateien():
        for z in p.read_text(errors="replace").splitlines():
            if z.lstrip().startswith("#"):
                continue
            m = PLATZ_DOM.search(z)
            if m and m.group(0) != dom and not m.group(0).endswith("." + dom):
                reste.append(
                    f"{p.relative_to(HIER)}: {z.split('=')[0].strip()} zeigt auf {m.group(0)}")
    if reste:
        befunde.append(
            f"{len(reste)} Adresse(n) tragen noch einen Beispiel-Namen, u.a. {reste[0]}. "
            "Steht er ueber ORIGIN, lehnt die App jede Anmeldung mit 403 ab, "
            "waehrend jede Leseprobe 200 liefert. Beheben: ./einrichten.sh"
        )
    print(f"  Beispiel-Adressen: {len(reste)} uebrig")

    # 2. Jeder ORIGIN muss ein Name sein, den der Eingang bedient. ORIGIN ist
    # die harte Sorte: stimmt er nicht, schlaegt jeder POST fehl.
    tot = []
    for p in env_dateien():
        wert = lies(p, "ORIGIN")
        if not wert or not wert.startswith("http"):
            continue
        wirt = wert.split("//", 1)[1].split("/")[0].split(":")[0]
        if not wirt.endswith(dom):
            continue  # eine fremde Domaene ist eine Aussage, kein Versehen
        sub = wirt[: -len(dom)].rstrip(".")
        if sub not in bedient:
            tot.append(f"{p.relative_to(HIER)}: ORIGIN={wert}")

    # 3. Die Kacheln der Schale. Sie baut ihre Links aus PUBLIC_SAGANTA_DOMAIN
    # und einer Unterdomaene je App; wer dort steht, muss auch bedient werden.
    katalog = SAG / "apps/shell/src/lib/catalog.ts"
    if katalog.exists():
        for sub, status in re.findall(
                r"appAdresse\('([a-z0-9-]+)'\)[^}]*?status:\s*'([a-z]+)'",
                katalog.read_text(errors="replace")):
            if status == "available" and sub not in bedient:
                tot.append(f"Kachel '{sub}' der Schale zeigt auf {sub}.{dom}")

    for t in tot:
        befunde.append(
            f"{t}. Diesen Namen bedient der Eingang nicht, und kein Dienst "
            "wird davon rot: die Adresse antwortet einfach nicht."
        )
    print(f"  Adressen gegen Vhosts: {len(tot)} ohne Eingang")

    # 4. JEDE konfigurierte Adresse, nicht nur ORIGIN und nicht nur die Kacheln.
    #
    # ★★ Die Eigenschaft statt der Aufzaehlung (2026-09-12). Die drei Bloecke
    # darueber suchen je ein bekanntes Fehlerbild; dieser sucht die Klasse. Zwei
    # Beispiele, beide am 2026-09-12 im laufenden Betrieb gefunden und beide von
    # keiner Pruefung erfasst:
    #
    #   `LIFEOPS_BASE_URL=http://life-ops-api:8000` im auth-proxy nannte einen
    #   Dienst, den diese Suite nicht mitliefert. Ergebnis waren zwei
    #   Protokollzeilen je Seitenaufruf der Schale und sonst nichts.
    #
    #   `CORS_ORIGINS=...,https://n.<domaene>` erlaubte einen Ursprung, den der
    #   Eingang nicht bedient.
    #
    # Beide Fehler sind dieselbe Sache: eine Adresse ohne Ziel. Was hier geprueft
    # wird, ist deshalb nicht "steht der richtige Name da", sondern "gibt es das,
    # worauf der Name zeigt": Dienstnamen gegen das aufgeloeste Compose, eigene
    # Unterdomaenen gegen das Caddyfile. Eine fremde Domaene bleibt unangetastet,
    # die ist eine Aussage (SMTP-Wirt, Abo-Quelle) und kein Versehen.
    namen = erreichbare_namen(d)
    ohne_dienst, ohne_vhost = [], []
    for p in env_dateien():
        for z in p.read_text(errors="replace").splitlines():
            if z.lstrip().startswith("#"):
                continue
            schluessel, trenner, wert = z.partition("=")
            schluessel = schluessel.strip()
            # ORIGIN hat oben einen eigenen Block mit der haerteren Aussage.
            if not trenner or schluessel == "ORIGIN":
                continue
            for stueck in wert.split(","):
                m = ADRESSE.match(stueck.strip())
                if not m:
                    continue
                # Nur den Wirt lesen, nie den ganzen Wert: in einer Adresse
                # koennen Zugangsdaten stehen, und ein Pruefer, der Geheimnisse
                # ausgibt, ist selbst ein Befund.
                wirt = m.group(1).rsplit("@", 1)[-1]
                # Eine Klammer heisst IPv6-Literal, und dort ist der Doppelpunkt
                # kein Port-Trenner. Ein blindes split(":") machte daraus einen
                # leeren Wirt und der waere als Befund gemeldet worden.
                wirt = (wirt.split("]")[0].strip("[") if wirt.startswith("[")
                        else wirt.split(":")[0])
                if not wirt or "$" in wirt:
                    continue  # leer oder eine Ersetzung, die erst Compose einsetzt
                if wirt in ("localhost", "127.0.0.1", "0.0.0.0", "::1"):
                    continue
                stelle = f"{p.relative_to(HIER)}: {schluessel}"
                if "." not in wirt:
                    if wirt not in namen:
                        ohne_dienst.append(f"{stelle} -> {wirt}")
                elif wirt == dom or wirt.endswith("." + dom):
                    sub = wirt[: -len(dom)].rstrip(".")
                    if sub not in bedient:
                        ohne_vhost.append(f"{stelle} -> {wirt}")

    for t in ohne_dienst:
        befunde.append(
            f"{t}. Diesen Dienst gibt es in der Suite nicht. Der Aufruf endet "
            "in einem Namensfehler, den nur das Protokoll zeigt. Entweder den "
            "Wert leeren (dann ist die Sache bewusst nicht konfiguriert) oder "
            "den Dienst dazunehmen."
        )
    for t in ohne_vhost:
        befunde.append(
            f"{t}. Diesen Namen bedient der Eingang nicht: erlaubt oder "
            "angesprochen wird damit etwas, das es hier nicht gibt."
        )
    print(f"  Adressen gegen Ziele: {len(ohne_dienst)} ohne Dienst, "
          f"{len(ohne_vhost)} ohne Vhost")

    return befunde


def pruefe_neustart(d):
    """Dienste, die einen Neustart des Wirts nicht ueberleben.

    ★★ Ein Dienst ohne Neustart-Regel kommt nach einem Stromausfall oder einem
    Kernel-Update nicht wieder, waehrend alle anderen wiederkommen. Es gibt
    keine Fehlermeldung dazu, nur eine Kachel, die nicht mehr antwortet, und
    einen Container im Zustand `exited`, den niemand ansieht, solange die
    Uebersicht "27 laufen" meldet.

    Der Briefkasten bringt genau das aus seinem eigenen Compose mit
    (`restart: "no"`), und dort ist es richtig: sein Datenverzeichnis liegt im
    Ursprungs-Haus in einem verschluesselten Tresor, der nach einem Neustart zu
    ist, und ein anlaufender Container legte daneben eine Klartext-Ablage an.
    In der Suite gibt es diesen Tresor nicht. Das Compose der Suite setzt die
    Zeile deshalb zurueck; diese Pruefung ist die Gegenprobe dazu und faengt
    zugleich jeden kuenftigen Teil, der dieselbe Vorsichtsmassnahme mitbringt.
    """
    ohne = [n for n, s in sorted(d["services"].items())
            if s.get("restart") in (None, "", "no")]
    for n in ohne:
        print(f"  Neustart-Regel: {n} hat keine")
    if not ohne:
        print(f"  Neustart-Regel: alle {len(d['services'])} Dienste kommen wieder")
    return [
        f"{n} startet nach einem Neustart des Wirts nicht von selbst. "
        "Alle anderen kommen wieder, dieser fehlt, und nichts meldet es. "
        "Wer das will (verschluesseltes Datenverzeichnis, das erst "
        "aufgeschlossen werden muss), setzt es in einer eigenen "
        "docker-compose.override.yml wieder auf \"no\"."
        for n in ohne
    ]


def pruefe_kalender_zustand():
    """Ein Datenbestand, der ein aelteres Geheimnis kennt als die Konfiguration.

    ★★ `docker compose down -v` raeumt die benannten Volumes ab, NICHT die
    Bind-Verzeichnisse. Der Kalender legt seine Datenbank unter
    `teile/kalender/data` ab, und dort steht der Feed-Token, mit dem sich sein
    BFF anmeldet: er wird beim allerersten Start aus der Konfiguration
    uebernommen und danach nie wieder. Wer die .env neu erzeugen laesst und den
    Datenbestand behaelt, hat zwei verschiedene Werte. Sichtbar ist davon nur
    „Kalender-BFF nicht erreichbar" in der Oberflaeche, und im Protokoll ein
    `token-login fehlgeschlagen: 401`.
    """
    db = TEILE / "kalender/data/kalender.db"
    soll = lies(TEILE / "kalender/.env", "FEED_TOKEN")
    if not db.exists() or not soll:
        print("  Kalender-Datenbestand: neu (nichts zu vergleichen)")
        return []
    try:
        import sqlite3
        with sqlite3.connect(f"file:{db}?mode=ro", uri=True) as c:
            zeile = c.execute(
                "select value from settings where key = 'feed_token'").fetchone()
    except Exception as e:
        print(f"  Kalender-Datenbestand: nicht lesbar ({type(e).__name__})")
        return []
    if zeile and zeile[0] != soll:
        print("  Kalender-Datenbestand: Token weicht ab")
        return [
            "Der Kalender-Datenbestand kennt einen anderen Feed-Token als "
            "teile/kalender/.env. Sein BFF bekommt damit 401, und die App "
            "meldet „Kalender-BFF nicht erreichbar\". Entweder "
            "teile/kalender/data loeschen (Termine gehen verloren) oder den "
            "Token aus der Datenbank in die .env uebernehmen."
        ]
    print("  Kalender-Datenbestand: Token passt")
    return []


def pruefe_teile_stand():
    """Wie weit ist jeder Klon unter teile/ hinter seinem Zweig?

    Bewusst OHNE Netzzugriff: kein `git fetch`. Gemessen wird gegen die zuletzt
    geholten Fernzweige, die im Klon schon liegen. Ein Pruefskript, das ins Netz
    geht, scheitert ohne Netz und blockiert dann eine Inbetriebnahme, die sonst
    laufen wuerde. Wer den Stand frisch will, ruft vorher `./holen.sh
    --aktualisieren`; wer es nicht tut, sieht hier mindestens den Stand vom
    letzten Mal.
    """
    befunde = []
    if not TEILE.is_dir():
        return ["teile/ fehlt ganz: erst ./holen.sh"]
    for teil in sorted(p.name for p in TEILE.iterdir() if (p / ".git").exists()):
        pfad = TEILE / teil
        fern = None
        for kandidat in ("gitea/main", "origin/main", "gitea/master", "origin/master"):
            p = subprocess.run(["git", "rev-parse", "--verify", "--quiet", kandidat],
                               cwd=pfad, capture_output=True, text=True)
            if p.returncode == 0:
                fern = kandidat
                break
        if fern is None:
            befunde.append(f"{teil}: kein Fernzweig im Klon, Stand nicht pruefbar")
            continue
        p = subprocess.run(["git", "rev-list", "--count", f"HEAD..{fern}"],
                           cwd=pfad, capture_output=True, text=True)
        if p.returncode != 0:
            befunde.append(f"{teil}: Stand nicht lesbar ({p.stderr.strip()[:80]})")
            continue
        hinter = int(p.stdout.strip() or 0)
        if hinter:
            befunde.append(
                f"{teil}: {hinter} Commit(s) hinter {fern}. "
                f"Der Klon unter teile/ ist nicht versioniert und veraltet lautlos; "
                f"nachziehen mit ./holen.sh --aktualisieren")
    return befunde


def main():
    print("== Suite pruefen")
    d = compose_config()
    print(f"  Compose gueltig: {len(d['services'])} Dienste")

    befunde = (pruefe_eingang(d) + pruefe_start(d) + pruefe_geheimnisse()
               + pruefe_adressen(d) + pruefe_neustart(d) + pruefe_kalender_zustand()
               + pruefe_teile_stand())

    print()
    if befunde:
        print("BEFUNDE:")
        for b in befunde:
            print(f"  - {b}")
        return 1
    print("OK: kein Befund.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
