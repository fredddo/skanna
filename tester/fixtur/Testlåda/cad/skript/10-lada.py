"""Testprojektets låda: låda (design), lock (design) och insats (design, underdel till lådan). Gör flera delar,
så att Radera av en av dem lämnar skriptet kvar. Körs av tester/testa.sh via bygg_projekt.sh."""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.environ.get("SKANNA_HEM", os.path.expanduser("~/git/worldforge/local/skanna-v2")), "cad"))
from projekt import Projekt  # noqa: E402

from build123d import Align, Box, BuildPart, Mode, Pos  # noqa: E402

prj = Projekt(sys.argv[1])
P = prj.parametrar("Låda", {"längd": (60.0, "mm"), "bredd": (40.0, "mm"), "höjd": (20.0, "mm"), "vägg": (2.0, "mm")})
L, B, H, v = P["längd"], P["bredd"], P["höjd"], P["vägg"]
with BuildPart() as lada:
    Box(L, B, H, align=(Align.CENTER, Align.CENTER, Align.MIN))
    with BuildPart(mode=Mode.SUBTRACT):
        Pos(0, 0, v) * Box(L - 2 * v, B - 2 * v, H, align=(Align.CENTER, Align.CENTER, Align.MIN))
with BuildPart() as lock:
    Pos(0, 0, H + 15) * Box(L, B, 2, align=(Align.CENTER, Align.CENTER, Align.MIN))
with BuildPart() as insats:
    Pos(0, 0, v) * Box(L / 2, B / 2, 6, align=(Align.CENTER, Align.CENTER, Align.MIN))
prj.del_("lada", "Låda", lada.part, farg="#2E7DD7", beskrivning="Testlådan", bambu={"wall_loops": 3, "plast": "PETG"})
prj.del_("lock", "Lock", lock.part, farg="#E0A030", beskrivning="Lock ovanför")
prj.del_("insats", "Insats", insats.part, farg="#3BA55C", beskrivning="Underdel till lådan", utskrift=False)
d = json.loads((prj.cad / "delar.json").read_text())
for x in d["delar"]:
    if x["id"] == "insats":
        x["foralder"] = "lada"
(prj.cad / "delar.json").write_text(json.dumps(d, ensure_ascii=False, indent=2))
prj.spara(beskrivning="Testprojekt för tester/testa.sh")
