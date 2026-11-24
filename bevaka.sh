#!/bin/zsh
# Väntar tills Claude har något att göra: okvitterade meddelanden i något projekts cad/svar.json (nyare än
# claude.json → "mottaget", också sådana som kom medan Claude arbetade) eller en ny skanning (modell-mm.obj).
# Skriver ut vad det gäller och avslutar. Valfritt: en projektmapp som argument = bevaka bara den.
# Logiken ligger i cad/bevaka.py (bara stdlib); se den för flaggor (--sek, --fonster).
HEM="$(cd "$(dirname "$0")" && pwd)"
PY="$HEM/.venv/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"
exec "$PY" "$HEM/cad/bevaka.py" "$@"
