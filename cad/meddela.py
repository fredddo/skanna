"""Claude → Skanna.app: status och svar som visas i appen (skriver <skanning>/cad/claude.json).

  meddela.py <skanning> --mottaget                      # kvittera allt i svar.json som mottaget + status "arbetar"
  meddela.py <skanning> --status arbetar "Mäter läppen …"
  meddela.py <skanning> --svar "Läppen är inlagd …" [--svar-pa TID]   # TID = användarmeddelandets "tid"; utan = senaste
  meddela.py <skanning> --klar ["Klart – modellen är uppdaterad"]
  meddela.py <skanning> --trad TID --status arbetar|fraga|klar [--titel "Hål i locket"]   # trådens läge (TID = rot-tid eller fråge-id)
  meddela.py <skanning> --svar "…" --svar-pa TID   # TID = valfritt meddelande i tråden (användarens eller Claudes)
"""
import argparse
import json
from datetime import datetime
from pathlib import Path

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

cad = Path(a.scan).expanduser() / "cad"
cad.mkdir(exist_ok=True)
path = cad / "claude.json"
info = json.loads(path.read_text()) if path.exists() else {"meddelanden": []}
svar = json.loads((cad / "svar.json").read_text())["svar"] if (cad / "svar.json").exists() else []
latest = max((s["tid"] for s in svar), default=None)
now = datetime.now().astimezone().isoformat(timespec="seconds")

if a.mottaget:
    info["mottaget"] = latest
    info["status"], info["status_text"] = "arbetar", "Har tagit emot ditt meddelande och arbetar med det …"
if a.trad:
    # trådens läge: --trad TID --status arbetar|fraga|klar [--titel "…"]
    if not a.status or a.status[0] not in ("arbetar", "fraga", "klar"):
        ap.error("--trad kräver --status arbetar|fraga|klar")
    t = info.setdefault("tradar", {}).setdefault(a.trad, {})
    t["status"] = a.status[0]
    if a.titel:
        t["titel"] = a.titel
elif a.status:
    if len(a.status) != 2:
        ap.error("--status tar STATUS och TEXT")
    info["status"], info["status_text"] = a.status
if a.svar:
    info.setdefault("meddelanden", []).append({"tid": now, "text": a.svar, "svar_pa": a.svar_pa or latest})
if a.klar:
    info["status"], info["status_text"] = "klar", a.klar
info["uppdaterad"] = now
path.write_text(json.dumps(info, ensure_ascii=False, indent=2))
print(path, info.get("status"))
