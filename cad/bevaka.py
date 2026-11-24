"""Vänta tills det finns något för Claude att göra (anropas av bevaka.sh).

Avslutar med en rad per projekt och kod 0 när
- ett projekt har användarmeddelanden i cad/svar.json som är nyare än claude.json → "mottaget" (dvs. inte kvitterade) –
  också sådana som kom innan bevakningen startade, så inget meddelande missas mellan två bevakningar;
- en ny skanning (modell/modell-mm.obj) har blivit klar eller ändrats sedan start.
Annars "timeout" efter --sek sekunder (standard 3400).

Utan projekt bevakas alla projekt (video-skanningar *.modell* i Hämtade filer/Skrivbord/Dokument, ~/Documents/Skanna,
appens projektmapp och SKANNA_PROJEKTROT). Då räknas bara okvitterade meddelanden från de senaste --fonster minuterna
(standard 120), så att gamla projekt med obesvarade meddelanden inte väcker Claude om och om igen.
Med ett projekt som argument räknas alla okvitterade meddelanden i det projektet.
"""
import argparse
import os
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lagring  # noqa: E402


def rotter():
    hem = Path.home()
    r = [hem / "Documents" / "Skanna"]
    for dom in ("local.skanna.beta", "local.skanna"):
        try:
            s = subprocess.run(["defaults", "read", dom, "projektRot"], capture_output=True, text=True, timeout=5).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            s = ""
        if s:
            r.append(Path(s))
    if os.environ.get("SKANNA_PROJEKTROT"):
        r.append(Path(os.environ["SKANNA_PROJEKTROT"]))
    return [p for i, p in enumerate(r) if p.is_dir() and p not in r[:i]]


def projekt_alla():
    hem = Path.home()
    ut = set()
    for d in (hem / "Downloads", hem / "Desktop", hem / "Documents"):
        try:
            ut.update(p for p in d.iterdir() if ".modell" in p.name and p.is_dir())
        except OSError:
            pass
    for r in rotter():
        try:
            ut.update(p for p in r.iterdir() if p.is_dir() and ((p / "cad").is_dir() or (p / "modell").is_dir()))
        except OSError:
            pass
    return sorted(ut)


def okvitterade(projekt, efter=None):
    """Användarmeddelanden som Claude inte kvitterat (tid > mottaget), och nyare än `efter` om den är satt."""
    cad = projekt / "cad"
    try:
        svar = (lagring.las_json(cad / "svar.json", {}) or {}).get("svar", [])
        claude = lagring.las_json(cad / "claude.json", {}) or {}
    except lagring.Trasig as e:
        print(f"Varning: {projekt}: {e}", file=sys.stderr)
        return []
    mott = lagring.tid_datum(claude.get("mottaget"))
    ut = []
    for s in svar if isinstance(svar, list) else []:
        d = lagring.tid_datum(s.get("tid")) if isinstance(s, dict) else None
        if d and (mott is None or d > mott) and (efter is None or d > efter):
            ut.append(s)
    return ut


def skanningar(projekt_lista):
    out = {}
    for p in projekt_lista:
        f = p / "modell" / "modell-mm.obj"
        try:
            out[str(f)] = f.stat().st_mtime_ns
        except OSError:
            pass
    return out


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("projekt", nargs="?")
    ap.add_argument("--sek", type=float, default=3400)
    ap.add_argument("--fonster", type=float, default=120, help="minuter bakåt för okvitterade meddelanden (alla projekt)")
    ap.add_argument("--intervall", type=float, default=2)
    a = ap.parse_args(argv)
    ett = Path(a.projekt).expanduser().resolve() if a.projekt else None
    lista = (lambda: [ett]) if ett else projekt_alla
    efter = None if ett else datetime.now().astimezone() - timedelta(minutes=a.fonster)
    start_skan = skanningar(lista())
    slut = time.monotonic() + a.sek
    while True:
        alla = lista()
        rader = []
        for p in alla:
            n = okvitterade(p, efter)
            if n:
                rader.append(f"NYTT: {p} ({len(n)} meddelande{'n' if len(n) > 1 else ''}, senast {n[-1].get('tid')})")
        for f, m in skanningar(alla).items():
            if start_skan.get(f) != m:
                rader.append(f"SKANNING: {f}")
        if rader:
            print("ÄNDRAT:")
            print("\n".join(rader), flush=True)
            return 0
        if time.monotonic() > slut:
            print("timeout")
            return 0
        time.sleep(a.intervall)


if __name__ == "__main__":
    sys.exit(main())
