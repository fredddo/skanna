#!/bin/zsh
# Bygg alla delar i ett Skanna-projekt: kör <projekt>/cad/skript/*.py i namnordning med Skanna-hemmets Python.
# Äldre skanningar utan skript (men med modell-cad.step) byggs med cad/bygg_alla.sh som förut.
set -e
HEM="${SKANNA_HEM:-$(cd "$(dirname "$0")" && pwd)}"
export SKANNA_HEM="$HEM"
P="${1:?projektmapp}"
PY="$HEM/.venv/bin/python"
if [[ -x "$P/cad/bygg.sh" ]]; then exec "$P/cad/bygg.sh" "$P"; fi
setopt null_glob
skript=("$P"/cad/skript/*.py)
# Äldre skanning (HiKOKI-projektet): modell-cad.step byggs med samma skript som den vanliga Skanna.app använder, så båda
# apparna bygger likadant. Har projektet dessutom del-skript (t.ex. en mall som lagts till) körs de efteråt – det äldre
# bygget skriver om delar.json/geometri.json, och del-skripten lägger sedan till sina delar och mått.
if [[ -f "$P/cad/modell-cad.step" ]]; then
  LEGACY="${SKANNA_LEGACY_BYGG:-$HOME/git/worldforge/local/fotoskanning/cad/bygg_alla.sh}"
  [[ -x "$LEGACY" ]] || LEGACY="$HEM/cad/bygg_alla.sh"
  echo "== äldre skanning: $LEGACY"
  "$LEGACY" "$P"
elif (( ${#skript} == 0 )); then
  echo "Inga del-skript i $P/cad/skript/ – inget att bygga." >&2
  exit 1
fi
for s in $skript; do
  echo "== ${s:t}"
  "$PY" "$s" "$P"
done
