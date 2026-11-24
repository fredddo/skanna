"""Claude → Skanna.app: status och svar som visas i appen (skriver <projekt>/cad/claude.json).

  meddela.py <projekt> --mottaget                      # kvittera allt i svar.json som mottaget + status "arbetar"
  meddela.py <projekt> --status arbetar "Mäter läppen …"
  meddela.py <projekt> --svar "Läppen är inlagd …" --svar-pa TID   # TID = rot-tid eller ett meddelande i tråden
  meddela.py <projekt> --svar "Hej!"                   # utan --svar-pa: fristående meddelande (ingen tråd)
  meddela.py <projekt> --klar ["Klart – modellen är uppdaterad"]
  meddela.py <projekt> --trad TID --status arbetar|fraga|klar [--titel "Hål i locket"]   # trådens läge

Filen skrivs atomiskt under projektets lås (flera trådar/agenter samtidigt går bra). Varje meddelande får en unik tid
med millisekunder; skriv ut den (står sist på raden) om du vill svara på ditt eget meddelande senare.
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lagring  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("scan")
ap.add_argument("--mottaget", action="store_true")
ap.add_argument("--status", nargs="+", metavar="STATUS [TEXT]")
ap.add_argument("--trad", metavar="TID")
ap.add_argument("--titel")
ap.add_argument("--svar")
ap.add_argument("--svar-pa")
ap.add_argument("--klar", nargs="?", const="Klart.")
a = ap.parse_args()

if a.trad and (not a.status or a.status[0] not in ("arbetar", "fraga", "klar")):
    ap.error("--trad kräver --status arbetar|fraga|klar")
if not a.trad and a.status and len(a.status) != 2:
    ap.error("--status tar STATUS och TEXT")

cad = Path(a.scan).expanduser() / "cad"
cad.mkdir(parents=True, exist_ok=True)
path = cad / "claude.json"
ut = {}


def andra(info):
    if not isinstance(info, dict):
        info = {}
    info.setdefault("meddelanden", [])
    svar = (lagring.las_json(cad / "svar.json", {"svar": []}) or {}).get("svar", [])
    tider = [s.get("tid") for s in svar if isinstance(s, dict)]
    latest = max((t for t in tider if lagring.tid_datum(t)), key=lagring.tid_datum, default=None)
    alla_tider = tider + [m.get("tid") for m in info["meddelanden"]] + [info.get("uppdaterad")]
    now = lagring.ny_tid(alla_tider)
    if a.mottaget:
        info["mottaget"] = latest
        info["status"], info["status_text"] = "arbetar", "Har tagit emot ditt meddelande och arbetar med det …"
    if a.trad:
        t = info.setdefault("tradar", {}).setdefault(a.trad, {})
        t["status"] = a.status[0]
        if a.titel:
            t["titel"] = a.titel
    elif a.status:
        info["status"], info["status_text"] = a.status
    if a.svar:
        m = {"tid": now, "text": a.svar}
        if a.svar_pa:
            m["svar_pa"] = a.svar_pa
        info["meddelanden"].append(m)
        ut["tid"] = now
    if a.klar:
        info["status"], info["status_text"] = "klar", a.klar
    info["uppdaterad"] = now
    ut["status"] = info.get("status")
    return info


lagring.uppdatera_json(path, andra, {"meddelanden": []})
print(path, ut.get("status"), ut.get("tid", ""))
