#!/bin/zsh
# Väntar tills något projekts cad/svar.json ändras/skapas, eller en ny skanning (modell-mm.obj) blir klar.
# Täcker video-skanningar (~/Downloads|Desktop|Documents/*.modell*) och projekt i ~/Documents/Skanna/*.
# Skriver ut vad som ändrades och avslutar. Valfritt: en projektmapp som argument = bevaka bara den.
sig() {
  if [[ -n "$1" ]]; then
    find "$1" -maxdepth 3 \( -path '*/cad/svar.json' -o -path '*/modell/modell-mm.obj' \) -exec stat -f '%N %m' {} + 2>/dev/null | sort
  else
    { find ~/Downloads ~/Desktop ~/Documents -maxdepth 3 \( -path '*.modell*/cad/svar.json' -o -path '*.modell*/modell/modell-mm.obj' \) -exec stat -f '%N %m' {} + 2>/dev/null
      find ~/Documents/Skanna -maxdepth 4 \( -path '*/cad/svar.json' -o -path '*/modell/modell-mm.obj' \) -exec stat -f '%N %m' {} + 2>/dev/null; } | sort -u
  fi
}
start="$(sig "$1")"
for i in {1..1700}; do
  now="$(sig "$1")"
  if [[ "$now" != "$start" ]]; then sleep 4; echo "ÄNDRAT:"; diff <(echo "$start") <(sig "$1") | grep '^>'; exit 0; fi
  sleep 2
done
echo timeout
