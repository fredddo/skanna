#!/bin/zsh
# Hela testsviten för Skanna Beta. Körs före varje ombygge av Beta (bygg-beta.sh) och när som helst:
#   tester/testa.sh                 # allt
#   tester/testa.sh vrid            # bara UI-scenarier vars namn innehåller "vrid" (Python-testerna körs ändå)
#   SKANNA_TESTBILDER=<mapp> tester/testa.sh   # en skärmbild per UI-scenario
# Steg: 1) skripten är giltiga  2) appen och CLI:t kompilerar  3) testprojektet byggs (cache: tester/.bygg)
#       4) Python-tester (cad/*.py)  5) UI-scenarier (tester/ui, appen körs osynligt).
# Inget i användarens projekt eller i Skanna Beta rörs; allt sker i temporära kopior.
set -u
cd "$(dirname "$0")/.."
HEM="$(pwd)"
PY="$HEM/.venv/bin/python"
BYGG="$HEM/tester/.bygg"; mkdir -p "$BYGG"
FIXTUR="$BYGG/Testlåda"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fel=0
steg() { print -P "%B$1%b" }
ok() { echo "  ✓ $1" }
nej() { echo "  ✗ $1"; fel=1 }

steg "1. Skript"
for f in bygg-beta.sh bevaka.sh bygg_projekt.sh tester/testa.sh ikon/bygg_ikon.sh; do
  zsh -n "$f" 2>"$TMP/sh.txt" && ok "$f" || { nej "$f"; cat "$TMP/sh.txt" }
done
"$PY" -m py_compile cad/*.py motor/*.py 2>"$TMP/py.txt" && ok "cad/*.py och motor/*.py kompilerar" || { nej "cad/*.py, motor/*.py"; cat "$TMP/py.txt" }

steg "2. Appen kompilerar"
if swiftc -parse-as-library -typecheck app/*.swift 2>"$TMP/sw.txt" && swiftc -parse-as-library -typecheck main.swift 2>>"$TMP/sw.txt"; then
  ok "app/*.swift och skanna-cli"
else
  nej "kompileringsfel"; grep -E "error" "$TMP/sw.txt" | head -20
fi

steg "3. Testprojektet"
nyckel=$( { cat tester/fixtur/**/*(.N) cad/*.py bygg_projekt.sh } | shasum | cut -c1-16)
if [[ -f "$FIXTUR/.nyckel" && "$(cat "$FIXTUR/.nyckel")" == "$nyckel" ]]; then
  ok "byggt sedan förut (oförändrade skript)"
else
  rm -rf "$FIXTUR"; cp -R tester/fixtur/Testlåda "$FIXTUR"
  if SKANNA_HEM="$HEM" ./bygg_projekt.sh "$FIXTUR" >"$TMP/fixtur.txt" 2>&1; then
    echo "$nyckel" > "$FIXTUR/.nyckel"; ok "byggt (lada, lock, insats, fotter)"
  else
    nej "testprojektet gick inte att bygga"; tail -20 "$TMP/fixtur.txt"; exit 1
  fi
fi

steg "4. Python"
if (cd tester/python && SKANNA_TESTFIXTUR="$FIXTUR" "$PY" -m unittest discover -p 'test_*.py' >"$TMP/pyt.txt" 2>&1); then
  ok "$(grep -E '^Ran ' "$TMP/pyt.txt")"
else
  nej "Python-tester underkända"; grep -vE '^\.+$' "$TMP/pyt.txt" | tail -40
fi

steg "5. UI"
if swiftc -O $(ls app/*.swift | grep -v SkannaApp.swift) tester/ui/*.swift -o "$BYGG/uitest" 2>"$TMP/ui.txt"; then
  SKANNA_HEM="$HEM" SKANNA_INGEN_MIK=1 SKANNA_ALDRIG_SLICER=1 SKANNA_PROJEKTROT="$TMP/rot" SKANNA_TESTFIXTUR="$FIXTUR" \
    SKANNA_TESTFILTER="${1:-}" perl -e 'alarm 900; exec @ARGV' "$BYGG/uitest" >"$TMP/uiut.txt" 2>&1
  r=$?
  grep -E "^  [✓✗]|^      –|^UI:" "$TMP/uiut.txt"
  [[ $r -eq 0 ]] || { nej "UI-scenarier underkända (kod $r)"; grep -qE "^UI:" "$TMP/uiut.txt" || tail -20 "$TMP/uiut.txt" }
else
  nej "UI-testerna kompilerar inte"; grep -E "error" "$TMP/ui.txt" | head -20
fi

echo
if [[ $fel -eq 0 ]]; then print -P "%F{green}Alla tester godkända.%f"; else print -P "%F{red}Tester underkända.%f"; fi
exit $fel
