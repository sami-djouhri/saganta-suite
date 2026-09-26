# Die Konfiguration der Suite

`./einrichten.sh` legt die `.env` an und fragt dabei nach dem, was ein Mensch
entscheiden muss. Diese Datei erklaert, was in den Feldern steht, und dient als
Vorlage zum Nachschlagen.

★ **Hier stehen nur die Werte, die ein Mensch entscheiden muss.** Alle
Geheimnisse erzeugt `einrichten.sh` selbst und schreibt sie in die `.env` des
jeweiligen Teils. Grund: `include:` loest `env_file: .env` relativ zum
eingebundenen Compose auf, also nach `teile/<teil>/.env`. Die `.env` im
Dach-Verzeichnis erreicht die Teile **nicht**, sie versorgt nur den Eingang und
die `${...}`-Ersetzungen in den Teil-Composes.

Und weil ein von Hand abgetipptes Geheimnis der wahrscheinlichste Fehler an
dieser Stelle ist, und einer, der nicht auffaellt: der Dienst laeuft, er
antwortet nur mit 401.

## Muss gesetzt sein

| Feld | Bedeutung |
|---|---|
| `SAGANTA_DOMAENE` | Unter welchem Namen die Suite erreichbar ist. Die Apps bekommen Unterdomaenen davon: `kalender.<domaene>`, `post.<domaene>` und so weiter. Ohne Wert startet der Eingang nicht, statt unter einem Platzhalternamen hochzufahren, den niemand erreicht. |

## Zertifikate

| Feld | Bedeutung |
|---|---|
| `SAGANTA_TLS` | **Leer** = echte Zertifikate von Let's Encrypt. Dafuer muessen die Unterdomaenen oeffentlich auf diesen Rechner zeigen und Port 80 erreichbar sein. **`internal`** = Caddys eigene CA, fuer den Betrieb im Heimnetz ohne oeffentlichen Namen. Der Browser warnt einmal, danach ist es ein sicherer Kontext, und den brauchen mehrere Apps tatsaechlich (Standortabfrage, Verschluesselung im Browser). |
| `SAGANTA_EMAIL` | Nur fuer Let's Encrypt, fuer Ablaufwarnungen. Bei `internal` egal. |

## Ports des Wirts

`SAGANTA_HTTP_PORT` (Vorgabe 80) und `SAGANTA_HTTPS_PORT` (443). Nur aendern,
wenn die Ports schon belegt sind.

## Wo die Daten liegen

| Feld | Bedeutung |
|---|---|
| `POSTFACH_DATEN` | Der Briefkasten legt Scans und seine Datenbank hier ab. **Das Verzeichnis muss existieren**, Docker legt es bewusst nicht an: im Haus liegt es in einem verschluesselten Tresor, und ein automatisch angelegtes leeres Verzeichnis waere dort genau der stille Fehler, vor dem die Einstellung schuetzt (frische Datenbank, Briefe im Klartext daneben, nichts sieht nach Fehler aus). Vorgabe `./daten/postfach`. |

## Was einrichten.sh fuellt

Nicht von Hand setzen. Die Werte muessen an mehreren Stellen gleich sein, und
das Skript ist die Stelle, die das sicherstellt.

| Feld | Wozu | Wohin |
|---|---|---|
| `SAGANTA_BACKEND_SECRET` | verbindet die Oberflaechen mit ihren Backends | alle Teile |
| `LAGER_TENANT_SECRET` u.a. | je App eines, weist die Mandanten-Kennung nach | die App und ihre Aufrufer |
| `KALENDER_FEED_TOKEN` | Lesezugriff auf den Kalender ohne Anmeldung | kalender, postfach, mealprep |
| `DEFAULT_OWNER_SUB` | die Kennung des ersten Kontos | lager, mealprep, fitness, kalender |

★ Die Mandanten-Geheimnisse muessen sich **zwischen** den Gruppen unterscheiden,
das ist ihr Zweck. **Innerhalb** einer Gruppe muessen sie gleich sein: weicht
eines ab, bekommt genau dieser Weg beim Scharfschalten 401, und zwar erst dann,
also lange nach dem Tippfehler.

## Der Beobachtungsschalter

`TENANT_HEADER_ENFORCE` bleibt zunaechst `0` (beobachten). Erst auf `1` stellen,
wenn ueber Tage nichts Unsigniertes mehr in den Protokollen steht.

⚠️ Null Meldungen sind kein Beweis. Sie kommen auch, wenn niemand die Apps
benutzt hat.

## Warum diese Datei nicht `.env.example` heisst

Der Arbeitsplatz, an dem die Suite entsteht, schuetzt Dateien mit `.env` im
Namen gegen versehentliches Schreiben und Lesen. Das ist die richtige Vorgabe,
und eine Vorlage ist die Ausnahme davon nicht wert. `einrichten.sh` erzeugt die
`.env` ohnehin, ein Kopieren von Hand entfaellt damit.
