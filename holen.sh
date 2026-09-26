#!/usr/bin/env bash
# Holt die sechs Teile der Suite nach ./teile/.
#
# Das Dach-Repo enthaelt bewusst keinen Anwendungscode. Die Teile bleiben
# eigenstaendige Repos, weil sie es auch ohne die Suite sind: der Kalender etwa
# wird anderswo als einzelner Dienst betrieben. Ein Monorepo haette das
# zerschnitten.
#
# Kein git-submodule: Submodule pinnen einen Commit und sind beim Aktualisieren
# eine eigene Fehlerquelle (detached HEAD, vergessenes `--recurse`). Hier ist
# ein Klon ein Klon, und `--aktualisieren` ist ein `git pull` je Teil.
set -euo pipefail
cd "$(dirname "$0")"

TEILE=(saganta kalender postfach lager mealprep fitness)
ZIEL=teile

# Adresse eines Teils. Vorgabe ist das flache Schema <basis>/<teil>.git, denn so
# liegen die Repos nach der Veroeffentlichung unter einem Konto.
#
# ★ Je Teil ueberschreibbar. Gebraucht wurde das, solange `postfach` in der
# internen Gitea unter `homelab/` lag und die uebrigen fuenf unter `apps/`: ein
# Klon brach dann mitten im Lauf ab. Seit dem 2026-09-06 liegen alle sechs unter
# `apps/`, der Sonderfall ist weg. Die Moeglichkeit bleibt, weil sie nichts
# kostet und beim naechsten Umzug eines Teils wieder traegt:
#   SAGANTA_GIT_POSTFACH=http://.../andere-org/postfach.git ./holen.sh
adresse_von() {
  local teil=$1
  local schluessel="SAGANTA_GIT_${teil^^}"
  local eigen=${!schluessel:-}
  if [[ -n $eigen ]]; then
    printf '%s' "$eigen"
  else
    printf '%s/%s.git' "${SAGANTA_GIT_BASIS%/}" "$teil"
  fi
}

usage() {
  cat <<'EOF'
Aufrufe:
  SAGANTA_GIT_BASIS=https://github.com/<konto> ./holen.sh
  SAGANTA_GIT_BASIS=... ./holen.sh --aktualisieren
  ./holen.sh --status
EOF
}

status() {
  for t in "${TEILE[@]}"; do
    if [[ -d $ZIEL/$t/.git ]]; then
      stand=$(git -C "$ZIEL/$t" log -1 --format='%h %ad %s' --date=short 2>/dev/null | cut -c1-60)
      schmutzig=$(git -C "$ZIEL/$t" status --porcelain | wc -l)
      printf '  %-10s %s%s\n' "$t" "$stand" "$([[ $schmutzig -gt 0 ]] && echo "  [$schmutzig geaendert]")"
    else
      printf '  %-10s fehlt\n' "$t"
    fi
  done
}

basis_pruefen() {
  # Nur fuer die Aufrufe, die wirklich ins Netz gehen. --status liest
  # ausschliesslich lokale Klone und soll ohne Konfiguration funktionieren.
  : "${SAGANTA_GIT_BASIS:?SAGANTA_GIT_BASIS setzen, z.B. https://github.com/<konto>}"
}

holen() {
  basis_pruefen
  mkdir -p "$ZIEL"
  for t in "${TEILE[@]}"; do
    if [[ -d $ZIEL/$t/.git ]]; then
      echo "== $t: vorhanden, uebersprungen (--aktualisieren zum Nachziehen)"
      continue
    fi
    echo "== $t klonen"
    git clone --depth 1 "$(adresse_von "$t")" "$ZIEL/$t"
  done
  echo; status
}

aktualisieren() {
  basis_pruefen
  for t in "${TEILE[@]}"; do
    [[ -d $ZIEL/$t/.git ]] || { echo "== $t fehlt, erst ./holen.sh"; continue; }
    # Nur wenn sauber: ein Pull ueber lokale Aenderungen hinweg ist der
    # Handgriff, bei dem man hinterher nicht mehr weiss, was der eigene Stand war.
    if [[ -n $(git -C "$ZIEL/$t" status --porcelain) ]]; then
      echo "== $t hat lokale Aenderungen, uebersprungen"
      continue
    fi
    echo "== $t aktualisieren"
    git -C "$ZIEL/$t" pull --ff-only
  done
  echo; status
}

case "${1:-}" in
  "") holen ;;
  --aktualisieren) aktualisieren ;;
  --status) status ;;
  *) usage; exit 1 ;;
esac
